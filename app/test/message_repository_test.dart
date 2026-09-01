// MessageRepository 单测：drift 内存库 + fake ApiClient，
// 验证离线发送入队、同步落库/推进锚点、补发队列、历史解密。
//
// 需要 LIBSODIUM_PATH 指向 libsodium.dll（与 shared 单测一致）。

import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz/data/burn_after_settings.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/data/message_repository.dart';
import 'package:einz_shared/einz_shared.dart';

/// fake ApiClient：不真正联网，返回预先编排的数据。
class FakeApi extends ApiClient {
  FakeApi({List<String>? posted}) : posted = posted ?? [], super('http://fake');

  /// 已成功上传的 message_id（记录 postMessage 调用）。
  final List<String> posted;

  /// 编排的 sync 页（每页是一个 SyncPage）。
  List<({List<MessageEnvelope> messages, List<Map<String, dynamic>> attachmentsMeta, int lastSequence, bool hasMore})> pages = [];

  /// 编排的 /space 设备列表（person 映射测试用）。
  List<SpaceDevice> spaceDevices = [];

  @override
  Future<SpaceResult> getSpace(String token) async {
    return SpaceResult(spaceId: 'space-test', devices: spaceDevices);
  }

  @override
  Future<PostMessageResult> postMessage(MessageEnvelope env, String token) async {
    posted.add(env.messageId);
    return PostMessageResult(messageId: env.messageId, serverSequence: posted.length, createdAt: 1000);
  }

  @override
  Future<({List<MessageEnvelope> messages, List<Map<String, dynamic>> attachmentsMeta, int lastSequence, bool hasMore})> sync(
    String token, {
    int after = 0,
    int limit = 100,
  }) async {
    final page = pages.isEmpty
        ? (messages: <MessageEnvelope>[], attachmentsMeta: <Map<String, dynamic>>[], lastSequence: after, hasMore: false)
        : pages.removeAt(0);
    // 模拟 Server 分配 server_sequence（真实 Server 在同步响应中携带，见 PROTOCOL.md §5.2）
    var seq = after;
    final messages = <MessageEnvelope>[
      for (final env in page.messages)
        () {
          seq++;
          return MessageEnvelope.fromJson({...env.toJson(), 'server_sequence': seq});
        }(),
    ];
    return (
      messages: messages,
      attachmentsMeta: page.attachmentsMeta,
      lastSequence: seq,
      hasMore: page.hasMore,
    );
  }
}

