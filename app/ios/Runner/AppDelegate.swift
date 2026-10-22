import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var apnsToken: String?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // APNs：权限请求 + 远程通知注册都不在启动时做——新版 iOS 模拟器上
    // registerForRemoteNotifications 也会触发系统权限弹窗（2026-10-20 实测），
    // 「冷启动/演示秘境都弹」会骚扰用户和审核员（演示全离线，根本不用推送）。
    // 全部挪到 Dart 侧进入真实空间时经 einz/apns 频道 registerAndToken 触发。
    // 推送只发"有新消息"提示，绝不携带正文（productLens §10）。
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // MethodChannel：Dart 侧取 APNs device token，认证后调用 Server /push/register。
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "Einz") {
      let channel = FlutterMethodChannel(name: "einz/apns", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { [weak self] call, result in
        switch call.method {
        case "getToken":
          result(self?.apnsToken ?? "")
        case "registerAndToken":
          // Dart 侧进入真实空间时调用；演示秘境不走这里（永不弹窗）。
          // 权限已决策过时系统静默返回；注册后等 didRegister 回调落 token（最多 3s）。
          UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]) { _, _ in
              UIApplication.shared.registerForRemoteNotifications()
              DispatchQueue.global().async {
                let deadline = Date().addingTimeInterval(3)
                while (self?.apnsToken ?? "").isEmpty && Date() < deadline {
                  Thread.sleep(forTimeInterval: 0.1)
                }
                let token = self?.apnsToken ?? ""
                DispatchQueue.main.async { result(token) }
              }
            }
        default:
          result(FlutterMethodNotImplemented)
        }
      }

      // MethodChannel：Dart 侧取「附件明文长期存放目录」（stored 模式）。
      // 目录在 Application Support 下，并标记 isExcludedFromBackup ——
      // 明文绝不能进 iCloud/iTunes 备份（换机还原就能读到旧附件）。
      let store = FlutterMethodChannel(name: "einz/store", binaryMessenger: registrar.messenger())
      store.setMethodCallHandler { call, result in
        if call.method == "getStoredDir" {
          let base = NSSearchPathForDirectoriesInDomains(
            .applicationSupportDirectory, .userDomainMask, true).first ?? ""
          let dir = (base as NSString).appendingPathComponent("einz_media")
          try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
          var url = URL(fileURLWithPath: dir)
          var values = URLResourceValues()
          values.isExcludedFromBackup = true
          try? url.setResourceValues(values)
          result(dir)
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    apnsToken = deviceToken.map { String(format: "%02x", $0) }.joined()
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    apnsToken = nil
  }
}
