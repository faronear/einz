import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:einz_shared/einz_shared.dart';

import 'local_database.dart';
import 'secure_store.dart';
import 'server_config.dart';

/// App 启动锁（方案 B：PIN 加密密钥）。安全口径与威胁模型见 `docs/SECURITY.md`
/// §2/§4，密钥存储位置见 `docs/DATABASE.md` §4（原先指向的 docs/APP_LOCK.md 从未落地）。
///
/// - 首次设置 PIN：Argon2id 派生密钥加密"Space Key 包"（XChaCha20，复用 backup.dart），
///   密文存 drift app_state；同时用 12 词恢复码再加密一份（PIN 丢失兑底）。
/// - 每次启动：输入 PIN → 解密成功才拿到 Space Key → 进入聊天页。
/// - 防爆破：连续错误 [maxAttempts] 次 → 锁定 [lockSeconds] 秒（纯本地，Server 不参与）。
/// - 跳过 PIN：明文 Space Key 包存系统安全存储（Keychain/Keystore，SecureStore），
///   不再落 SQLite（老板 2026-09-14：消除 app_state 明文密钥）。
/// - **卸载即重置**（老板 2026-09-14 决策，见 [ensureFreshInstall]）：安全存储条目会
///   活过 App 卸载（iOS/macOS Keychain、Linux libsecret；Android/Windows 落在应用数据
///   目录里卸载即清），故全新安装时清掉上一次安装的残留，语义与设 PIN 用户一致。
class AppLockService {
  AppLockService(this.db);

  final LocalDatabase db;

  /// 明文 Space Key 包在 SecureStore 里的条目名（自动加 einz.secure. 前缀）。
  static const _securePlain = 'app_lock.plain';

  /// SecureStore 里属于本 App 的条目清单（[ensureFreshInstall] 清理用；新增条目须登记）。
  static const secureKeys = [_securePlain];

  static const int maxAttempts = 5;
  static const int lockSeconds = 30;

  /// 锁屏码规则（老板 2026-09-11 定稿：与 CLI 一致——只允许数字，至少
  /// [pinMinLength] 位；6 位数字约 20 bit，明显强于 4 位的 13 bit）。
  /// 仅约束设置/修改；已有更短的旧 PIN 解锁不受影响。
  static const int pinMinLength = 6;

  /// 锁屏码是否只含数字（键盘为数字键盘，但可粘贴/外接键盘输入字母——需显式校验）。
  static bool isPinDigitsOnly(String pin) => RegExp(r'^\d+$').hasMatch(pin);

  static const _kPackage = 'app_lock.package';
  static const _kAttempts = 'app_lock.attempts';
  static const _kLockedUntil = 'app_lock.locked_until';
  static const _kPlain = 'app_lock.plain'; // 【遗留】旧版明文包在 app_state 的键（仅迁移读取）
  static const _kSkipped = 'app_lock.skipped'; // '1' = 用户确认暂不设锁
  static const _kProfile = 'app_lock.profile'; // JSON: {personName, peerName, deviceName}

  /// 本次安装的标记（随机 id）。**非密钥、非敏感**——它的全部意义就是"沙盒里有没有
  /// 东西"：drift 库随 App 卸载消失，安全存储条目不会，故"标记不在"= 全新安装。
  static const _kInstallId = 'app_lock.install_id';

  /// 是否已设置启动锁（有 PIN 加密的密钥包）。
  Future<bool> get isSetup async => await _get(_kPackage) != null;

  /// 本设备是否已配置（设锁或跳过均算；StartupGate 据此决定直接进聊天）。
  Future<bool> get hasConfig async =>
      await isSetup || await loadPlain() != null;

