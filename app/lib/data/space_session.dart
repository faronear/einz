import 'package:einz_shared/einz_shared.dart';

import 'app_lock.dart';
import 'local_database.dart';
import 'vault_session.dart';

/// 一个空间的会话：**该空间唯一的权威 token**（可变、可续期）。
///
/// 为什么必须收敛到一处（2026-09-26 老板线上实测）：会话 24h 过期后，
/// 同步（`MessageRepository._withAutoAuth`）与 WS（`WsRealtimeService.updateToken`）
/// 各写**自己内存里那份** token，而聊天页/空间列表里的直接请求用的是构造时固化的
/// `widget.token`（= Vault 里那个死 token）→ 头像上传、改名、开通码、更多通道、
/// 未读角标、退役…… 全部 401「invalid session」，而且**重启也不恢复**
/// （续期结果从不落盘）。所以：**带鉴权的请求一律走 [call]，不要再把
/// `AppLockPayload.token` 直接塞给 ApiClient。**
///
/// 三件事一起做才算根治：
/// 1. token 只有一份（本类持有，续期后就地更新）；
/// 2. 401 自动续期并**重试一次**（不再是"只有同步/WS 才会续期"）；
/// 3. 续期结果**尽力写回 Vault**（无 PIN 时能写）→ 下次冷启动就不是死 token 了。
class SpaceSession {
  SpaceSession({
    required this.spaceId,
    required String initialToken,
    this.refresh,
    this.db,
  }) : _token = initialToken;

  final String spaceId;

  /// 续期回调（challenge-response 重新签发 token）。null = 这个锁包没有通道密钥对
  /// （旧装机）→ 续不了期，401 原样抛出，不假装成功。
  final Future<String> Function()? refresh;

  /// 写回 Vault 用（可空：测试/无库场景）。落盘失败不影响本次会话。
  final LocalDatabase? db;

  String _token;
  Future<String>? _inFlight;

  /// 当前 token（**只读**——要发请求请用 [call]，别把它抄到别处去）。
  String get token => _token;

  /// 带鉴权的请求都走它：401（session 过期）→ 续期 → 用新 token **重试一次**；
  /// 其他错误原样抛。语义与 `MessageRepository._withAutoAuth` 一致。
  Future<T> call<T>(Future<T> Function(String token) fn) async {
    try {
      return await fn(_token);
    } on ApiException catch (e) {
      if (e.httpStatus != 401 || refresh == null) rethrow;
      final fresh = await renew();
      return await fn(fresh);
    }
  }

  /// 续期（**并发去重**）：一次过期会同时打到同步 / WS / 直接请求三处，
  /// 各自发一次 challenge 会白烧限流额度（AUTH 60 次/5 分钟/IP，2026-09-22
  /// 就实测撞过 429）——在途的那个直接共享给后来者。
  Future<String> renew() {
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;
    final started = _renew();
    _inFlight = started;
    // 用 whenComplete 而不是 then：失败也要把在途标记清掉，否则永远卡在"续期失败"上
    return started.whenComplete(() => _inFlight = null);
  }

  Future<String> _renew() async {
    final refresh = this.refresh;
    if (refresh == null) throw StateError('这个空间没有可用的续期凭证（旧锁包无通道密钥对）');
    final fresh = await refresh();
    _token = fresh;
    await _persist(fresh);
    return fresh;
  }

  /// 尽力把新 token 写回 Vault。
  ///
  /// **只在无 PIN（明文包）时写**：令牌是 bearer 凭证，PIN 模式下绝不能落到密文包
  /// 之外（聊天页也拿不到 PIN，写不了密文包）。写不了也不影响本次会话——内存里已经
  /// 是新的，用户看不到任何错误；只是下次冷启动还要再续一次。
  Future<void> _persist(String fresh) async {
    final database = db;
    if (database == null) return;
    try {
      final vault = VaultSession.current;
      if (vault == null) return;
      final lock = AppLockService(database);
      if (await lock.isSetup) return; // PIN 模式：不写
      await lock.saveVault(vault.updateToken(spaceId, fresh));
    } catch (_) {
      // 落盘失败无所谓：内存会话已经是新的
    }
  }
}

/// 每个空间一份 [SpaceSession]，全 App 共用（聊天页 / 空间列表 / 退役都取同一个，
/// 这样一处续期、处处生效，且并发时只发一次 challenge）。
class SpaceSessions {
  SpaceSessions._();

  static final Map<String, SpaceSession> _bySpace = {};

  /// 取（或建）该空间的会话。已存在则原样返回——**首次创建者提供的 refresh/db 生效**。
  static SpaceSession of({
    required String spaceId,
    required String token,
    Future<String> Function()? refresh,
    LocalDatabase? db,
  }) =>
      _bySpace.putIfAbsent(
        spaceId,
        () => SpaceSession(
            spaceId: spaceId, initialToken: token, refresh: refresh, db: db),
      );

  /// 从 Vault 里的 payload 建（空间列表用它给**其他空间**拿会话）。
  /// 密钥对齐全才有续期能力（旧包没有 → 401 照抛）。
  static SpaceSession ofPayload(AppLockPayload payload, {LocalDatabase? db}) {
    final canRenew = (payload.publicKeyB64?.isNotEmpty ?? false) &&
        (payload.privateKeyB64?.isNotEmpty ?? false);
    return of(
      spaceId: payload.spaceId,
      token: payload.token ?? '',
      refresh: canRenew ? () => reauthFromPayload(payload) : null,
      db: db,
    );
  }

  /// 清空（全量重置 / 本地数据被清）后调。留着旧条目的风险：同名空间重新加入后，
  /// 会话里还是上一轮那条死 token（而 refresh 闭包也可能握着旧凭证）。
  static void clear() => _bySpace.clear();

  /// 只忘掉一个空间（该空间被移除 / 被撤销 / 退役后调）。
  static void forget(String spaceId) => _bySpace.remove(spaceId);
}
