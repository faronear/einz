import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:einz_shared/einz_shared.dart';

import 'local_database.dart';
import 'vault_session.dart';
import 'attachment_store.dart';
import 'media_cache.dart';
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
  static const _kProfile = 'app_lock.profile'; // JSON: {memberName, peerName, entranceName, myGender, peerGender, mySlot, peerSlot, peerMemberId}

  /// 安装级标识（同一物理设备各空间共用；服务端 entrances.install_uid 的来源）。
  static const _kInstallUid = 'app_lock.install_uid';

  /// "上次用的是哪个空间"（**明文**，非秘密）：Spaces 表本来就明文存着空间 id 与名字，
  /// 单独记一份是为了让**切换空间不需要锁屏码**——PIN 模式下重写加密锁包要 pin，
  /// 而聊天页刻意不持有 pin（见 [setActiveSpace]）。
  static const _kActiveSpace = 'app_lock.active_space';

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

  /// 安装级标识（服务端 `entrances.install_uid`）：同一台物理设备上的所有空间
  /// **共用这一份**，服务端据此把不同空间的 entrance_id 认成同一台机器。
  ///
  /// 定位（老板 2026-09-22 定）：
  /// - 只做**服务端侧认知**（运维/审计/将来"整机退役"），不参与任何授权或破坏性
  ///   操作的范围判断，也**绝不返回给任何客户端**（成员之间互不可见）；
  /// - 生命周期 = **安装级**：卸载重装即换新；整机清空（`resetLocalData`）时随
  ///   app_state 整表清掉 → 轮换。**App 里销毁单个通道（`removeSpace`）不动它。**
  ///
  /// 存 app_state 而不是 SecureStore：它与密钥无关，且在这里读安全存储会让一次
  /// "取个 id"依赖平台支持（同 [loadProfile] 的教训，见 multiSpaceDesign §3.6）。
  /// 惰性生成：首次调用落库，之后每次读回同一个值。
  Future<String> installUid() async {
    final existing = await _get(_kInstallUid);
    if (existing != null && existing.isNotEmpty) return existing;
    final fresh = _newInstallId(); // 同形状：16 字节 hex
    await _set(_kInstallUid, fresh);
    return fresh;
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
    final vault = await loadPlainVault();
    if (vault == null) return null;
    // "当前空间"以明文键为准（见 setActiveSpace）——不能只用 Vault 里的 activeSpaceId，
    // 否则"在聊天页里无 pin 切换过空间"之后，这里会读出上一个空间。
    final payload = await resolveActivePayload(vault);
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
    VaultSession.publish(vault);
    await SecureStore.write(_securePlain, jsonEncode(vault.toJson()));
    await _set(_kSkipped, '1');
    await _deletePlainFromDb(); // 兼容：清掉旧版本可能残留的明文副本
    await _syncAllSpaceRows(vault);
  }

  /// 写 PIN 加密的 Vault（设置/修改锁屏码）：成功后清除明文副本（同旧 [setPin] 语义）。
  Future<void> writePinVault(String pin, VaultPayload vault) async {
    VaultSession.publish(vault);
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(vault.toJson())));
    final pkg = await encryptWithPassphrase(payload: bytes, passphrase: pin);
    await _set(_kPackage, jsonEncode(pkg.toJson()));
    await _set(_kAttempts, '0');
    await _set(_kLockedUntil, '0');
    await clearPlain(); // 补设 PIN 后不再保留明文副本
    await _syncAllSpaceRows(vault);
  }

  /// 读 Vault：PIN 场景传 [pin]（走解锁，含防爆破）；无 PIN 场景读明文。
  Future<VaultPayload?> loadVault({String? pin}) async {
    if (pin != null) return unlockVault(pin);
    if (await isSetup) throw StateError('PIN 模式下读写 Vault 必须传入 pin');
    return _publishNormalized(await loadPlainVault());
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
    // 明文键（"当前空间"的真相）先跟着走：新加的空间就是当前空间
    await _set(_kActiveSpace, payload.spaceId);
    await saveVault(
      base.upsert(payload).copyWith(activeSpaceId: payload.spaceId),
      pin: pin,
    );
    await _syncSpaceRow(payload);
  }

  /// 本地移除一个空间：Vault 条目 + 该空间的全部本地数据。
  /// **不动其他空间**。
  ///
  /// 清除范围的分工（别再加"全量清除"的第三个 API）：
  /// - **逐空间** → 本方法（含被撤销时的自毁，见 chat_page._onEntranceRevoked）；
  /// - **全设备** → `resetLocalData()`（`data/local_reset.dart`，删 app_state 整表 +
  ///   安全存储 + 明文缓存，天生不会漏键）。
  ///
  /// [pin]：PIN 模式下重写密文包必须给；给不了（例如撤销发生在聊天页，那里没有
  /// pin 也不该留着 pin）时走"挂 pending + 立即清数据"，凭证条目等下次解锁再摘。
  Future<void> removeSpace(String spaceId, {String? pin}) async {
    if (pin == null && await isSetup) {
      await _set(_pendingRemoveKey(spaceId), '1');
      await _deleteSpaceData(spaceId);
      return;
    }
    final vault = await loadVault(pin: pin);
    if (vault != null) {
      final next = vault.remove(spaceId);
      await saveVault(next, pin: pin);
      await _syncActiveKey(next); // 删的若是当前空间，键要让给剩下的那个
    } else if (VaultSession.current != null) {
      // PIN 模式且没有 pin（撤销自毁路径）：改不了密文包，但内存里的 Vault 要同步，
      // 否则界面还会看到已删除的空间。
      VaultSession.publish(VaultSession.current!.remove(spaceId));
    }
    await _deleteSpaceData(spaceId);
  }

  /// 删除一个空间的全部本地数据（**只动这一个空间**）：消息、附件、回执、同步锚点、
  /// 草稿、Spaces 行、per-space 资料键与设置键，以及这些消息的媒体缓存/留存明文。
  Future<void> _deleteSpaceData(String spaceId) async {
    final rows = await (db.select(db.localMessages)
          ..where((m) => m.spaceId.equals(spaceId)))
        .get();
    final messageIds = {for (final r in rows) r.messageId};
    await (db.delete(db.localMessages)..where((m) => m.spaceId.equals(spaceId))).go();
    // 附件按 spaceId 删，并兼容回填失败的空 spaceId 行（按所属消息再兜一遍）
    await (db.delete(db.localAttachments)
          ..where((a) => a.spaceId.equals(spaceId) | a.messageId.isIn(messageIds)))
        .go();
    await (db.delete(db.peerReceipts)..where((p) => p.spaceId.equals(spaceId))).go();
    await (db.delete(db.syncState)..where((s) => s.spaceId.equals(spaceId))).go();
    await (db.delete(db.drafts)..where((d) => d.spaceId.equals(spaceId))).go();
    await (db.delete(db.spaces)..where((s) => s.spaceId.equals(spaceId))).go();
    await _delete(_profileKey(spaceId));
    await (db.delete(db.appState)..where((a) => a.key.like('space.$spaceId.%'))).go();
    // 缓存/留存明文已按空间分目录（2026-09-23）→ 删目录即可，不必逐条删
    await MediaCache.deleteSpace(spaceId);
    await AttachmentStore.clearSpace(spaceId);
  }

  /// 切换当前空间（同时刷新该空间的 lastActiveAt）。**不需要锁屏码**。
  ///
  /// 老板 2026-09-22 定：要让"在聊天页里直接切空间"成为可能。为此"上次用的是哪个空间"
  /// 落**明文**键 [_kActiveSpace]（不是秘密：Spaces 表本来就明文存着空间 id 与名字），
  /// 不再为它重写加密锁包——PIN 模式下重写密文包必须给 pin，而聊天页刻意不持有 pin。
  /// [pin] 给出时额外同步锁包内的 activeSpaceId（兼容旧读法，非必需）。
  Future<void> setActiveSpace(String spaceId, {String? pin}) async {
    await _set(_kActiveSpace, spaceId);
    final v = VaultSession.current;
    if (v != null) VaultSession.publish(v.copyWith(activeSpaceId: spaceId));
    await (db.update(db.spaces)..where((s) => s.spaceId.equals(spaceId))).write(
      SpacesCompanion(lastActiveAt: Value(DateTime.now().millisecondsSinceEpoch)),
    );
    if (pin != null) {
      final vault = await loadVault(pin: pin);
      if (vault != null) await saveVault(vault.copyWith(activeSpaceId: spaceId), pin: pin);
    }
  }

  /// 解析"上次用的是哪个空间"：[_kActiveSpace] 明文键 → 锁包内 activeSpaceId → 第一个空间。
  ///
  /// 明文键优先，因为它是**不需要锁屏码**就能更新的那一份；键指向的空间若已被移除则跳过。
  Future<String?> resolveActiveSpaceId(VaultPayload vault) async {
    bool exists(String? id) =>
        id != null && vault.spaces.any((s) => s.spaceId == id);
    final stored = await _get(_kActiveSpace);
    if (exists(stored)) return stored;
    if (exists(vault.activeSpaceId)) return vault.activeSpaceId;
    return vault.spaces.isEmpty ? null : vault.spaces.first.spaceId;
  }

  /// 取"上次用的那个空间"的凭证（冷启动直接进它，不再先进列表页）。
  /// 空间列表为空时返回 null。
  Future<AppLockPayload?> resolveActivePayload(VaultPayload vault) async {
    final id = await resolveActiveSpaceId(vault);
    if (id == null) return null;
    for (final s in vault.spaces) {
      if (s.spaceId == id) return s;
    }
    return vault.active;
  }

  /// 发布到内存会话，并把 activeSpaceId **归一**为明文键解析出的当前空间。
  ///
  /// 为什么必须归一：明文键才是"当前空间"的真相，锁包里的 activeSpaceId 会落后
  /// （无 pin 切换不重写密文包）。不归一的话，任何一次 unlock 都会把内存里的
  /// "当前空间"打回旧值（实测：切到 B 后再解锁一次又变回 A）。
  Future<VaultPayload?> _publishNormalized(VaultPayload? vault) async {
    if (vault == null) return VaultSession.publish(null);
    final id = await resolveActiveSpaceId(vault);
    return VaultSession.publish(
        id == null ? vault : vault.copyWith(activeSpaceId: id));
  }

  /// 把明文键对齐到 [vault] 的当前空间（空间列表为空时删键）。
  /// 用于"移除空间"这类会让当前空间变化、但调用方又不是显式切换的路径。
  Future<void> _syncActiveKey(VaultPayload vault) async {
    final id = await resolveActiveSpaceId(vault);
    if (id == null) {
      await _delete(_kActiveSpace);
    } else {
      await _set(_kActiveSpace, id);
    }
  }

  /// 现有 Vault 并入 [payload]（按 spaceId 覆盖或追加），并置为 active。
  Future<VaultPayload> _mergedVault(AppLockPayload payload) async {
    final vault = await loadPlainVault() ?? VaultPayload.single(payload);
    return vault.upsert(payload).copyWith(activeSpaceId: payload.spaceId);
  }

  /// Vault 里每个空间都保证有 Spaces 行（列表页展示名字/未读用）。
  Future<void> _syncAllSpaceRows(VaultPayload vault) async {
    for (final space in vault.spaces) {
      await _syncSpaceRow(space);
    }
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
            entranceId: Value(payload.entranceId),
            keyVersion: Value(payload.keyVersion),
            createdAt: Value(now),
            lastActiveAt: Value(now),
          ));
    } else {
      await (db.update(db.spaces)..where((s) => s.spaceId.equals(payload.spaceId))).write(
        SpacesCompanion(
          entranceId: Value(payload.entranceId),
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
      // 上次退出前挂的"待摘除空间"（当时没有 pin，改不了密文包）在这里补做
      final cleaned = await _applyPendingRemovals(VaultPayload.fromJson(jsonDecode(utf8.decode(plain))));
      if (cleaned != null) await writePinVault(pin, cleaned);
      final vault = cleaned ?? VaultPayload.fromJson(jsonDecode(utf8.decode(plain)));
      final active = vault.active;
      if (active != null) await _syncSpaceRow(active);
      return await _publishNormalized(vault) ?? vault;
    } on FormatException {
      await _registerFailure();
      throw const AppLockException('锁屏码 错误');
    }
  }

  /// 摘掉所有 pending 空间（数据此前已清，这里只摘凭证条目）；无 pending 返回 null。
  Future<VaultPayload?> _applyPendingRemovals(VaultPayload vault) async {
    final rows = await (db.select(db.appState)
          ..where((s) => s.key.like('app_lock.pending_remove.%')))
        .get();
    if (rows.isEmpty) return null;
    var next = vault;
    for (final row in rows) {
      next = next.remove(row.key.substring('app_lock.pending_remove.'.length));
      await _delete(row.key);
    }
    return next;
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

  /// 待摘除的空间（PIN 模式下没有 pin 时标记，下次解锁有 pin 了再真正摘凭证）。
  static String _pendingRemoveKey(String spaceId) => 'app_lock.pending_remove.$spaceId';

  /// 用户资料（名字）持久化：向导完成时保存，PIN 解锁/重启后 ChatPage 恢复显示。
  /// （名字不在 AppLockPayload 里——解锁构造 ChatPage 时无法获得，故单独存。）
  ///
  /// [spaceId] 给出时写 per-space 键（`app_lock.profile.<spaceId>`）并同步 Spaces 行的
  /// 名字；缺省（单空间旧调用点）回退全局键 [_kProfile]。
  Future<void> saveProfile({
    String? spaceId,
    required String memberName,
    required String peerName,
    required String entranceName,
    String myGender = '', // 本人性别（male/female；个人资料弹窗图标展示用）
    String peerGender = '', // 对方性别（male/female；消息气泡配色用）
    int? mySlot, // 本人身份槽位（0=第一人/创建者，1=第二人；同性别气泡青色用）
    int? peerSlot, // 对方身份槽位（同上；对方气泡配色判定用）
  }) async {
    final sid = spaceId;
    await _set(sid == null ? _kProfile : _profileKey(sid), jsonEncode({
      'memberName': memberName,
      'peerName': peerName,
      'entranceName': entranceName,
      'myGender': myGender,
      'peerGender': peerGender,
      'mySlot': mySlot,
      'peerSlot': peerSlot,
    }));
    if (sid != null) {
      await (db.update(db.spaces)..where((s) => s.spaceId.equals(sid))).write(
        SpacesCompanion(name: Value(memberName), peerName: Value(peerName)),
      );
    }
  }

  /// 读回保存的资料（键缺失返回空串——解锁场景 ChatPage 空名时恢复）。
  ///
  /// [spaceId] 给出时读该空间的 per-space 键；读不到才回退旧全局键 [_kProfile]
  /// （兼容分支，见 [_legacyProfileRaw]）。[spaceId] 缺省时直接读旧全局键
  /// （未传 spaceId 的旧调用点，如单空间时代的 AppLockPage 流程）。
  Future<Map<String, Object?>> loadProfile({String? spaceId}) async {
    final sid = spaceId;
    final raw = sid == null
        ? await _get(_kProfile)
        : await _get(_profileKey(sid)) ?? await _legacyProfileRaw();
    if (raw == null) return const {};
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return {
        'memberName': (m['memberName'] as String?) ?? '',
        'peerName': (m['peerName'] as String?) ?? '',
        'entranceName': (m['entranceName'] as String?) ?? '',
        'myGender': (m['myGender'] as String?) ?? '',
        'peerGender': (m['peerGender'] as String?) ?? '',
        'mySlot': (m['mySlot'] as num?)?.toInt(),
        'peerSlot': (m['peerSlot'] as num?)?.toInt(),
        'peerMemberId': (m['peerMemberId'] as String?) ?? '',
      };
    } catch (_) {
      return const {};
    }
  }

  /// 记下本空间**对方**的 member_id（头像等按 member 维度取数据时用）。
  ///
  /// 为什么需要单独存：对方的身份 id 原本只在"取数据那一刻"现算——从服务端 `GET /space`
  /// 的通道表取 `entranceId → memberId` 再排掉自己，**算完即丢**；而对方的名字/性别/槽位
  /// 都早已落进 per-space 资料。于是会出现"卡片有对方名字、却不知道对方是谁、头像只能给默认"
  /// 的不对称（老板 2026-09-23 指出）。这里把它与 peerName 并列存进同一份资料。
  ///
  /// 读改写、只加这一个键（不碰其它键），幂等——值没变不写盘。
  Future<void> savePeerMemberId({
    required String spaceId,
    required String peerMemberId,
  }) async {
    final pid = peerMemberId.trim();
    if (spaceId.isEmpty || pid.isEmpty) return;
    final key = _profileKey(spaceId);
    var m = <String, dynamic>{};
    final raw = await _get(key);
    if (raw != null) {
      try {
        m = jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {
        m = <String, dynamic>{}; // 坏 JSON：重写一份干净的
      }
    }
    if (m['peerMemberId'] == pid) return; // 幂等
    await _set(key, jsonEncode({...m, 'peerMemberId': pid}));
  }

  /// 旧全局键 [_kProfile] 的兼容读：**仅当本机只登记了 ≤1 个空间**时返回。
  ///
  /// 背景：v7 迁移故意不搬资料（迁移阶段解不开 PIN 包、也拿不到 spaceId），
  /// 老安装的名字只存在全局键里 —— 单空间用户必须靠它才不会升级后变空。
  /// 但多空间下全局键是所有空间共用的一格（会被最后保存的空间覆写），继续回退
  /// 就会把别的空间的名字/性别读进来（老板 2026-09-22 实测的串台）。用空间条数
  /// 把这条兼容路径收窄：多空间时宁可先读空（随后 `_refreshProfileFromServer`
  /// 会从服务端补回），也不要显示另一个空间的身份。
  Future<String?> _legacyProfileRaw() async {
    final rows = await (db.select(db.spaces)..limit(2)).get();
    if (rows.length > 1) return null;
    return _get(_kProfile);
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
    required this.entranceId,
    this.keyVersion = 1,
    this.token,
    this.escrowUpdatedAt,
    this.publicKeyB64,
    this.privateKeyB64,
  });

  final String spaceKeyB64;
  final String spaceId;
  final String entranceId;
  final int keyVersion;
  final String? token;

  /// 本端已知的服务端口令更新时间（ms）：上线时与服务器对比，
  /// 服务器更新 = 离线期间口令被重设（应弹窗重新验证）。
  final int? escrowUpdatedAt;

  /// 通道 X25519 密钥对（b64）：随锁包持久化——重启后 challenge-response
  /// 重新认证（reauth）需用私钥签名；「我的通道」弹窗展示公钥。旧包无此字段。
  final String? publicKeyB64;
  final String? privateKeyB64;

  Map<String, dynamic> toJson() => {
        'space_key': spaceKeyB64,
        'space_id': spaceId,
        'entrance_id': entranceId,
        'key_version': keyVersion,
        'token': token,
        'escrow_updated_at': escrowUpdatedAt,
        'entrance_public_key': publicKeyB64,
        'entrance_private_key': privateKeyB64,
      };

  factory AppLockPayload.fromJson(Map<String, dynamic> json) => AppLockPayload(
        spaceKeyB64: json['space_key'] as String,
        spaceId: json['space_id'] as String,
        entranceId: json['entrance_id'] as String,
        keyVersion: (json['key_version'] as int?) ?? 1,
        token: json['token'] as String?,
        escrowUpdatedAt: json['escrow_updated_at'] as int?,
        publicKeyB64: json['entrance_public_key'] as String?,
        privateKeyB64: json['entrance_private_key'] as String?,
      );
}

