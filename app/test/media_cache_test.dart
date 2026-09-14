// MediaCache 缓存文件名白名单化（P1 路径遍历防御）。
//
// 背景（老板 2026-09-14 排查出的缺口）：缓存文件名由 messageId + 扩展名拼成，
// 两者都不可信——messageId 来自服务器下发的消息信封，音频消息的 ext 来自对端
// 可控的密文正文（`_extOf(plaintext)`）。原样拼接时，对端发一条 caption 为
// `x.mp4/../../evil` 的语音，用户点播放就把解密后的字节写到缓存目录之外。
import 'package:flutter_test/flutter_test.dart';

import 'package:einz/data/media_cache.dart';

void main() {
  test('恶意 messageId/ext 不会在文件名里留下路径分隔符', () {
    expect(MediaCache.safeName('a/../../evil'), isNot(contains('/')));
    expect(MediaCache.safeName(r'a\..\evil'), isNot(contains(r'\')));

    final name = MediaCache.cacheFileName('a/../../evil', 'mp4/../../../x');
    expect(name, startsWith('einz_media_'));
    expect(name, isNot(contains('/')));
    expect(name, isNot(contains(r'\')));
    // 文件名恒以前缀开头 → 不可能形成 `..` 路径段
    expect(name.split('.').where((p) => p == '..'), isEmpty);
  });

  test('合法 id（UUID / 38 位 hex-dash）经安全化后不变——旧缓存仍能命中', () {
    const uuid = '01a0ffff-aaaa-7bbb-9ccc-0123456789ab';
    const cliId = '018f2c3d-4e5f-7a8b-9c0d-1e2f3a4b5c6d';
    expect(MediaCache.safeName(uuid), uuid);
    expect(MediaCache.safeName(cliId), cliId);
    expect(MediaCache.cacheFileName(uuid, 'm4a'), 'einz_media_$uuid.m4a');
  });

  test('messageIdOf 与 cacheFileName 互为逆运算（prune 保留名单据此比对）', () {
    const uuid = '01a0ffff-aaaa-7bbb-9ccc-0123456789ab';
    expect(MediaCache.messageIdOf(MediaCache.cacheFileName(uuid, 'mp4')), uuid);
    // 非本类命名 → null（prune 视为孤儿）
    expect(MediaCache.messageIdOf('einz_audio_123.m4a'), isNull);
    expect(MediaCache.messageIdOf('other_file.mp4'), isNull);
  });
}
