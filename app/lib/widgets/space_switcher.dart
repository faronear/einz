import 'dart:async';
import 'dart:typed_data';

import 'package:einz_shared/einz_shared.dart';
import 'package:flutter/material.dart';

import '../chat_entry.dart';
import '../data/app_lock.dart';
import '../data/local_database.dart';
import '../data/notify_settings.dart';
import '../data/server_config.dart';
import '../data/space_session.dart';
import '../data/vault_session.dart';
import '../l10n/app_localizations.dart';
import '../setup_page.dart';
import 'pin_prompt.dart';
import 'scrollable_card_area.dart';

/// 空间选择结果：选中某个空间，或"去新建/加入一个空间"。
class SpacePick {
  const SpacePick.space(this.spaceId) : add = false;
  const SpacePick.add()
      : spaceId = null,
        add = true;

  final String? spaceId;
  final bool add;
}

/// 卡片间距（横竖同值）+ 每行张数。
const double _kCardSpacing = 12;
const int _kCardsPerRow = 3;

/// 弹层**内容区**的最大宽度：modal bottom sheet 在 M3 下把内容限在 640，窗口再宽也不再长
/// （实测 800 / 1600 宽的视口，内容区都是 640、居中）。
const double _kSheetMaxWidth = 640;

/// 弹层内容区左右的内边距（下面 Padding 的 16）。
const double _kSheetHPadding = 16;

/// 卡片边长上限 = **弹层最大宽度**下"一行 3 张"的边长：608 − 两条 12 的间距，再均分
/// 3 份 = 194.67（`_cardSizeFor` 向下取整到 194，右边最多余 2px）。
///
/// 老板 2026-09-26：桌面窗口拉宽到弹层不再增长之后，卡片也不能先停止增长——原来上限
/// 硬写 160，宽窗口下三张卡只铺到 504，右边空一大截。手机上可用宽度够不到它，
/// 不影响"一行正好 3 张"。
/// 「更多通道」弹层有一份同口径的 `_entranceCardMaxSize`（chat_page.dart），改一处要改两处。
const double _kCardMaxSize = (_kSheetMaxWidth -
        _kSheetHPadding * 2 -
        _kCardSpacing * (_kCardsPerRow - 1)) /
    _kCardsPerRow;

/// 一张卡片的边长：由弹层**可用宽度反算**，保证一行正好放下 [_kCardsPerRow] 张
/// （老板 2026-09-24：iPhone 16 上固定 120 时，2 张空太多、3 张放不下）。
/// 向下取整，避免浮点误差把最后一张挤到下一行。
double _cardSizeFor(double availableWidth) {
  final raw =
      (availableWidth - _kCardSpacing * (_kCardsPerRow - 1)) / _kCardsPerRow;
  return raw.floorToDouble().clamp(64.0, _kCardMaxSize).toDouble();
}


/// 弹出「选择秘境」弹层：**小卡片瀑布流**（每张卡片 = 一个已加入的空间，写对方名字；
/// 右上角未读数字角标；当前空间描边 + 打勾），底部一条「＋ 新建/加入空间」通往第一屏。
///
/// 为什么是弹层而不是页面（老板 2026-09-22 定）：切换空间**不再需要锁屏码**——"当前空间"
/// 落在明文键上（见 `AppLockService.setActiveSpace`），其它空间的凭证已经在内存会话里
/// （[VaultSession]），聊天页自己就能完成"切到另一个空间"，不必跳出去再回来。
Future<SpacePick?> showSpacePicker(
  BuildContext context, {
  LocalDatabase? db,
  ApiClient? api,
}) =>
    showModalBottomSheet<SpacePick>(
      context: context,
      // 允许弹层用到满窗高（与「我的通道」弹层同口径，老板 2026-10-02）：
      // 默认上限 9/16 屏时窗口一开始缩小弹层就跟着缩；开了之后弹层高度保持
      // 到窗口压到其上边沿才一起往下压，矮窗由卡片区内滚吸收。
      isScrollControlled: true,
      builder: (_) => _SpacePickerSheet(
        db: db ?? LocalDatabase.shared,
        api: api,
      ),
    );

