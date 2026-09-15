import 'package:flutter/services.dart';

/// 全屏查看（图片/视频/头像）期间**隐藏系统状态栏**（时间、电量、信号）——
/// 遮罩要覆盖到屏幕最顶端才有沉浸感；状态栏是系统层绘制的，App 盖不住，只能隐藏。
///
/// 平台不支持 / 测试环境（MissingPluginException）时静默降级：只是不隐藏而已，
/// 不影响查看。退出后恢复"状态栏与导航栏都显示"。
Future<void> withImmersiveFullscreen(Future<void> Function() open) async {
  Future<void> setUi(SystemUiMode mode, List<SystemUiOverlay> overlays) async {
    try {
      await SystemChrome.setEnabledSystemUIMode(mode, overlays: overlays);
    } catch (_) {
      // 平台/通道不可用：忽略
    }
  }

  await setUi(SystemUiMode.immersiveSticky, []);
  try {
    await open();
  } finally {
    await setUi(SystemUiMode.manual, SystemUiOverlay.values);
  }
}