  /// 全新安装检测 + 上一次安装残留清理（老板 2026-09-14 决策：卸载即重置）。
  ///
  /// 安全存储条目会活过 App 卸载（iOS/macOS Keychain、Linux libsecret），而 drift
  /// 库不会。所以"沙盒里没有本次安装标记"≈"沙盒被清过 = 全新安装"，此时清掉上一次
  /// 安装残留的密钥条目——否则"跳过 PIN"的用户卸载重装会被直接拖进聊天，与"设了
  /// PIN"的用户（锁包在 drift，随沙盒一起消失）行为不一致。
  ///
  /// 幂等，启动流程里可重复调用。iOS"卸载 App（保留数据）"、iCloud/整机备份恢复都会
  /// 把沙盒带回来（标记仍在）→ 不会误清。跨设备泄漏另由 SecureStore 的
  /// `..._this_device` 无障碍级别兜住（条目不随备份迁移）。
  Future<void> ensureFreshInstall() async {
    if (await _get(_kInstallId) != null) return; // 同一安装：什么都不做
    await SecureStore.deleteAll(secureKeys); // 全新安装：清残留（无残留则静默）
    await _set(_kInstallId, _newInstallId());
  }

  /// 随机安装标记（16 字节 hex）。只用于判定"沙盒是否为空"，无密码学用途。
  static String _newInstallId() {
    final r = Random.secure();
    return List.generate(
        16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  /// 明文保存 Space Key 包（跳过 PIN 场景）：无锁包但有此明文时，
  /// 下次启动直接进聊天（免打扰），直到用户在聊天页补设 PIN。
  /// 存系统安全存储（Keychain/Keystore），SQLite 不再保留明文副本。
  ///
  /// 多空间下写的是**整个 Vault**：该空间并入现有 Vault 并置为 active
  /// （旧单包读时自动归一，见 [VaultPayload.fromJson]）。
  Future<void> savePlain(AppLockPayload payload) async {
    await writePlainVault(await _mergedVault(payload));
  }

  /// 读取明文 Space Key 包（跳过 PIN 的无锁配置）；不存在返回 null。
  ///
  /// 兼容旧版：包还在 app_state（明文落 SQLite）时自动迁移到 SecureStore，
  /// 并删除 app_state 里的明文副本；迁移失败视为未配置（宁可重新引导）。
  /// 多空间下返回 Vault 里 **active 空间** 的 payload。
  Future<AppLockPayload?> loadPlain() async {
    final payload = (await loadPlainVault())?.active;
    if (payload != null) await _syncSpaceRow(payload);
    return payload;
  }

  /// 明文 Vault（无 PIN 场景）：读 SecureStore，回退旧版 app_state 明文包并归一。
  Future<VaultPayload?> loadPlainVault() async {
    final raw = await SecureStore.read(_securePlain) ?? await _get(_kPlain);
    if (raw == null) return null;
    try {
      final vault = VaultPayload.fromJson(jsonDecode(raw));
      if (await _get(_kPlain) != null) {
        // 旧版明文包（app_state）→ 归一后写入 SecureStore，删掉 SQLite 副本
        await SecureStore.write(_securePlain, jsonEncode(vault.toJson()));
        await _deletePlainFromDb();
      }
      return vault;
    } catch (_) {
      return null; // 明文损坏视为未配置（宁可重新引导）
    }
  }

  /// 写明文 Vault（无 PIN 场景）。
  Future<void> writePlainVault(VaultPayload vault) async {
    await SecureStore.write(_securePlain, jsonEncode(vault.toJson()));
    await _set(_kSkipped, '1');
    await _deletePlainFromDb(); // 兼容：清掉旧版本可能残留的明文副本
  }

  /// 写 PIN 加密的 Vault（设置/修改锁屏码）：成功后清除明文副本（同旧 [setPin] 语义）。
  Future<void> writePinVault(String pin, VaultPayload vault) async {
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(vault.toJson())));
    final pkg = await encryptWithPassphrase(payload: bytes, passphrase: pin);
    await _set(_kPackage, jsonEncode(pkg.toJson()));
    await _set(_kAttempts, '0');
    await _set(_kLockedUntil, '0');
    await clearPlain(); // 补设 PIN 后不再保留明文副本
  }

