/// 加入信息（A 端生成 → 二维码/文本分享给 B，KEY_ESCROW.md §6 流程）：
///
/// 格式：`einz-join-v1?space=<spaceId>&p=<passphrase>[&i=<inviteCode>]`
///
/// B 端扫码/粘贴后自动填入空间 ID、接入口令与邀请码（小白零输入）；
/// inviteCode 可选——旧格式（无邀请码）仍可解码，由 UI 引导手动输入邀请码；
/// 各参数经 URL 编码（可能含 +/= 等特殊字符）。
class JoinInfo {
  JoinInfo({required this.spaceId, required this.passphrase, this.inviteCode});

  static const String prefix = 'einz-join-v1';

  final String spaceId;
  final String passphrase;

  /// 一次性设备登记邀请码（服务端 /invites 生成，24h 有效）；
  /// 空/缺失 = 旧格式，加入时需另行输入。
  final String? inviteCode;

  /// 编码为分享字符串。
  String encode() {
    final s = Uri.encodeQueryComponent(spaceId);
    final p = Uri.encodeQueryComponent(passphrase);
    final i = inviteCode == null || inviteCode!.isEmpty
        ? ''
        : '&i=${Uri.encodeQueryComponent(inviteCode!)}';
    return '$prefix?space=$s&p=$p$i';
  }

  /// 解析分享字符串；格式不符或参数缺失返回 null。
  static JoinInfo? decode(String raw) {
    if (!raw.startsWith('$prefix?')) return null;
    try {
      final params = Uri.splitQueryString(raw.substring(prefix.length + 1));
      final space = params['space'];
      final p = params['p'];
      if (space == null || space.isEmpty || p == null || p.isEmpty) return null;
      final i = params['i'];
      return JoinInfo(
        spaceId: space,
        passphrase: p,
        inviteCode: (i == null || i.isEmpty) ? null : i,
      );
    } catch (_) {
      return null;
    }
  }
}
