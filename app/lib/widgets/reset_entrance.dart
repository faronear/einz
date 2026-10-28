import 'package:einz_shared/einz_shared.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/app_lock.dart';
import '../data/local_database.dart';
import '../data/space_session.dart';
import '../widgets/cancel_button.dart';
import '../widgets/top_notice.dart';
import '../data/server_config.dart';
import '../l10n/app_localizations.dart';

/// 破坏性操作的确认弹窗文案（当前只有空间级「销毁本秘境通道」用，结构留给将来的破坏性操作）。
class ConfirmDialogCopy {
  const ConfirmDialogCopy({
    required this.title,
    required this.message,
    required this.confirmLabel,
    this.nameHint,
    this.nameLabel,
    this.nameMismatch,
  });

  final String title;
  final String message;
  final String confirmLabel;

  /// 名字输入区的三套文案（缺省 = 通道名口径；退群传群组名口径）。
  /// 空 = 用 [_ConfirmDestructiveDialog] 里的 resetEntrance* 默认键。
  final String? nameHint;
  final String? nameLabel;
  final String? nameMismatch;
}

/// 弹出闸门（通道名 + 已设时的锁屏码），两道都对返回 true。
///
/// **闸门故意只用本机独占的因子**（老板 2026-09-22 定稿）：通道名确认清的是这条，
/// 锁屏码是本地秘密。刻意**不校验空间口令**——那是**共享**给伴侣的加入凭证，不该获得
/// 销毁我这条通道的权力；而且校验它必须联网，会让"这条通道连的服务器已经连不上"
/// 这个最常见的重置场景直接自锁（详情见 `server/src/entrances.ts` 的 retireEntrance）。
///
/// 本机级的「清除本设备全部数据」已删除（2026-09-22）→ 当前只有空间级「销毁本秘境通道」用它。
Future<bool> _confirmDestructive(
  BuildContext context, {
  required LocalDatabase db,
  required String entranceName,
  required bool hasPin,
  required ConfirmDialogCopy copy,

  /// 名字缺失时要求用户照抄的固定词。缺省沿用「销毁本通道」的
  /// [AppLocalizations.resetEntranceConfirmWord]（重置/RESET）；退群传自己的
  /// 「退群/LEAVE」——两类操作语义不同，确认词不该共用（老板 2026-10-28）。
  String? fallbackConfirmWord,
}) async {
  if (!context.mounted) return false;
  // 通道名取不到（本地快照与服务端都问不出来）时退一步：改让用户打一个固定确认词。
  // 不可用性优先——本地快照缺 entranceName 的旧装机不该因此永远清不掉。
  final l10n = AppLocalizations.of(context)!;
  final expected = entranceName.trim().isEmpty
      ? (fallbackConfirmWord ?? l10n.resetEntranceConfirmWord)
      : entranceName.trim();
  final ok = await showDialog<bool>(
    context: context,
    // 含输入框：禁误触关闭（点外面/系统返回都不行），必须点按钮（老板 2026-10-15）
    barrierDismissible: false,
    builder: (ctx) => PopScope(
      canPop: false,
      child: _ConfirmDestructiveDialog(
        db: db,
        entranceName: expected,
        hasPin: hasPin,
        copy: copy,
      ),
    ),
  );
  return ok ?? false;
}

/// 尽力而为地让服务端退役**一个空间**的那条虚拟通道（只影响这一个空间的那一行）。
///
/// 失败不阻塞本地移除（本地移除才是用户要的结果），但**要把失败如实告诉用户**：
/// 退役没成功 = 对方通道列表里这条通道仍是 active 的幽灵。返回是否成功，由调用方提示。
///
/// 走 [SpaceSession] 而不是裸 token（2026-09-26 修）：会话 24h 就过期，拿旧 token 直接
/// 请求只会 401「invalid session」→ 这里原本 catch 掉 → 用户只看到"服务端可能还留着"，
/// 却永远留着一行幽灵通道。
Future<bool> retireSpaceQuietly(SpaceSession session, {ApiClient? api}) async {
  if (session.token.isEmpty) return false;
  try {
    await session.call(
        (t) => (api ?? ApiClient(effectiveServer)).retireEntrance(t));
    return true;
  } catch (_) {
    // 离线 / 已被对方撤销 / 老服务端
    return false;
  }
}

/// 「删除所有消息」（高级安全，老板 2026-10-02）的确认闸门：与销毁通道同一条
/// [_confirmDestructive] 弹窗（说明小字 + 通道名 + 已设时的锁屏码），文案换成
/// 清消息专用（销毁会撤通道，本操作通道保留——措辞必须分开）。
Future<bool> confirmClearMessages(
  BuildContext context, {
  LocalDatabase? db,
  required String entranceName,
  bool hasPin = false,
}) async {
  final l10n = AppLocalizations.of(context)!;
  return _confirmDestructive(
    context,
    db: db ?? LocalDatabase.shared,
    entranceName: entranceName,
    hasPin: hasPin,
    copy: ConfirmDialogCopy(
      title: l10n.advancedClearMessages,
      message: l10n.clearMessagesMessage,
      confirmLabel: l10n.clearMessagesConfirm,
    ),
  );
}