  /// 读 Vault：PIN 场景传 [pin]（走解锁，含防爆破）；无 PIN 场景读明文。
  Future<VaultPayload?> loadVault({String? pin}) async {
    if (pin != null) return unlockVault(pin);
    if (await isSetup) throw StateError('PIN 模式下读写 Vault 必须传入 pin');
    return loadPlainVault();
  }

  /// 写 Vault：[pin] 非空 → 重写加密包；否则写明文。
  /// PIN 模式下不传 [pin] 直接拒绝——否则会静默降级为明文存储。
  Future<void> saveVault(VaultPayload vault, {String? pin}) async {
    if (pin != null) {
      await writePinVault(pin, vault);
      return;
    }
    if (await isSetup) throw StateError('PIN 模式下读写 Vault 必须传入 pin');
    await writePlainVault(vault);
  }

  /// 追加一个空间（新空间向导完成后调用）并置为 active。
  Future<void> addSpace(AppLockPayload payload, {String? pin}) async {
    final base = await loadVault(pin: pin) ?? const VaultPayload(spaces: []);
    await saveVault(
      base.upsert(payload).copyWith(activeSpaceId: payload.spaceId),
      pin: pin,
    );
    await _syncSpaceRow(payload);
  }

  /// 本地移除一个空间的身份：Vault 条目 + Spaces 行 + per-space 资料键。
  /// **不动其他空间**。该空间的消息/附件/媒体缓存清理属 M1（多空间数据隔离），
  /// 见 `aimemo/multiSpaceDesign.zhcn.md` §4.4/§3.5。
  Future<void> removeSpace(String spaceId, {String? pin}) async {
    final vault = await loadVault(pin: pin);
    if (vault == null) return;
    await saveVault(vault.remove(spaceId), pin: pin);
    await (db.delete(db.spaces)..where((s) => s.spaceId.equals(spaceId))).go();
    await _delete(_profileKey(spaceId));
  }

  /// 切换当前空间（同时刷新该空间的 lastActiveAt）。
  Future<void> setActiveSpace(String spaceId, {String? pin}) async {
    final vault = await loadVault(pin: pin);
    if (vault == null) return;
    await saveVault(vault.copyWith(activeSpaceId: spaceId), pin: pin);
    await (db.update(db.spaces)..where((s) => s.spaceId.equals(spaceId))).write(
      SpacesCompanion(lastActiveAt: Value(DateTime.now().millisecondsSinceEpoch)),
    );
  }

  /// 现有 Vault 并入 [payload]（按 spaceId 覆盖或追加），并置为 active。
  Future<VaultPayload> _mergedVault(AppLockPayload payload) async {
    final vault = await loadPlainVault() ?? VaultPayload.single(payload);
    return vault.upsert(payload).copyWith(activeSpaceId: payload.spaceId);
  }

  /// 凭证与 Spaces 表对齐（幂等）：补写该空间的元数据行。
  ///
  /// 首行**不在 v7 迁移里灌**——PIN 包在迁移阶段无法解密，只能等解锁时补。
  Future<void> _syncSpaceRow(AppLockPayload payload) async {
    final row = await (db.select(db.spaces)
          ..where((s) => s.spaceId.equals(payload.spaceId)))
        .getSingleOrNull();
    if (row == null) {
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.into(db.spaces).insert(SpacesCompanion.insert(
            spaceId: payload.spaceId,
            deviceId: Value(payload.deviceId),
            keyVersion: Value(payload.keyVersion),
            createdAt: Value(now),
            lastActiveAt: Value(now),
          ));
    } else {
      await (db.update(db.spaces)..where((s) => s.spaceId.equals(payload.spaceId))).write(
        SpacesCompanion(
          deviceId: Value(payload.deviceId),
          keyVersion: Value(payload.keyVersion),
        ),
      );
    }
  }