/// 切到另一个空间（**不需要锁屏码**）：更新明文键 → 用该空间的凭证**替换**当前聊天页。
///
/// `pushReplacement` 而不是 push：等价于"进入另一个空间"（重连 WS、重新同步、重建头像
/// 缓存），路由上也不留旧聊天页——旧页的数据可能已经因退出空间被删掉了。
Future<void> switchToSpace(
  BuildContext context,
  String spaceId, {
  LocalDatabase? db,
}) async {
  await AppLockService(db ?? LocalDatabase.shared).setActiveSpace(spaceId);
  final payload = VaultSession.current?.active;
  if (payload == null || payload.spaceId != spaceId) return; // 会话里没有：交给上层
  if (!context.mounted) return;
  await Navigator.of(context).pushReplacement(
    MaterialPageRoute(builder: (_) => buildChatPage(payload, db: db)),
  );
}

/// 「新建 / 加入空间」：**先过一次锁屏码**，再进第一屏（向导）。
///
/// 为什么要锁屏码：新增空间要把新凭证写进**加密锁包**（`addSpace` 必须给 pin），而弹层与
/// 聊天页都刻意不持有 pin（见 `widgets/pin_prompt.dart`）。老板 2026-09-22 定：整机清空
/// 太危险、不呈现给用户；但"往锁屏保护的身份里加一个空间"理应现验一次锁屏码。
Future<void> addSpaceFlow(
  BuildContext context, {
  LocalDatabase? db,
  ApiClient? api,
}) async {
  final database = db ?? LocalDatabase.shared;
  final lock = AppLockService(database);
  String? pin;
  if (await lock.isSetup) {
    if (!context.mounted) return;
    pin = await promptLockCode(context, db: database);
    if (pin == null || !context.mounted) return; // 取消
  }
  if (!context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => SetupPage(
      db: db,
      existingPin: pin, // 已有锁：向导不再问一次锁屏码
      onCompleted: (payload) async {
        await lock.addSpace(payload, pin: pin); // 新空间成为当前空间
        // 邮箱通知按设备共享（老板 2026-10-01）：新空间自动继承本机已设置的提醒
        // 邮箱——否则每加一个空间都得去弹窗里重存一次。后台 best-effort，
        // 失败静默（没继承上无非是重存一次），不阻塞进聊天页。
        // 尊重「应用于本机所有秘境」偏好（老板 2026-10-02）：不勾＝用户明确只要
        // 当前秘境收信，新建空间就不该被自动绑上。
        unawaited(NotifyAllSpacesPref(database)
            .load()
            .then((all) async {
              if (!all) return;
              final sources = _notifyEmailSourceSpaces(payload.spaceId);
              if (sources.isEmpty) return;
              await _inheritNotifyEmail(sources, payload, db: db);
            })
            .catchError((_) {}));
        if (!context.mounted) return;
        Navigator.of(context).pop(); // 关掉向导 → 回到聊天页
        if (!context.mounted) return;
        await switchToSpace(context, payload.spaceId, db: db); // 换进新空间
      },
    ),
  ));
}

/// 找一个**已设置了提醒邮箱**的旧空间（新空间继承地址的来源）。全离线判断不了
/// "有没有设置"——需要逐个空间问服务端，所以这里只挑出候选（其它空间），真正的
/// GET 在 [_inheritNotifyEmail] 里做，拿到第一个有地址的就停。
List<AppLockPayload> _notifyEmailSourceSpaces(String newSpaceId) {
  final vault = VaultSession.current;
  return (vault?.spaces ?? const <AppLockPayload>[])
      .where((s) => s.spaceId != newSpaceId && (s.token ?? '').isNotEmpty)
      .toList();
}

/// 把旧空间已设置的提醒邮箱回填到新空间（join/create 完成钩子，老板 2026-10-01）：
/// 逐个旧空间 GET 邮箱状态 → 拿到地址 → 对新空间 PUT。全部 best-effort：
/// 会话过期/离线/服务端没开邮件通知都静默放弃——这是锦上添花，不值得打扰用户
/// （"可观测性放代码里，不放 UI"既定原则）。地址在服务端是**地址级**验证
/// （notify_emails.verified_at），已验证地址 PUT 过去直接 verified，不重发确认信。
Future<void> _inheritNotifyEmail(
  List<AppLockPayload> sources,
  AppLockPayload newSpace, {
  LocalDatabase? db,
}) async {
  final client = ApiClient(effectiveServer);
  String? email;
  String lang = 'zh';
  for (final source in sources) {
    try {
      final status =
          await SpaceSessions.ofPayload(source, db: db).call((t) => client.getNotifyEmail(t));
      if (status.email == null || status.email!.isEmpty) continue;
      email = status.email;
      break; // 第一个有地址的就够了（按设备共享，各空间本就一致）
    } catch (_) {
      // 该空间拉不到（会话过期/离线）→ 换下一个
    }
  }
  if (email == null) return; // 本机还没设过邮箱，没东西可继承
  try {
    await SpaceSessions.ofPayload(newSpace, db: db)
        .call((t) => client.setNotifyEmail(email!, t, lang: lang));
  } catch (_) {
    // 回填失败就算了：用户在弹窗里重存一次即可
  }
}