void main() {
  setUpAll(() async {
    await sodium();
  });

  late LocalDatabase db;
  late Uint8List spaceKey;

  setUp(() async {
    db = LocalDatabase.forTesting(NativeDatabase.memory());
    spaceKey = await generateSpaceKey();
  });

  tearDown(() async {
    await db.close();
  });

  MessageRepository makeRepo(FakeApi api, {String? token}) => MessageRepository(
        db: db,
        api: api,
        spaceKey: spaceKey,
        spaceId: 'space-test',
        deviceId: 'dev-a',
        keyVersion: 1,
        token: token,
      );

  test('person 身份判断：同 person 不同设备显示 me，对方设备显示 peer', () async {
    final api = FakeApi();
    api.spaceDevices = [
      const SpaceDevice(deviceId: 'dev-a', personId: 'person-a', status: 'active'),
      const SpaceDevice(deviceId: 'dev-a2', personId: 'person-a', status: 'active'),
      const SpaceDevice(deviceId: 'dev-b', personId: 'person-b', status: 'active'),
    ];
    final repo = makeRepo(api, token: 'tok');
    await repo.refreshDeviceMap();

    // 同 person 的另一设备（dev-a2）与对方设备（dev-b）各发一条消息
    final fromA2 = await encryptMessage(
      plaintext: '来自我的另一台设备',
      spaceKey: spaceKey,
      spaceId: 'space-test',
      senderDeviceId: 'dev-a2',
      messageId: 'msg-a2-1',
      keyVersion: 1,
    );
    final fromB = await encryptMessage(
      plaintext: '来自对方',
      spaceKey: spaceKey,
      spaceId: 'space-test',
      senderDeviceId: 'dev-b',
      messageId: 'msg-b-1',
      keyVersion: 1,
    );
    api.pages.add((
      messages: [fromA2, fromB],
      attachmentsMeta: <Map<String, dynamic>>[],
      lastSequence: 2,
      hasMore: false,
    ));

    await repo.sync();
    final hist = await repo.history();
    final byMsg = {for (final h in hist) h.env.messageId: h.sender};
    expect(byMsg['msg-a2-1'], 'me', reason: '同 person 的另一设备消息应显示为 me');
    expect(byMsg['msg-b-1'], 'peer', reason: '对方设备消息显示为 peer');
  });

  test('purgeExpired：到期消息本地删除，未到期保留（阅后即焚）', () async {
    final api = FakeApi();
    final settings = BurnAfterSettings(db);
    final repo = MessageRepository(
      db: db,
      api: api,
      spaceKey: spaceKey,
      spaceId: 'space-test',
      deviceId: 'dev-a',
      keyVersion: 1,
      settings: settings,
    );
    await settings.save(60); // 设置 1 分钟焚毁（本设备独立，纯本地）

    final mid = await repo.send('burn after 60s');
    final hist = await repo.history();
    expect(hist.single.env.messageId, mid);
    expect(hist.single.expiresAt, isNotNull, reason: '阅后即焚消息应带到期时间');

    final now = DateTime.now().millisecondsSinceEpoch;
    // 未到期（+59s）：不删除
    expect(await repo.purgeExpired(now: now + 59 * 1000), 0);
    expect((await repo.history()).length, 1);
    // 到期（+61s）：删除
    expect(await repo.purgeExpired(now: now + 61 * 1000), 1);
    expect((await repo.history()).length, 0, reason: '到期消息应被本地删除');
  });

  test('分页：historyRecent 最近 N 条升序 / historyBefore 更早 / historySince 新增', () async {
    final api = FakeApi();
    final repo = makeRepo(api, token: 'tok'); // 需要 token 才能 sync 拉取
    final envs = <MessageEnvelope>[];
    for (var i = 1; i <= 7; i++) {
      envs.add(await encryptMessage(
        plaintext: 'msg-$i',
        spaceKey: spaceKey,
        spaceId: 'space-test',
        senderDeviceId: 'dev-b',
        messageId: 'msg-$i',
        keyVersion: 1,
      ));
    }
    api.pages.add((messages: envs, attachmentsMeta: const [], lastSequence: 7, hasMore: false));
    await repo.sync();

    // recent：最近 3 条（升序）
    final recent = await repo.historyRecent(limit: 3);
    expect(recent.map((h) => h.env.messageId).toList(), ['msg-5', 'msg-6', 'msg-7']);

    // before：比 seq=4 更早的 2 条（升序）
    final before = await repo.historyBefore(beforeSequence: 4, limit: 2);
    expect(before.map((h) => h.env.messageId).toList(), ['msg-2', 'msg-3']);

    // since：比 seq=5 更新（升序）
    final since = await repo.historySince(afterSequence: 5);
    expect(since.map((h) => h.env.messageId).toList(), ['msg-6', 'msg-7']);
  });

  test('分页：未同步 pending 消息排最后（recent/since 含未同步）', () async {
    final api = FakeApi();
    final repo = makeRepo(api, token: 'tok'); // sync 拉取需要 token
    final envs = <MessageEnvelope>[];
    for (var i = 1; i <= 3; i++) {
      envs.add(await encryptMessage(
        plaintext: 'msg-$i',
        spaceKey: spaceKey,
        spaceId: 'space-test',
        senderDeviceId: 'dev-b',
        messageId: 'msg-$i',
        keyVersion: 1,
      ));
    }
    api.pages.add((messages: envs, attachmentsMeta: const [], lastSequence: 3, hasMore: false));
    await repo.sync();
    repo.token = null; // 之后 send 只落库 pending（不尝试上传 → 未同步）
    final mid = await repo.send('pending-new'); // 未同步

    // recent(limit 2)：最近 2 条同步 + 未同步全部（排最后）
    final recent = await repo.historyRecent(limit: 2);
    expect(recent.map((h) => h.env.messageId).toList(), ['msg-2', 'msg-3', mid]);

    // since(2)：比 seq=2 更新 + 未同步
    final since = await repo.historySince(afterSequence: 2);
    expect(since.map((h) => h.env.messageId).toList(), ['msg-3', mid]);
  });

  test('离线发送：无 token 时消息入 pending 队列，本地可见', () async {
    final api = FakeApi();
    final repo = makeRepo(api);

    final id = await repo.send('离线消息');
    expect(id, isNotEmpty);

    expect(await repo.pendingCount, 1, reason: '无 token 时消息应留在队列');
    expect(api.posted, isEmpty, reason: '无 token 不应触发网络请求');

    final hist = await repo.history();
    expect(hist.length, 1);
    expect(hist.first.plaintext, '离线消息');
    expect(hist.first.sender, 'me');
  });

  test('在线发送：有 token 时立即上传并置 sent（锚点不推进）', () async {
    final api = FakeApi();
    final repo = makeRepo(api, token: 'tok');

    await repo.send('在线消息');

    expect(api.posted.length, 1);
    expect(await repo.pendingCount, 0);
    // P2 修复：锚点只随 /sync 推进，send/补发不推进——否则新设备未同步先发消息会跳过对方历史
    expect(await repo.lastSequence, 0, reason: 'send 不应推进锚点（锚点只随 /sync 推进）');
  });

  test('同步：翻页拉全量落库 + attachments_meta + 锚点推进', () async {
    final api = FakeApi();
    // 两页：第 1 页 2 条 + hasMore，第 2 页 1 条
    final env1 = await _makeEnv(spaceKey, 'peer', 'msg-1', '你好');
    final env2 = await _makeEnv(spaceKey, 'peer', 'msg-2', '今天天气不错');
    final env3 = await _makeEnv(spaceKey, 'dev-a', 'msg-3', '我自己发的');
    api.pages = [
      (messages: [env1, env2], attachmentsMeta: [
        {
          'attachment_id': 'att-1',
          'message_id': 'msg-1',
          'key_version': 1,
          'size': 100,
          'sha256': 'abc',
          'nonce': 'bm9uY2U=',
        }
      ], lastSequence: 2, hasMore: true),
      (messages: [env3], attachmentsMeta: <Map<String, dynamic>>[], lastSequence: 3, hasMore: false),
    ];

    final repo = makeRepo(api, token: 'tok');
    final added = await repo.sync();

    expect(added, 3, reason: '两页共 3 条');
    expect(await repo.lastSequence, 3, reason: '锚点应推进到 3');

    final hist = await repo.history();
    expect(hist.length, 3);
    expect(hist.map((h) => h.plaintext).toList(), ['你好', '今天天气不错', '我自己发的']);
    expect(hist.map((h) => h.sender).toList(), ['peer', 'peer', 'me']);
  });

  test('补发：sync 会清空 pending 队列（无重复）', () async {
    final api = FakeApi();
    final repo = makeRepo(api); // 无 token：先离线入队
    await repo.send('要补发的消息');
    expect(await repo.pendingCount, 1);

    // 注入 token 后 sync 应触发补发
    repo.token = 'tok';
    await repo.sync();

    expect(api.posted.length, 1, reason: '补发恰一次');
    expect(await repo.pendingCount, 0, reason: '队列已清空');
    // P2 修复：补发不推进锚点（本场景服务端无其他消息，锚点保持 0）
    expect(await repo.lastSequence, 0, reason: '补发不应推进锚点（锚点只随 /sync 推进）');
  });

  test('锚点只前进不倒退：重复 sync 不重复计数', () async {
    final api = FakeApi();
    final env1 = await _makeEnv(spaceKey, 'peer', 'msg-1', 'only once');
    api.pages = [
      (messages: [env1], attachmentsMeta: <Map<String, dynamic>>[], lastSequence: 1, hasMore: false),
    ];
    final repo = makeRepo(api, token: 'tok');

    expect(await repo.sync(), 1);
    expect(await repo.sync(), 0, reason: '锚点已到 1，二次 sync 应无新增');
  });
}

/// 用 shared 加密构造一个服务端返回的信封（含 server_sequence/created_at）。
/// 注意：必须使用与 repository 相同的 [key]，否则解密会失败（AAD/密钥不匹配）。
Future<MessageEnvelope> _makeEnv(Uint8List key, String sender, String messageId, String plaintext) async {
  final env = await encryptMessage(
    plaintext: plaintext,
    spaceKey: key,
    spaceId: 'space-test',
    senderDeviceId: sender,
    messageId: messageId,
  );
  return MessageEnvelope(
    v: env.v,
    type: env.type,
    keyVersion: env.keyVersion,
    messageId: env.messageId,
    senderDeviceId: env.senderDeviceId,
    nonce: env.nonce,
    ciphertext: env.ciphertext,
    serverSequence: 1,
    createdAt: 1000,
  );
}
