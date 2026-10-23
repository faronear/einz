import 'local_database.dart';
import 'space_scoped_setting.dart';

/// 语音转写的两项本设备设置（方案 D'，voiceTranscript.zhcn.md §15.1 ③）。
///
/// **2026-10-23 老板重构**：原「本地 / 服务端 / 每条询问」三选一拆成两组——
/// 「每条询问」不再是并列的第三个选项，而是**自动转写关闭时**的行为：
///
/// - **转写方式**（key=`voice_transcript_engine`，二选一）：
///   - `local`（默认）：本地模型转写——模型未就绪时手动入口触发下载/解包
///     （§11），全程无网络、服务端不可见；
///   - `server`：服务端转写——本地解密后的 wav 明文上送 `POST /transcriptions`，
///     whisper.cpp 即转即删（§15.2；隐私边界见 docs/PROTOCOL.md §6.3）。
/// - **自动转写**（key=`voice_transcript_auto`，默认 **false = 每条询问**）：
///   - false：不自动转写任何消息——用户经长按菜单「转写」逐条确认后执行；
///     **不论选的是本机还是服务端，执行前都会询问**（老板 2026-10-23 定）。
///     默认关 = 省流量/上传；
///   - true：按上面的方式自动转写（旧「本地/服务端」模式的行为）。
///
/// 多空间：给 [spaceId] 时键为 `space.<spaceId>.<key>`；读不到时回退旧全局键。
/// 「应用于本机所有秘境」：两个键都写全局 + 清除各自 per-space 覆盖。
///
/// 旧版迁移（2026-10-23 前的单键 `voice_transcript_auth`，值 local/server/ask）：
/// 读时派生——local/server → 自动开（保持存量行为），ask → 方式取 server、
/// 自动关。新键一旦显式写过即以它为准。
const List<String> kVoiceTranscriptEngineOptions = ['local', 'server'];

/// 语音转写设置（转写方式 + 自动转写开关，均每设备、每空间独立）。
class VoiceTranscriptSettings {
  VoiceTranscriptSettings(this.db, {this.spaceId}) {
    _engine = _ScopedKey(db, spaceId, _kEngineKey);
    _auto = _ScopedKey(db, spaceId, _kAutoKey);
  }

  final LocalDatabase db;

  /// 归属空间；null = 用旧全局键（单空间/无空间上下文的场景）。
  final String? spaceId;

  static const _kEngineKey = 'voice_transcript_engine';
  static const _kAutoKey = 'voice_transcript_auto';
  static const _kLegacyAuthKey = 'voice_transcript_auth';

  late final _ScopedKey _engine;
  late final _ScopedKey _auto;

  /// 当前转写方式（'local' / 'server'；旧版本/非法值回落 'local'）。
  Future<String> loadEngine() async {
    final v = await _read(_engine);
    if (v != null && kVoiceTranscriptEngineOptions.contains(v)) return v;
    // 旧版迁移：ask 的服务端语义归到 server 方式（是否自动由 auto 键决定）
    final legacy = await _readLegacy();
    if (legacy == 'server' || legacy == 'ask') return 'server';
    return 'local';
  }

  /// 是否自动转写（默认 false = 每条询问）。
  Future<bool> loadAuto() async {
    final v = await _read(_auto);
    if (v != null) return v == '1';
    final legacy = await _readLegacy();
    // 存量行为保持：旧 local/server 是自动的；ask 本就不自动
    if (legacy != null) return legacy != 'ask';
    return false;
  }

  /// 保存转写方式（只写当前空间）。
  Future<void> saveEngine(String engine) async {
    assert(kVoiceTranscriptEngineOptions.contains(engine), '非法转写方式: $engine');
    await _engine.write(engine);
  }

  /// 保存自动转写开关（只写当前空间）。
  Future<void> saveAuto(bool auto) async => _auto.write(auto ? '1' : '0');

  /// 保存两项并**应用于本机所有秘境**（各键写全局 + 清除各自 per-space 覆盖）。
  Future<void> saveAll({required String engine, required bool auto}) async {
    await _engine.saveAll(engine);
    await _auto.saveAll(auto ? '1' : '0');
  }

  /// 读一个键：per-space 优先，回落旧全局键（mixin 的键层级同款）。
  Future<String?> _read(_ScopedKey key) async {
    final row = await (db.select(db.appState)
          ..where((s) => s.key.equals(key.scopedKey)))
        .getSingleOrNull();
    if (row != null) return row.value;
    if (spaceId == null) return null;
    final global = await (db.select(db.appState)
          ..where((s) => s.key.equals(key.settingKey)))
        .getSingleOrNull();
    return global?.value;
  }

  /// 读旧版单键（迁移用；键层级同 [_read]）。
  Future<String?> _readLegacy() async {
    final scoped =
        spaceId == null ? _kLegacyAuthKey : spaceScopedKey(spaceId!, _kLegacyAuthKey);
    final row = await (db.select(db.appState)
          ..where((s) => s.key.equals(scoped)))
        .getSingleOrNull();
    if (row != null) return row.value;
    if (spaceId == null) return null;
    final global = await (db.select(db.appState)
          ..where((s) => s.key.equals(_kLegacyAuthKey)))
        .getSingleOrNull();
    return global?.value;
  }
}

/// 单键的 per-space 读写骨架（[SpaceScopedSetting] mixin 的具名实例）——
/// 转写设置有两个键，各持一个实例，避免把两键逻辑塞进一个 settingKey。
class _ScopedKey with SpaceScopedSetting {
  _ScopedKey(this.db, this.spaceId, this.key);

  @override
  final LocalDatabase db;

  @override
  final String? spaceId;

  /// 主键名（如 'voice_transcript_engine'）。
  final String key;

  @override
  String get settingKey => key;

  /// 写本键的值（mixin 的 writeSetting 要显式传 key，包一层少一个出错点）。
  Future<void> write(String value) => writeSetting(key, value);
}
