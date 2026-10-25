import AVFoundation
import Cocoa
import CoreAudio
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

    // 录音前麦克风格式预锁（2026-10-25 老板 iMac 实测修复，详见下方函数注释）。
    // Dart 侧每次开录前调一次；锁一次即持久（直到重启/设备重插）。
    let audioInputChannel = FlutterMethodChannel(
      name: "einz.audio.input",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    audioInputChannel.setMethodCallHandler { call, result in
      if call.method == "ensureIntegerFormat" {
        let args = call.arguments as? [String: Any]
        lockInputDeviceToIntegerPcm(
          sampleRate: args?["sampleRate"] as? Double ?? 16000,
          channels: args?["channels"] as? Int ?? 1)
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }
}

/// 把默认音频输入设备锁定到整数 PCM 格式（优先 16-bit，采样率取最接近 [sampleRate] 的）。
///
/// 为什么必须锁（老板 2026-10-25 两机对照实测定位）：macOS 的
/// AVCaptureAudioFileOutput 写 WAV 时，输入设备若运行在 Float32，其文件写入链
/// 无法完成 Float32→Int16 转换——沙盒内表现为 `AudioFileCreateWithURL failed
/// (fmt?)`（kAudioFileUnsupportedDataFormatError），非沙盒直接 -11805
/// "The combination of audio file type and audio format in audioSettings is not
/// supported"。结果是 0 字节录音、振幅流全静音：UI 上「不出现波形图」+ 松手
/// 弹「录音内容为空」。iMac（iMac19,1）重启后内置麦克风 HAL 默认 Float32，
/// 必坏；MacBook Air 的内置麦克风默认即整数 PCM，故同版本 debug 包在 Air 上
/// 一直能录。锁定后录制全链路正常（16kHz 单声道 WAV 亦正常，文件写入链自带
/// 重采样）。m4a/AAC 录音不受影响（AAC 编码路径吃得下 Float32）。
///
/// 失败（设备被独占、设备无任何整数格式）时静默返回，录音路径保持原行为。
private func lockInputDeviceToIntegerPcm(sampleRate: Double, channels: Int) {
  guard let device = AVCaptureDevice.default(for: .audio) else { return }

  // 当前已是整数 PCM 就不动：lock/unlock 会短暂打断其他采集客户端
  // （Teams 等）的设备格式。
  if let desc = CMAudioFormatDescriptionGetStreamBasicDescription(
      device.activeFormat.formatDescription)?.pointee,
     desc.mFormatID == kAudioFormatLinearPCM,
     desc.mFormatFlags & kLinearPCMFormatFlagIsFloat == 0 {
    return
  }

  // 候选格式：整数 PCM；代价 = 采样率距离（主）> 16-bit 偏好 > 声道数距离。
  var best: AVCaptureDevice.Format?
  var bestCost = Int.max
  for format in device.formats {
    guard let desc = CMAudioFormatDescriptionGetStreamBasicDescription(format.formatDescription)?.pointee,
          desc.mFormatID == kAudioFormatLinearPCM,
          desc.mFormatFlags & kLinearPCMFormatFlagIsFloat == 0,
          desc.mBitsPerChannel > 0, desc.mBitsPerChannel <= 32 else { continue }
    let cost = Int(abs(desc.mSampleRate - sampleRate)) * 10
      + (desc.mBitsPerChannel == 16 ? 0 : 8)
      + abs(Int(desc.mChannelsPerFrame) - channels)
    if cost < bestCost {
      bestCost = cost
      best = format
    }
  }
  guard let target = best else { return }
  do {
    try device.lockForConfiguration()
    device.activeFormat = target
    device.unlockForConfiguration()
  } catch {
    // 设备被独占等：保持原样
  }
}
