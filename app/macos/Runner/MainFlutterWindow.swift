import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // 启动参数桥：让 Dart 侧能读到 `open -a Einz --args --server …` 传入的参数。
    // macOS embedder 不会把 --args 转发给 Dart 的 Platform.executableArguments，
    // 故这里直接读 ProcessInfo（首元素是执行文件路径，需去掉）。
    let launchChannel = FlutterMethodChannel(
      name: "einz.launch.args",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    launchChannel.setMethodCallHandler { call, result in
      if call.method == "get" {
        let args = ProcessInfo.processInfo.arguments
        result(Array(args.dropFirst()))
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }
}
