// 通道存储：成员名称/性别缓存落盘往返（离线启动兜底配色用）。
//
// 老板 2026-09-13：服务器离线启动时 TUI 仍要按性别配色，不能全回退青绿——
// 因此 GET /space 的 member_names/member_genders 要落盘、启动时读回。
import 'dart:io';

import 'package:test/test.dart';

import 'package:einz_cli/store.dart';

void main() {
  test('memberNames/memberGenders 落盘后可读回', () {
    final dir = Directory.systemTemp.createTempSync('einz-store-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/s.json';

    final st = EntranceStore(publicKey: 'pk', privateKey: 'sk')
      ..memberNames = {'memberA': 'Lukas', 'memberB': 'Alice'}
      ..memberGenders = {'memberA': 'male', 'memberB': 'female'};
    st.save(path);

    final loaded = EntranceStore.load(path);
    expect(loaded.memberNames, {'memberA': 'Lukas', 'memberB': 'Alice'});
    expect(loaded.memberGenders, {'memberA': 'male', 'memberB': 'female'});
  });

  test('旧 store 缺缓存字段时按空表处理（不崩）', () {
    final dir = Directory.systemTemp.createTempSync('einz-store-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/old.json';
    File(path).writeAsStringSync('{"public_key":"pk","private_key":"sk"}');

    final loaded = EntranceStore.load(path);
    expect(loaded.memberNames, isEmpty);
    expect(loaded.memberGenders, isEmpty);
    expect(loaded.peerName, isNull); // 旧 store 无预置名 → 顶部条回退 '-'
    expect(loaded.installUid, isNull); // 旧 store 无安装级标识 → 启动时补生成
  });

  test('installUid：惰性生成一次、落盘后可读回（多空间关联用，不能每次换）', () {
    final dir = Directory.systemTemp.createTempSync('einz-store-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/uid.json';

    final st = EntranceStore(publicKey: 'pk', privateKey: 'sk');
    final first = st.ensureInstallUid();
    expect(first.length, 32, reason: '16 字节 hex（服务端形状约束 8–64 位 [0-9A-Za-z_-]）');
    expect(st.ensureInstallUid(), first, reason: '同一 store 内稳定，不重复生成');
    st.save(path);

    // 重启读回：必须还是同一个（否则服务端把同一台设备认成两台）
    expect(EntranceStore.load(path).installUid, first);
  });

  // 对方尚未加入时空间里还没有他的 member_id，GET /space 的 member 表拿不到对方
  // 名字 → 顶部条要用 create/join 时已知的名字兜底（老板 2026-09-16：刚创建后
  // 进入聊天窗口应显示对方名字），故该名字必须落盘、重启后仍在。
  test('peerName（对方预置名）落盘后可读回', () {
    final dir = Directory.systemTemp.createTempSync('einz-store-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/s.json';

    final st = EntranceStore(publicKey: 'pk', privateKey: 'sk')
      ..memberName = 'Lukas'
      ..peerName = 'Alice';
    st.save(path);

    final loaded = EntranceStore.load(path);
    expect(loaded.peerName, 'Alice');
    expect(loaded.memberName, 'Lukas');
  });

  // 2026-09-24 老板实测：旧 store 的历史信封只有 sender_device_id，新代码读
  // sender_entrance_id → null cast 抛崩 → TUI 连 /reset 都进不去。回归：
  // ① 旧键名自动归一（值不变，AAD 用值 → 仍可解密）；② 坏信封跳过、不抛。
  test('旧版键名的历史/待发信封可读回（自动归一，不崩）', () {
    final st = EntranceStore(publicKey: 'pk', privateKey: 'sk')
      ..history.add(const {
        'v': 1,
        'type': 'text',
        'key_version': 1,
        'message_id': 'm1',
        'sender_device_id': 'dev1',
        'sender_person_id': 'mem1',
        'nonce': 'n',
        'ciphertext': 'c',
        'server_sequence': 5,
        'created_at': 100,
      })
      ..pending.add(
          '{"v":1,"type":"text","key_version":1,"message_id":"m2","sender_device_id":"dev1","nonce":"n","ciphertext":"c"}');

    final envs = st.historyEnvelopes;
    expect(envs.length, 1);
    expect(envs.first.senderEntranceId, 'dev1'); // 旧 sender_device_id 归一
    expect(envs.first.senderMemberId, 'mem1'); // 旧 sender_person_id 归一
    expect(envs.first.serverSequence, 5);
    expect(st.pendingEnvelopes.single.senderEntranceId, 'dev1');
  });

  test('损坏/无法解析的信封被跳过，不抛错', () {
    final st = EntranceStore(publicKey: 'pk', privateKey: 'sk')
      ..history.add(const {'garbage': true})
      ..history.add(const {
        'v': 1,
        'type': 'text',
        'key_version': 1,
        'message_id': 'ok',
        'sender_entrance_id': 'dev1',
        'nonce': 'n',
        'ciphertext': 'c',
      })
      ..pending.add('{ not json');

    expect(st.historyEnvelopes.map((e) => e.messageId), ['ok']); // 坏的跳过、好的保留
    expect(st.pendingEnvelopes, isEmpty);
  });
}
