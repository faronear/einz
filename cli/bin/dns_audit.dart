// DNS 巡检（2026-10-11）：对全部入口域名做"系统解析 vs DoH 加密解析"双通道比对。
//
// 背景：部分网络对明文 UDP-53 做抢答注入（假 IP + TTL 3600），系统解析被污染而
// DoH 仍返回真 IP——分歧即污染。老板"早于用户发现被劫持"的自查工具：
//   npm run dns-audit          （= cd cli && dart run bin/dns_audit.dart）
// 也可在任意一台想当探针的机器上跑。有任何分歧或 DoH 失败 → 退出码 1（可接 cron）。
//
// 判定语义：
// - 一致 → ✅ 该域名解析干净；
// - 分歧 → ⚠️ 系统解析被污染（列出两侧 IP）；
// - DoH 失败 → ❓ 无法判定（DoH 服务不可达 / 网络断），不计为污染但计入告警。
// 注意：DoH 域名解析结果会带 TTL 缓存——刚清过缓存的分歧可能已自愈，重跑确认。
import 'dart:io';

import 'package:einz_shared/einz_shared.dart';

/// 与 App/TUI 候选列表同源（server_config.dart / einz_tui.dart）；巡检覆盖全部入口。
const _domains = <String>[
  'einz.tic.cc',
  'einz.yuanjinx.com',
  'einz.farinear.cn',
  'einz.bittic.cn',
];

Future<void> main() async {
  stdout.writeln('DNS 巡检：系统解析 vs DoH（doh.pub → dns.alidns.com）');
  stdout.writeln('时间：${DateTime.now().toUtc().toIso8601String()}');
  stdout.writeln('-' * 72);

  var poisoned = 0;
  var undetermined = 0;

  for (final domain in _domains) {
    // 系统解析（走 mDNSResponder——与 App 实际所见同一路径）
    var systemIps = <String>{};
    var systemFailed = false;
    try {
      final addrs = await InternetAddress.lookup(domain, type: InternetAddressType.IPv4)
          .timeout(const Duration(seconds: 5));
      systemIps = addrs.map((a) => a.address).toSet();
    } on Object {
      systemFailed = true;
    }

    // DoH 加密解析（可信基准）
    final dohIp = await dohResolveHost(domain);

    final String verdict;
    if (dohIp == null) {
      undetermined++;
      verdict = '❓ DoH 解析失败（无法判定；若系统也失败则网络不通）';
    } else if (systemIps.contains(dohIp)) {
      verdict = '✅ 一致（$dohIp）';
    } else if (systemFailed) {
      undetermined++;
      verdict = '❓ 系统解析失败（DoH=$dohIp）——网络不通或解析被拒';
    } else {
      poisoned++;
      verdict = '⚠️ 分歧！系统=${systemIps.join(',')} DoH=$dohIp —— 系统解析被污染';
    }
    stdout.writeln('$domain\n    $verdict');
  }

  stdout.writeln('-' * 72);
  if (poisoned > 0) {
    stdout.writeln('结论：$poisoned 个域名被污染。客户端会自动 DoH 兜底自愈；'
        '建议记录时间与网络环境（worklog），并到服务器看 GET /network/dns-report 聚合。');
    exitCode = 1;
  } else if (undetermined > 0) {
    stdout.writeln('结论：$undetermined 个域名无法判定（见上），其余干净。');
    exitCode = 1; // 无法判定也报非零：巡检要的是确定性
  } else {
    stdout.writeln('结论：全部入口解析干净，无污染迹象。');
  }
}
