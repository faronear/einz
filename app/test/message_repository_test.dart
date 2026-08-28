// MessageRepository 单测：drift 内存库 + fake ApiClient，
// 验证离线发送入队、同步落库/推进锚点、补发队列、历史解密。
//
// 需要 LIBSODIUM_PATH 指向 libsodium.dll（与 shared 单测一致）。

import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onlyspace/data/local_database.dart';
import 'package:onlyspace/data/message_repository.dart';
import 'package:onlyspace_shared/onlyspace_shared.dart';

/// fake ApiClient：不真正联网，返回预先编排的数据。
class FakeApi extends ApiClient {
  FakeApi({List<String>? posted}) : posted = posted ?? [], super('http://fake');

  /// 已成功上传的 message_id（记录 postMessage 调用）。
  final List<String> posted;

  /// 编排的 sync 页（每页是一个 SyncPage）。
  List<({List<MessageEnvelope> messages, List<Map<String, dynamic>> attachmentsMeta, int lastSequence, bool hasMore})> pages = [];

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
    return (
      messages: page.messages,
      attachmentsMeta: page.attachmentsMeta,
      lastSequence: page.lastSequence,
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

  test('在线发送：有 token 时立即上传并置 sent、推进锚点', () async {
    final api = FakeApi();
    final repo = makeRepo(api, token: 'tok');

    await repo.send('在线消息');

    expect(api.posted.length, 1);
    expect(await repo.pendingCount, 0);
    expect(await repo.lastSequence, 1, reason: '发送成功后锚点应为 1');
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
    expect(await repo.lastSequence, 1);
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
