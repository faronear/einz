import 'dart:convert';

import 'package:einz_shared/einz_shared.dart';
import 'package:test/test.dart';

void main() {
  group('消息载荷（密文内明文形状）', () {
    test('无附加字段 = 裸文本（与旧版消息一致）', () {
      expect(encodeMessagePayload('晚上吃啥？'), '晚上吃啥？');
      final decoded = decodeMessagePayload('晚上吃啥？');
      expect(decoded.plaintext, '晚上吃啥？');
      expect(decoded.quote, isNull);
      expect(decoded.meta, isNull);
    });

    test('meta 往返：语音时长', () {
      final payload = encodeMessagePayload(
        '语音',
        meta: {kMetaAudioDurationSeconds: 25},
      );
      expect(jsonDecode(payload), {
        'plaintext': '语音',
        'meta': {'audioDurationSeconds': 25},
      });
      final decoded = decodeMessagePayload(payload);
      expect(decoded.plaintext, '语音');
      expect(decoded.meta?[kMetaAudioDurationSeconds], 25);
    });

    test('带引用 + meta 一起也能取回', () {
      final payload = encodeMessagePayload(
        '好的',
        quote: {'messageId': 'm1', 'preview': '原文'},
        meta: {kMetaAudioDurationSeconds: 90},
      );
      final decoded = decodeMessagePayload(payload);
      expect(decoded.plaintext, '好的');
      expect(decoded.quote?['messageId'], 'm1');
      expect(decoded.meta?[kMetaAudioDurationSeconds], 90);
    });

    test('未知键容错（老客户端看到新 meta 键不炸）', () {
      final payload = jsonEncode({
        'plaintext': '语音',
        'meta': {'audioDurationSeconds': 12, 'futureUnknownKey': {'a': 1}},
      });
      final decoded = decodeMessagePayload(payload);
      expect(decoded.plaintext, '语音');
      expect(decoded.meta?['futureUnknownKey'], {'a': 1});
    });

    test('裸文本恰好以 { 开头：按原文展示，不解析', () {
      const raw = '{not json at all';
      expect(decodeMessagePayload(raw).plaintext, raw);
      expect(decodeMessagePayload('{"plaintext": 123}').plaintext, '{"plaintext": 123}');
    });
  });
}
