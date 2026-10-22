import 'local_database.dart';
import 'space_scoped_setting.dart';

/// 语音转写的授权模式（方案 D'，voiceTranscript.zhcn.md §15.1 ③；本设备设置，
/// 存 app_state 不同步——每台设备自己选）：
///
/// - `local`（**默认**，现行行为）：本地模型转写——模型未就绪时手动入口触发
///   下载/解包（§11），全程无网络、服务端不可见；
/// - `server`：服务端转写——本地解密后的 wav 明文上送 `POST /transcriptions`，
///   whisper.cpp 即转即删（§15.2；隐私边界见 docs/PROTOCOL.md §6.3）；
/// - `ask`：每条询问——点转写时先弹授权确认，确认后走服务端路径（本地模型
///   就绪时也可选「本地转写」）。
///
/// 注意：`server`/`ask` 模式只在服务端转写已启用时才有意义（/health 的
/// `transcribe: true`）；服务端未启用时这两个模式的效果回落 `local`。
const List<String> kVoiceTranscriptAuthOptions = ['local', 'server', 'ask'];

/// 语音转写授权模式设置（key='voice_transcript_auth'）。
///
/// 多空间：给 [spaceId] 时键为 `space.<spaceId>.voice_transcript_auth`；读不到时
/// 回退旧全局键。「应用于本机所有秘境」走 mixin 的 [saveAll]。
class VoiceTranscriptSettings with SpaceScopedSetting {
  VoiceTranscriptSettings(this.db, {this.spaceId});

  @override
  final LocalDatabase db;

  @override
  final String? spaceId;

  static const _kKey = 'voice_transcript_auth';

  @override
  String get settingKey => _kKey;

  /// 当前授权模式（默认 'local'；旧版本/非法值也回落它）。
  Future<String> load() async {
    final row = await (db.select(db.appState)..where((s) => s.key.equals(scopedKey)))
        .getSingleOrNull();
    final v = row?.value ?? (spaceId == null
        ? null
        : (await (db.select(db.appState)..where((s) => s.key.equals(_kKey))).getSingleOrNull())?.value);
    return (v == null || !kVoiceTranscriptAuthOptions.contains(v)) ? 'local' : v;
  }

  /// 保存模式（只写当前空间；'local' / 'server' / 'ask'）。
  Future<void> save(String mode) async {
    assert(kVoiceTranscriptAuthOptions.contains(mode), '非法转写授权模式: $mode');
    await writeSetting(scopedKey, mode);
  }
}
