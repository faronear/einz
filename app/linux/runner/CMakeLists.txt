cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME}
  "main.cc"
  "my_application.cc"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the application ID.
add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")

# Add dependency libraries. Add any application-specific dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK)

# 曾试过静态链 libsodium（设 LIBSODIUM_STATIC_LIB 时 --whole-archive 链入），
# 2026-11-24 放弃：CI 默认构建产物带 AVX2 指令，老 CPU（如 Celeron N3150）
# 启动即 SIGILL，且 --disable-* 开关未拦住；改为依赖系统 libsodium23。
# 详见 aimemo/worklog/wl20261124T130027.201020Z.json。

target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")