  /// 清除无锁配置（补设 PIN 成功后调用：不再保留明文副本）。
  Future<void> clearPlain() async {
    await SecureStore.delete(_securePlain);
    await _deletePlainFromDb();
    await (db.delete(db.appState)..where((s) => s.key.equals(_kSkipped))).go();
  }

  /// 清除本地锁与密钥包（设备被撤销时调用：回到未配置状态，防止残留密钥）。
  ///
  /// 全量清除（含所有空间的 Vault 条目与 Spaces 行）。多空间下**逐空间**的清除走
  /// [removeSpace]；只有"整库清理/卸载即重置"才用这个。
  Future<void> clear() async {
    await SecureStore.delete(_securePlain);
    await (db.delete(db.appState)
          ..where((s) => s.key.isIn({_kPackage, _kAttempts, _kLockedUntil, _kPlain, _kSkipped})))
        .go();
    // per-space 资料键（app_lock.profile.<spaceId>）与 Spaces 行一并清干净
    await (db.delete(db.appState)..where((s) => s.key.like('$_kProfile.%'))).go();
    await db.delete(db.spaces).go();
  }

  /// 删除 app_state 里的旧版明文包（迁移/清理用）。
  Future<void> _deletePlainFromDb() async {
    await (db.delete(db.appState)..where((s) => s.key.equals(_kPlain))).go();
  }

  /// 取消启动锁（"设为空"）：删除加密包，保留明文配置（Space Key 仍可进聊天）。
  Future<void> clearPackage() async {
    await (db.delete(db.appState)
          ..where((s) => s.key.equals(_kPackage)))
        .go();
  }

  /// 设置 PIN 并加密保存 Vault（老板决策：不再生成 12 词恢复码）。
  /// 注意：PIN 丢失则本设备所有空间的密钥包无法解密（无恢复副本，纯本地）。
  ///
  /// [payload] 并入现有 Vault 并置为 active——覆盖写"唯一一个空间"的旧语义在多空间下
  /// 会丢掉其他空间，故这里只覆盖同 spaceId 的那一项。
  Future<void> setPin(String pin, {required AppLockPayload payload}) async {
    await writePinVault(pin, await _mergedVault(payload));
  }

  /// 恢复码兑底已删除（老板决策）：PIN 丢失即无法解锁本设备密钥包。
  ///
  /// 返回 **active 空间** 的 payload（多空间下 Vault 里可能有多项）。
  Future<AppLockPayload> unlock(String pin) async {
    final payload = (await unlockVault(pin)).active;
    if (payload == null) throw const AppLockException('Vault 里没有可用空间');
    return payload;
  }

  /// 解锁并取回整个 Vault（多空间切换用）。旧版单 payload 密文自动归一为单元素 Vault。
  Future<VaultPayload> unlockVault(String pin) async {
    await _ensureNotLocked();
    final raw = await _get(_kPackage);
    if (raw == null) throw const AppLockException('尚未设置锁屏码');
    try {
      final plain = await decryptWithPassphrase(envelope: PassphraseEnvelope.fromJson(jsonDecode(raw)), passphrase: pin);
      await _set(_kAttempts, '0');
      final vault = VaultPayload.fromJson(jsonDecode(utf8.decode(plain)));
      final active = vault.active;
      if (active != null) await _syncSpaceRow(active);
      return vault;
    } on FormatException {
      await _registerFailure();
      throw const AppLockException('锁屏码 错误');
    }
  }

  /// 剩余锁定秒数（0 = 未锁定）。
  Future<int> get remainingLockSeconds async {
    final until = int.tryParse(await _get(_kLockedUntil) ?? '0') ?? 0;
    final remain = until - DateTime.now().millisecondsSinceEpoch;
    return remain > 0 ? (remain / 1000).ceil() : 0;
  }

