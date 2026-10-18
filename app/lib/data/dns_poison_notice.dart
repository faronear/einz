/// DNS 污染事件通知（2026-10-13，老板需求）：DoH 兜底成功 = 当前网络在对服务器
/// 域名做抢答注入。About 页「连接状态」下方展示这一条，让用户知道「连接是被
/// 自动修复的，不是本来就好」。
///
/// **只存该给用户看的**：被注入的域名 + 假 IP。**真 IP 不落这里**（老板
/// 2026-10-13：要保护）——shared 的钉扎表自己管，展示层只说"已自动修复"。
///
/// 会话级内存、不落盘（与 shared 的 IP 钉扎表同一纪律，见
/// `shared/lib/src/protocol/dns_fallback.dart`）：重启后重新探测，若网络已
/// 恢复则不显示。上报在 shared 内已 fire-and-forget，这里只做展示数据。
library;

import 'package:flutter/foundation.dart';

/// 最近一次 DNS 污染事件（DoH 解析与系统解析分歧并成功修复）。
class DnsPoisonNotice {
  const DnsPoisonNotice({
    required this.host,
    required this.poisonedIp,
    required this.at,
  });

  /// 被注入的域名（服务器入口域名）。
  final String host;

  /// 系统解析被注入成的**假 IP**（现场再解析一次捕获；查不到 = null，展示层
  /// 降级为"未知"）。真 IP 刻意不存——见库注释。
  final String? poisonedIp;

  /// 事件时刻（排查用）。
  final DateTime at;
}

/// 进程级单槽：最近一次污染事件，null = 本次会话没遇到。
/// [main] 里给 shared 的 `onDnsPoisonDetected` 钩子赋值时写入；About 页用
/// [ValueListenableBuilder] 订阅——弹层开着的时候才触发也能即时显示。
final ValueNotifier<DnsPoisonNotice?> dnsPoisonNotice =
    ValueNotifier<DnsPoisonNotice?>(null);
