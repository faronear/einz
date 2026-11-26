import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:screen_capturer_platform_interface/screen_capturer_platform_interface.dart';
import 'package:win32/win32.dart';

final Map<CaptureMode, String> _knownCaptureModeArgs = {
  CaptureMode.region: 'Rectangle',
  CaptureMode.screen: '',
  CaptureMode.window: 'Window',
};

bool _isScreenClipping() {
  // win32 6 兼容补丁（einz）：GetForegroundWindow 返回 HWND（不再是 int），
  // OpenProcess 的 dwDesiredAccess 之下的 BOOL 参数改传 bool。
  final hWnd = GetForegroundWindow();
  final lpdwProcessId = calloc<Uint32>();

  GetWindowThreadProcessId(hWnd, lpdwProcessId);
  // Get a handle to the process.
  // win32 6 兼容补丁（einz）：OpenProcess 返回 Win32Result<HANDLE>，需解包。
  final hProcess = OpenProcess(
    // win32 6 兼容补丁（einz）：PROCESS_* 常量改为顶层（PROCESS_ACCESS_RIGHTS(n)）
    PROCESS_QUERY_INFORMATION | PROCESS_VM_READ,
    false,
    lpdwProcessId.value,
  ).value;

  if (hProcess == null) {
    return false;
  }

  // Get a list of all the modules in this process.
  // win32 6 兼容补丁（einz）：HMODULE 不再是 NativeType 子类（calloc<HMODULE>
  // 编译不过），EnumProcessModules/GetModuleFileNameEx 改为返回
  // Win32Result<bool/int>。改用 Pointer 数组 + fromAddress 重建句柄。
  final hModules = calloc<Pointer>(1024);
  final cbNeeded = calloc<Uint32>();

  try {
    final r = EnumProcessModules(
      hProcess,
      hModules,
      sizeOf<Pointer>() * 1024,
      cbNeeded,
    );

    if (r.value) {
      for (var i = 0; i < (cbNeeded.value ~/ sizeOf<Pointer>()); i++) {
        final szModName = wsalloc(MAX_PATH);
        // Get the full path to the module's file.
        final hModule = HMODULE(hModules[i]);
        if (GetModuleFileNameEx(hProcess, hModule, szModName, MAX_PATH).value !=
            0) {
          String moduleName = szModName.toDartString();
          if (moduleName.contains('ScreenClippingHost.exe') ||
              moduleName.contains('SnippingTool.exe')) {
            free(szModName);
            return true;
          }
        }
        free(szModName);
      }
    }
  } finally {
    free(hModules);
    free(cbNeeded);
    CloseHandle(hProcess);
  }

  return false;
}

class _MsScreenclip with SystemScreenCapturer {
  @override
  Future<void> capture({
    required CaptureMode mode,
    String? imagePath,
    bool copyToClipboard = true,
    bool silent = true,
  }) async {
    String url = 'ms-screenclip://?';
    if (mode == CaptureMode.screen) {
      url += 'type=snapshot';
    } else {
      url += 'clippingMode=${_knownCaptureModeArgs[mode]}';
    }
    await Clipboard.setData(const ClipboardData(text: ''));
    // win32 6 兼容补丁（einz 2026-11-26）：win32 6 把 HWND/PCWSTR 改成
    // extension type、SW_SHOWNORMAL 改成顶层常量（SHOW_WINDOW_CMD(1)），
    // 0.2.2 原始写法在其上编译不过。
    ShellExecute(
      HWND(nullptr),
      PCWSTR('open'.toNativeUtf16()),
      PCWSTR(url.toNativeUtf16()),
      PCWSTR(nullptr),
      PCWSTR(nullptr),
      SW_SHOWNORMAL,
    );
    await Future.delayed(const Duration(seconds: 1));

    while (_isScreenClipping()) {
      await Future.delayed(const Duration(milliseconds: 200));
    }

    if (imagePath != null) {
      await ScreenCapturerPlatform.instance.saveClipboardImageAsPngFile(
        imagePath: imagePath,
      );
    }
  }
}

final msScreenclip = _MsScreenclip();
