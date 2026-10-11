/// DNS 污染兜底（2026-10-11）：部分网络（家庭路由器 / 运营商网关）会对明文
/// UDP-53 查询做**抢答注入**——伪造应答（假 IP + TTL 3600）抢先于真实应答到达，
/// 导致系统解析被污染约 1 小时，客户端连不上服务器。
///
/// 兜底策略：连接探测失败 → 用加密 DoH（doh.pub → dns.alidns.com，响应经
/// TLS 校验、无法被注入）重新解析 → 把真 IP **钉扎**（pin）进进程级表 →
/// 后续所有连接经 [createPinnedHttpClient] 的 `connectionFactory` 直连该 IP。
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

/// 进程级 IP 钉扎表（host → IPv4）。唯一来源：TLS 校验过的 DoH 响应。
final Map<String, String> pinnedServerIps = <String, String>{};

void setServerPin(String host, String ip) => pinnedServerIps[host] = ip;
void clearServerPin(String host) => pinnedServerIps.remove(host);

/// 清空全部兜底状态（pin 表 + DoH 速率闸）。仅供测试隔离用。
void resetDohFallbackState() {
  pinnedServerIps.clear();
  _dohTriedAt.clear();
}

/// DoH 解析函数类型（测试可注入 fake）。
typedef DoHResolver = Future<String?> Function(String host);

/// DoH 解析：doh.pub 优先、alidns 兜底；各 4s 超时；只取 A 记录。
/// 两个都失败 → null（调用方保留原始连接错误，行为与无兜底一致）。
///
/// 解析 doh.pub / dns.alidns.com 本身仍走系统 DNS——这两个是头部大域，
/// 实际上不会被抢答；且其应答经 HTTPS 证书校验，注入无法伪造。
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
    final pinnedIp = pinnedServerIps[uri.host];
    if (proxyHost != null || pinnedIp == null) {
      // 未钉扎（或出现代理——本工程不配置）：复刻 SDK 直连默认路径。
      return uri.isScheme('https')
          ? SecureSocket.startConnect(uri.host, uri.port)
          : Socket.startConnect(uri.host, uri.port);
    }
    final task = await Socket.startConnect(
        InternetAddress(pinnedIp, type: InternetAddressType.IPv4), uri.port);
    final Future<Socket> socket = () async {
      try {
        final raw = await task.socket;
        if (!uri.isScheme('https')) return raw;
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
  return attempt();
}
