/// 设备名规则（**唯一来源**，App / TUI / CLI 共用；服务端 `server/src/entranceName.ts`
/// 是同一约定的 TS 版本，改动请两边同步）。
///
/// 老板 2026-09-16 定：设备名只允许 **中文字、英文字母、数字 0-9、下划线 `_`、
/// 中划线 `-`**，最长 32 字符。
///
/// 为什么收字符集：设备名会出现在顶部条、设备列表、消息落款与推送提示里，是一路
/// 被拼接显示的短标识；空格/emoji/标点会让"名字边界"变得模糊（哪儿是名字、哪儿是
/// 分隔），也会在日志与终端渲染里制造歧义。统一收口到这个很小的集合，展示层不需要
/// 再为怪字符做转义。
library;

/// 最长字符数（与 TUI 此前对宿主名的截断一致；顶部条/设备列表放得下）。
const int kEntranceNameMaxLength = 32;

/// 单个合规字符：中文字 / 英文字母 / 数字 / `_` / `-`。
///
/// 中文用 Unicode 属性 `\p{Script=Han}`（覆盖全部汉字区：基本区 + 扩展 A~G +
/// 兼容汉字，包括 `𠮷` 这类罕见姓名用字），且**不含**日文假名、韩文、全角字母
/// 与中文标点——它们不是汉字。
final RegExp kEntranceNameAllowedChar = RegExp(
  r'[0-9A-Za-z_\-\p{Script=Han}]',
  unicode: true,
);

/// 整个名字是否合规（配合 [checkEntranceNamePolicy] 用；单独用于逐字符替换）。
final RegExp kEntranceNamePattern = RegExp(
  r'^[0-9A-Za-z_\-\p{Script=Han}]+$',
  unicode: true,
);

/// 违规原因（稳定码；各端自行映射文案 / l10n key，不把文案写进策略层）。
enum EntranceNameViolation {
  /// 空（或 trim 后为空）。
  empty,

  /// 超过 [kEntranceNameMaxLength] 个字符。
  tooLong,

  /// 含白名单之外的字符（空格、emoji、标点……）。
  illegalCharacter,
}

/// 校验用户输入的设备名：返回 null = 通过。
///
/// 用户输入（TUI `/device <名字>`、App 改名弹窗）走这里——不合规就拒绝并提示重输，
/// **不静默改写**用户的输入（改了不告诉用户 = 名字莫名变了）。
EntranceNameViolation? checkEntranceNamePolicy(String name) {
  final value = name.trim();
  if (value.isEmpty) return EntranceNameViolation.empty;
  // 长度按**字符**算（Dart String.length 是 UTF-16 码元；emoji 等代理对会算 2，
  // 但这类字符本就不合规，先判字符集再判长度更准）
  if (!kEntranceNamePattern.hasMatch(value)) {
    return EntranceNameViolation.illegalCharacter;
  }
  if (value.length > kEntranceNameMaxLength) return EntranceNameViolation.tooLong;
  return null;
}

/// 自动生成名（宿主机名 / 设备型号）的消毒：不合规字符**逐个**换成 `_`，再截断到
/// [kEntranceNameMaxLength]。
///
/// 只用于"系统自动取名"这条路（用户没有表达过意愿，换成 `_` 不违背他的意图）；
/// 全是不合规字符时会得到一串 `_`——仍是合法名（例如型号 `???` → `___`）。
String sanitizeEntranceName(String raw) {
  final source = raw.trim();
  final buf = StringBuffer();
  for (final rune in source.runes) {
    final ch = String.fromCharCode(rune);
    buf.write(kEntranceNameAllowedChar.hasMatch(ch) ? ch : '_');
  }
  final out = buf.toString();
  return out.length > kEntranceNameMaxLength
      ? out.substring(0, kEntranceNameMaxLength)
      : out;
}
