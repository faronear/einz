#!/usr/bin/env python3
# 启动输出包含 store 路径回归（老板 2026-10-23）：
# TUI 启动时除服务端地址等外，还在消息流里亮出**当前 store 路径**（📁 Store: <路径>）。
# 为什么需要它：npm 包装脚本虽也 echo store 路径，但 TUI 首帧清屏（2J/3J）后不可见；
# 直跑 dart run 时压根没有——多 store（--store / STORE 环境变量）场景下用户无法确认
# 自己连的是哪个文件。
# 路径：新 store + 不可达服务器（跳过登记）→ 引导首问「秘境向导」出现前，
# 消息流里应已有 📁 Store 行（_guidanceNotes 机制，排在 loadHistory 之后）。
import os, pty, re, select, subprocess, sys, tempfile, time

# 由脚本位置推导 cli 目录（仓库已迁移过，不硬编码）
CLI = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# 短路径：pty 默认 80 列，路径过长会被消息流折行、整行断言失配
STORE = os.path.join(tempfile.mkdtemp(prefix='esp-', dir='/tmp'), 'store.json')
ANSI = re.compile(r'\x1b\[[0-9;?]*[A-Za-z]')


def start_tui():
    master, slave = pty.openpty()
    env = dict(os.environ, TERM='xterm-256color')
    cmd = ['dart', 'run', 'bin/einz_tui.dart', '--store', STORE,
           '--server', 'http://127.0.0.1:39999']  # 不可达：跳过登记，只走启动流
    p = subprocess.Popen(cmd, stdin=slave, stdout=slave, stderr=slave,
                         close_fds=True, cwd=CLI, env=env)
    os.close(slave)
    return master, p


def drain(master, seconds=1.0):
    out = b''
    deadline = time.time() + seconds
    while time.time() < deadline:
        r, _, _ = select.select([master], [], [], 0.2)
        if r:
            try:
                data = os.read(master, 8192)
            except OSError:
                break
            if not data:
                break
            out += data
    return out.decode('utf-8', errors='replace')


def main():
    master, p = start_tui()
    out = ''
    try:
        # 1) 冷启动：服务器地址问答（回车沿用）→ _onboard 生成身份 → 启动流 → 向导首问
        out += drain(master, 8)
        os.write(master, b'\r')  # 服务器地址：回车沿用
        deadline = time.time() + 25
        while '秘境向导' not in out and time.time() < deadline and p.poll() is None:
            out += drain(master, 0.8)
        clean = ANSI.sub('', out)
        reached = '秘境向导' in out
        needle = f'📁 Store: {STORE}'
        shown = needle in clean
        print('到达向导首问（启动流已跑完）:', reached)
        print('消息流出现 store 路径行:', shown)
        if not (reached and shown):
            print('---- 输出尾部 ----')
            print(clean[-1200:])
        if reached and shown:
            print('✅ TUI 启动输出包含 store 路径')
            return 0
        print('❌ 验证失败')
        return 1
    finally:
        if p.poll() is None:
            p.kill()
        try:
            os.close(master)
        except OSError:
            pass


if __name__ == '__main__':
    sys.exit(main())