  Future<void> _ensureNotLocked() async {
    final remain = await remainingLockSeconds;
    if (remain > 0) throw AppLockLockedException('尝试次数过多，请 $remain 秒后再试', remain);
  }

  Future<void> _registerFailure() async {
    final n = (int.tryParse(await _get(_kAttempts) ?? '0') ?? 0) + 1;
    if (n >= maxAttempts) {
      await _set(_kLockedUntil, '${DateTime.now().millisecondsSinceEpoch + lockSeconds * 1000}');
      await _set(_kAttempts, '0');
    } else {
      await _set(_kAttempts, '$n');
    }
  }

  Future<String?> _get(String key) async {
    final row = await (db.select(db.appState)..where((s) => s.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<void> _set(String key, String value) async {
    await (db.into(db.appState)).insertOnConflictUpdate(
      AppStateCompanion.insert(key: key, value: value),
    );
  }

  Future<void> _delete(String key) async {
    await (db.delete(db.appState)..where((s) => s.key.equals(key))).go();
  }

  /// per-space 资料键（多空间：每个空间一份名字/性别/槽位）。
  ///
  /// 不传 spaceId 时沿用旧全局键 [_kProfile]——**不去读 Vault 猜 active 空间**：
  /// 资料读写发生在 ChatPage/向导这些没有 Vault 上下文的地方，读 Vault 意味着读
  /// 安全存储（测试环境/平台未支持会抛），不该让"取名字"依赖它。
  static String _profileKey(String spaceId) => '$_kProfile.$spaceId';

  /// 用户资料（名字）持久化：向导完成时保存，PIN 解锁/重启后 ChatPage 恢复显示。
  /// （名字不在 AppLockPayload 里——解锁构造 ChatPage 时无法获得，故单独存。）
  ///
  /// [spaceId] 给出时写 per-space 键（`app_lock.profile.<spaceId>`）并同步 Spaces 行的
  /// 名字；缺省（单空间旧调用点）回退全局键 [_kProfile]。
  Future<void> saveProfile({
    String? spaceId,
    required String personName,
    required String peerName,
    required String deviceName,
    String myGender = '', // 本人性别（male/female；个人资料弹窗图标展示用）
    String peerGender = '', // 对方性别（male/female；消息气泡配色用）
    int? mySlot, // 本人身份槽位（0=第一人/创建者，1=第二人；同性别气泡青色用）
    int? peerSlot, // 对方身份槽位（同上；对方气泡配色判定用）
  }) async {
    final sid = spaceId;
    await _set(sid == null ? _kProfile : _profileKey(sid), jsonEncode({
      'personName': personName,
      'peerName': peerName,
      'deviceName': deviceName,
      'myGender': myGender,
      'peerGender': peerGender,
      'mySlot': mySlot,
      'peerSlot': peerSlot,
    }));
    if (sid != null) {
      await (db.update(db.spaces)..where((s) => s.spaceId.equals(sid))).write(
        SpacesCompanion(name: Value(personName), peerName: Value(peerName)),
      );
    }
  }

  /// 读回保存的资料（键缺失返回空串——解锁场景 ChatPage 空名时恢复）。
  ///
  /// [spaceId] 缺省时先读 active 空间的 per-space 键，再回退旧全局键 [_kProfile]
  /// （v7 迁移前保存的资料、以及未传 spaceId 的旧调用点）。
  Future<Map<String, Object?>> loadProfile({String? spaceId}) async {
    final sid = spaceId;
    final raw = sid == null ? await _get(_kProfile) : await _get(_profileKey(sid)) ?? await _get(_kProfile);
    if (raw == null) return const {};
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return {
        'personName': (m['personName'] as String?) ?? '',
        'peerName': (m['peerName'] as String?) ?? '',
        'deviceName': (m['deviceName'] as String?) ?? '',
        'myGender': (m['myGender'] as String?) ?? '',
        'peerGender': (m['peerGender'] as String?) ?? '',
        'mySlot': (m['mySlot'] as num?)?.toInt(),
        'peerSlot': (m['peerSlot'] as num?)?.toInt(),
      };
    } catch (_) {
      return const {};
    }
  }
}

/// 被 PIN 加密保护的 Space Key 包（解密成功后进入聊天所需的一切）。
///
/// **不含服务器地址**：地址每次启动由 `--server` > 编译期覆盖 > 出厂域名算出
/// （见 `data/server_config.dart` 的 `effectiveServer`），不是设备数据。锁包解锁前
/// 读不到，地址存进来就会出现"锁屏页显示的和解锁后实际连的不一致"。
class AppLockPayload {
  const AppLockPayload({
    required this.spaceKeyB64,
    required this.spaceId,
    required this.deviceId,
    this.keyVersion = 1,
    this.token,
    this.escrowUpdatedAt,
    this.publicKeyB64,
    this.privateKeyB64,
  });

  final String spaceKeyB64;
  final String spaceId;
  final String deviceId;
  final int keyVersion;
  final String? token;

  /// 本端已知的服务端口令更新时间（ms）：上线时与服务器对比，
  /// 服务器更新 = 离线期间口令被重设（应弹窗重新验证）。
  final int? escrowUpdatedAt;

  /// 设备 X25519 密钥对（b64）：随锁包持久化——重启后 challenge-response
  /// 重新认证（reauth）需用私钥签名；「我的设备」弹窗展示公钥。旧包无此字段。
  final String? publicKeyB64;
  final String? privateKeyB64;

  Map<String, dynamic> toJson() => {
        'space_key': spaceKeyB64,
        'space_id': spaceId,
        'device_id': deviceId,
        'key_version': keyVersion,
        'token': token,
        'escrow_updated_at': escrowUpdatedAt,
        'device_public_key': publicKeyB64,
        'device_private_key': privateKeyB64,
      };

  factory AppLockPayload.fromJson(Map<String, dynamic> json) => AppLockPayload(
        spaceKeyB64: json['space_key'] as String,
        spaceId: json['space_id'] as String,
        deviceId: json['device_id'] as String,
        keyVersion: (json['key_version'] as int?) ?? 1,
        token: json['token'] as String?,
        escrowUpdatedAt: json['escrow_updated_at'] as int?,
        publicKeyB64: json['device_public_key'] as String?,
        privateKeyB64: json['device_private_key'] as String?,
      );
}

/// 一台设备上的**全部空间凭证**（多空间支持，见 `aimemo/multiSpaceDesign.zhcn.md` §3.2）。
///
/// 存储形态：PIN 模式下整个对象加密后存 `app_lock.package`；跳过 PIN 模式明文存
/// SecureStore `app_lock.plain`。旧版只有一个 [AppLockPayload] 的包在**读取时归一**
/// 为单元素 Vault（[VaultPayload.fromJson]），不重写旧密文。
///
/// Space Key 只在这里（+ 解锁后的内存），Spaces 表不存任何密钥。
class VaultPayload {
  const VaultPayload({
    required this.spaces,
    this.activeSpaceId,
    this.deviceName = '',
  });

  /// 单空间（旧包归一、首次创建用）。
  factory VaultPayload.single(AppLockPayload payload, {String deviceName = ''}) =>
      VaultPayload(spaces: [payload], activeSpaceId: payload.spaceId, deviceName: deviceName);

  final List<AppLockPayload> spaces;

  /// 当前进入的空间；为 null 或指向不存在的空间时 [active] 退回第一项。
  final String? activeSpaceId;

  /// Vault 级统一设备名（各空间用同一个名字登记——「我的设备」弹窗只显示名字+公钥，
  /// 统一名字后不同空间看起来是同一台设备，见设计文档 §2.2）。
  final String deviceName;

  /// 当前空间凭证（无空间时 null）。
  AppLockPayload? get active {
    if (spaces.isEmpty) return null;
    for (final s in spaces) {
      if (s.spaceId == activeSpaceId) return s;
    }
    return spaces.first;
  }

  /// 按 spaceId 覆盖或追加一项（保持原有顺序）。
  VaultPayload upsert(AppLockPayload payload) {
    final next = <AppLockPayload>[];
    var replaced = false;
    for (final s in spaces) {
      if (s.spaceId == payload.spaceId) {
        next.add(payload);
        replaced = true;
      } else {
        next.add(s);
      }
    }
    if (!replaced) next.add(payload);
    return copyWith(spaces: next);
  }

  /// 移除一个空间；移除的是 active 时把 active 让给剩下的第一个。
  VaultPayload remove(String spaceId) {
    final next = spaces.where((s) => s.spaceId != spaceId).toList();
    final nextActive = activeSpaceId == spaceId ? (next.isEmpty ? null : next.first.spaceId) : activeSpaceId;
    return VaultPayload(spaces: next, activeSpaceId: nextActive, deviceName: deviceName);
  }

  VaultPayload copyWith({List<AppLockPayload>? spaces, String? activeSpaceId, String? deviceName}) =>
      VaultPayload(
        spaces: spaces ?? this.spaces,
        activeSpaceId: activeSpaceId ?? this.activeSpaceId,
        deviceName: deviceName ?? this.deviceName,
      );

  Map<String, dynamic> toJson() => {
        'version': 1,
        'device_name': deviceName,
        'active_space_id': activeSpaceId,
        'spaces': spaces.map((s) => s.toJson()).toList(),
      };

  /// 解析：新版 Vault JSON（含 `spaces` 列表）或**旧版单个 payload** 的 JSON。
  /// 结构不对抛 [FormatException]（调用方据此判定"损坏/未配置"）。
  static VaultPayload fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) throw const FormatException('Vault 格式错误');
    final list = raw['spaces'];
    if (list is! List) {
      // 旧版：单个 AppLockPayload 的 JSON（有 space_key / space_id）
      if (!raw.containsKey('space_id')) throw const FormatException('Vault 格式错误');
      return VaultPayload.single(AppLockPayload.fromJson(raw));
    }
    final spaces = <AppLockPayload>[];
    for (final e in list) {
      if (e is! Map<String, dynamic>) throw const FormatException('Vault.space 格式错误');
      spaces.add(AppLockPayload.fromJson(e));
    }
    return VaultPayload(
      spaces: spaces,
      activeSpaceId: raw['active_space_id'] as String?,
      deviceName: (raw['device_name'] as String?) ?? '',
    );
  }
}

/// 用锁包里的设备密钥对完成 challenge-response 重新认证（重启后 reauth 用：
/// 会话过期 401/4401 时自动续期）。锁包无密钥对（旧包）时抛 [StateError]。
Future<String> reauthFromPayload(AppLockPayload payload) async {
  final pub = payload.publicKeyB64;
  final priv = payload.privateKeyB64;
  if (pub == null || priv == null || pub.isEmpty || priv.isEmpty) {
    throw StateError('锁包无设备密钥对');
  }
  final s = await sodium();
  final api = ApiClient(effectiveServer);
  final challenge = await api.challenge(payload.deviceId);
  final opened = await sealOpen(
    s,
    base64Decode(challenge.sealedChallenge),
    base64Decode(pub),
    base64Decode(priv),
  );
  return (await api.verify(challenge.challengeId, base64Encode(opened))).sessionToken;
}

class AppLockException implements Exception {
  const AppLockException(this.message);
  final String message;
  @override
  String toString() => message;
}

class AppLockLockedException extends AppLockException {
  const AppLockLockedException(super.message, this.remainingSeconds);
  final int remainingSeconds;
}
