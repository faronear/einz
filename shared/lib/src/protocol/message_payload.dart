/// 消息载荷（AEAD 密文内的明文，PROTOCOL.md §5）。
///
/// Server 只存 ciphertext、从不解析内容，所以载荷形状纯属客户端约定：
/// - **裸文本**：无附加字段时就是用户输入的原文（旧版消息、CLI 文本消息）；
/// - **JSON**：带引用或 meta 时包装成 `{"plaintext":…,"quote":…,"meta":…}`。
///
/// 兼容规则（双向）：老客户端遇到未知键忽略（按 `plaintext` 显示），新客户端
/// 遇到缺键/裸文本按缺省处理——所以往 `meta` 里加新键是安全的渐进升级。
library;

import 'dart:convert';

/// meta 键：音频/语音时长（秒，整数）。语音（录音）与音频文件消息都用它，
/// 省得把时长塞进明文（老版本的「song.mp3 [3m 20s]」写法已废弃，仅作兜底解析）。
///
/// 新增 meta 键请在此登记并同步到 docs/PROTOCOL.md 的载荷小节。
const String kMetaAudioDurationSeconds = 'audioDurationSeconds';

/// meta 键：通话记录（语音通话结束时在聊天流里留的一条 `system` 消息）。
///
/// 通话结果本身**说不清是哪一方的**（"未接"对主叫是没打通、对被叫是没接到），
/// 所以只在 meta 里记结果与时长，**具体文案由各自客户端按自己的语言渲染**——
/// 明文留空，避免把一方的语言塞给另一方。
const String kMetaCallState = 'callState';

/// meta 键：通话时长（秒，整数；仅 `kMetaCallState == kCallStateCompleted` 时有意义）。
const String kMetaCallDurationSeconds = 'callDurationSeconds';

/// [kMetaCallState] 取值。
const String kCallStateCompleted = 'completed'; // 已接通并结束（有 duration）
const String kCallStateMissed = 'missed'; // 振铃超时没人接（**不做后台呼入，这是常态**）
const String kCallStateDeclined = 'declined'; // 被叫拒接
const String kCallStateBusy = 'busy'; // 被叫忙线
const String kCallStateCanceled = 'canceled'; // 主叫在接通前取消
const String kCallStateFailed = 'failed'; // 连接失败（ICE 没打通等）

/// 载荷编码：[quote]/[meta] 都为 null 时返回裸 [plaintext]（与旧版完全一致）。
String encodeMessagePayload(
  String plaintext, {
  Map<String, dynamic>? quote,
  Map<String, dynamic>? meta,
}) {
  if (quote == null && meta == null) return plaintext;
  return jsonEncode({
    'plaintext': plaintext,
    if (quote != null) 'quote': quote,
    if (meta != null) 'meta': meta,
  });
}

/// 载荷解码：裸文本、或文本碰巧以 `{` 开头（解析失败）时按原文返回，
/// quote/meta 为 null。
({String plaintext, Map<String, dynamic>? quote, Map<String, dynamic>? meta})
    decodeMessagePayload(String raw) {
  if (raw.startsWith('{')) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic> && decoded['plaintext'] is String) {
        final quote = decoded['quote'];
        final meta = decoded['meta'];
        return (
          plaintext: decoded['plaintext'] as String,
          quote: quote is Map<String, dynamic> ? quote : null,
          meta: meta is Map<String, dynamic> ? meta : null,
        );
      }
    } catch (_) {
      // 裸文本恰好以 { 开头：按原文展示
    }
  }
  return (plaintext: raw, quote: null, meta: null);
}
