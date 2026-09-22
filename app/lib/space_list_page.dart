import 'package:einz_shared/einz_shared.dart';
import 'package:flutter/material.dart';

import 'chat_entry.dart';
import 'data/app_lock.dart';
import 'data/local_database.dart';
import 'data/server_config.dart';
import 'l10n/app_localizations.dart';
import 'setup_page.dart';

/// 本机已加入的空间列表：点击进入；底部按钮通往第一屏（创建/加入）。
///
/// 出现时机（见 `aimemo/multiSpaceDesign.zhcn.md` §5）：
/// - 冷启动：Vault 里超过一个空间时作为启动落点；
/// - 聊天页：菜单「切换空间」退回本页；
/// - 设置入口：任何情况下都能进（单空间用户也能从这里加第二个空间）。
///
/// **本页不做任何破坏性操作**（老板 2026-09-22 定）：
/// - 「移除某个空间」不在这里——它与聊天页菜单里的「退出并清除这个空间」是同一件事，
///   留两处只会让人以为是两种不同的操作；退出后自然回到本页（空了就回向导）；
/// - 「清除本设备全部数据」（整机清空）**不呈现给用户**：太危险。用户想要"清干净"的
///   等价路径是逐个退出空间，或直接卸载重装（`ensureFreshInstall` 会清掉残留密钥）。
///
/// [vault] 是解锁后内存里的凭证集合；[pin] 在 PIN 模式下必须给（改写密文包需要它），
/// 无锁（跳过 PIN）场景为 null。[api] 仅测试注入用；默认按 [effectiveServer] 新建。
class SpaceListPage extends StatefulWidget {
  const SpaceListPage({super.key, required this.vault, this.pin, this.db, this.api});

  final VaultPayload vault;

  /// PIN 模式下的锁屏码（仅内存持有，用于 addSpace/removeSpace/setActiveSpace）。
  final String? pin;

  /// 测试注入用；默认 [LocalDatabase.shared]。
  final LocalDatabase? db;

  /// 测试注入用（退役调用）；默认 `ApiClient(effectiveServer)`。
  final ApiClient? api;

  @override
  State<SpaceListPage> createState() => _SpaceListPageState();
}

class _SpaceListPageState extends State<SpaceListPage> {
  late VaultPayload _vault;
  late final AppLockService _lock;
  Map<String, ({String name, String peerName})> _names = {};

  /// 各空间未读数（服务端派生，见 [_loadUnread]）。
  Map<String, int> _unread = {};

  @override
  void initState() {
    super.initState();
    _vault = widget.vault;
    _lock = AppLockService(widget.db ?? LocalDatabase.shared);
    _loadNames();
    _loadUnread();
  }

  /// 拉各空间未读数：`GET /messages/unread`，用**各空间自己的 token**（会话绑定空间）。
  ///
  /// 老板 2026-09-22 定：**服务端派生**，不做"冷启动逐空间拉历史"那套本地方案
  /// （`repo.sync()` 会循环拉到 hasMore=false，久未打开的空间等于把积压全量拉下来）；
  /// 读取水位本来就在服务器上（客户端在"用户真看到最新消息"时才上报）。
  /// 代价：离线时列表没有角标（可接受）。
  Future<void> _loadUnread() async {
    final client = widget.api ?? ApiClient(effectiveServer);
    final spaces = _vault.spaces;
    final counts = await Future.wait([
      for (final s in spaces)
        (s.token ?? '').isEmpty
            ? Future.value(0)
            // 单个空间失败（离线/会话过期）不该拖垮其余：吞掉异常，该项按 0 处理
            : client.unreadCount(s.token!).catchError((_) => 0),
    ]);
    if (!mounted) return;
    setState(() {
      _unread = {
        for (var i = 0; i < spaces.length; i++) spaces[i].spaceId: counts[i],
      };
    });
  }

