# OnlySpace 本地 podspec：把 libsodium 静态库（xcframework）链接进 iOS 工程。
# 方案来源：sodium_libs 2.2.1+6 的 iOS 集成（vendored_frameworks + force_load），
# 取其二进制绕开其 Gradle 插件（与 Android jniLibs 方案同理）。
#
# 静态链接后运行时无需 dlopen：shared 的 loadDynamicLibrary iOS 分支
# 会先尝试 DynamicLibrary.process() 解析静态链接符号。
Pod::Spec.new do |s|
  s.name             = 'libsodium'
  s.version          = '1.0.20'
  s.summary          = 'libsodium (OnlySpace vendored static library)'
  s.homepage         = 'https://download.libsodium.org'
  s.license          = { :type => 'ISC' }
  s.author           = { 'libsodium' => 'https://github.com/jedisct1/libsodium' }
  s.source           = { :path => '.' }
  s.platform         = :ios, '12.0'

  s.vendored_frameworks = 'libsodium.xcframework'
  s.pod_target_xcconfig = {
    'OTHER_LDFLAGS[sdk=iphoneos*]' => '$(inherited) -force_load "$(PODS_ROOT)/libsodium/libsodium.xcframework/ios-arm64/libsodium.a"',
    'OTHER_LDFLAGS[sdk=iphonesimulator*]' => '$(inherited) -force_load "$(PODS_ROOT)/libsodium/libsodium.xcframework/ios-arm64_x86_64-simulator/libsodium.a"',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
  }
end
