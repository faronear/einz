/// 用户名称（member 显示名）规则（**唯一来源**，App / TUI / CLI 共用；服务端
/// `server/src/memberName.ts` 是同一约定的 TS 版本，改动请两边同步）。
///
/// 老板 2026-09-16 定：最多 32 字符，只允许 **中文字、英文字母、数字、`_`、
/// `-`、表情符 emoji**。
///
/// 与通道名（entrance_name_policy.dart）的差别：**这里允许 emoji**——名字是给人看的
/// 亲昵称呼（"小猪🐷"），通道名是给机器看的短标识，所以两条规则不合并。
///
/// 名字一律是**用户自己输入**的（向导里的"我的名字/伴侣的名字"、改名弹窗、
/// `/myname`），没有"自动取名"这条路，因此只提供校验、不提供消毒函数：不合规就
/// 拒绝并提示重输（静默改写人的名字 = 名字莫名变了）。
library;

/// 最长字符数（按 Unicode 码点计：一个 emoji 算 1 个；ZWJ 组合/国旗这类多码点
/// 序列会多算，属可接受偏差——真要按"肉眼一个字"计需要 grapheme 切分库）。
const int kMemberNameMaxLength = 32;

/// 单个合规字符：中文字 / 英文字母 / 数字 / `_` / `-` / emoji。
///
/// 中文用 `\p{Script=Han}`（全部汉字区，含 `𠮷` 这类罕见姓名用字；不含假名/谚文/
/// 全角）。emoji 走 `\p{Extended_Pictographic}`（比手写区间全：含杂项符号、
/// dingbats、supplemental symbols 等），再补四类"拼装件"：
/// `\u{1F1E6}-\u{1F1FF}` 区域指示符（国旗 🇨🇳）、`\uFE0F/\uFE0E` 变体选择符
/// （❤️）、`\u200D` ZWJ（👨‍👩‍👧 家庭组合）、`\u20E3` 键帽（1️⃣）。
final RegExp kMemberNameAllowedChar = RegExp(
  r'[0-9A-Za-z_\-\p{Script=Han}'
  r'\p{Extended_Pictographic}'
  r'\u{1F1E6}-\u{1F1FF}\u{FE0F}\u{FE0E}\u{200D}\u{20E3}]',
  unicode: true,
);

/// 整个名字是否合规（含首尾空白与空格——空格不在白名单里）。
final RegExp kMemberNamePattern = RegExp(
  r'^[0-9A-Za-z_\-\p{Script=Han}'
  r'\p{Extended_Pictographic}'
  r'\u{1F1E6}-\u{1F1FF}\u{FE0F}\u{FE0E}\u{200D}\u{20E3}]+$',
  unicode: true,
);

/// 违规原因（稳定码；各端自行映射文案 / l10n key，不把文案写进策略层）。
enum MemberNameViolation {
  /// 空（或 trim 后为空）。
  empty,

  /// 超过 [kMemberNameMaxLength] 个码点。
  tooLong,

  /// 含白名单之外的字符（空格、中文标点、`@`、全角符号……）。
  illegalCharacter,
}

/// 校验用户名称：返回 null = 通过。
MemberNameViolation? checkMemberNamePolicy(String name) {
  final value = name.trim();
  if (value.isEmpty) return MemberNameViolation.empty;
  if (!kMemberNamePattern.hasMatch(value)) {
    return MemberNameViolation.illegalCharacter;
  }
  if (value.runes.length > kMemberNameMaxLength) return MemberNameViolation.tooLong;
  return null;
}

/// 两个名字是否算"同一个名字"（取名空间的两人同名校验用）：**trim + 大小写不敏感**。
///
/// 老板 2026-09-24 定：`lukas` 与 `Lukas` 视作同名，不允许作为新建空间里的两人。
/// 名字白名单只含 Han / 拉丁 / 数字 / `_` / `-` / emoji，中文与 emoji 无大小写概念，
/// 故 casefold 实际只对拉丁字母生效。
bool isSameMemberName(String a, String b) =>
    a.trim().toLowerCase() == b.trim().toLowerCase();
