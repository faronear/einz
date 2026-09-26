// 空间会话（SpaceSession）：**一个空间一份可续期的 token**。
//
// 背景（老板 2026-09-26 线上实测）：服务端 session 24h 过期后，只有同步/WS 会续期
// （且只写各自内存里那份），页面里的直接请求拿的是构造时固化的旧 token →
// 头像上传/改名/开通码/更多通道/未读角标/退役 全部 401「invalid session」，
// 而且**重启也不恢复**（续期结果从不落盘）。本文件守的就是这条链路的四个要点：
// 401 自动续期并重试、并发只发一次 challenge、续不了期就老实抛、续期结果尽力写回 Vault。

import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz/data/app_lock.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/data/space_session.dart';
import 'package:einz/data/vault_session.dart';
import 'package:einz_shared/einz_shared.dart';

/// 过期 token 才会抛的 401（服务端 auth.ts 的原话就是 invalid session）。
ApiException _invalidSession() =>
    ApiException('UNAUTHORIZED', 'invalid session', 401);

void main() {
  setUpAll(() async {
    await sodium();
  });

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({}); // SecureStore 测试替身
    VaultSession.publish(null); // 进程级解锁态是静态的，逐用例复位
    SpaceSessions.clear(); // 注册表也是静态的，别让用例互相串味
  });

  test('401 → 续期 → 用新 token 重试一次（并记住新 token）', () async {
    var renewCalls = 0;
    final session = SpaceSession(
      spaceId: 'space-a',
      initialToken: 'stale',
      refresh: () async {
        renewCalls++;
        return 'fresh';
      },
    );
    final seen = <String>[];
    final result = await session.call((t) async {
      seen.add(t);
      if (t == 'stale') throw _invalidSession();
      return 'ok';
    });

    expect(result, 'ok');
    expect(seen, ['stale', 'fresh'], reason: '重试必须用新 token');
    expect(renewCalls, 1);
    expect(session.token, 'fresh', reason: '会话里的 token 就地更新（后续请求不再 401）');
  });

  test('非 401 不续期、原样抛（被撤销的 403 不能被"续期"糊过去）', () async {
    var renewCalls = 0;
    final session = SpaceSession(
      spaceId: 'space-a',
      initialToken: 'tok',
      refresh: () async {
        renewCalls++;
        return 'fresh';
      },
    );

    await expectLater(
      session.call((t) async =>
          throw ApiException('ENTRANCE_REVOKED', 'revoked', 403)),
      throwsA(isA<ApiException>()),
    );
    expect(renewCalls, 0);
  });

  test('续不了期（旧锁包没有通道密钥对）→ 401 照抛，不假装成功', () async {
    final session = SpaceSession(spaceId: 'space-a', initialToken: 'stale');
    await expectLater(
        session.call((t) async => throw _invalidSession()),
        throwsA(isA<ApiException>()));
  });

  test('并发 401 只续期一次（共用同一个在途请求，别把限流打满）', () async {
    var renewCalls = 0;
    final session = SpaceSession(
      spaceId: 'space-a',
      initialToken: 'stale',
      refresh: () async {
        renewCalls++;
        // 故意拖一下：让三个请求都落在"续期在途"的窗口里
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return 'fresh';
      },
    );
    Future<String> hit(String t) async {
      if (t == 'stale') throw _invalidSession();
      return t;
    }

    final results = await Future.wait(
        [session.call(hit), session.call(hit), session.call(hit)]);
    expect(results, ['fresh', 'fresh', 'fresh']);
    expect(renewCalls, 1,
        reason: '同步/WS/直接请求同时过期只该发一次 challenge（AUTH 限流 60 次/5 分钟）');
  });

  test('续期失败后还能再试（在途标记要清掉，不能永久卡死）', () async {
    var attempts = 0;
    final session = SpaceSession(
      spaceId: 'space-a',
      initialToken: 'stale',
      refresh: () async {
        attempts++;
        if (attempts == 1) throw StateError('网络抖了一下');
        return 'fresh';
      },
    );
    await expectLater(session.call((t) async => throw _invalidSession()),
        throwsA(isA<StateError>()));
    // 第二次：在途标记已清 → 重新续期 → 成功重试
    final ok = await session.call((t) async {
      if (t == 'stale') throw _invalidSession();
      return 'ok';
    });
    expect(ok, 'ok');
    expect(attempts, 2);
  });

  test('注册表：同一空间只建一份（聊天页与空间列表共用同一个会话）', () {
    final a = SpaceSessions.of(spaceId: 'space-a', token: 'tok');
    final b = SpaceSessions.of(spaceId: 'space-a', token: 'other');
    expect(identical(a, b), isTrue);
    expect(b.token, 'tok', reason: '首次创建者播种，后来者不覆盖（否则又把活的 token 打回旧的）');

    SpaceSessions.forget('space-a');
    expect(identical(SpaceSessions.of(spaceId: 'space-a', token: 'tok2'), a),
        isFalse,
        reason: '空间被移除/重新加入后必须重建，别攥着上一轮的凭证');
  });

  test('无 PIN：续期后新 token 写回 Vault（下次冷启动不再是死 token）', () async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await AppLockService(db).savePlain(const AppLockPayload(
      spaceKeyB64: 'a2V5',
      spaceId: 'space-a',
      entranceId: 'dev-a',
      token: 'stale',
    ));

    final session = SpaceSession(
      spaceId: 'space-a',
      initialToken: 'stale',
      refresh: () async => 'fresh',
      db: db,
    );
    await session.call((t) async {
      if (t == 'stale') throw _invalidSession();
      return 'ok';
    });

    expect(VaultSession.current!.spaces.single.token, 'fresh');
    // 重新从存储读一遍：确认是落盘了，不只是内存里改了
    final reread = await AppLockService(db).loadPlainVault();
    expect(reread!.spaces.single.token, 'fresh');
  });

  test('PIN 模式：不写回（令牌不能落到密文包之外），但内存里照样续期（用户无感）',
      () async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final lock = AppLockService(db);
    await lock.setPin('123456', payload: const AppLockPayload(
      spaceKeyB64: 'a2V5',
      spaceId: 'space-a',
      entranceId: 'dev-a',
      token: 'stale',
    ));

    final session = SpaceSession(
      spaceId: 'space-a',
      initialToken: 'stale',
      refresh: () async => 'fresh',
      db: db,
    );
    await session.call((t) async {
      if (t == 'stale') throw _invalidSession();
      return 'ok';
    });

    expect(session.token, 'fresh', reason: '内存里续期，用户看不到任何错误');
    final vault = await lock.loadVault(pin: '123456');
    expect(vault!.spaces.single.token, 'stale',
        reason: 'PIN 模式不重写密文包——token 是 bearer 凭证，不能落到包外');
  });
}