/// 「销毁本秘境通道」——**空间级**破坏性操作（聊天页菜单 → 高级）。
///
/// 语义（老板 2026-09-22 定）：站在某个空间里点破坏性入口，用户心里想的就是"结束这个
/// 空间"，不该顺手抹掉本机上的其他空间。所以这里只做：
/// ① 服务端退役**这个空间**那一行（best-effort，失败照清）；② 本地 removeSpace(spaceId)。
/// 整台设备的清理由空间列表页的「清除本设备全部数据」负责。
///
/// 返回 true 表示已完成（调用方负责导航）。
Future<bool> confirmLeaveSpace(
  BuildContext context, {
  LocalDatabase? db,
  ApiClient? api,
  required String spaceId,
  required SpaceSession session,
  required String entranceName,
  bool hasPin = false,
}) async {
  final database = db ?? LocalDatabase.shared;
  final l10n = AppLocalizations.of(context)!;
  final ok = await _confirmDestructive(
    context,
    db: database,
    entranceName: entranceName,
    hasPin: hasPin,
    copy: ConfirmDialogCopy(
      title: l10n.leaveSpaceTitle,
      message: l10n.leaveSpaceMessage,
      confirmLabel: l10n.leaveSpaceConfirm,
    ),
  );
  if (!ok || !context.mounted) return false;

  // 服务端退役：尽力而为（顺序不能反——凭证在本地，清完就再也调不动它了）。
  // 只影响这一个空间那一行，其他空间的通道行不动。失败如实提示（顶部通知挂在根
  // Overlay 上，本页随后 pop 也不影响它显示）。
  final retired = await retireSpaceQuietly(session, api: api);
  // PIN 模式下这里没有 pin（聊天页不持有）→ removeSpace 走"挂 pending + 立即清数据"，
  // 凭证条目等下次解锁再摘（见 AppLockService.removeSpace 文档）。
  await AppLockService(database).removeSpace(spaceId);
  if (!retired && context.mounted) {
    showTopNotice(context, l10n.resetEntranceServerResidualHint,
        extraTop: kNoticeExtraTopBelowStatusBar);
  }
  return true;
}

/// 「退出群组」——group 空间的**自愿退群**（2026-10-19，aimemo/20261019_groupExitDesign.md；
/// 老板三项拍板：duo 不开放、多设备一并退、顶部通知+名单刷新）。
///
/// 与 [confirmLeaveSpace]（销毁本通道）的本质区别——**身份级离场**：
/// - 销毁通道：只退役**本机这一条通道**，身份仍在册，对方可 re-invite 接回**同一身份**；
/// - 退出群组：服务端把本人身份名下**全部**通道一并注销、成员行转墓碑（名字保留，
///   slot 让位）、本身份其他设备自动销毁本地数据（"就像被撤回一样"）。日后回来 =
///   剩余成员发新 invite，以**新身份**加入。
///
/// 语义边界（服务端同款兜底）：
/// - **仅 group**：duo 空间没有这个入口（服务端 409 LEAVE_NOT_ALLOWED）；
/// - **不校验共享口令**：自助语义，session 即所有权（同退役）；本地闸门 =
///   群组名 + 已设时的本机 PIN（[_confirmDestructive] 既有两条因子）；
/// - **失败不清本地**：leaveSpace 抛错 → 顶部报错、返回 false，调用方留在群内。
///
/// 返回 true = 已完成服务端退出 + 本地 removeSpace（调用方负责导航收尾）。
Future<bool> confirmExitGroup(
  BuildContext context, {
  LocalDatabase? db,
  ApiClient? api,
  required String spaceId,
  required SpaceSession session,
  required String groupName,
  bool hasPin = false,
}) async {
  final database = db ?? LocalDatabase.shared;
  final l10n = AppLocalizations.of(context)!;
  // 群组名是确认因子（用户自己起的名字）；没起过名 → 弹窗内部退化为固定确认词
  // （resetEntranceConfirmWord，与未命名通道的销毁流程同一机制）。此时三套文案
  // 必须换成"确认词"口径——否则提示写"请输入群组名称「重置」"，而「重置」显然不是
  // 群名，用户不知道该输什么（老板 2026-10-19 实测）。
  final name = groupName.trim();
  final hasName = name.isNotEmpty;
  // 退群的固定确认词是「退群/LEAVE」，不是销毁通道那套「重置/RESET」
  // （老板 2026-10-28：动作不同，确认词也该不同）。
  final confirmWord = l10n.exitGroupConfirmWord;
  final ok = await _confirmDestructive(
    context,
    db: database,
    fallbackConfirmWord: confirmWord,
    // 群名仅本机存储（服务端没有空间名字段），所以这里只能用它
    entranceName: groupName,
    hasPin: hasPin,
    copy: ConfirmDialogCopy(
      title: l10n.exitGroupTitle,
      message: l10n.exitGroupMessage,
      confirmLabel: l10n.exitGroupConfirm,
      nameHint: hasName
          ? l10n.exitGroupNameHint(name)
          : l10n.exitGroupConfirmWordHint(confirmWord),
      nameLabel: hasName ? l10n.exitGroupNameLabel(name) : confirmWord,
      nameMismatch:
          hasName ? l10n.exitGroupNameMismatch : l10n.exitGroupConfirmWordMismatch,
    ),
  );
  if (!ok || !context.mounted) return false;

  // 服务端退出（顺序不能反——凭证在本地，清完就再也调不动它了）。
  // 走 [SpaceSession] 而不是裸 token：会话 24h 就过期（同 retireSpaceQuietly）。
  try {
    await session.call(
        (t) => (api ?? ApiClient(effectiveServer)).leaveSpace(spaceId, t));
  } catch (_) {
    // 失败不清本地（老板拍板的口径：留在群里，数据完好，可重试）。
    // 顶部通知挂在根 Overlay 上，随后本页继续显示也不影响它。
    if (context.mounted) {
      showTopNotice(context, l10n.exitGroupFailed,
          extraTop: kNoticeExtraTopBelowStatusBar);
    }
    return false;
  }
  // PIN 模式下这里没有 pin（聊天页不持有）→ removeSpace 走"挂 pending + 立即清数据"，
  // 凭证条目等下次解锁再摘（见 AppLockService.removeSpace 文档）。
  await AppLockService(database).removeSpace(spaceId);
  return true;
}

