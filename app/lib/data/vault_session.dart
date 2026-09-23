import 'app_lock.dart';

/// **解锁后的 Vault（仅进程内存，绝不落盘）**——多空间"直接在聊天页内切换"的底座。
///
/// 为什么需要它：聊天页刻意不持有 PIN（PIN 是长期凭证，常驻内存等于把"用时输一次"变成
/// "内存里躺着一把能反复开门的钥匙"，见 worklog 2026-09-22）。但没有 PIN 就读不到
/// Vault → 也就拿不到**其他空间**的凭证 → 无法直接切空间，只能"回列表再进"。
/// 折中：PIN 依旧只在解锁那一刻存在，而**解锁的结果**（Vault）留一份在内存里。
///
/// 暴露面与现状同量级：当前空间的 Space Key 本来就在 `ChatPage.spaceKey` 里活着；
/// 这里多的只是"其他空间的那几把"——都是同一条通道、同一次解锁解出来的东西。
///
/// 生命周期：随进程（退出即没了）。写入点：
/// - 解锁/读取 Vault（`AppLockService.loadVault` / `unlockVault`）；
/// - 写盘 Vault（`writePlainVault` / `writePinVault`，加/删空间后保持同步）；
/// - 切换空间（`setActiveSpace`）；
/// - **整机清空**（`resetLocalData`）时清掉。
///
/// 刻意**不在锁屏时清**：现在重锁是用 LockPage 覆盖在聊天页之上，聊天页与其 Space Key
/// 本来就活着——清了反而会让"解锁回来继续聊"失效。这一条与既有行为一致，不是新放松。
class VaultSession {
  VaultSession._();

  static VaultPayload? _vault;

  /// 当前内存里的 Vault；未解锁/已清空时为 null。
  static VaultPayload? get current => _vault;

  /// 写入（传 null 表示清空）。返回写入的值，便于 `return VaultSession.publish(v)` 这样链式用。
  static VaultPayload? publish(VaultPayload? vault) {
    _vault = vault;
    return vault;
  }

  /// 当前空间（active）的凭证：优先按 [VaultPayload.activeSpaceId]，兜底第一个空间。
  static AppLockPayload? get active {
    final v = _vault;
    if (v == null) return null;
    return v.active;
  }
}
