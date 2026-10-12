// logoslogan.png 的生成脚本（对标参照站 images/theme/logoslogan.psd 的"源文件"角色）。
//
// 用法（macOS，自带 Swift + AppKit，无需第三方依赖）：
//   swift www/images/theme/logoslogan.swift
// 重新生成 www/images/theme/logoslogan.png（600×150 逻辑画布，2x 光栅化出
// 1200×300）。素材读 ../../../app/assets/logo.png，路径相对本脚本解析，
// 换机器/换目录都能跑。
//
// 注意：画 logo 的圆角裁剪必须包在 save/restoreGraphicsState 里——
// addClip 的裁剪区持续生效，不还原会把右侧文字全部裁掉（实测踩坑）。

import AppKit

let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let logoPath = scriptDir.appendingPathComponent("../../../app/assets/logo.png").path
let outPath = scriptDir.appendingPathComponent("logoslogan.png").path

// 画布 600×150（参照站 300×75 的 2x，横版文字标志）
let img = NSImage(size: NSSize(width: 600, height: 150))
img.lockFocusFlipped(true) // 左上角原点，y 向下——logo 与文字同一坐标系
NSGraphicsContext.current?.imageInterpolation = .high

// ── 左：app 图标（圆角，与 BrandLogo 的 ClipRRect 同观感）──────────────
let logo = NSImage(contentsOfFile: logoPath)!
let logoRect = NSRect(x: 12, y: 12, width: 126, height: 126)
NSGraphicsContext.saveGraphicsState()
NSBezierPath(roundedRect: logoRect, xRadius: 22, yRadius: 22).addClip()
logo.draw(in: logoRect)
NSGraphicsContext.restoreGraphicsState()

let dark = NSColor(red: 0.11, green: 0.11, blue: 0.13, alpha: 1)
let blue = NSColor(red: 0x22 / 255, green: 0x71 / 255, blue: 0xF7 / 255, alpha: 1) // 品牌蓝（同链接色）
let gray = NSColor(red: 0.42, green: 0.42, blue: 0.46, alpha: 1)

func font(_ name: String, _ size: CGFloat) -> NSFont {
  NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size)
}

// ── 第一行：秘境（深）+ Einz（品牌蓝），垂直与左侧 logo 对中 ──────────
let line1 = NSMutableAttributedString(string: "秘境", attributes: [
  .font: font("PingFangSC-Semibold", 50),
  .foregroundColor: dark,
])
line1.append(NSAttributedString(string: " Einz", attributes: [
  .font: font("PingFangSC-Semibold", 50),
  .foregroundColor: blue,
]))
let l1 = line1.size()
let line1Top: CGFloat = 24
line1.draw(in: NSRect(x: 160, y: line1Top, width: l1.width + 6, height: l1.height + 6))

// ── 第二行：标语（灰小字）────────────────────────────────────────────
let line2 = NSAttributedString(string: "端到端加密的二人私密空间", attributes: [
  .font: font("PingFangSC-Regular", 20),
  .foregroundColor: gray,
])
let l2 = line2.size()
line2.draw(
  in: NSRect(x: 162, y: line1Top + l1.height + 8, width: l2.width + 6, height: l2.height + 6))

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
  let rep = NSBitmapImageRep(data: tiff),
  let png = rep.representation(using: .png, properties: [:])
else {
  fatalError("PNG 导出失败")
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("written: \(outPath) (\(png.count) bytes)")
