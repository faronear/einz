import 'package:flutter/material.dart';

import 'chat_entry.dart';
import 'data/app_lock.dart';
import 'data/local_database.dart';
import 'l10n/app_localizations.dart';
import 'setup_page.dart';

/// 本机已加入的空间列表：点击进入、删除（仅本地）、新建/加入新空间。
///
/// 出现时机（见 `aimemo/multiSpaceDesign.zhcn.md` §5）：
/// - 冷启动：Vault 里超过一个空间时作为启动落点；
/// - 聊天页：菜单「切换空间」退回本页；
/// - 设置入口：任何情况下都能进（单空间用户也能从这里加第二个空间）。
///
/// [vault] 是解锁后内存里的凭证集合；[pin] 在 PIN 模式下必须给（改写密文包需要它），
/// 无锁（跳过 PIN）场景为 null。
class SpaceListPage extends StatefulWidget {
  const SpaceListPage({super.key, required this.vault, this.pin, this.db});

  final VaultPayload vault;

  /// PIN 模式下的锁屏码（仅内存持有，用于 addSpace/removeSpace/setActiveSpace）。
  final String? pin;

  /// 测试注入用；默认 [LocalDatabase.shared]。
  final LocalDatabase? db;

  @override
  State<SpaceListPage> createState() => _SpaceListPageState();
}

class _SpaceListPageState extends State<SpaceListPage> {
  late VaultPayload _vault;
  late final AppLockService _lock;
  Map<String, ({String name, String peerName})> _names = {};

  @override
  void initState() {
    super.initState();
    _vault = widget.vault;
    _lock = AppLockService(widget.db ?? LocalDatabase.shared);
    _loadNames();
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
    setState(() => _vault = v);
    await _loadNames();
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

  Future<void> _confirmRemove(String spaceId) async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.spaceListDeleteTitle),
        content: Text(l10n.spaceListDeleteMessage),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(MaterialLocalizations.of(context).cancelButtonLabel)),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(l10n.spaceListDeleteConfirm)),
        ],
      ),
    );
    if (ok != true) return;
    await _lock.removeSpace(spaceId, pin: widget.pin);
    await _reload();
    if (!mounted) return;
    if (_vault.spaces.isEmpty) {
      // 最后一个空间也被移除：回到向导
      await Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => SetupPage(db: widget.db)),
        (route) => false,
      );
    }
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
          return ListTile(
            leading: const Icon(Icons.forum_outlined),
            title: Text(title),
            subtitle: names?.name.isNotEmpty == true
                ? Text(l10n.spaceListMe(names!.name))
                : null,
            trailing: isActive ? const Icon(Icons.check, size: 18) : null,
            onTap: () => _enter(space),
            onLongPress: () => _confirmRemove(space.spaceId),
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