// 「清除本设备全部数据」（本机级）**已删除**（老板 2026-09-22：太危险，不呈现给用户）。
// 用户的等价路径：逐个空间「销毁本秘境通道」，或直接卸载重装（ensureFreshInstall
// 会清掉残留密钥）。`data/local_reset.dart` 的 resetLocalData() 作为"整机清空"原语保留。

/// 破坏性操作共用的确认弹窗：说明小字 + 输入通道名（+已设时的锁屏码）。
///
/// 文案由 [copy] 注入（空间级 / 本机级各一套）。
class _ConfirmDestructiveDialog extends StatefulWidget {
  const _ConfirmDestructiveDialog({
    required this.db,
    required this.entranceName,
    required this.hasPin,
    required this.copy,
  });

  final LocalDatabase db;
  final String entranceName;
  final bool hasPin;
  final ConfirmDialogCopy copy;

  @override
  State<_ConfirmDestructiveDialog> createState() => _ConfirmDestructiveDialogState();
}

class _ConfirmDestructiveDialogState extends State<_ConfirmDestructiveDialog> {
  final _nameCtrl = TextEditingController();
  final _pinCtrl = TextEditingController();
  String? _error;
  bool _busy = false; // 锁屏码校验中（Argon2id 解包）：防连点重复提交

  @override
  void dispose() {
    _nameCtrl.dispose();
    _pinCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context)!;
    if (_busy) return;
    final name = _nameCtrl.text.trim();
    final pin = _pinCtrl.text;

    // ① 通道名：精确比对（trim 后大小写敏感——通道名是用户自己起的，不像邮箱该宽容）
    if (name != widget.entranceName) {
      setState(() => _error = widget.copy.nameMismatch ?? l10n.resetEntranceNameMismatch);
      return;
    }
    // ② 锁屏码（已设才验）：走 AppLockService.unlock —— 与锁屏同一套防爆破
    // （连错 5 次锁 30 秒）；这里只是借用它的校验结果，成功即放行。
    if (widget.hasPin) {
      if (pin.isEmpty) {
        setState(() => _error = l10n.verifyPinRequired);
        return;
      }
      setState(() {
        _busy = true;
        _error = null;
      });
      try {
        await AppLockService(widget.db).unlock(pin);
      } on AppLockLockedException catch (e) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _error = l10n.lockPageTooManyAttempts(e.remainingSeconds);
        });
        return;
      } on AppLockException {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _error = l10n.verifyPinWrong;
        });
        return;
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _error = l10n.setPinDialogSetupFailed('$e');
        });
        return;
      }
      if (!mounted) return;
      setState(() => _busy = false);
    }
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final nameHint = widget.copy.nameHint ?? l10n.resetEntranceNameHint(widget.entranceName);
    final nameLabel = widget.copy.nameLabel ?? l10n.resetEntranceNameLabel(widget.entranceName);
    return AlertDialog(
      // 标题居中（老板 2026-09-25：弹窗标题一律居中，不居左）
      title: Center(child: Text(widget.copy.title)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.copy.message,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            nameHint,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _nameCtrl,
            autofocus: true, // 闸门第一个框：打开弹窗即待输入
            decoration: InputDecoration(
              hintText: nameLabel,
              border: const OutlineInputBorder(),
            ),
          ),
          if (widget.hasPin) ...[
            const SizedBox(height: 8),
            Text(
              l10n.resetEntrancePinHint,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _pinCtrl,
              obscureText: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                hintText: l10n.resetEntrancePinLabel,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 13)),
          ],
        ],
      ),
      actions: [
        CancelButton(onPressed: () => Navigator.of(context).pop(false)),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: _busy ? null : _submit,
          child: Text(widget.copy.confirmLabel),
        ),
      ],
    );
  }
}
