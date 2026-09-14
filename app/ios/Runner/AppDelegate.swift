import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var apnsToken: String?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // APNs：申请通知权限 + 注册远程通知，获取 device token。
    // 推送只发"有新消息"提示，绝不携带正文（productLens §10）。
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    application.registerForRemoteNotifications()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // MethodChannel：Dart 侧取 APNs device token，认证后调用 Server /push/register。
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "Einz") {
      let channel = FlutterMethodChannel(name: "einz/apns", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { [weak self] call, result in
        if call.method == "getToken" {
          result(self?.apnsToken ?? "")
        } else {
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
