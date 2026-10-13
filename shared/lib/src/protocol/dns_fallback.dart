/// DNS 污染兜底（2026-10-11）：部分网络（家庭路由器 / 运营商网关）会对明文
/// UDP-53 查询做**抢答注入**——伪造应答（假 IP + TTL 3600）抢先于真实应答到达，
/// 导致系统解析被污染约 1 小时，客户端连不上服务器。
///
/// 兜底策略：连接探测失败 → 用加密 DoH（doh.pub → dns.alidns.com →
/// cloudflare-dns.com，响应经 TLS 校验、无法被注入）重新解析 → 把真 IP
/// **钉扎**（pin）进进程级表 → 后续所有连接经 [createPinnedHttpClient] 的
/// `connectionFactory` 直连该 IP。
///
/// 安全红线：
/// - TLS 证书始终按**真实域名**校验（[SecureSocket.secure] 的 `host:` 参数
///   同时决定 SNI 与证书验证），全链路不出现 `onBadCertificate`；
/// - 钉扎 IP 唯一来源是 TLS 校验过的 DoH 响应；
/// - 会话级内存，永不落盘（与"服务器地址不落盘"同一纪律）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'types.dart';

/// 进程级 IP 钉扎表（host → IPv4）。唯一来源：TLS 校验过的 DoH 响应。
final Map<String, String> pinnedServerIps = <String, String>{};

/// DNS 污染事件钩子：DoH 解析与系统解析**分歧**（= 链路被注入）并成功拿到
/// 真 IP 时触发。App/CLI 用它把"此刻这个网络在被污染"变成可见警报。
/// [poisonedIp] = 系统解析此刻返回的**假 IP**（现场再解析一次捕获，纯展示；
/// 查不到/超时 = null）。全局单槽（本工程单服务器，无需多订阅）；回调异常被吞，
/// 绝不影响主流程。
void Function(String host, String pinnedIp, String? poisonedIp)?
    onDnsPoisonDetected;

void setServerPin(String host, String ip) => pinnedServerIps[host] = ip;
void clearServerPin(String host) => pinnedServerIps.remove(host);

/// 清空全部兜底状态（pin 表 + DoH 速率闸）。仅供测试隔离用。
void resetDohFallbackState() {
  pinnedServerIps.clear();
  _dohTriedAt.clear();
}

/// DoH 解析函数类型（测试可注入 fake）。
typedef DoHResolver = Future<String?> Function(String host);

/// DoH 解析：doh.pub 优先、alidns 兜底、Cloudflare 收尾（海外用户在前两家
/// 慢/不稳时有更好的选择；大陆 1.1.1.1 被墙，实际永远轮不到它，零代价）；
/// 各 4s 超时；只取 A 记录。全失败 → null（调用方保留原始连接错误）。
///
/// 解析 doh.pub / dns.alidns.com / cloudflare-dns.com 本身仍走系统 DNS——这些
/// 头部大域实际不会被抢答；且其应答经 HTTPS 证书校验，注入无法伪造。
Future<String?> dohResolveHost(String host) async {
  for (final endpoint in _kDohEndpoints) {
    try {
      final client = HttpClient()..connectionTimeout = _kDohTimeout;
      try {
        final req = await client
            .getUrl(Uri.parse('$endpoint?name=$host&type=A'))
            .timeout(_kDohTimeout);
        req.headers.set(HttpHeaders.acceptHeader, 'application/dns-json');
        final res = await req.close().timeout(_kDohTimeout);
        final body =
            await res.transform(utf8.decoder).join().timeout(_kDohTimeout);
        if (res.statusCode == 200) {
          final ip = parseDohAnswer(body);
          if (ip != null) return ip;
        }
      } finally {
        client.close(force: true);
      }
    } on Object {
      // 本家 DoH 不通 → 试下一家；全挂 → null
    }
  }
  return null;
}