/// 一条通道上的**全部空间凭证**（多空间支持，见 `aimemo/multiSpaceDesign.zhcn.md` §3.2）。
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
  });

  /// 单空间（旧包归一、首次创建用）。
  factory VaultPayload.single(AppLockPayload payload) =>
      VaultPayload(spaces: [payload], activeSpaceId: payload.spaceId);

  final List<AppLockPayload> spaces;

  /// 当前进入的空间；为 null 或指向不存在的空间时 [active] 退回第一项。
  final String? activeSpaceId;

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
    return VaultPayload(spaces: next, activeSpaceId: nextActive);
  }

  VaultPayload copyWith({List<AppLockPayload>? spaces, String? activeSpaceId}) =>
      VaultPayload(
        spaces: spaces ?? this.spaces,
        activeSpaceId: activeSpaceId ?? this.activeSpaceId,
      );

  Map<String, dynamic> toJson() => {
        'version': 1,
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
      // 旧 Vault JSON 里的 entrance_name 已废弃（通道名归 per-space profile，见
      // multiSpaceDesign §2.2 的 2026-09-22 修订），读到也不处理。
    );
  }
}

/// 用锁包里的通道密钥对完成 challenge-response 重新认证（重启后 reauth 用：
/// 会话过期 401/4401 时自动续期）。锁包无密钥对（旧包）时抛 [StateError]。
///
/// **必须带 spaceId**：challenge 签发的 session 会绑定该 Space（服务端 auth.ts
/// 自 2026-09-15 起 space_id 必填，缺了直接 400）——会话过期时消息发送会走到这条
/// 路径，400 又会被 [_isServerRejection] 判成"服务端明确拒绝"，把一条本可自动恢复的
/// 消息变成**永久**发送失败（老板 2026-09-22 排查线上红色标签时发现）。
Future<String> reauthFromPayload(AppLockPayload payload) async {
  final pub = payload.publicKeyB64;
  final priv = payload.privateKeyB64;
  if (pub == null || priv == null || pub.isEmpty || priv.isEmpty) {
    throw StateError('锁包无通道密钥对');
  }
  final s = await sodium();
  final api = ApiClient(effectiveServer);
  final challenge = await api.challenge(payload.entranceId, spaceId: payload.spaceId);
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