class _SpacePickerSheet extends StatefulWidget {
  const _SpacePickerSheet({required this.db, this.api});

  final LocalDatabase db;
  final ApiClient? api;

  @override
  State<_SpacePickerSheet> createState() => _SpacePickerSheetState();
}

class _SpacePickerSheetState extends State<_SpacePickerSheet> {
  Map<
      String,
      ({
        String name,
        String peerName,
        String peerGender,
        String peerMemberId,
        bool peerJoined,
        bool isGroup,
        List<SpaceMemberBrief> others,
      })> _names = {};
  Map<String, int> _unread = {};
  String? _activeId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final lock = AppLockService(widget.db);
    final rows = await widget.db.select(widget.db.spaces).get();
    final out = <
        String,
        ({
          String name,
          String peerName,
          String peerGender,
          String peerMemberId,
          bool peerJoined,
          bool isGroup,
          List<SpaceMemberBrief> others,
        })>{};
    for (final row in rows) {
      var name = row.name;
      var peerName = row.peerName;
      var peerGender = '';
      // 性别只在 per-space 资料里（Spaces 表没这一列）→ 一律读一次（本空间 key-value，开销可忽略）
      final p = await lock.loadProfile(spaceId: row.spaceId);
      peerGender = (p['peerGender'] as String?) ?? '';
      if (name.isEmpty && peerName.isEmpty) {
        // Spaces 行还没被 saveProfile 写过（旧空间）：名字也一并回退 per-space 资料
        name = (p['memberName'] as String?) ?? '';
        peerName = (p['peerName'] as String?) ?? '';
      }
      out[row.spaceId] = (
        name: name,
        peerName: peerName,
        peerGender: peerGender,
        // 与 peerName/peerGender 同源：都是这份 per-space 资料里的并列字段。
        // 取不到（还没连过服务端 / 对方还没加入）→ 空串：卡片显示默认头像。
        peerMemberId: (p['peerMemberId'] as String?) ?? '',
        // 对方是否已入网：**只有明确的 false 才显示「待加入」**（null = 本机还没判断过，
        // 什么都不说——宁可少显示，也不要把"还没刷新"误报成"对方没来"）。
        peerJoined: (p['peerJoined'] as bool?) != false,
        // 空间类型（'duo' | 'group'）：创建时定死、永不改变，落在 per-space 资料里
        // （见 app_lock.saveProfile 的 mode 参数）。老记录没有这个键 → 回退 duo。
        isGroup: ((p['mode'] as String?) ?? 'duo') == 'group',
        // 除我之外的成员（按加入先后）：群组卡片平铺 2×2 用。老记录/离线还没拉过
        // → 空列表（卡片退回"单一头像 + 待加入"那套）
        others: [
          for (final m in (p['otherMembers'] as List<dynamic>? ?? const []))
            if (m is Map)
              (memberId: (m['id'] as String?) ?? '', name: (m['name'] as String?) ?? ''),
        ],
      );
    }
    final vault = VaultSession.current;
    final activeId = vault == null ? null : await lock.resolveActiveSpaceId(vault);
    // 未读：服务端派生（GET /messages/unread），逐个空间 best-effort。
    // **走各空间的会话**（不是裸 token）：会话 24h 过期，拿 Vault 里那份旧 token 直接
    // 请求会 401 → 被 catchError 吞成 0 → 未读角标静默消失（2026-09-26 修）。
    final client = widget.api ?? ApiClient(effectiveServer);
    final spaces = vault?.spaces ?? const <AppLockPayload>[];
    final counts = await Future.wait([
      for (final s in spaces)
        (s.token ?? '').isEmpty
            ? Future.value(0)
            : SpaceSessions.ofPayload(s, db: widget.db)
                .call((t) => client.unreadCount(t))
                .catchError((_) => 0),
    ]);
    if (!mounted) return;
    setState(() {
      _names = out;
      _activeId = activeId;
      _unread = {for (var i = 0; i < spaces.length; i++) spaces[i].spaceId: counts[i]};
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spaces = VaultSession.current?.spaces ?? const <AppLockPayload>[];
    return SafeArea(
      child: Padding(
        // 顶边 0：标题自己的 Padding 负责上 14 留白（同参照弹层）
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 标题**居中**、上 14 下 10（老板 2026-09-25：与「界面语言」/「界面主题」
            // /「附件存储」/「阅后即焚」弹层标题的居中与留白口径对齐）
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
              child: Center(
                child: Text(l10n.spaceListTitle,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 16)),
              ),
            ),
            // 小卡片瀑布流：每张卡片 = 一个空间（强调"空间"概念，而不是聊天对象）
            if (spaces.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(l10n.spaceListEmpty,
                    style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.outline)),
              )
            else
              // 卡片排到两行以上 + 窗口矮 → 在这一块内部滚动（不再把整个弹层撑破，
              // 老板 2026-09-28 桌面实测）。卡片排得下时不滚动、观感与原来一致。
              // 卡片排到两行以上 + 窗口矮 → 在这一块内部滚动（不再把整个弹层撑破，
              // 老板 2026-09-28 桌面实测）。卡片排得下时不滚动、观感与原来一致。
              ScrollableCardArea(
                // 卡片**边长按可用宽度反算**，保证一行正好 3 张（老板 2026-09-24：
                // iPhone 16 上固定 120 时，2 张空太多、3 张放不下）。
                // 不满 3 张的行由 Wrap 默认的 `WrapAlignment.start` 靠左。
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final size = _cardSizeFor(constraints.maxWidth);
                    return Wrap(
                      spacing: _kCardSpacing,
                      runSpacing: _kCardSpacing,
                      children: [
                        for (final space in spaces)
                          _SpaceCard(
                            size: size,
                            name: _titleOf(space),
                            peerGender: _names[space.spaceId]?.peerGender ?? '',
                            peerMemberId: _names[space.spaceId]?.peerMemberId ?? '',
                            peerPending: _names[space.spaceId]?.peerJoined == false,
                            isGroup: _names[space.spaceId]?.isGroup ?? false,
                            others: _names[space.spaceId]?.others ??
                                const <SpaceMemberBrief>[],
                            server: effectiveServer,
                            api: widget.api,
                            unread: _unread[space.spaceId] ?? 0,
                            current: space.spaceId == _activeId,
                            onTap: () =>
                                Navigator.of(context).pop(SpacePick.space(space.spaceId)),
                          ),
                      ],
                    );
                  },
                ),
              ),
            const SizedBox(height: 8),
            // 「添加秘境」：**常态就是淡灰底**，提示"这里可以点"；鼠标悬浮/按住再渐变深色
            // （老板 2026-09-24：原先只有按住才有底色，看不出可点）。
            // 与卡片之间不再要分隔线（老板 2026-09-24）。
            Material(
              color: Colors.black.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(12),
              clipBehavior: Clip.antiAlias, // 让 ink 跟着圆角裁
              child: InkWell(mouseCursor: SystemMouseCursors.click,
                onTap: () => Navigator.of(context).pop(const SpacePick.add()),
                hoverColor: Colors.black.withValues(alpha: 0.10),
                highlightColor: Colors.black.withValues(alpha: 0.14),
                // 图标 + 文字整体**居中**（老板 2026-09-25；原 ListTile 的 leading 靠左）
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.add),
                      const SizedBox(width: 6),
                      Text(l10n.spaceListAdd),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 卡片上的名字：**对方名字**优先（老板 2026-09-22：卡片代表空间，上面写对方的名字即可）；
  /// 取不到再退回"我的名字"、空间 id。
  String _titleOf(AppLockPayload space) {
    final n = _names[space.spaceId];
    if ((n?.peerName ?? '').isNotEmpty) return n!.peerName;
    if ((n?.name ?? '').isNotEmpty) return n!.name;
    return space.spaceId;
  }
}

