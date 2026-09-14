# Einz 本地 podspec：把 libsodium 静态库（xcframework）链接进 iOS 工程。
# 方案来源：sodium_libs 2.2.1+6 的 iOS 集成（vendored_frameworks + force_load），
# 取其二进制绕开其 Gradle 插件（与 Android jniLibs 方案同理）。
#
# 静态链接后运行时无需 dlopen：shared 的 loadDynamicLibrary iOS 分支
# 会先尝试 DynamicLibrary.process() 解析静态链接符号。
Pod::Spec.new do |s|
  s.name             = 'libsodium'
  s.version          = '1.0.20'
  s.summary          = 'libsodium (Einz vendored static library)'
  s.homepage         = 'https://download.libsodium.org'
  s.license          = { :type => 'ISC' }
  s.author           = { 'libsodium' => 'https://github.com/jedisct1/libsodium' }
  s.source           = { :path => '.' }
  s.platform         = :ios, '12.0'

  s.vendored_frameworks = 'libsodium.xcframework'
  # 注意：必须用 user_target_xcconfig（作用于 Runner 链接步骤），
  # pod_target_xcconfig 只作用于 pod 自身 target，-force_load 不会进 Runner 链接。
  # 本地 pod 路径：Runner 的 PODS_ROOT=${SRCROOT}/Pods，本 pod 在 ${PODS_ROOT}/../Libraries。
  #
  # 链接期要点（2026-09-14 真机实测，逐条有证据）：
  # - `-force_load <静态库>`：把该静态库**整个**链进来。否则链接器只按需取用，
  #   而我们的 native 代码根本不引用任何 sodium_* 符号（见下条）→ 一个都不会进。
  # - `-Wl,-export_dynamic`：ld 文档「保留主可执行文件里的全局符号」。
  #   libsodium 的符号**只**由 Dart 在运行时经 `DynamicLibrary.process()`（dlsym）查找，
  #   链接期没有可见引用，需要它们留在导出表里。
  # - **还需要关掉 install-strip**（见 Runner.xcodeproj 的 `STRIP_INSTALLED_PRODUCT = NO`）：
  #   archive/install 阶段的 strip 会把主可执行文件的导出表清空（实测：同一次构建
  #   不 strip 时导出 652 个符号、含 sodium 包需要的全部 647 个；archive 产物只剩 1 个
  #   `__mh_execute_header`）→ 真机 release 抛
  #   `Invalid argument(s): Failed to look up symbol 'sodium_init'`。
  #   三者缺一都会复现该 bug；模拟器（Debug，不走 install-strip）因此测不出来。
  s.user_target_xcconfig = {
    'OTHER_LDFLAGS[sdk=iphoneos*]' => '$(inherited) -force_load "${PODS_ROOT}/../Libraries/libsodium.xcframework/ios-arm64/libsodium.a" -Wl,-export_dynamic',
    'OTHER_LDFLAGS[sdk=iphonesimulator*]' => '$(inherited) -force_load "${PODS_ROOT}/../Libraries/libsodium.xcframework/ios-arm64_x86_64-simulator/libsodium.a" -Wl,-export_dynamic',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
  }
end
