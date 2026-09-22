import 'package:einz_shared/einz_shared.dart';
import 'package:flutter/material.dart';

import 'chat_entry.dart';
import 'data/app_lock.dart';
import 'data/local_database.dart';
import 'l10n/app_localizations.dart';
import 'setup_page.dart';
import 'widgets/reset_device.dart';

/// 本机已加入的空间列表：点击进入、删除（仅本地）、新建/加入新空间。
///
/// 出现时机（见 `aimemo/multiSpaceDesign.zhcn.md` §5）：
/// - 冷启动：Vault 里超过一个空间时作为启动落点；
/// - 聊天页：菜单「切换空间」退回本页；
/// - 设置入口：任何情况下都能进（单空间用户也能从这里加第二个空间）。
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
    if (v.spaces.isEmpty) {
      // 一个空间都不剩：回到全新入网向导。两条路都会走到这里——列表页长按删掉最后一个，
      // 以及从聊天页「退出并清除这个空间」退回本页时正好清空。
      await Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => SetupPage(db: widget.db)),
        (route) => false,
      );
      return;
    }
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

    // 服务端退役**这个空间**那一行（best-effort）：只影响本空间，别的空间不动。
    // 不做这一步的话，对方设备列表里会一直留着一台 active 的幽灵设备（老板 2026-09-22 定）。
    // 顺序不能反——token 来自 Vault，removeSpace 之后就取不到了。
    AppLockPayload? target;
    for (final s in _vault.spaces) {
      if (s.spaceId == spaceId) {
        target = s;
        break;
      }
    }
    final token = target?.token ?? '';
    await retireSpaceQuietly(token, api: widget.api);

    await _lock.removeSpace(spaceId, pin: widget.pin);
    await _reload();
  }

  /// 设备级「清除本设备全部数据」：逐个空间的会话各退役一次 + 清空整库（见 [confirmResetDevice]）。
  Future<void> _resetDevice() async {
    final deviceName = await _resolveDeviceName();
    if (!mounted) return;
    final tokens = [
      for (final s in _vault.spaces)
        if ((s.token ?? '').isNotEmpty) s.token!,
    ];
    await confirmResetDevice(
      context,
      db: widget.db,
      api: widget.api,
      deviceName: deviceName,
      tokens: tokens,
      // 闸门第二道：本机锁屏码（PIN 模式下本页才持有它）
      hasPin: widget.pin != null,
    );
  }

  /// 闸门要的本机设备名：取当前空间资料里的 deviceName（多空间下各空间一份）。
  /// 取不到返回 ''，由弹窗退化为固定确认词（见 `reset_device._confirmDestructive`）。
  Future<String> _resolveDeviceName() async {
    final active = _vault.activeSpaceId ??
        (_vault.spaces.isEmpty ? null : _vault.spaces.first.spaceId);
    if (active == null) return '';
    final p = await _lock.loadProfile(spaceId: active);
    return (p['deviceName'] as String? ?? '').trim();
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
      appBar: AppBar(
        title: Text(l10n.spaceListTitle),
        actions: [
          // 设备级破坏性入口收在溢出菜单里：极少用、不可逆，不该在列表上直接撞见
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            tooltip: l10n.chatPageMenuMore,
            onSelected: (value) async {
              if (value != 'reset') return;
              // 与菜单关闭动画错开再开 dialog：Overlay 里两个 route 交叉卸载会触发断言
              // （同 chat_page._menuAction 的 2026-09-05 修复）
              await Future<void>.delayed(const Duration(milliseconds: 300));
              if (!mounted) return;
              await _resetDevice();
            },
            itemBuilder: (ctx) => [
              PopupMenuItem(
                value: 'reset',
                child: Text(
                  l10n.spaceListResetDevice,
                  style: TextStyle(color: Theme.of(ctx).colorScheme.error),
                ),
              ),
            ],
          ),
        ],
      ),
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