/// 切空间卡片上要平铺的一个成员（群组空间用）：member_id（拉头像）+ 显示名。
typedef SpaceMemberBrief = ({String memberId, String name});

/// 切空间卡片底色（老板 2026-10-04 定的四条规则）：
///
/// | 空间 | 取色 | 未选中（淡） | 当前（深） |
/// | --- | --- | --- | --- |
/// | duo + 性别已知 | 按性别 | 女 #D6529C / 男 #3BAFFD 的 18% tint | 女 #B83D80 / 男 #2271F7 |
/// | duo + 性别未知（对方还没加入 / 从没登记过性别） | **青** | #26C6DA 22% tint | #00838F |
/// | group | **紫** | #9575CD 18% tint | #6A4FB6 |
///
/// - 粉/蓝是**性别的象征色**（与对话气泡同源：淡 = 素雅主题气泡、深 = 渐变主题气泡）。
/// - 青 = "**还不知道是谁**"：系统里已在两处用它表同一件事——同性别第二人气泡
///   （`chat_page._bubbleColor`）与群气泡色板第 3 色。沿用，不新造色。
/// - 紫是给群组的（老板让我挑）：粉/蓝/青分别被"女/男/未知"占着，群组不该借用其中
///   任何一个（否则一眼看不出这是个群）；紫与它们同处品牌色系（群气泡色板里就有），
///   且不带性别联想的包袱。
///
/// 提成顶层函数是为了**可单测**（`test/space_card_color_test.dart` 逐条钉住上表）。
Color spaceCardColor({
  required bool isGroup,
  required String peerGender,
  required bool current,
}) {
  if (isGroup) {
    return current
        ? const Color(0xFF6A4FB6) // 深紫
        : const Color(0xFF9575CD).withValues(alpha: 0.18); // 紫 tint
  }
  if (peerGender == 'female') {
    return current
        ? const Color(0xFFB83D80)
        : const Color(0xFFD6529C).withValues(alpha: 0.18);
  }
  if (peerGender == 'male') {
    return current
        ? const Color(0xFF2271F7)
        : const Color(0xFF3BAFFD).withValues(alpha: 0.18);
  }
  // 性别未知（对方尚未加入 / 没登记过性别）→ 青
  return current
      ? const Color(0xFF00838F)
      : const Color(0xFF26C6DA).withValues(alpha: 0.22);
}

