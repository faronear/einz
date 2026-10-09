/// 通道（entrance）行的在线/离线/已撤销判定——**App 与 TUI 共用唯一实现**。
///
/// 背景（2026-10-08 合并）：同一套判定此前在 app/lib/chat_page.dart（_isRowOnline /
/// _sinceOfRow / 通道卡片内联）与 cli/bin/einz_tui.dart（entranceOnline /
/// _fetchEntranceRows / _refreshPeerOnline）里各存一份拷贝，已撤销（revoked）的
/// 处理两边分叉（TUI 计数跳过、App 群成员聚合不跳 → 刚被撤销的通道 last_seen=now
/// 会误判 60s 内"在线"）。此处收敛为单一口径：
///
/// - **在线** = 有实时 WS 连接（`connected_at` 非 null）；老服务端无该字段时退回
///   `last_seen` 距今 < 60s 兜底（last_seen 会被轮询 touchLastSeen 持续刷新，
///   不能单独代表实时连接——"未入网却显示绿灯"修复）。
/// - **本机通道**一律以调用方传入的本地 WS 状态为准，**不回退服务端**：服务端要等
///   心跳超时（最多 30s）才把本机判离线，那段时间会出现"本机灯已红、计数仍把自己
///   算在线"的自相矛盾（老板 2026-09-16）。
/// - **已撤销**（`status != 'active'`，老服务端缺省视为在用）是**独立状态**，绝不同于
///   离线（老板 2026-10-08）：不参与在线判定、**不计入通道总数**（撤销是软标记，行
///   仍在 /entrances 里，服务端置 last_seen=now / offline_since=撤销时刻——若不按
///   status 先判撤销，撤销后 60s 内会被 last_seen 兜底误判在线）。
library;

/// 单条通道行的状态（三态，互斥）。
enum EntranceRowState { online, offline, revoked }

/// 老服务端 `last_seen` 兜底的在线窗口（ms）：60s。
const int kEntranceOnlineWindowMs = 60 * 1000;

/// 通道是否已被撤销（`status` 非 null 且非 'active'；老服务端缺省视为在用）。
bool isEntranceRevoked(Map<String, dynamic> row) =>
    row['status'] != null && row['status'] != 'active';

/// 通道是否在线。[myEntranceId] 命中时直接返回 [myWsOnline]（本机以本地 WS 为准，
/// 不回退服务端——见文件头注释）。已撤销恒为 false。
bool isEntranceOnline(
  Map<String, dynamic> row, {
  String? myEntranceId,
  bool myWsOnline = false,
}) {
  if (isEntranceRevoked(row)) return false;
  if (myEntranceId != null && row['entrance_id'] == myEntranceId) return myWsOnline;
  if (row.containsKey('connected_at')) return row['connected_at'] != null;
  final last = row['last_seen'];
  if (last is! num) return false;
  return DateTime.now().millisecondsSinceEpoch - last < kEntranceOnlineWindowMs;
}

/// 通道行三态判定（[isEntranceRevoked] 优先于 [isEntranceOnline]）。
EntranceRowState entranceRowState(
  Map<String, dynamic> row, {
  String? myEntranceId,
  bool myWsOnline = false,
}) {
  if (isEntranceRevoked(row)) return EntranceRowState.revoked;
  return isEntranceOnline(row,
          myEntranceId: myEntranceId, myWsOnline: myWsOnline)
      ? EntranceRowState.online
      : EntranceRowState.offline;
}

/// 上线时刻（ms）：`online_since`（进入在线态，重连不刷新）→ 退回 `connected_at`
/// → 0（无数据）。展示层 `> 0` 才显示（避免 1970-01-01）。
int rowOnlineSince(Map<String, dynamic> row) =>
    (row['online_since'] as num?)?.toInt() ??
    (row['connected_at'] is num ? (row['connected_at'] as num).toInt() : 0);

/// 下线时刻（ms）＝ `max(last_seen, offline_since)`：
/// - 干净下线时服务端把 last_seen 置 0，断线时刻只落在 offline_since；
/// - last_seen 会被心跳/REST 刷新，服务端重启这类"close 没跑到"的情况它反倒是
///   更新的证据（比上一次会话留下的 offline_since 新），故取两者较晚者；
/// - 已撤销时服务端同时写 last_seen=now 与 offline_since=now → 即撤销时刻。
/// 两者都是 0 → 0（无数据）。
int rowOfflineSince(Map<String, dynamic> row) {
  final lastSeen = (row['last_seen'] as num?)?.toInt() ?? 0;
  final offlineSince = (row['offline_since'] as num?)?.toInt() ?? 0;
  return lastSeen > offlineSince ? lastSeen : offlineSince;
}

