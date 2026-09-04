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
  s.user_target_xcconfig = {
    'OTHER_LDFLAGS[sdk=iphoneos*]' => '$(inherited) -force_load "${PODS_ROOT}/../Libraries/libsodium.xcframework/ios-arm64/libsodium.a"',
    'OTHER_LDFLAGS[sdk=iphonesimulator*]' => '$(inherited) -force_load "${PODS_ROOT}/../Libraries/libsodium.xcframework/ios-arm64_x86_64-simulator/libsodium.a"',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
  }
end
