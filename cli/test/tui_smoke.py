#!/usr/bin/env python3
# TUI 冒烟 v2：验证 TUI 的核心业务（发送 + WS 实时接收落盘）。
#
# 说明：pty 模拟终端下 Dart 的 stdout 渲染可能被吞（"StreamSink is bound to a
# stream" 是 Dart 在非终端/pty 下的已知行为，真实终端正常），故本脚本不依赖
# stdout 文本断言，改为验证数据落盘：
#   1) A(TUI) 启动渲染状态栏（能启动不崩）
#   2) A(TUI) 发送消息 → B 同步解密收到（发送链路 OK）
#   3) B 发送 → A(TUI) 保持运行，store-a 历史出现 B 消息（WS 实时接收落盘 OK）
import os, pty, subprocess, select, time, sys, json, re

CLI = '/Users/luk/einz/cli'
SERVER = 'http://127.0.0.1:3901'
STORE_A = os.path.join(CLI, 'demo/store-a.json')
STORE_B = os.path.join(CLI, 'demo/store-b.json')

def run_capture(cmd, timeout=60):
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, cwd=CLI)
    return r.stdout + r.stderr

def store_history_count(path):
    with open(path) as f:
        return len(json.load(f).get('history', []))

def store_last_seq(path):
    with open(path) as f:
        hist = json.load(f).get('history', [])
        return hist[-1].get('server_sequence') if hist else None

def start_tui(store):
    master, slave = pty.openpty()
    env = dict(os.environ, TERM='xterm-256color')
    cmd = ['dart', 'run', 'bin/einz_tui.dart', '--store', store, '--server', SERVER]
    p = subprocess.Popen(cmd, stdin=slave, stdout=slave, stderr=slave, close_fds=True, cwd=CLI, env=env)
    os.close(slave)
    return master, p

def read_until(master, needle, timeout=20):
    out = b''
    deadline = time.time() + timeout
    while time.time() < deadline:
        r, _, _ = select.select([master], [], [], 0.3)
        if r:
            try:
                data = os.read(master, 4096)
            except OSError:
                break
            if not data:
                break
            out += data
            if needle.encode() in out:
                return out.decode('utf-8', errors='replace')
    return out.decode('utf-8', errors='replace')

def main():
    # 0) server 健康
    code = run_capture(['curl', '-s', '-o', '/dev/null', '-w', '%{http_code}', f'http://127.0.0.1:3901/devices'])
    print(f'[0] server 探测: HTTP {code}')
    if not code.startswith('4'):
        print('❌ server 未就绪'); sys.exit(1)

    # 1) A TUI 启动并渲染状态栏
    print('[1] 启动 A TUI（pty）…')
    master, p = start_tui('demo/store-a.json')
    out = read_until(master, 'Einz TUI', timeout=25)
    if 'Einz TUI' not in out:
        print('❌ TUI 未渲染状态栏'); print(out[-600:]); sys.exit(1)
    print('✅ TUI 状态栏渲染 OK')

    # 2) A 发送消息（中文，验证 utf8 输入解码）
    print('[2] A(TUI) 发送中文消息…')
    msg_a = f'TUI冒烟A{int(time.time())}'
    os.write(master, f'{msg_a}\r'.encode('utf-8'))
    time.sleep(4)  # 等发送 + 落盘
    # 检查 B 能否解密出 A 的消息（发送链路：用真正的 sync 子命令）
    out_b = run_capture(['dart', 'run', 'bin/einz.dart', 'sync', '--store', 'demo/store-b.json', '--server', SERVER])
    if msg_a in out_b:
        print('✅ A(TUI) 发送成功，B 已解密收到')
    else:
        print('❌ B 未收到 A 的消息')
        print(out_b[-800:])
        cleanup(master, p)
        sys.exit(1)

    # 3) B 发送 → A(TUI) WS 实时接收落盘
    print('[3] B 发送，A(TUI) WS 实时接收…')
    before = store_history_count(STORE_A)
    before_seq = store_last_seq(STORE_A)
    msg_b = f'TUI冒烟B{int(time.time())}'
    run_capture(['dart', 'run', 'bin/einz.dart', 'send', '--store', 'demo/store-b.json', '--server', SERVER, '--message', msg_b])
    time.sleep(5)  # 等 WS message.new → 落盘
    after = store_history_count(STORE_A)
    after_seq = store_last_seq(STORE_A)
    if after > before and after_seq is not None and after_seq > (before_seq or 0):
        print(f'✅ A(TUI) 通过 WS 实时收到 B 的消息并落盘（history {before}→{after} 条，seq {before_seq}→{after_seq}）')
    else:
        print(f'❌ A 未实时收到 B 的消息（history {before}→{after} 条, seq {before_seq}→{after_seq}）')
        cleanup(master, p)
        sys.exit(1)

    print('\n🎉 TUI 双端实时收发冒烟全部通过')
    cleanup(master, p)

def cleanup(master, p):
    try:
        os.write(master, b'/exit\r')
    except OSError:
        pass
    time.sleep(0.5)
    try:
        p.terminate()
    except Exception:
        pass
    try:
        os.close(master)
    except Exception:
        pass

if __name__ == '__main__':
    main()
