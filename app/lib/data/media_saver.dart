import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:gal/gal.dart';

/// 保存媒体到**系统相册**的能力封装（老板 2026-10-08：手机端图片/视频默认存相册，
/// 而不是落到 App 自己的文件系统里）。
///
/// 只有移动端有"相册"这个概念；桌面端（macOS/Windows/Linux）没有，调用方在桌面
/// 走系统保存对话框（`FilePicker.saveFile`），不要用这里。
bool get canSaveToGallery => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

/// 保存**图片字节**到系统相册。[name] 为文件名（可带扩展名，内部会去掉——gal 的
/// `name` 不含扩展名，格式由字节自行判定）。
///
/// 失败时抛异常（权限被拒 / 存储不足 / 原生错误），由调用方统一按"保存失败"提示。
Future<void> saveImageToGallery(Uint8List bytes, {String? name}) async {
  await _ensureGalleryAccess();
  await Gal.putImageBytes(bytes, name: _baseName(name));
}

/// 保存**视频文件**到系统相册。[path] 必须是**含扩展名**的本地文件路径。
Future<void> saveVideoToGallery(String path) async {
  await _ensureGalleryAccess();
  await Gal.putVideo(path);
}

/// 首次调用时申请相册写入权限；被拒抛 [StateError]。
Future<void> _ensureGalleryAccess() async {
  if (await Gal.hasAccess()) return;
  if (await Gal.requestAccess()) return;
  throw StateError('未获得相册访问权限');
}

/// gal 的文件名参数不含扩展名（扩展名它按字节判定），这里统一剥掉。
String _baseName(String? name) {
  final n = (name ?? '').trim();
  if (n.isEmpty) return 'image';
  final dot = n.lastIndexOf('.');
  return dot > 0 ? n.substring(0, dot) : n;
}