  Future<void> _loadNames() async {
    final db = widget.db ?? LocalDatabase.shared;
    final rows = await db.select(db.spaces).get();
    final out = <String, ({String name, String peerName})>{};
    for (final row in rows) {
      var name = row.name;
      var peerName = row.peerName;
      if (name.isEmpty && peerName.isEmpty) {
        // Spaces 行还没被 saveProfile 写过（旧空间）：回退 per-space 资料
        final p = await _lock.loadProfile(spaceId: row.spaceId);
        name = (p['personName'] as String?) ?? '';
        peerName = (p['peerName'] as String?) ?? '';
      }
      out[row.spaceId] = (name: name, peerName: peerName);
    }
    if (!mounted) return;
    setState(() => _names = out);
  }

  Future<void> _reload() async {
    final v = widget.pin != null ? await _lock.unlockVault(widget.pin!) : await _lock.loadVault();
    if (v == null) return;
    if (!mounted) return;
    if (v.spaces.isEmpty) {
      // 一个空间都不剩：回到全新入网向导（从聊天页「退出并清除这个空间」退回本页时，
      // 若那是最后一个空间就会走到这里）。
      await Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => SetupPage(db: widget.db)),
        (route) => false,
      );
      return;
    }
    setState(() => _vault = v);
    await _loadNames();
    await _loadUnread(); // 从空间返回时未读会变（那边看过了 / 又来新消息）
  }

  /// 进入某个空间：置为 active → push 聊天页（返回即回列表）。
  Future<void> _enter(AppLockPayload payload) async {
    await _lock.setActiveSpace(payload.spaceId, pin: widget.pin);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => buildChatPage(
        payload,
        db: widget.db,
        onSwitchSpace: () => Navigator.of(context).pop(),
      ),
    ));
    // 从聊天页返回：空间可能被删除/新增，刷新列表
    await _reload();
  }

  Future<void> _addSpace() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SetupPage(
        db: widget.db,
        // 已有锁：沿用当前 PIN，向导不再问一次锁屏码
        existingPin: widget.pin,
        onCompleted: (payload) async {
          await AppLockService(widget.db ?? LocalDatabase.shared)
              .addSpace(payload, pin: widget.pin);
          await _reload();
          if (!mounted) return;
          Navigator.of(context).pop(); // 退回列表
          await _enter(_vault.spaces.firstWhere(
            (s) => s.spaceId == payload.spaceId,
            orElse: () => payload,
          ));
        },
      ),
    ));
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.spaceListTitle)),
      body: ListView.separated(
        itemCount: _vault.spaces.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final space = _vault.spaces[index];
          final names = _names[space.spaceId];
          final title = (names?.peerName ?? '').isNotEmpty
              ? names!.peerName
              : ((names?.name ?? '').isNotEmpty ? names!.name : space.spaceId);
          final isActive = space.spaceId == _vault.activeSpaceId;
          final unread = _unread[space.spaceId] ?? 0;
          return ListTile(
            leading: const Icon(Icons.forum_outlined),
            title: Row(
              children: [
                Flexible(child: Text(title, overflow: TextOverflow.ellipsis)),
                // 未读角标（数字；>99 显示 99+）。0 不显示。
                if (unread > 0) ...[
                  const SizedBox(width: 6),
                  Container(
                    key: ValueKey('unreadBadge-${space.spaceId}'),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.error,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      unread > 99 ? '99+' : '$unread',
                      style: const TextStyle(
                          color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ],
            ),
            subtitle: names?.name.isNotEmpty == true
                ? Text(l10n.spaceListMe(names!.name))
                : null,
            trailing: isActive ? const Icon(Icons.check, size: 18) : null,
            onTap: () => _enter(space),
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: FilledButton.icon(
            onPressed: _addSpace,
            icon: const Icon(Icons.add),
            label: Text(l10n.spaceListAdd),
          ),
        ),
      ),
    );
  }
}
