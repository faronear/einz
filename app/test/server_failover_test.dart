// 运行期换入口（ServerFailover）回归测试：
// - 当前入口探不通、备用入口可用 → 切换并通知；
// - 当前入口健康（只是 401/会话过期等应用层错误）→ 不换；
// - 全部不通 → 留在原地址（不能退回到已停用的主域名）；
// - 冷却期/单飞不重复探测。

import 'dart:async';
import 'dart:io';

import 'package:einz/data/server_config.dart';
import 'package:einz/data/server_failover.dart';
import 'package:einz_shared/einz_shared.dart' show ApiException;
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    effectiveServer = kPrimaryServer;
    ServerFailover.instance.reset();
  });

  tearDown(() {
    effectiveServer = kPrimaryServer;
    ServerFailover.instance.reset();
  });

  test('当前入口不可达、备用入口可达 → 切换并通知', () async {
    final failover = ServerFailover(cooldown: Duration.zero);
    addTearDown(failover.reset);
    final probed = <String>[];
    Future<ServerHealth> probe(String server) async {
      probed.add(server);
      return ServerHealth(ok: server == kServerCandidates[1]);
    }

    await failover.check(probe: probe);

    expect(effectiveServer, kServerCandidates[1]);
    expect(failover.switches.value, 1);
    expect(failover.lastSwitchFrom, kPrimaryServer);
    expect(failover.lastSwitchTo, kServerCandidates[1]);
    // 第一轮先探当前地址，再回候选列表并发重探
    expect(probed.first, kPrimaryServer);
    expect(probed, contains(kServerCandidates[1]));
  });

  test('当前入口健康 → 不换（应用层错误不触发换入口）', () async {
    final failover = ServerFailover(cooldown: Duration.zero);
    addTearDown(failover.reset);

    await failover.check(probe: (_) async => const ServerHealth(ok: true));

    expect(effectiveServer, kPrimaryServer);
    expect(failover.switches.value, 0);
  });

  test('全部不通 → 留在原地址，不退回到已停用的主域名', () async {
    effectiveServer = kServerCandidates[1];
    final failover = ServerFailover(cooldown: Duration.zero);
    addTearDown(failover.reset);

    await failover.check(probe: (_) async => const ServerHealth());

    expect(effectiveServer, kServerCandidates[1],
        reason: '全失败时应保持当前入口，而不是切到更坏的兜底');
    expect(failover.switches.value, 0);
  });

  test('冷却期内不重复探测', () async {
    final failover = ServerFailover(cooldown: const Duration(minutes: 1));
    addTearDown(failover.reset);
    var calls = 0;
    Future<ServerHealth> probe(String _) async {
      calls++;
      return const ServerHealth();
    }

    await failover.check(probe: probe);
    final first = calls;
    await failover.check(probe: probe);

    expect(first, greaterThan(0));
    expect(calls, first, reason: '冷却期内第二次 check 不应再探');
  });

  test('开发覆盖地址不参与换入口', () async {
    effectiveServer = 'http://localhost:3000';
    final failover = ServerFailover(cooldown: Duration.zero);
    addTearDown(failover.reset);
    var calls = 0;

    await failover.check(probe: (_) async {
      calls++;
      return const ServerHealth();
    });

    expect(calls, 0);
    expect(effectiveServer, 'http://localhost:3000');
  });

  test('isNetworkFailure 只认网络层 / 5xx，不认 4xx', () {
    expect(isNetworkFailure(SocketException('x')), isTrue);
    expect(isNetworkFailure(TimeoutException('x')), isTrue);
    expect(isNetworkFailure(HandshakeException('x')), isTrue);
    expect(isNetworkFailure(ApiException('HTTP_502', 'bad gateway', 502)),
        isTrue);
    expect(isNetworkFailure(ApiException('UNAUTHORIZED', '401', 401)), isFalse);
    expect(isNetworkFailure(ApiException('FORBIDDEN', '403', 403)), isFalse);
    expect(isNetworkFailure(StateError('x')), isFalse);
  });
}
