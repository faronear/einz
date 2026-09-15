/// 设备名规则（**唯一来源**，App / TUI / CLI 共用；服务端 `server/src/deviceName.ts`
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
const int kDeviceNameMaxLength = 32;

/// 单个合规字符：中文字 / 英文字母 / 数字 / `_` / `-`。
///
/// 中文取 CJK 统一汉字基本区（\u4e00-\u9fff）与扩展 A（\u3400-\u4dbf）——覆盖日常
/// 用字；不含标点、全角符号、emoji（它们在展示层的宽度与截断行为都不可控）。
final RegExp kDeviceNameAllowedChar = RegExp(
  r'[0-9A-Za-z_\-\u3400-\u4dbf\u4e00-\u9fff]',
);

/// 整个名字是否合规（配合 [checkDeviceNamePolicy] 用；单独用于逐字符替换）。
final RegExp kDeviceNamePattern = RegExp(
  r'^[0-9A-Za-z_\-\u3400-\u4dbf\u4e00-\u9fff]+$',
);

/// 违规原因（稳定码；各端自行映射文案 / l10n key，不把文案写进策略层）。
enum DeviceNameViolation {
  /// 空（或 trim 后为空）。
  empty,

  /// 超过 [kDeviceNameMaxLength] 个字符。
  tooLong,

  /// 含白名单之外的字符（空格、emoji、标点……）。
  illegalCharacter,
}

/// 校验用户输入的设备名：返回 null = 通过。
///
/// 用户输入（TUI `/device <名字>`、App 改名弹窗）走这里——不合规就拒绝并提示重输，
/// **不静默改写**用户的输入（改了不告诉用户 = 名字莫名变了）。
DeviceNameViolation? checkDeviceNamePolicy(String name) {
  final value = name.trim();
  if (value.isEmpty) return DeviceNameViolation.empty;
  // 长度按**字符**算（Dart String.length 是 UTF-16 码元；emoji 等代理对会算 2，
  // 但这类字符本就不合规，先判字符集再判长度更准）
  if (!kDeviceNamePattern.hasMatch(value)) {
    return DeviceNameViolation.illegalCharacter;
  }
  if (value.length > kDeviceNameMaxLength) return DeviceNameViolation.tooLong;
  return null;
}

/// 自动生成名（宿主机名 / 设备型号）的消毒：不合规字符**逐个**换成 `_`，再截断到
/// [kDeviceNameMaxLength]。
///
/// 只用于"系统自动取名"这条路（用户没有表达过意愿，换成 `_` 不违背他的意图）；
/// 全是不合规字符时会得到一串 `_`——仍是合法名（例如型号 `???` → `___`）。
String sanitizeDeviceName(String raw) {
  final source = raw.trim();
  final buf = StringBuffer();
  for (final rune in source.runes) {
    final ch = String.fromCharCode(rune);
    buf.write(kDeviceNameAllowedChar.hasMatch(ch) ? ch : '_');
  }
  final out = buf.toString();
  return out.length > kDeviceNameMaxLength
      ? out.substring(0, kDeviceNameMaxLength)
      : out;
}
