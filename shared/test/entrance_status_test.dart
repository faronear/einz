// entrance_status 单测：通道行三态判定的唯一口径（App/TUI 共用）。
//
// 重点覆盖 2026-10-08 合并的三件事：
// ① 在线判定（connected_at 优先、last_seen<60s 兜底、本机走本地 WS）；
// ② 已撤销 = 独立状态（先判撤销，防 last_seen=now 误判在线；不计入总数）；
// ③ 时刻口径（online_since→connected_at；max(last_seen, offline_since)）。
import 'package:einz_shared/einz_shared.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.now().millisecondsSinceEpoch;
  final justNow = now - 1000; // 1s 前
  final stale = now - 120 * 1000; // 120s 前（超 60s 窗口）

  group('isEntranceRevoked / entranceRowState', () {
    test('status 缺省（老服务端）视为在用', () {
      final row = {'entrance_id': 'e1', 'connected_at': now};
      expect(isEntranceRevoked(row), isFalse);
      expect(
          entranceRowState(row), EntranceRowState.online);
    });

    test("status='active' 为在用", () {
      expect(
          isEntranceRevoked({'entrance_id': 'e1', 'status': 'active'}),
          isFalse);
    });

    test("status='revoked' 恒为已撤销，即使 connected_at 非空", () {
      final row = {
        'entrance_id': 'e1',
        'status': 'revoked',
        'connected_at': now,
        'last_seen': now,
      };
      expect(entranceRowState(row), EntranceRowState.revoked);
      expect(isEntranceOnline(row), isFalse);
    });

    test('撤销的 last_seen=now（服务端 revoke 行为）不得被 60s 兜底误判在线', () {
      final row = {
        'entrance_id': 'e1',
        'status': 'revoked',
        'last_seen': now,
        'offline_since': now,
      };
      expect(entranceRowState(row), EntranceRowState.revoked);
    });
  });

  group('在线判定', () {
    test('connected_at 非 null → 在线', () {
      expect(
          isEntranceOnline({'entrance_id': 'e1', 'connected_at': now}),
          isTrue);
    });

    test('connected_at 为 null → 离线（即使 last_seen 是新的）', () {
      expect(
          isEntranceOnline({
            'entrance_id': 'e1',
            'connected_at': null,
            'last_seen': justNow,
          }),
          isFalse);
    });

    test('老服务端无 connected_at 字段：last_seen<60s 兜底', () {
      expect(isEntranceOnline({'entrance_id': 'e1', 'last_seen': justNow}),
          isTrue);
      expect(isEntranceOnline({'entrance_id': 'e1', 'last_seen': stale}),
          isFalse);
      expect(isEntranceOnline({'entrance_id': 'e1', 'last_seen': 0}), isFalse);
    });

    test('本机通道只看本地 WS 状态，不回退服务端', () {
      final row = {
        'entrance_id': 'me',
        'connected_at': now, // 服务端仍认为在线（心跳超时窗口内）
        'last_seen': now,
      };
      expect(
          isEntranceOnline(row, myEntranceId: 'me', myWsOnline: false),
          isFalse); // 本地已断 → 离线
      expect(
          isEntranceOnline(row, myEntranceId: 'me', myWsOnline: true),
          isTrue);
      // 非本机不受 myWsOnline 影响
      expect(
          isEntranceOnline(row, myEntranceId: 'other', myWsOnline: false),
          isTrue);
    });
  });

  group('时刻口径', () {
    test('rowOnlineSince：online_since 优先，退回 connected_at，无数据 0', () {
      expect(rowOnlineSince({'online_since': 111, 'connected_at': 222}), 111);
      expect(rowOnlineSince({'connected_at': 222}), 222);
      expect(rowOnlineSince({}), 0);
    });

    test('rowOfflineSince = max(last_seen, offline_since)', () {
      expect(
          rowOfflineSince({'last_seen': 0, 'offline_since': 500}), 500);
      expect(rowOfflineSince({'last_seen': 900, 'offline_since': 500}), 900);
      expect(rowOfflineSince({'last_seen': 0, 'offline_since': 0}), 0);
      expect(rowOfflineSince({}), 0);
    });

    test('rowSince 按在线与否取上线/下线时刻', () {
      final online = {'online_since': 111, 'connected_at': 222};
      final offline = {'last_seen': 0, 'offline_since': 500};
      expect(rowSince(online, online: true), 111);
      expect(rowSince(offline, online: false), 500);
    });
  });

  group('summarizeEntrances', () {
    Map<String, dynamic> row(String id, {String? member, int? connectedAt}) =>
        {
          'entrance_id': id,
          'member_id': member,
          'entrance_name': id.toUpperCase(),
          'connected_at': connectedAt,
          'last_seen': 0,
        };

    test('在线计数/时刻表（本机以本地 WS 为准）', () {
      final rows = [
        row('me', member: 'm1', connectedAt: now),
        row('mine2', member: 'm1', connectedAt: now), // 我的另一条在线
        row('p1', member: 'm2', connectedAt: now), // 对方在线
        row('p2', member: 'm2', connectedAt: null), // 对方离线
      ];
      final s = summarizeEntrances(rows,
          myEntranceId: 'me', myMemberId: 'm1', myWsOnline: false);
      // 本机 WS 断开：只影响本机那一行；我的其它设备按服务端判定（mine2 在线）
      expect(s.myOtherTotal, 1);
      expect(s.myOtherOnlineSince, {'mine2': now});
      expect(s.peerOnlineCount, 1);
      expect(s.peerActiveTotal, 2);
      expect(s.peerOnlineSince, {'p1': now});
      expect(s.peerHasOnline, isTrue);
      expect(s.peerAllRevoked, isFalse);
      expect(s.nameMap, {
        'me': 'ME',
        'mine2': 'MINE2',
        'p1': 'P1',
        'p2': 'P2',
      });
      expect(s.memberStates['m2']?.online, isTrue);
      expect(s.memberStates.containsKey('m1'), isFalse); // 不含我自己
    });

    test('已撤销：独立状态，不计入总数，但"全撤"判定成立', () {
      final rows = [
        row('me', member: 'm1', connectedAt: now),
        {
          'entrance_id': 'p1',
          'member_id': 'm2',
          'entrance_name': 'P1',
          'status': 'revoked',
          'connected_at': null,
          'last_seen': now, // 撤销时刻
          'offline_since': now,
        },
      ];
      final s = summarizeEntrances(rows,
          myEntranceId: 'me', myMemberId: 'm1', myWsOnline: true);
      expect(s.peerActiveTotal, 0);
      expect(s.peerRevokedTotal, 1);
      expect(s.peerOnlineCount, 0);
      expect(s.peerHasOnline, isFalse);
      expect(s.peerAllRevoked, isTrue); // 标题栏第三态
      expect(s.nameMap.containsKey('p1'), isFalse); // 已撤销不映射名
      expect(s.memberStates['m2']?.revokedOnly, isTrue);
    });

    test('member 聚合：同一人任一在用通道在线即在线；撤销通道不点亮', () {
      final rows = [
        row('a', member: 'm2'),
        {
          'entrance_id': 'b',
          'member_id': 'm2',
          'status': 'revoked',
          'connected_at': now, // 撤销行若按在线口径会被误点亮
          'last_seen': now,
        },
      ];
      final s = summarizeEntrances(rows,
          myEntranceId: 'me', myMemberId: 'm1', myWsOnline: true);
      expect(s.memberStates['m2']?.online, isFalse);
      expect(s.memberStates['m2']?.activeCount, 1);
      expect(s.memberStates['m2']?.revokedCount, 1);
      expect(s.memberStates['m2']?.revokedOnly, isFalse); // 还有在用通道
    });

    test('身份未落位：退回按通道判定，不统计多通道数', () {
      final rows = [
        row('me', connectedAt: now),
        row('p1', connectedAt: now),
      ];
      final s = summarizeEntrances(rows, myEntranceId: 'me', myWsOnline: true);
      expect(s.peerOnlineCount, 1);
      expect(s.peerActiveTotal, 0); // 无 member 信息 → 不统计
      expect(s.myOtherTotal, 0);
    });
  });
}
