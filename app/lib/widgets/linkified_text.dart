import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// 文本消息里的超链接：自动扫描并渲染为可点击的链接文字。
///
/// 方案1（老板 2026-09-28 选定）：不做"添加链接"消息类型，直接在**渲染层**
/// 扫描明文里的 URL——不动消息协议/服务器/CLI，历史消息也自动生效。
///
/// 只认 `http://` / `https://` 开头的完整网址（ftp/mailto 等 scheme 暂不支持，
/// 避免误判普通单词）；点击唤起系统浏览器/对应 App（url_launcher external）。
///
/// 链接色：素雅浅色气泡用品牌深蓝 #2271F7（与「邀请加入」链接同源）；
/// gradient 深色气泡下由调用方传白色——见 [LinkifiedText.linkColor]。
class LinkifiedText extends StatelessWidget {
  const LinkifiedText(
    this.text, {
    super.key,
    this.style,
    this.linkColor = const Color(0xFF2271F7),
    this.textAlign,
  });

  /// 原始明文（可含 0~n 个 URL）。
  final String text;

  /// 正文样式（来自气泡的 DefaultTextStyle 之外的显式覆盖，一般不传）。
  final TextStyle? style;

  /// 链接文字颜色（含下划线）。
  final Color linkColor;

  final TextAlign? textAlign;

  /// URL 正则：scheme 只认 http/https，主体懒匹配到"不像 URL 结尾的字符"为止
  /// （中文标点、右括号、行尾空白都算边界——"（见 https://a.b）。"这类不能把
  /// 尾部的 `）。` 吞进链接）。用 [RegExp] 静态编译一次。
  static final RegExp _urlRegex =
      RegExp(r"""https?://[^\s<>"'（）【】，。；：！？、]+[^\s<>"'（）【】，。；：！？、.,;:!?)]""");

  /// 把明文拆成 普通/链接 交替段：[文本, url, 文本, url, …]。
  @visibleForTesting
  static List<(String, bool)> splitSegments(String text) {
    final segments = <(String, bool)>[];
    var last = 0;
    for (final match in _urlRegex.allMatches(text)) {
      if (match.start > last) segments.add((text.substring(last, match.start), false));
      segments.add((match.group(0)!, true));
      last = match.end;
    }
    if (last < text.length) segments.add((text.substring(last), false));
    return segments;
  }

  Future<void> _open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final segments = splitSegments(text);
    // 无链接：走最普通的 Text，行为与改造前完全一致（不引入额外手势开销）
    if (segments.length == 1 && !segments.first.$2) {
      return Text(text, style: style, textAlign: textAlign);
    }
    final baseStyle = style ?? DefaultTextStyle.of(context).style;
    final linkStyle = baseStyle.copyWith(
        color: linkColor,
        decoration: TextDecoration.underline,
        decorationColor: linkColor);
    return Text.rich(
      TextSpan(
        children: [
          for (final (segment, isLink) in segments)
            if (!isLink)
              TextSpan(text: segment, style: baseStyle)
            else
              TextSpan(
                text: segment,
                style: linkStyle,
                recognizer: TapGestureRecognizer()..onTap = () => _open(segment),
              ),
        ],
      ),
      textAlign: textAlign,
    );
  }
}