class _SpaceCard extends StatelessWidget {
  const _SpaceCard({
    required this.size,
    required this.name,
    required this.peerGender,
    required this.peerMemberId,
    required this.peerPending,
    required this.isGroup,
    required this.others,
    required this.server,
    required this.api,
    required this.unread,
    required this.current,
    required this.onTap,
  });

  /// 卡片边长（正方形，含内边距）——由 [_cardSizeFor] 按弹层宽度算出。
  final double size;
  final String name;
  /// 对方性别（male/female/''）：卡片底色按它取色——选中深粉 / 深蓝，未选中淡粉 / 淡蓝；
  /// 未知 → 不给底色，用 Card 默认表面色。
  final String peerGender;
  /// 该空间里对方的 member_id（头像用；空串 → 显示默认头像）。
  final String peerMemberId;

  /// 对方**明确尚未加入**（服务端通道表里除我之外没有别的成员）→ 名字下显示「待加入」。
  /// 注意与 `peerMemberId` 为空的区别：后者也可能是"本机还没刷新过"，那种情况不该报状态。
  final bool peerPending;

  /// 群组空间（mode='group'）→ 用紫色，不按性别取色（一群人没有"对方的性别"可言）。
  final bool isGroup;

  /// 本空间**除我之外**的成员（按加入先后）：群组卡片平铺 2×2 头像+名字用。
  final List<SpaceMemberBrief> others;
  final String server;
  final ApiClient? api;
  final int unread;
  final bool current;
  final VoidCallback onTap;

  /// 卡片底色（规则见顶层 [spaceCardColor]）：当前空间用深色，其余用同色淡 tint。
  Color get _background => spaceCardColor(
        isGroup: isGroup,
        peerGender: peerGender,
        current: current,
      );

  /// 前景色（名字 / 对勾）：**当前空间**一定是深色底 → 白字；其余（淡色 tint）
  /// 返回 null → 回退主题默认深色字。
  Color? get _foreground => current ? Colors.white : null;