/// 行当前应显示的时刻：在线 → [rowOnlineSince]；离线/已撤销 → [rowOfflineSince]。
int rowSince(Map<String, dynamic> row, {required bool online}) =>
    online ? rowOnlineSince(row) : rowOfflineSince(row);

/// 一个成员（member）的存在感聚合（group 成员名单点灯用，**不含我自己**）。
///
/// [online] 任一**在用**通道在线即在线；[revokedOnly] = 没有任何在用通道、
/// 只有已撤销通道——独立于离线的第三态（老板 2026-10-08）。
/// [maxSince] 该成员**最近一次状态变化的时刻**（ms；同一人多条通道取 max）：
/// 在线取上线时刻、离线/已撤销取下线（撤销）时刻——展示层排序用
/// （最新上线的排最前，下线/撤销的沉底）。
class MemberPresence {
  const MemberPresence({
    required this.online,
    required this.activeCount,
    required this.revokedCount,
    this.maxSince = 0,
  });

  final bool online;

  /// 在用（未撤销）通道数。
  final int activeCount;

  /// 已撤销通道数。
  final int revokedCount;

  /// 最近一次状态变化时刻（ms；0 = 无数据）。
  final int maxSince;

  bool get hasEntrance => activeCount + revokedCount > 0;

  /// 仅有已撤销通道（无在用通道）→ 名单里的第三态灯。
  bool get revokedOnly => !online && activeCount == 0 && revokedCount > 0;

  @override
  bool operator ==(Object other) =>
      other is MemberPresence &&
      other.online == online &&
      other.activeCount == activeCount &&
      other.revokedCount == revokedCount &&
      other.maxSince == maxSince;

  @override
  int get hashCode => Object.hash(online, activeCount, revokedCount, maxSince);
}

/// 成员在线聚合：member_id → [MemberPresence]（跳过本机通道、跳过我自己；
/// 同一 member 任一在用通道在线即在线）。
Map<String, MemberPresence> aggregateMemberStates(
  List<Map<String, dynamic>> rows, {
  String? myMemberId,
  String? myEntranceId,
  bool myWsOnline = false,
}) {
  final result = <String, MemberPresence>{};
  for (final row in rows) {
    final pid = row['member_id'] as String?;
    if (pid == null || pid.isEmpty) continue;
    final isLocal = myEntranceId != null && row['entrance_id'] == myEntranceId;
    if (isLocal) continue;
    if (myMemberId != null && pid == myMemberId) continue;
    final p = result[pid] ??
        const MemberPresence(online: false, activeCount: 0, revokedCount: 0);
    // 最近状态变化时刻（在线行取上线时刻、撤销行取撤销时刻；多通道取 max）
    final since = rowSince(row,
        online: !isEntranceRevoked(row) &&
            entranceRowState(row,
                    myEntranceId: myEntranceId, myWsOnline: myWsOnline) ==
                EntranceRowState.online);
    final maxSince = p.maxSince > since ? p.maxSince : since;
    if (isEntranceRevoked(row)) {
      result[pid] = MemberPresence(
          online: p.online,
          activeCount: p.activeCount,
          revokedCount: p.revokedCount + 1,
          maxSince: maxSince);
    } else {
      final onlineNow = entranceRowState(row,
              myEntranceId: myEntranceId, myWsOnline: myWsOnline) ==
          EntranceRowState.online;
      result[pid] = MemberPresence(
        online: p.online || onlineNow,
        activeCount: p.activeCount + 1,
        revokedCount: p.revokedCount,
        maxSince: maxSince,
      );
    }
  }
  return result;
}

/// /entrances 一次轮询的汇总结果（顶部条计数/时刻/名单共用；已撤销通道不计入
/// 任何总数——老板 2026-10-08）。
class EntranceSummary {
  const EntranceSummary({
    required this.nameMap,
    required this.peerOnlineCount,
    required this.peerActiveTotal,
    required this.peerRevokedTotal,
    required this.myOtherTotal,
    required this.peerOnlineSince,
    required this.myOtherOnlineSince,
    required this.memberStates,
  });

