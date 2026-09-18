# Einz 本地 podspec：把 libsodium 静态库（macOS 双架构 fat library）链接进 macOS 工程。
# 与 iOS 侧 Libraries/libsodium.podspec 同方案：静态链接 + force_load + export_dynamic，
# 运行时 shared 的 loadDynamicLibrary 走 DynamicLibrary.process() 解析符号，
# 不依赖用户机器上的 Homebrew（App Sandbox 也读不到 /usr/local/lib）。
#
# 静态库来源：libsodium 1.0.20 官方源码 configure/make 构建（arm64 + x86_64 fat），
# 与 iOS xcframework 内的版本一致。
Pod::Spec.new do |s|
  s.name             = 'libsodium-macos'
  s.version          = '1.0.20'
  s.summary          = 'libsodium (Einz vendored static library, macOS)'
  s.homepage         = 'https://download.libsodium.org'
  s.license          = { :type => 'ISC' }
  s.author           = { 'libsodium' => 'https://github.com/jedisct1/libsodium' }
  s.source           = { :path => '.' }

  s.platform         = :osx, '13.0'
  s.vendored_libraries = 'libsodium-macos.a'

  # 必须用 user_target_xcconfig（作用于 Runner 链接步骤），原因同 iOS podspec 注释：
  # - force_load：native 代码不引用 sodium_* 符号，按需链接一个都不会进
  # - export_dynamic：符号只由 Dart 运行时 dlsym 查找，需留在导出表
  # - STRIP_INSTALLED_PRODUCT = NO 见 Runner.xcodeproj（strip 会清空导出表）
  s.user_target_xcconfig = {
    'OTHER_LDFLAGS' => '$(inherited) -force_load "${PODS_ROOT}/../Libraries/libsodium-macos.a" -Wl,-export_dynamic',
  }
end