const _kDohEndpoints = <String>[
  'https://doh.pub/dns-query',
  'https://dns.alidns.com/resolve',
  'https://cloudflare-dns.com/dns-query', // 第三顺位：海外用户兜底（大陆被墙，仅前两家全挂时尝试）
];
const _kDohTimeout = Duration(seconds: 4);

/// 解析 doh.pub / alidns 的 JSON 应答：
/// `{"Status":0,"Answer":[{"name":..,"type":1,"TTL":300,"data":"1.2.3.4"},..]}`
///
/// 只认 type=1（A 记录，跳过 CNAME=5 / AAAA=28——服务器只有 A 记录），
/// 且 data 必须是合法 IPv4；其余一律视为解析失败 → null。
String? parseDohAnswer(String body) {
  try {
    final json = jsonDecode(body);
    if (json is! Map<String, dynamic>) return null;
    if (json['Status'] != 0) return null;
    final answers = json['Answer'];
    if (answers is! List) return null;
    for (final answer in answers) {
      if (answer is! Map<String, dynamic>) continue;
      if (answer['type'] != 1) continue;
      final data = answer['data'];
      if (data is! String) continue;
      final addr = InternetAddress.tryParse(data);
      if (addr != null && addr.type == InternetAddressType.IPv4) return data;
    }
    return null;
  } on FormatException {
    return null;
  }
}

/// 带 IP 钉扎的 HttpClient 工厂（App / CLI / WS 共用）。
///
/// - host 无钉扎（健康网络的常态）：完全等价于默认直连路径，零额外开销；
/// - host 有钉扎：TCP 连到钉扎 IP，https 时用**真实域名**做 TLS 握手
///   （SNI + 证书校验，绝不传 onBadCertificate）——假 IP 拿不出本域名的
///   合法证书，必然握手失败；
/// - 钉扎连接失败（TCP 或 TLS 阶段）→ 清除钉扎后原样上抛，让下一轮探测
///   重新 DoH（陈旧 pin 自愈：服务器搬迁后旧 IP 不再阻断）。
HttpClient createPinnedHttpClient({Duration? connectionTimeout}) {
  final client = HttpClient();
  if (connectionTimeout != null) client.connectionTimeout = connectionTimeout;
  client.connectionFactory = (Uri uri, String? proxyHost, int? proxyPort) async {
    // ws/wss 不是 Dart 认识默认端口的 scheme：Uri.port 会返回 **0**，
    // isScheme('https') 对 wss 也是 false（2026-10-11 红灯排查实测：
    // WsClient 经 pinned client 连 wss 时 "port = 0" errno 49）。这里把
    // 端口与 TLS 判定一并归一化，四个 scheme 全覆盖。
    final port = uri.port != 0
        ? uri.port
        : ((uri.isScheme('https') || uri.isScheme('wss')) ? 443 : 80);
    final isTls = uri.isScheme('https') || uri.isScheme('wss');
    final pinnedIp = pinnedServerIps[uri.host];
    if (proxyHost != null || pinnedIp == null) {
      // 未钉扎（或出现代理——本工程不配置）：复刻 SDK 直连默认路径。
      return isTls
          ? SecureSocket.startConnect(uri.host, port)
          : Socket.startConnect(uri.host, port);
    }
    final task = await Socket.startConnect(
        InternetAddress(pinnedIp, type: InternetAddressType.IPv4), port);
    final Future<Socket> socket = () async {
      try {
        final raw = await task.socket;
        if (!isTls) return raw;
        return await SecureSocket.secure(raw, host: uri.host);
      } on Object {
        // 钉扎 IP 连不上 / 证书对不上 → 清钉扎自愈，原始异常照常上抛
        clearServerPin(uri.host);
        rethrow;
      }
    }();
    return Future<ConnectionTask<Socket>>.value(
        ConnectionTask.fromSocket(socket, task.cancel));
  };
  return client;
}

/// 每主机 DoH 速率闸：60s 内最多尝试一次（setup 页 4s 重探循环不该打 DoH）。
final Map<String, DateTime> _dohTriedAt = <String, DateTime>{};

