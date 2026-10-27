# 2026-10-25 macOS 音频采集复刻工具（capture repro）

排查「macOS 录音空白」时搭的原生复刻骨架，**下次遇到 AVCaptureAudioFileOutput /
麦克风采集类问题直接改用**，不必从零写。结论见 20261009_voiceTranscript.zhcn.md §8
「macOS 设备格式的坑」与 worklog 20261025T074652.219000Z.json。

## 工具一：AVCaptureAudioFileOutput 抓取复刻（swiftc 直接编）

```swift
// capture_repro.swift：复刻 record_macos 插件同参数抓取；用法 ./repro [秒] [设备名子串] [模式]
import Foundation
import AVFoundation
import CoreAudio

final class Recorder: NSObject, AVCaptureFileOutputRecordingDelegate {
  let sem = DispatchSemaphore(value: 0)
  var err: Error?
  func fileOutput(_ o: AVCaptureFileOutput, didFinishRecordingTo u: URL, from c: [AVCaptureConnection], error: Error?) { err = error; sem.signal() }
}

let args = CommandLine.arguments
let seconds = Double(args.count > 1 ? args[1] : "2") ?? 2
let nameFilter = args.count > 2 ? args[2] : "Built-in"
let lockInt16 = args.count > 3 ? args[3] == "lock" : false

let types: [AVCaptureDevice.DeviceType] = [.microphone, .external]
let devices = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .audio, position: .unspecified).devices
for d in devices { print("device: \(d.localizedName) id=\(d.uniqueID)") }  // 注意：发现顺序不固定，别用下标
for f in (devices.first { $0.localizedName.contains(nameFilter) })!.formats {
  let a = CMAudioFormatDescriptionGetStreamBasicDescription(f.formatDescription)!.pointee
  print("  fmt \(a.mSampleRate)Hz \(a.mChannelsPerFrame)ch \(a.mBitsPerChannel)bit flags=\(String(a.mFormatFlags, radix: 16))")
}
guard let device = devices.first(where: { $0.localizedName.contains(nameFilter) }) else { exit(1) }
if lockInt16, let f = device.formats.first(where: { f in
  let a = CMAudioFormatDescriptionGetStreamBasicDescription(f.formatDescription)!.pointee
  return a.mSampleRate == 44100 && a.mChannelsPerFrame == 2 && a.mBitsPerChannel == 16 }) {
  try device.lockForConfiguration(); device.activeFormat = f; device.unlockForConfiguration()
}
guard let input = try? AVCaptureDeviceInput(device: device) else { print("FATAL no input (TCC?)"); exit(2) }
let session = AVCaptureSession()
session.beginConfiguration(); session.addInput(input)
let output = AVCaptureAudioFileOutput(); session.addOutput(output)
output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
  AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
  AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1]   // 与 record 插件 wav 分支一致
session.commitConfiguration()
let url = URL(fileURLWithPath: NSTemporaryDirectory() + "repro.wav")
let del = Recorder()
session.startRunning()
while !session.isRunning { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }  // 必须有主 run loop！
output.startRecording(to: url, outputFileType: .wav, recordingDelegate: del)
print("isRecording=\(output.isRecording) authStatus=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
RunLoop.main.run(until: Date().addingTimeInterval(seconds))
output.stopRecording()
RunLoop.main.run(until: Date().addingTimeInterval(6))
session.stopRunning()
print("err=\(del.err.map { "\($0)" } ?? "nil") size=\((try? Data(contentsOf: url))?.count ?? -1)")
```

```
swiftc -O capture_repro.swift -o repro && ./repro 2 Built-in nolock
```

踩过的坑：
- **必须跑主 run loop**（`RunLoop.main.run(until:)`），Thread.sleep 会让 didFinishRecordingTo
  永不到达（delegate 默认主队列）。
- `startRecording` 后立刻读 `output.isRecording` 可能是 false 但录音其实成功了——以
  delegate 回调和文件大小为准。
- Float32 settings + .wav 会**抛 NSInvalidArgumentException**（"WAVE files cannot contain
  floating-point LPCM"），不是返回错误。

## 工具二：AudioFileCreateWithURL 格式矩阵（不需要麦克风权限）

直接 `AudioFileCreateWithURL(url, kAudioFileWAVEType, &asbd, .eraseFile, &id)` 遍历候选
ASBD：LPCM 16k 单声道 16bit signed|packed → OK；flags=0 / IsAlignedHigh → 1718449215
（`fmt?` = kAudioFileUnsupportedDataFormatError）。

## 工具三：沙盒 .app 复刻（验证沙盒内行为）

把工具一的二进制塞进 .app（CFBundleIdentifier 用 **cc.tic.einz**——与正式/调试 app 同
bundle ID + 同团队签名，TCC 直接认已授权，不弹窗），entitlements 只需
`com.apple.security.app-sandbox` + `com.apple.security.device.audio-input`，
`codesign -s 'Apple Distribution: Faronear Co. Ltd. (CQ6733CTMV)' --entitlements ent.plist`，
直接执行 `.app/Contents/MacOS/xxx` 即带沙盒运行。

## 统一日志（最快的现场证据）

```
log show --last 6h --predicate 'process == "einz"' --style compact | grep -E 'AVCaptureAudioFileOutput|AudioFileCreate|Fig assert|IsDeviceUsable|AUHAL.*Selecting'
```
- `IsDeviceUsable: Device ID: N (Input:No | Output:Yes)` → 当前设备有无输入。
- `AudioFileCreateWithURL failed (1718449215)` = fmt? = 数据格式不被文件类型接受。
- TCC：`log show --predicate 'eventMessage CONTAINS "kTCCServiceMicrophone"'`。