  /// 通道名映射（entrance_id → 在用通道的 entrance_name，含本机；已撤销不映射）。
  final Map<String, String> nameMap;

  /// 对方**在线**通道数。
  final int peerOnlineCount;

  /// 对方**在用**通道总数（不含已撤销）。
  final int peerActiveTotal;

  /// 对方**已撤销**通道数（标题栏"全撤"第三态判定用）。
  final int peerRevokedTotal;

  /// 我的其它在用通道总数（不含本机——它由 @通道名 单独表示）。
  final int myOtherTotal;

  /// 对方在线通道 → 上线时刻（ms）。
  final Map<String, int> peerOnlineSince;

  /// 我的其它在线通道 → 上线时刻（ms；不含本机）。
  final Map<String, int> myOtherOnlineSince;

  /// 成员存在感聚合（group 名单点灯；不含我自己）。
  final Map<String, MemberPresence> memberStates;

  bool get peerHasOnline => peerOnlineCount > 0;

  /// 对方有通道但**全部已撤销**（标题栏第三态灯）。
  bool get peerAllRevoked => peerActiveTotal == 0 && peerRevokedTotal > 0;
}

/// 汇总 [rows]（/entrances 返回）：在线判定、计数、时刻表、成员聚合一次算齐。
///
/// 身份未落位（[myMemberId] 为空，新通道引导中）：退回按通道判定——非本机且在线
/// 的都算对方，不统计多通道数（与旧 TUI 行为一致）。
EntranceSummary summarizeEntrances(
  List<Map<String, dynamic>> rows, {
  String? myEntranceId,
  String? myMemberId,
  bool myWsOnline = false,
}) {
  final nameMap = <String, String>{};
  final memberStates = aggregateMemberStates(rows,
      myMemberId: myMemberId, myEntranceId: myEntranceId, myWsOnline: myWsOnline);
  var peerOnlineCount = 0;
  var peerActiveTotal = 0;
  var peerRevokedTotal = 0;
  var myOtherTotal = 0;
  final peerOnlineSince = <String, int>{};
  final myOtherOnlineSince = <String, int>{};
  final selfMemberId =
      (myMemberId == null || myMemberId.isEmpty) ? null : myMemberId;

  for (final row in rows) {
    final devId = (row['entrance_id'] as String?) ?? '';
    final isLocal = myEntranceId != null && devId.isNotEmpty && devId == myEntranceId;
    if (isEntranceRevoked(row)) {
      // 已撤销：独立状态——不映射名、不计入任何总数（老板 2026-10-08）。
      // 只有能确定归属对方时累计（用于标题栏"全撤"判定；member 聚合已在上方算好）。
      final pid = row['member_id'] as String?;
      if (!isLocal &&
          pid != null &&
          pid.isNotEmpty &&
          (selfMemberId == null || pid != selfMemberId)) {
        peerRevokedTotal++;
      }
      continue;
    }
    final devName = (row['entrance_name'] as String?) ?? '';
    if (devId.isNotEmpty && devName.isNotEmpty) nameMap[devId] = devName;
    final online =
        entranceRowState(row, myEntranceId: myEntranceId, myWsOnline: myWsOnline) ==
            EntranceRowState.online;
    final since = rowOnlineSince(row);
    final pid = row['member_id'] as String?;
    if (pid == null || pid.isEmpty || selfMemberId == null) {
      // 身份尚未落位：退回按通道判定，不统计多通道数
      if (!isLocal && online) {
        peerOnlineCount++;
        peerOnlineSince[devId] = since;
      }
      continue;
    }
    if (pid == selfMemberId) {
      // 本机不参与 #n/m 与通道列表（它由 @通道名 单独表示，不论在线与否）
      if (isLocal) continue;
      myOtherTotal++;
      if (online) myOtherOnlineSince[devId] = since;
      continue;
    }
    peerActiveTotal++;
    if (online) {
      peerOnlineCount++;
      peerOnlineSince[devId] = since;
    }
  }

  return EntranceSummary(
    nameMap: nameMap,
    peerOnlineCount: peerOnlineCount,
    peerActiveTotal: peerActiveTotal,
    peerRevokedTotal: peerRevokedTotal,
    myOtherTotal: myOtherTotal,
    peerOnlineSince: peerOnlineSince,
    myOtherOnlineSince: myOtherOnlineSince,
    memberStates: memberStates,
  );
}
