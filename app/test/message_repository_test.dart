// MessageRepository 单测：drift 内存库 + fake ApiClient，
// 验证离线发送入队、同步落库/推进锚点、补发队列、历史解密。
//
// 需要 LIBSODIUM_PATH 指向 libsodium.dll（与 shared 单测一致）。

import 'dart:convert';
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

  /// 是否让附件上传抛异常（模拟服务端 500 等上传失败）。
  bool failAttachmentUpload = false;

  /// 是否让消息发送（postMessage）抛异常（模拟发送失败）。
  bool failPostMessage = false;

  /// 回执：记录的上报（delivered/read 高水位）。
  final List<({int delivered, int read})> reportedReceipts = [];
  /// 回执：GET /receipts 编排返回值。
  List<ReceiptRow> receiptRows = [];

  @override
  Future<({int deliveredUptoSeq, int readUptoSeq})> postReceipts(
    String token, {
    int? deliveredUptoSeq,
    int? readUptoSeq,
  }) async {
    reportedReceipts.add((delivered: deliveredUptoSeq ?? 0, read: readUptoSeq ?? 0));
    // 服务端只前进（此处按最后一次上报返回即可，够测试用）
    return (deliveredUptoSeq: deliveredUptoSeq ?? 0, readUptoSeq: readUptoSeq ?? 0);
  }

  @override
  Future<List<ReceiptRow>> getReceipts(String token) async => receiptRows;

  @override
  Future<SpaceResult> getSpace(String token) async {
    return SpaceResult(spaceId: 'space-test', devices: spaceDevices);
  }

  @override
  Future<PostMessageResult> postMessage(MessageEnvelope env, String token) async {
    if (failPostMessage) throw Exception('post message failed');
    posted.add(env.messageId);
    return PostMessageResult(messageId: env.messageId, serverSequence: posted.length, createdAt: 1000);
  }

  @override
  Future<Map<String, dynamic>> postAttachment({
    required String messageId,
    required String attachmentId,
    required int keyVersion,
    required int size,
    required String sha256,
    required String nonce,
    required Uint8List blob,
    required String token,
  }) async {
    if (failAttachmentUpload) throw Exception('attachment upload failed');
    return {'attachment_id': attachmentId, 'storage_path': '01/$attachmentId', 'created_at': 1000};
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

  test('tombstoneExpired：到期消息打墓碑（记录保留、内容隐藏），未到期不动', () async {
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
    expect(hist.single.deleted, isFalse);
    expect(hist.single.burnManual, isFalse,
        reason: '随全局设置焚毁的消息不算手动设置（气泡不标注修改时间）');

    final now = DateTime.now().millisecondsSinceEpoch;
    // 未到期（+59s）：不打标记
    expect(await repo.tombstoneExpired(now: now + 59 * 1000), 0);
    expect((await repo.history()).single.deleted, isFalse);
    // 到期（+61s）：打墓碑——记录保留、deleted 标记（不打破历史流水）
    expect(await repo.tombstoneExpired(now: now + 61 * 1000), 1);
    final burned = await repo.history();
    expect(burned.length, 1, reason: '焚毁后记录应保留（内容隐藏、时间+时钟+时长保留）');
    expect(burned.single.deleted, isTrue, reason: '焚毁消息应标记为已删除（内容隐藏）');
    expect(burned.single.expiresAt, isNotNull, reason: '焚毁记录的时间+时钟+时长保留');
    // 已墓碑的不重复标记
    expect(await repo.tombstoneExpired(now: now + 61 * 1000), 0);
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

  test('发送失败：有 token 但 postMessage 抛错 → status=failed（不计入 pending）', () async {
    final api = FakeApi()..failPostMessage = true;
    final repo = makeRepo(api, token: 'tok');

    await repo.send('会失败的消息');

    final hist = await repo.history();
    expect(hist.single.status, 'failed');
    expect(hist.single.sender, 'me');
    expect(await repo.pendingCount, 0, reason: 'failed 与 pending 区分：不自动重发');
  });

  test('重发：retryMessage 成功后置 sent 且回填 server_sequence', () async {
    final api = FakeApi()..failPostMessage = true;
    final repo = makeRepo(api, token: 'tok');
    await repo.send('待重发');
    final failed = (await repo.history()).single;
    expect(failed.status, 'failed');

    api.failPostMessage = false;
    await repo.retryMessage(failed.env.messageId);

    final h = (await repo.history()).single;
    expect(h.status, 'sent');
    expect(h.env.serverSequence, isNotNull, reason: '重发成功后 server_sequence 应回填到信封');
    expect(api.posted.length, 1);
  });

  test('乐观回调：本地落库后、上传前触发，此时为 pending', () async {
    final api = FakeApi();
    final repo = makeRepo(api, token: 'tok');
    String? observed;
    var beforeUpload = false;

    await repo.send('乐观回显', onPersisted: (id) async {
      observed = (await repo.historySince(afterSequence: 0)).single.status;
      beforeUpload = api.posted.isEmpty; // 回调时尚未 postMessage
    });

    expect(observed, 'pending', reason: '回调触发时消息应已在本地库且为 pending');
    expect(beforeUpload, isTrue, reason: '应在上传之前回调（才能乐观回显）');
  });

  test('附件乐观回调：在 postAttachment 之前触发，且附件元数据已落库', () async {
    final api = FakeApi();
    final repo = makeRepo(api, token: 'tok');
    var metaReady = false;

    await repo.sendAttachment(
      fileBytes: Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]), // PNG magic
      fileName: 'image.jpg',
      type: 'image',
      onPersisted: (_) async {
        metaReady = (await repo.historySince(afterSequence: 0)).single.attachment != null;
      },
    );

    expect(metaReady, isTrue, reason: '回调时附件元数据应已落库（图片/视频可即时显示）');
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

  test('同步回来的自己消息：status=sent 且信封回填 server_sequence（分页/锚点依赖）', () async {
    final api = FakeApi();
    final env = await _makeEnv(spaceKey, 'dev-a', 'msg-own', '我自己发的');
    api.pages = [
      (messages: [env], attachmentsMeta: <Map<String, dynamic>>[], lastSequence: 1, hasMore: false),
    ];
    final repo = makeRepo(api, token: 'tok');
    await repo.sync();

    final h = (await repo.history()).single;
    expect(h.sender, 'me');
    expect(h.status, 'sent');
    expect(h.env.serverSequence, isNotNull,
        reason: '本机发送的消息 ciphertext 无 seq，应从列回填（否则分页/增量锚点误判）');
  });

  test('引用消息：send 携带 quote → 历史解密还原 plaintext + quote 快照', () async {
    final api = FakeApi();
    final repo = makeRepo(api, token: 'tok');

    final mid = await repo.send(
      '这是回复',
      quote: {
        'messageId': 'msg-origin',
        'preview': '被引用的原文内容',
      },
    );
    expect(api.posted.length, 1);

    final hist = await repo.history();
    expect(hist.single.env.messageId, mid);
    expect(hist.single.plaintext, '这是回复', reason: '明文应剥离引用包装');
    expect(hist.single.quote, isNotNull, reason: '引用快照应随载荷解密还原');
    expect(hist.single.quote!['messageId'], 'msg-origin');
    expect(hist.single.quote!['preview'], '被引用的原文内容');

    // 兼容性：无 quote 的普通消息 quote 字段为 null、明文原样
    final mid2 = await repo.send('普通消息');
    final normal = (await repo.history()).firstWhere((h) => h.env.messageId == mid2);
    expect(normal.quote, isNull);
    expect(normal.plaintext, '普通消息');
  });

  test('tombstoneMessage：本机墓碑（记录保留、deleted 标记、重启后仍隐藏）', () async {
    final api = FakeApi();
    final repo = makeRepo(api, token: 'tok');
    final keep = await repo.send('保留的消息');
    final del = await repo.send('要删除的消息');
    expect((await repo.history()).length, 2);

    await repo.tombstoneMessage(del);

    final hist = await repo.history();
    expect(hist.length, 2, reason: '墓碑不删行——消息记录仍在（不打破历史流水）');
    expect(hist.singleWhere((h) => h.env.messageId == del).deleted, isTrue,
        reason: '被删消息应标记 deleted（内容隐藏）');
    expect(hist.singleWhere((h) => h.env.messageId == keep).deleted, isFalse,
        reason: '未删消息不受影响');

    // 模拟重启（新 repo 实例重读同一库）：记录仍在、deleted 标记保留
    final repo2 = makeRepo(api, token: 'tok');
    final hist2 = await repo2.history();
    expect(hist2.length, 2, reason: '重启后记录仍在');
    expect(hist2.singleWhere((h) => h.env.messageId == del).deleted, isTrue,
        reason: '重启后墓碑标记保留（内容仍隐藏）');
  });

  test('重启后引用消息不显示原始 JSON（send → 服务端回拉 → 重新读取历史）', () async {
    final api = FakeApi();
    final repo = makeRepo(api, token: 'tok');
    final mid = await repo.send(
      '这是回复',
      quote: {'messageId': 'q-1', 'preview': '被引用的原文'},
    );
    // 发送后立即显示正常
    expect((await repo.history()).single.plaintext, '这是回复');

    // 重启场景：_markSent 不推进锚点 → sync 会把这条消息从服务端再拉回来
    final row = await (db.select(db.localMessages)..where((m) => m.messageId.equals(mid))).getSingle();
    final env = MessageEnvelope.fromJson(jsonDecode(row.ciphertext) as Map<String, dynamic>);
    api.pages.add((
      messages: [env],
      attachmentsMeta: <Map<String, dynamic>>[],
      lastSequence: 1,
      hasMore: false,
    ));
    await repo.sync(); // 等价重启后 _loadInitial 里的 sync

    final hist = await repo.history();
    expect(hist.single.env.messageId, mid);
    expect(hist.single.plaintext, '这是回复', reason: '重启后引用消息不应显示为原始 JSON');
    expect(hist.single.quote, isNotNull);
    expect(hist.single.quote!['messageId'], 'q-1');
  });

  test('附件：上传失败也保留本地密文元数据（发送端气泡直接显示图片）', () async {
    // 回归：附件元数据原在上传+发送成功后才落库 → 服务端 500（v2 附件链路断裂）
    // 时本地无元数据 → 气泡回退「📎 文件名」，图片/视频不再直接显示。
    final api = FakeApi()..failAttachmentUpload = true;
    final repo = makeRepo(api, token: 'tok');
    final bytes = Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]); // PNG magic

    await repo.sendAttachment(fileBytes: bytes, fileName: 'image.jpg', type: 'image');

    final hist = await repo.history();
    expect(hist.length, 1);
    expect(hist.single.attachment, isNotNull, reason: '上传失败也应保留本地附件元数据');
    final plain = await repo.attachmentBytes(hist.single.attachment!);
    expect(plain, bytes, reason: '本地密文应能解密回原始字节（可直接渲染）');
  });

  test('单条消息阅后即焚只作用于该消息：不改全局设置、不污染后续新消息', () async {
    // 回归：长按单条消息设阅后即焚不应变成全局（否则后续新收消息也被焚）。
    // 验证 setMessageBurn 只写该 messageId 行，全局 BurnAfterSettings 不动，
    // 后续 sync 的新消息沿用全局(0)。
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
      token: 'tok',
    );
    expect(await settings.load(), 0, reason: '初始全局应为无限(0)');

    // 先同步来一条消息 A（对方发送）
    final envA = await _makeEnv(spaceKey, 'dev-b', 'msg-a', '旧消息');
    api.pages.add((messages: [envA],
        attachmentsMeta: const [], lastSequence: 1, hasMore: false));
    await repo.sync();
    expect((await repo.history()).singleWhere((h) => h.env.messageId == 'msg-a').burnAfterSeconds, 0);

    // 对 A 长按设单条阅后即焚 = 60s
    expect(await repo.setMessageBurn('msg-a', 60), isTrue);

    // 关键断言 1：全局设置未被单条设置污染
    expect(await settings.load(), 0, reason: '单条设置不应改写全局阅后即焚');
    // 关键断言 2：仅 A 被焚
    final after = await repo.history();
    expect(after.singleWhere((h) => h.env.messageId == 'msg-a').burnAfterSeconds, 60,
        reason: '被长按的消息应带 burn=60');
    expect(after.singleWhere((h) => h.env.messageId == 'msg-a').burnManual, isTrue,
        reason: '长按单独设置的消息应标记 burnManual（气泡标注修改时间）');

    // 后续新消息 B 到达（对方新发）
    final envB = await _makeEnv(spaceKey, 'dev-b', 'msg-b', '新消息');
    api.pages.add((messages: [envB],
        attachmentsMeta: const [], lastSequence: 2, hasMore: false));
    await repo.sync();
    final hist = await repo.history();
    final a = hist.singleWhere((h) => h.env.messageId == 'msg-a');
    final b = hist.singleWhere((h) => h.env.messageId == 'msg-b');
    expect(a.burnAfterSeconds, 60, reason: 'A 的单条焚毁保留');
    expect(a.burnManual, isTrue, reason: 'A 为手动设置');
    expect(b.burnAfterSeconds, 0, reason: '后续新消息应沿用全局(0)，不被 A 的单条设置污染');
    expect(b.burnManual, isFalse, reason: '全局设置的消息不应被标为手动');
  });

  // ---------- 回执（已送达/已读）地基：本轮只落库 + 推导，不显示 ----------

  test('回执：sync 拉取并落库，推导 receiptOf（null/delivered/read）', () async {
    final api = FakeApi();
    final repo = makeRepo(api, token: 'tok');
    api.receiptRows = [
      ReceiptRow(
          personId: 'person-b', deliveredUptoSeq: 10, readUptoSeq: 5, updatedAt: 111),
    ];
    await repo.sync();

    final rows = await repo.peerReceipts();
    expect(rows.single.personId, 'person-b');
    expect(rows.single.deliveredUptoSeq, 10);
    expect(rows.single.readUptoSeq, 5);

    // 推导：seq ≤ read → read；read < seq ≤ delivered → delivered；超出 → null
    expect(MessageRepository.receiptOf(1, rows), 'read', reason: 'seq=1 ≤ read(5) → 已读');
    expect(MessageRepository.receiptOf(5, rows), 'read', reason: '边界：=read → 已读');
    expect(MessageRepository.receiptOf(6, rows), 'delivered', reason: 'read < 6 ≤ delivered');
    expect(MessageRepository.receiptOf(10, rows), 'delivered', reason: '边界：=delivered → 已送达');
    expect(MessageRepository.receiptOf(11, rows), isNull, reason: '超出高水位 → 仅已发送');
    expect(MessageRepository.receiptOf(null, rows), isNull, reason: '未同步的消息无回执');
    expect(MessageRepository.receiptOf(1, const []), isNull, reason: '没有任何回执行 → null');
  });

  test('回执：单调只前进（陈旧的重放不会把高水位拉低）', () async {
    final api = FakeApi();
    final repo = makeRepo(api, token: 'tok');
    await repo.upsertPeerReceipt(
        personId: 'person-b', deliveredUptoSeq: 20, readUptoSeq: 10);
    // 重放一个更旧的值（如乱序的 WS 帧/过期 GET）
    await repo.upsertPeerReceipt(
        personId: 'person-b', deliveredUptoSeq: 5, readUptoSeq: 1);
    final rows = await repo.peerReceipts();
    expect(rows.single.deliveredUptoSeq, 20, reason: '单调：不得回退');
    expect(rows.single.readUptoSeq, 10, reason: '单调：不得回退');
  });

  test('回执：reportReceipts 走 _withAutoAuth，无 token 时静默跳过', () async {
    final api = FakeApi();
    final repo = makeRepo(api); // token 为 null
    await repo.reportReceipts(deliveredUptoSeq: 3);
    expect(api.reportedReceipts, isEmpty, reason: '无 token 不应上报');
    expect(repo.token, isNull);
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