  /// 单人（duo）卡片的正文：头像在上、名字在下，整块**居中**
  /// （老板 2026-09-23 / 2026-09-24）。
  Widget _buildSingleBody(BuildContext context, ThemeData theme) {
    // 头像半径随卡片收缩：老板定的 24（"头像再大两号"）是**大卡片**上的取值，
    // 卡片边长最小可到 64（`_cardSizeFor` 的下限，窄窗口），那时内容区只有 48，
    // 固定的 Ø48 头像 + 6 间距 + 「待加入」那行必然溢出（实测 6px，2026-10-04）。
    // 0.22 的系数在手机上（边长 ~111）刚好回到 24，桌面（194）也是 24 → 观感不变，
    // 只在窄窗口里等比缩小。
    final singleRadius =
        (size * 0.22).clamp(10.0, _PeerAvatar.defaultRadius).toDouble();
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _PeerAvatar(
            memberId: peerMemberId, server: server, api: api, radius: singleRadius),
        const SizedBox(height: 6),
        // Flexible：名字最多 2 行、超出「…」，空间不够时也只会被压缩而不会把卡片撑破
        // （老板 2026-09-24）。「待加入」时收成 1 行：卡片是固定正方形，要给状态行留位置。
        Flexible(
          child: Text(
            name,
            maxLines: peerPending ? 1 : 2,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        // 「待加入」（老板 2026-09-25）：把"对方还没来"与"来了但没设头像"区分开——
        // 后者不显示任何状态行。
        if (peerPending) ...[
          const SizedBox(height: 2),
          Text(
            AppLocalizations.of(context)!.memberPending,
            style: TextStyle(
              fontSize: 11,
              color: (_foreground ?? theme.colorScheme.onSurfaceVariant)
                  .withValues(alpha: 0.85),
            ),
          ),
        ],
      ],
    );
  }

