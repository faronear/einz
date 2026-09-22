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
  Map<String, ({String name, String peerName})> _names = {};
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
    final out = <String, ({String name, String peerName})>{};
    for (final row in rows) {
      var name = row.name;
      var peerName = row.peerName;
      if (name.isEmpty && peerName.isEmpty) {
        // Spaces 行还没被 saveProfile 写过（旧空间）：回退 per-space 资料
        final p = await lock.loadProfile(spaceId: row.spaceId);
        name = (p['personName'] as String?) ?? '';
        peerName = (p['peerName'] as String?) ?? '';
      }
      out[row.spaceId] = (name: name, peerName: peerName);
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
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final space in spaces)
                    _SpaceCard(
                      name: _titleOf(space),
                      unread: _unread[space.spaceId] ?? 0,
                      current: space.spaceId == _activeId,
                      onTap: () => Navigator.of(context).pop(SpacePick.space(space.spaceId)),
                    ),
                ],
              ),
            const SizedBox(height: 12),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.add),
              title: Text(l10n.spaceListAdd),
              onTap: () => Navigator.of(context).pop(const SpacePick.add()),
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
    required this.name,
    required this.unread,
    required this.current,
    required this.onTap,
  });

  final String name;
  final int unread;
  final bool current;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 104,
      height: 96,
      child: Card(
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: current
              ? BorderSide(color: theme.colorScheme.primary, width: 2)
              : BorderSide.none,
        ),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Stack(
              children: [
                Align(
                  alignment: Alignment.topLeft,
                  child: Text(
                    name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ),
                if (current)
                  Align(
                    alignment: Alignment.bottomRight,
                    child: Icon(Icons.check_circle, size: 16, color: theme.colorScheme.primary),
                  ),
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
    );
  }
}
