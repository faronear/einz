import 'dart:typed_data';

import 'package:einz_shared/einz_shared.dart';
import 'package:flutter/material.dart';

import '../chat_entry.dart';
import '../data/app_lock.dart';
import '../data/local_database.dart';
import '../data/server_config.dart';
import '../data/vault_session.dart';
import '../l10n/app_localizations.dart';
import '../setup_page.dart';
import 'pin_prompt.dart';

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

/// 桌面大窗口的卡片边长上限：不设的话窗口一宽卡片会离谱地大。
/// 手机上（可用宽度 < 3*160+2*12 = 504）不影响"正好 3 张"。
const double _kCardMaxSize = 160;

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
        if (!context.mounted) return;
        Navigator.of(context).pop(); // 关掉向导 → 回到聊天页
        if (!context.mounted) return;
        await switchToSpace(context, payload.spaceId, db: db); // 换进新空间
      },
    ),
  ));
}

class _SpacePickerSheet extends StatefulWidget {
  const _SpacePickerSheet({required this.db, this.api});

  final LocalDatabase db;
  final ApiClient? api;

  @override
  State<_SpacePickerSheet> createState() => _SpacePickerSheetState();
}

class _SpacePickerSheetState extends State<_SpacePickerSheet> {
  Map<String, ({String name, String peerName, String peerGender, String peerMemberId})>
      _names = {};
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
    final out =
        <String, ({String name, String peerName, String peerGender, String peerMemberId})>{};
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
      );
    }
    final vault = VaultSession.current;
    final activeId = vault == null ? null : await lock.resolveActiveSpaceId(vault);
    // 未读：服务端派生（GET /messages/unread），逐个空间 best-effort
    final client = widget.api ?? ApiClient(effectiveServer);
    final spaces = vault?.spaces ?? const <AppLockPayload>[];
    final counts = await Future.wait([
      for (final s in spaces)
        (s.token ?? '').isEmpty
            ? Future.value(0)
            : client.unreadCount(s.token!).catchError((_) => 0),
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
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.spaceListTitle,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            // 小卡片瀑布流：每张卡片 = 一个空间（强调"空间"概念，而不是聊天对象）
            if (spaces.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(l10n.spaceListEmpty,
                    style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.outline)),
              )
            else
              // 卡片**边长按可用宽度反算**，保证一行正好 3 张（老板 2026-09-24：
              // iPhone 16 上固定 120 时，2 张空太多、3 张放不下）。
              // 不满 3 张的行由 Wrap 默认的 `WrapAlignment.start` 靠左。
              LayoutBuilder(
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
            const SizedBox(height: 8),
            // 「添加秘境」：**常态就是淡灰底**，提示"这里可以点"；鼠标悬浮/按住再渐变深色
            // （老板 2026-09-24：原先只有按住才有底色，看不出可点）。
            // 与卡片之间不再要分隔线（老板 2026-09-24）。
            Material(
              color: Colors.black.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(12),
              clipBehavior: Clip.antiAlias, // 让 ink 跟着圆角裁
              child: InkWell(
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

class _SpaceCard extends StatelessWidget {
  const _SpaceCard({
    required this.size,
    required this.name,
    required this.peerGender,
    required this.peerMemberId,
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
  final String server;
  final ApiClient? api;
  final int unread;
  final bool current;
  final VoidCallback onTap;

  /// 卡片底色（老板 2026-09-23 定的对照关系）：
  /// - **被选中** → 饱和"深色"：女 #B83D80（深粉）/ 男 #2271F7（深蓝）——与对话里
  ///   **渐变粉蓝主题** 的气泡同色（见 chat_page.dart 的 _bubbleColor）。
  /// - **未选中** → 对应的"淡色"：女 #D6529C / 男 #3BAFFD 的 18% tint——与对话里
  ///   **素雅纯色主题** 的气泡同色。
  /// - 性别未登记 → 不给底色（选中 / 未选中都不给），用 Card 默认表面色。
  Color? get _background {
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
    return null;
  }

  /// 前景色（名字 / 对勾）：只有"选中 + 有底色"（即深色底）才用白色，
  /// 淡色底 / 无底色都返回 null → 回退主题默认深色字。
  Color? get _foreground =>
      (current && _background != null) ? Colors.white : null;

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
          boxShadow: current
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.26),
                    blurRadius: 10,
                  ),
                ]
              : const <BoxShadow>[],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
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
                    // 头像在上、名字在下，整块**居中**（老板 2026-09-23 / 2026-09-24）
                    Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        _PeerAvatar(
                          memberId: peerMemberId,
                          server: server,
                          api: api,
                        ),
                        const SizedBox(height: 6),
                        // Flexible：名字最多 2 行、超出「…」，空间不够时也只会被压缩
                        // 而不会把卡片撑破（老板 2026-09-24）
                        Flexible(
                          child: Text(
                            name,
                            maxLines: 2,
                            textAlign: TextAlign.center,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
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
  });

  /// 对方的 member_id（空串 = 未知 → 直接显示默认头像，不发请求）。
  final String memberId;
  final String server;
  final ApiClient? api;

  /// 头像半径：18 → 24（老板 2026-09-24：空间的核心是对方是谁，头像再大两号）
  static const double radius = 24;

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
      radius: _PeerAvatar.radius,
      backgroundColor: Colors.grey.shade300,
      backgroundImage: bytes != null ? MemoryImage(bytes) : null,
      // 默认头像：人形图标（尺寸按半径等比：radius 24 → 26）
      child: bytes == null ? const Icon(Icons.person, size: 26) : null,
    );
  }
}
