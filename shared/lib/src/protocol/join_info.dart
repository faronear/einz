import 'dart:convert';

/// 加入信息（A 端生成 → 二维码/文本分享给 B，KEY_ESCROW.md §6 流程）：
///
/// 格式：`onlyspace-join-v1?space=<spaceId>&p=<passphrase>`
///
/// B 端扫码/粘贴后自动填入空间 ID 与接入口令（小白零输入）；
/// passphrase 经 URL 编码（可能含 +/= 等特殊字符）。
class JoinInfo {
  JoinInfo({required this.spaceId, required this.passphrase});

  static const String prefix = 'onlyspace-join-v1';

  final String spaceId;
  final String passphrase;

  /// 编码为分享字符串。
  String encode() {
    final s = Uri.encodeQueryComponent(spaceId);
    final p = Uri.encodeQueryComponent(passphrase);
    return '$prefix?space=$s&p=$p';
  }

  /// 解析分享字符串；格式不符或参数缺失返回 null。
  static JoinInfo? decode(String raw) {
    if (!raw.startsWith('$prefix?')) return null;
    try {
      final params = Uri.splitQueryString(raw.substring(prefix.length + 1));
      final space = params['space'];
      final p = params['p'];
      if (space == null || space.isEmpty || p == null || p.isEmpty) return null;
      return JoinInfo(spaceId: space, passphrase: p);
    } catch (_) {
      return null;
    }
  }
}
