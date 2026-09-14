/// 密保口令强度策略（**唯一来源**，由 App / TUI / CLI 共用）。
///
/// 为什么需要成文策略：密保口令是**免设备认证**的取包端点
/// （`POST /spaces/{id}/key-escrow`）的唯一凭证——服务端只存 argon2id hash 兜底
/// （`server/src/escrow.ts`）。也就是说"知道口令"≈"拿到 Space Key"，口令强度是
/// 这条链路的主要防线（服务端已加失败限速，见 SECURITY.md §2）。
///
/// 只约束**设置/修改**口令；输入既有口令（接入、验证旧口令）不校验，避免把
/// 已有短口令的用户挡在门外——与 App 锁屏码的处理一致。
library;

/// 最短长度。10 位含字母与数字 ≈ 47 bit（随机串），比 8 位多约 9 bit；
/// 真实收益主要是挡住"12345678""abcdefgh"这类最弱输入。
const int kPassphraseMinLength = 10;

/// 违规原因（稳定码；各端自行映射文案 / l10n key，不把文案写进策略层）。
enum PassphrasePolicyViolation {
  /// 长度不足 [kPassphraseMinLength]。
  tooShort,

  /// 未同时包含字母与数字。
  needLetterAndDigit,
}

/// 校验密保口令：返回 null = 通过。
PassphrasePolicyViolation? checkPassphrasePolicy(String passphrase) {
  if (passphrase.length < kPassphraseMinLength) {
    return PassphrasePolicyViolation.tooShort;
  }
  final hasLetter = RegExp('[A-Za-z]').hasMatch(passphrase);
  final hasDigit = RegExp('[0-9]').hasMatch(passphrase);
  if (!hasLetter || !hasDigit) {
    return PassphrasePolicyViolation.needLetterAndDigit;
  }
  return null;
}
