/// 用户名称（person 显示名）规则（**唯一来源**，App / TUI / CLI 共用；服务端
/// `server/src/personName.ts` 是同一约定的 TS 版本，改动请两边同步）。
///
/// 老板 2026-09-16 定：最多 32 字符，只允许 **中文字、英文字母、数字、`_`、
/// `-`、表情符 emoji**。
///
/// 与设备名（device_name_policy.dart）的差别：**这里允许 emoji**——名字是给人看的
/// 亲昵称呼（"小猪🐷"），设备名是给机器看的短标识，所以两条规则不合并。
///
/// 名字一律是**用户自己输入**的（向导里的"我的名字/伴侣的名字"、改名弹窗、
/// `/myname`），没有"自动取名"这条路，因此只提供校验、不提供消毒函数：不合规就
/// 拒绝并提示重输（静默改写人的名字 = 名字莫名变了）。
library;

/// 最长字符数（按 Unicode 码点计：一个 emoji 算 1 个；ZWJ 组合/国旗这类多码点
/// 序列会多算，属可接受偏差——真要按"肉眼一个字"计需要 grapheme 切分库）。
const int kPersonNameMaxLength = 32;

/// 单个合规字符：中文字 / 英文字母 / 数字 / `_` / `-` / emoji。
///
/// 中文用 `\p{Script=Han}`（全部汉字区，含 `𠮷` 这类罕见姓名用字；不含假名/谚文/
/// 全角）。emoji 走 `\p{Extended_Pictographic}`（比手写区间全：含杂项符号、
/// dingbats、supplemental symbols 等），再补四类"拼装件"：
/// `\u{1F1E6}-\u{1F1FF}` 区域指示符（国旗 🇨🇳）、`\uFE0F/\uFE0E` 变体选择符
/// （❤️）、`\u200D` ZWJ（👨‍👩‍👧 家庭组合）、`\u20E3` 键帽（1️⃣）。
final RegExp kPersonNameAllowedChar = RegExp(
  r'[0-9A-Za-z_\-\p{Script=Han}'
  r'\p{Extended_Pictographic}'
  r'\u{1F1E6}-\u{1F1FF}\u{FE0F}\u{FE0E}\u{200D}\u{20E3}]',
  unicode: true,
);

/// 整个名字是否合规（含首尾空白与空格——空格不在白名单里）。
final RegExp kPersonNamePattern = RegExp(
  r'^[0-9A-Za-z_\-\p{Script=Han}'
  r'\p{Extended_Pictographic}'
  r'\u{1F1E6}-\u{1F1FF}\u{FE0F}\u{FE0E}\u{200D}\u{20E3}]+$',
  unicode: true,
);

/// 违规原因（稳定码；各端自行映射文案 / l10n key，不把文案写进策略层）。
enum PersonNameViolation {
  /// 空（或 trim 后为空）。
  empty,

  /// 超过 [kPersonNameMaxLength] 个码点。
  tooLong,

  /// 含白名单之外的字符（空格、中文标点、`@`、全角符号……）。
  illegalCharacter,
}

/// 校验用户名称：返回 null = 通过。
PersonNameViolation? checkPersonNamePolicy(String name) {
  final value = name.trim();
  if (value.isEmpty) return PersonNameViolation.empty;
  if (!kPersonNamePattern.hasMatch(value)) {
    return PersonNameViolation.illegalCharacter;
  }
  if (value.runes.length > kPersonNameMaxLength) return PersonNameViolation.tooLong;
  return null;
}