  /// **还没有人加入**（duo 对方未加入 / group 除我之外无人）时的占位正文
  /// （老板 2026-10-06）：名字区域只显示「待加入」，**不再显示我自己的名字/头像**。
  /// 图标：duo = 默认个人头像（灰底人形，与 `_PeerAvatar` 无 id 时的默认同款）；
  /// group = 创建向导第一页「群组秘境」卡片同款 `groups_outlined`（品牌蓝）。
  Widget _buildPendingBody(BuildContext context, ThemeData theme) {
    final singleRadius =
        (size * 0.22).clamp(10.0, _PeerAvatar.defaultRadius).toDouble();
    final iconRadius = isGroup ? (size * 0.28).clamp(12.0, 30.0) : singleRadius;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // group：向导第一页同款图标（groups_outlined，品牌蓝）；
        // duo：默认个人头像（与 _PeerAvatar 的默认态一致：灰底 + 人形图标）
        if (isGroup)
          CircleAvatar(
            radius: iconRadius,
            backgroundColor:
                const Color(0xFF3BAFFD).withValues(alpha: 0.18),
            child: Icon(Icons.groups_outlined,
                size: iconRadius * 1.1, color: const Color(0xFF3BAFFD)),
          )
        else
          CircleAvatar(
            radius: singleRadius,
            backgroundColor: theme.colorScheme.onSurface.withValues(alpha: 0.12),
            child: Icon(Icons.person,
                size: singleRadius,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
          ),
        const SizedBox(height: 6),
        Flexible(
          child: Text(
            AppLocalizations.of(context)!.memberPending,
            maxLines: 1,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            // 「待加入」比正常名字淡一档（老板 2026-10-06）：它是状态不是名字，
            // 不该与人名同样抢眼。当前空间白字底下也压 alpha 保持淡感。
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: (_foreground ?? theme.colorScheme.onSurface)
                  .withValues(alpha: 0.55),
            ),
          ),
        ),
      ],
    );
  }

  /// 群组卡片的正文：**除我之外**的成员按加入先后平铺成 2×2（头像 + 名字）。
  ///
  /// 尺寸全部由卡片边长 [size] 反算：边长跨度很大（窄窗下限 64 → 桌面弹层上限 194），
  /// 写死像素在两头都会出事（要么溢出、要么小得看不清）。三条自适应规则：
  /// - 头像半径、名字字号都按**格子的边长**成比例取，并各自夹在合理区间；
  /// - 格子小到装不下"头像 + 一行名字"（< 32）→ **只画头像**，宁可少画也不溢出；
  /// - 超过 4 个成员 → 前 3 个 + 第 4 格显示「+N」（默认配置 4 人再去掉我最多 3 个，
  ///   这条是给自部署把 maxMembersPerSpace 调大留的）。
  Widget _buildMembersGrid(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // 内容区 = 边长 − 内边距 8×2；两列之间留 4
    final cell = (size - 16 - 4) / 2;
    final radius = (cell * 0.32).clamp(8.0, 26.0);
    final nameSize = (cell * 0.22).clamp(8.0, 13.0);
    final showName = cell >= 32;

    final overflow = others.length > 4 ? others.length - 3 : 0;
    final shown = overflow > 0 ? others.take(3).toList() : others;
    final cells = <Widget>[
      for (final m in shown)
        _memberCell(context, l10n,
            memberId: m.memberId, name: m.name, radius: radius,
            showName: showName, nameSize: nameSize),
      if (overflow > 0) _overflowCell(context, overflow, radius, showName, nameSize),
    ];

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var row = 0; row < 2; row++) ...[
            if (row > 0) const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var col = 0; col < 2; col++) ...[
                  if (col > 0) const SizedBox(width: 4),
                  SizedBox(
                    // 格子正方：2×2 铺满卡片内容区，单数成员时最后一格留空
                    width: cell,
                    height: cell,
                    child: row * 2 + col < cells.length
                        ? cells[row * 2 + col]
                        : const SizedBox.shrink(),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// 一格成员：小头像 + 一行名字（名字空 → 「未命名」；格子太矮就不画名字）。
  Widget _memberCell(
    BuildContext context,
    AppLocalizations l10n, {
    required String memberId,
    required String name,
    required double radius,
    required bool showName,
    required double nameSize,
  }) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        _PeerAvatar(memberId: memberId, server: server, api: api, radius: radius),
        if (showName) ...[
          const SizedBox(height: 2),
          Text(
            name.isEmpty ? l10n.chatPageMembersUnnamed : name,
            maxLines: 1,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            // height 写死：格子的高度是**算出来**的（cell = 2*radius + 2 + 行高），
            // 行高交给字体默认值会让某些平台字体（行距 1.4+）把格子撑破。
            style: TextStyle(
                fontSize: nameSize, fontWeight: FontWeight.w500, height: 1.1),
          ),
        ],
      ],
    );
  }

  /// 第 4 格：成员超过 4 个时的「+N」。
  Widget _overflowCell(
    BuildContext context,
    int count,
    double radius,
    bool showName,
    double nameSize,
  ) {
    final theme = Theme.of(context);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        CircleAvatar(
          radius: radius,
          backgroundColor: theme.colorScheme.onSurface.withValues(alpha: 0.12),
          child: Text('+$count',
              style: TextStyle(fontSize: radius * 0.8, fontWeight: FontWeight.w600)),
        ),
        if (showName) ...[
          const SizedBox(height: 2),
          // 占位：与其它格（头像 + 名字）等高，保证 2×2 的行基线对齐
          Text(' ', style: TextStyle(fontSize: nameSize, height: 1.1)),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 底色 / 阴影 / 对勾的**渐变过程**（老板 2026-09-23：只保留颜色渐变，去掉放大动画）。
    const anim = Duration(milliseconds: 200);
    return SizedBox(
      // 尺寸**固定正方形**，边长按可用宽度反算，保证一行正好 3 张
      // （老板 2026-09-24：长方形不好看；iPhone 16 上 2 张空太多、3 张放不下）。
      // 选中不放大 → Wrap 不重排、弹层不跳高（老板 2026-09-23）。
      width: size,
      height: size,
      child: AnimatedContainer(
        duration: anim,
        curve: Curves.easeOut,
        // 立体阴影：只在卡片**四边之外**投一层柔和光晕，绝不在卡片底色上叠东西。
        // （早先用 Material 的 elevation，它会往底色叠 surfaceTint 把颜色压暗——就是
        // 老板说的"发暗"；这里改用 BoxDecoration 的纯外阴影，底色永远是 _background 本身。）
        decoration: BoxDecoration(
          color: _background,
          borderRadius: BorderRadius.circular(12),
          // **当前正在使用的空间：用阴影做出"浮起来"的立体感**（老板 2026-10-04）。
          // 两层叠加才像立体：近处一层小而实（贴着卡片边缘，交代"它离你更近"），
          // 远处一层大而柔（环境光晕）。单层阴影只会看着像描了一圈灰边。
          // 一律外阴影、不叠在底色上——早期用 Material elevation 会往底色叠
          // surfaceTint 把颜色压暗（老板说的"发暗"），这里不碰底色。
          boxShadow: current
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.30),
                    blurRadius: 5,
                    offset: const Offset(0, 2),
                  ),
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.16),
                    blurRadius: 14,
                    offset: const Offset(0, 6),
                  ),
                ]
              : const <BoxShadow>[],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(mouseCursor: SystemMouseCursors.click,
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: Padding(
              // 内边距 8（原 10）：卡片边长在 3 张/行时约 112，留出空间给
              //「头像 48 + 名字两行」
              padding: const EdgeInsets.all(8),
              // 名字颜色跟着底色一起渐变（否则底色还在淡粉时字已经先跳成白的）
              child: AnimatedDefaultTextStyle(
                duration: anim,
                curve: Curves.easeOut,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: _foreground ?? theme.colorScheme.onSurface,
                ),
                // StackFit.expand：让非定位子项吃满整块，Column 才能真正**居中**
                // （默认 loose 下 Column 会缩到内容宽度并被摆到左上角 → 看着像靠左）
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // 内容：群组有人时平铺成员（2×2）；**还没有人加入**（peerPending）
                    // 时 duo/group 都显示占位正文（老板 2026-10-06：duo=默认头像，
                    // group=向导第一页同款群组图标；名字区域都是「待加入」——
                    // 不再显示我自己的名字和头像）；其余是"头像在上+名字在下"居中块
                    if (isGroup && others.isNotEmpty)
                      _buildMembersGrid(context)
                    else if (peerPending)
                      _buildPendingBody(context, theme)
                    else
                      _buildSingleBody(context, theme),
                    // 对勾用淡入而非 if(current)：跟着底色一起出现，不在淡色底上先白着跳出来。
                    // **左上角**（老板 2026-09-24）：右下角会盖住名字；与右上角的未读角标各占一角。
                    AnimatedOpacity(
                      opacity: current ? 1 : 0,
                      duration: anim,
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: Icon(Icons.check_circle,
                            size: 20, color: _foreground ?? theme.colorScheme.primary),
                      ),
                    ),
                    // 未读角标 → **右上角**（与左上角的对勾分居两角，互不遮挡）
                    if (unread > 0)
                      Positioned(
                        right: 0,
                        top: 0,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.error,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            unread > 99 ? '99+' : '$unread',
                            style: const TextStyle(
                                color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 空间卡片上的**对方头像**（老板 2026-09-23：头像在上、名字在下，居中）。
///
/// - 有头像就用头像；没有（memberId 未知 / 服务端没有 / 网络失败）→ **默认头像**：
///   灰底 + 人形图标，与消息流那套 `chat_page._MessageAvatar` 观感一致（同一组色值/图标）。
/// - 刻意**不做跨开合缓存**：弹层每次打开都重拉一次。这样对方换了头像立刻就对，
///   不必再维护一套失效广播；成本与弹层已有的「每空间一次 unreadCount」同量级。
class _PeerAvatar extends StatefulWidget {
  const _PeerAvatar({
    required this.memberId,
    required this.server,
    this.api,
    this.radius = defaultRadius,
  });

  /// 对方的 member_id（空串 = 未知 → 直接显示默认头像，不发请求）。
  final String memberId;
  final String server;
  final ApiClient? api;

  /// 本实例的头像半径。单人卡片用 [defaultRadius]（24，老板 2026-09-24："空间的
  /// 核心是对方是谁，头像再大两号"）；群组卡片的 2×2 小格按格子边长传更小的值
  /// （见 `_SpaceCard._buildMembersGrid`）。
  final double radius;

  /// 单人卡片的头像半径：18 → 24（老板 2026-09-24）
  static const double defaultRadius = 24;

  @override
  State<_PeerAvatar> createState() => _PeerAvatarState();
}

class _PeerAvatarState extends State<_PeerAvatar> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _PeerAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 必须补这一下（老板 2026-09-25 实测的 bug：对方明明有头像，卡片却永远是默认人形）：
    // 弹层的 `_load()` 是**异步**的（先读 Spaces 表、再逐空间读 per-space 资料），
    // 首帧建卡片时 memberId 还是空串 → `initState` 那次 `_load()` 直接 return；
    // memberId 到位后父级重建，State 复用、不会重走 initState，于是再没人去拉头像。
    // （同一原因不影响未读角标：它每次 build 都从 `_unread` 现读，而头像把结果
    //   存在 State 里，所以必须自己补拉一次。）
    if (widget.memberId != oldWidget.memberId && _bytes == null) _load();
  }

  Future<void> _load() async {
    final pid = widget.memberId;
    if (pid.isEmpty) return; // 未知：保持默认头像
    try {
      final bytes = await (widget.api ?? ApiClient(widget.server)).getAvatar(pid);
      if (bytes != null && mounted) setState(() => _bytes = bytes);
    } catch (_) {
      // 网络失败：保持默认头像
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    return CircleAvatar(
      radius: widget.radius,
      backgroundColor: Colors.grey.shade300,
      backgroundImage: bytes != null ? MemoryImage(bytes) : null,
      // 默认头像：人形图标（尺寸按半径等比：radius 24 → 26）
      child: bytes == null ? Icon(Icons.person, size: widget.radius * 1.08) : null,
    );
  }
}
