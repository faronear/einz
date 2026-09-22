/// 共享口令强度策略（**唯一来源**，由 App / TUI / CLI 共用）。
///
/// 为什么需要成文策略：共享口令是**免设备认证**的取包端点
/// （`POST /spaces/{id}/key-escrow`）的唯一凭证——服务端只存 argon2id hash 兜底
/// （`server/src/escrow.ts`）。也就是说"知道口令"≈"拿到 Space Key"，口令强度是
/// 这条链路的主要防线（服务端已加失败限速，见 SECURITY.md §2）。
///
/// 只约束**设置/修改**口令；输入既有口令（接入、验证旧口令）不校验，避免把
/// 已有短口令的用户挡在门外——与 App 锁屏码的处理一致。
library;

/// 最短长度（**唯一硬要求**，老板 2026-09-15 定）：只卡长度，不卡字符种类。
///
/// 思路：复杂度规则可以无限加（大小写、符号、字典……），但每加一条都是对用户的
/// 打扰，也挡不住"P@ssw0rd"这类应付。系统只守住最短长度这一条底线，**复杂度交给
/// 用户自己决定**——愿意的话可以用 CLI `einz passphrase random` / TUI
/// `/passphrase random` 生成 12 词恢复码当口令。
const int kPassphraseMinLength = 8;

/// 违规原因（稳定码；各端自行映射文案 / l10n key，不把文案写进策略层）。
enum PassphrasePolicyViolation {
  /// 长度不足 [kPassphraseMinLength]（当前唯一一条规则）。
  tooShort,
}

/// 校验共享口令：返回 null = 通过。
///
/// 只校验长度（[kPassphraseMinLength]）；不再要求字母+数字混合——见
/// [kPassphraseMinLength] 的说明。
PassphrasePolicyViolation? checkPassphrasePolicy(String passphrase) {
  if (passphrase.length < kPassphraseMinLength) {
    return PassphrasePolicyViolation.tooShort;
  }
  return null;
}
