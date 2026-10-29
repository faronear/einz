// 启动选路（3A）回归测试：
// - 临时入口不可达、备用可达 -> 切换并 ready；
// - 当前入口本身就是可达入口 -> 不换；
// - 全不可达 -> 保持临时地址，不阻塞进入；
// - 人为覆盖 -> 不探测；
// - 探测期间已被运行期换入口抢先 -> 丢弃旧结果，不覆盖新地址。

import 'dart:async';

import 'package:einz/data/server_bootstrap.dart';
import 'package:einz/data/server_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    resetServerRuntimeForTest();
    ServerBootstrap.instance.reset();
  });

  tearDown(() {
    resetServerRuntimeForTest();
    ServerBootstrap.instance.reset();
  });

  test('临时入口不可达、备用可达 -> 切换并 ready', () async {
    effectiveServer = kFallbackServer;
    final bootstrap = ServerBootstrap(
      probe: (server) async =>
          ServerHealth(ok: server == kServerCandidates[3]),
    );
    addTearDown(bootstrap.reset);

    await bootstrap.start();

    expect(effectiveServer, kServerCandidates[3]);
    expect(bootstrap.phase.value, ServerPhase.ready);
    expect(serverRevision.value, 1);
  });

  test('当前入口可达且被并发探测选中 -> 不换地址，ready', () async {
    effectiveServer = kFallbackServer;
    final probed = <String>[];
    final bootstrap = ServerBootstrap(probe: (server) async {
      probed.add(server);
      return ServerHealth(ok: server == kFallbackServer);
    });
    addTearDown(bootstrap.reset);

    await bootstrap.start();

    expect(effectiveServer, kFallbackServer);
    expect(serverRevision.value, 0);
    expect(bootstrap.phase.value, ServerPhase.ready);
    // 4 个候选并发 + 1 次确认（picked == before 时区分"当前最快"和"全不通"）
    expect(probed.length, kServerCandidates.length + 1);
  });

  test('全部不可达 -> 保持临时地址，unreachable', () async {
    effectiveServer = kFallbackServer;
    final bootstrap = ServerBootstrap(
      probe: (_) async => const ServerHealth(),
    );
    addTearDown(bootstrap.reset);

    await bootstrap.start();

    expect(effectiveServer, kFallbackServer);
    expect(serverRevision.value, 0);
    expect(bootstrap.phase.value, ServerPhase.unreachable);
  });

  test('人为覆盖 --server -> 不探测', () async {
    resetServerRuntimeForTest();
    effectiveServer = kServerCandidates[1];
    serverOverrideActive = true;
    var calls = 0;
    final bootstrap = ServerBootstrap(probe: (_) async {
      calls++;
      return const ServerHealth(ok: true);
    });
    addTearDown(bootstrap.reset);

    await bootstrap.start();

    expect(calls, 0);
    expect(bootstrap.phase.value, ServerPhase.idle);
  });

  test('启动探测期间已有更新选择 -> 丢弃旧结果，不覆盖', () async {
    effectiveServer = kFallbackServer;
    final gate = Completer<ServerHealth>();
    final bootstrap = ServerBootstrap(probe: (server) {
      if (server == kServerCandidates[2]) return gate.future;
      return Future<ServerHealth>.value(const ServerHealth());
    });
    addTearDown(bootstrap.reset);

    final running = bootstrap.start();
    // 模拟运行期换入口先完成
    applyEffectiveServer(kServerCandidates[3]);
    gate.complete(const ServerHealth(ok: true));
    await running;

    expect(effectiveServer, kServerCandidates[3],
        reason: '旧启动结果不能覆盖更新的运行期选择');
    expect(bootstrap.phase.value, ServerPhase.ready);
  });
}
