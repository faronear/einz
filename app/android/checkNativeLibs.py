#!/usr/bin/env python3
"""校验 vendored 的 Android 原生库（jniLibs/*/libsodium.so）。

为什么需要它：这两个问题在**本机模拟器上测不出来**（模拟器通常是 4KB 页、
且不走 release 的 strip），只有真机/特定设备才暴露，所以必须能静态验证。

1. **16KB 页对齐**：Android 15+ 的 16KB 页设备要求每个 LOAD 段 `p_align >= 0x4000`，
   4KB 对齐（0x1000）的 .so 在这些设备上 `dlopen` 直接失败——症状就是运行时
   "无法加载 libsodium / 密钥生成失败"。
2. **符号完整性**：libsodium 的符号只由 Dart 在运行时经 `DynamicLibrary.open('libsodium.so')`
   解析；若某个 .so 少了符号，会在运行时才炸。这里用 pub 缓存里的 `sodium` 包
   反查它 `lookupFunction` 用到的全部符号名，与 .so 的 dynsym 做差集。

用法：`python3 app/android/checkNativeLibs.py`（退出码非 0 = 有问题）

重建这两个库的方法（改动/升级 libsodium 时照做）：
    NDK=~/Library/Android/sdk/ndk/28.2.13676358   # r28 起默认 16KB
    curl -O https://download.libsodium.org/libsodium/releases/libsodium-1.0.20.tar.gz
    tar xzf libsodium-1.0.20.tar.gz && cd libsodium-1.0.20
    # 每个 ABI 各跑一次 configure/make，关键是 LDFLAGS 里的 max-page-size：
    #   arm64-v8a   --host=aarch64-linux-android     CC=$TC/aarch64-linux-android24-clang
    #   armeabi-v7a --host=armv7a-linux-androideabi  CC=$TC/armv7a-linux-androideabi24-clang
    #   x86_64      --host=x86_64-linux-android      CC=$TC/x86_64-linux-android24-clang
    #   x86         --host=i686-linux-android        CC=$TC/i686-linux-android24-clang
    # 公共参数：--enable-shared --disable-static --disable-soname-versions
    #   AR=$TC/llvm-ar RANLIB=$TC/llvm-ranlib LDFLAGS="-Wl,-z,max-page-size=16384"
    # 产物 src/libsodium/.libs/libsodium.so → 覆盖到 jniLibs/<abi>/，再
    #   $TC/llvm-strip --strip-unneeded（保留 dynsym）并重跑本脚本。
"""
import glob
import os
import re
import struct
import subprocess
import sys

JNI_LIBS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "app", "src", "main", "jniLibs")
# ELF e_machine → 该 ABI 应有的架构
EXPECTED_MACHINE = {"arm64-v8a": 183, "armeabi-v7a": 40, "x86_64": 62, "x86": 3}
MACHINE_NAME = {183: "aarch64", 40: "arm", 62: "x86_64", 3: "i386"}


def read_elf(path):
    """返回 (e_machine, LOAD 段 p_align 列表)；非 ELF 返回 (None, [])。"""
    data = open(path, "rb").read()
    if data[:4] != b"\x7fELF":
        return None, []
    is64, little = data[4] == 2, data[5] == 1
    end = "<" if little else ">"
    machine, = struct.unpack_from(end + "H", data, 0x12)
    if is64:
        phoff, = struct.unpack_from(end + "Q", data, 0x20)
        entsize, phnum = struct.unpack_from(end + "HH", data, 0x36)
        align_at = 0x30
    else:
        phoff, = struct.unpack_from(end + "I", data, 0x1c)
        entsize, phnum = struct.unpack_from(end + "HH", data, 0x2A)
        align_at = 0x1C
    aligns = []
    for i in range(phnum):
        off = phoff + i * entsize
        if struct.unpack_from(end + "I", data, off)[0] == 1:  # PT_LOAD
            fmt = end + ("Q" if is64 else "I")
            aligns.append(struct.unpack_from(fmt, data, off + align_at)[0])
    return machine, aligns


def needed_symbols():
    """从 pub 缓存的 sodium 包反查它需要的全部符号名；找不到则返回 None。"""
    roots = glob.glob(os.path.expanduser("~/.pub-cache/hosted/pub.dev/sodium-*"))
    for root in sorted(roots, reverse=True):
        hits = glob.glob(os.path.join(root, "lib", "**", "*.dart"), recursive=True)
        names = set()
        for f in hits:
            names |= set(re.findall(
                r"'(?:sodium|crypto|randombytes)[a-z0-9_]*'", open(f, encoding="utf-8").read()))
        if names:
            return {n.strip("'") for n in names}
    return None


def main():
    libs = sorted(glob.glob(os.path.join(JNI_LIBS, "*", "libsodium.so")))
    if not libs:
        print(f"❌ 没找到任何 libsodium.so（{JNI_LIBS}）")
        return 1

    needed = needed_symbols()
    print(f"sodium 包需要的符号数: {len(needed) if needed else '未找到 pub 缓存 → 跳过符号对账'}\n")

    failed = False
    for path in libs:
        abi = os.path.basename(os.path.dirname(path))
        machine, aligns = read_elf(path)
        problems = []
        if machine is None:
            problems.append("不是 ELF")
        else:
            want = EXPECTED_MACHINE.get(abi)
            if want is not None and machine != want:
                problems.append(f"架构不符（期望 {MACHINE_NAME.get(want)} 实为 {MACHINE_NAME.get(machine, machine)}）")
            if not aligns or any(a < 0x4000 for a in aligns):
                problems.append(f"16KB 页对齐不达标 p_align={[hex(a) for a in aligns]}")
        syms = set()
        out = subprocess.run(["/usr/bin/nm", "-D", "--defined-only", path],
                             capture_output=True, text=True).stdout
        for line in out.splitlines():
            if line.strip():
                syms.add(line.split()[-1])
        if "sodium_init" not in syms:
            problems.append("dynsym 缺少 sodium_init")
        if needed:
            missing = needed - syms
            if missing:
                problems.append(f"缺 {len(missing)} 个符号，如 {sorted(missing)[:3]}")

        status = "✅" if not problems else "❌"
        print(f"{status} {abi:12s} 架构={MACHINE_NAME.get(machine, '?'):8s} "
              f"p_align={[hex(a) for a in aligns]} dynsym={len(syms)}")
        for p in problems:
            print(f"     - {p}")
        failed |= bool(problems)

    print("\n" + ("❌ 存在问题（见上）" if failed else "✅ 全部通过：16KB 对齐 + 符号完整"))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