/// "直连失败 → DoH → 钉扎重试一次"公共包装（App probeServer 与 CLI
/// _probeServer 共用）。
///
/// - 健康网络：第一次 [attempt] 即 [ok] → 直接返回，零 DoH 流量；
/// - 被污染网络：DoH 拿到真 IP 后钉扎重试；**仍失败也保留钉扎**
///   （真实 A 记录好过被污染的系统 DNS）；
/// - DoH 也失败（如飞行模式）：返回原始失败结果，行为与无兜底一致。
Future<T> probeWithDohFallback<T>(
  String server,
  Future<T> Function() attempt, {
  required bool Function(T result) ok,
  DoHResolver? dohResolver,
}) async {
  final first = await attempt();
  if (ok(first)) return first;
  final host = Uri.parse(server).host;
  // IP 字面量 / localhost 无需（也无法）DoH
  if (host.isEmpty ||
      host == 'localhost' ||
      InternetAddress.tryParse(host) != null) {
    return first;
  }
  if (pinnedServerIps.containsKey(host)) return first; // 已钉扎还失败 → 等连接层自愈
  final last = _dohTriedAt[host];
  if (last != null && DateTime.now().difference(last) < const Duration(seconds: 60)) {
    return first;
  }
  _dohTriedAt[host] = DateTime.now();
  final ip = await (dohResolver ?? dohResolveHost)(host);
  if (ip == null) return first;
  setServerPin(host, ip);
  // 系统解析此刻返回的就是被注入的假 IP（DoH 刚证明它与真 IP 分歧）——现场
  // 再解析一次拿它，纯展示用（让用户看清"假的是什么、真的是什么"）；查不到
  // /超时 = null（假 IP 未知，展示层降级）。2s 超时：这是失败重试路径，
  // 不值得为它多等。
  final poisonedIp = await _systemResolveForDisplay(host);
  _onPoisonDetected(server, host, ip, poisonedIp);
  return attempt();
}

/// 系统解析（明文 DNS）当场查一次，取第一个地址——污染场景下它就是注入的假 IP。
Future<String?> _systemResolveForDisplay(String host) async {
  try {
    final addrs =
        await InternetAddress.lookup(host).timeout(const Duration(seconds: 2));
    return addrs.isNotEmpty ? addrs.first.address : null;
  } on Object {
    return null;
  }
}

/// 污染事件落地：① 可见警报钩子（带假 IP）；② 向被污染入口的服务端
/// fire-and-forget 上报一条（走刚建立的钉扎连接，此时它是唯一保证可达的路径）。
/// 失败静默——上报是尽力而为的遥测，绝不能反过来影响连接主流程。
/// 上报载荷维持 {domain, doh_ip} 不变（服务端表结构就这两列；假 IP 是展示向的，
/// 要入库需先做迁移，另开任务）。
void _onPoisonDetected(
    String server, String host, String ip, String? poisonedIp) {
  try {
    onDnsPoisonDetected?.call(host, ip, poisonedIp);
  } on Object {
    // 钩子是纯观测，异常不追责
  }
  unawaited(_reportPoison(server, host, ip));
}

Future<void> _reportPoison(String server, String host, String ip) async {
  HttpClient? client;
  try {
    client = createPinnedHttpClient(connectionTimeout: const Duration(seconds: 5));
    final req = await client
        .postUrl(Uri.parse('$server/network/dns-report'))
        .timeout(const Duration(seconds: 5));
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    req.headers.set('X-Protocol-Version', kProtocolVersion);
    req.write(jsonEncode(<String, String>{'domain': host, 'doh_ip': ip}));
    final res = await req.close().timeout(const Duration(seconds: 5));
    await res.drain<void>().timeout(const Duration(seconds: 5));
  } on Object {
    // 尽力而为：服务端还没升级（404）/网络仍不通/超时——都不追
  } finally {
    client?.close(force: true);
  }
}
