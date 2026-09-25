#!/usr/bin/env python3
# TUI 冒烟：验证 TUI 的核心业务（发送 + WS 实时接收落盘），**双端都是 TUI**。
#
# 历史：本脚本原先用 `bin/einz.dart`（v1 脚本 CLI）驱动另一端，随 v1 收敛一起删除
# （2026-09-15，老板拍板路线 1），改为两个 TUI 实例互为对端。
#
# 说明：pty 模拟终端下 Dart 的 stdout 渲染可能被吞（"StreamSink is bound to a
# stream" 是 Dart 在非终端/pty 下的已知行为，真实终端正常），故本脚本不依赖
# stdout 文本断言，改为验证数据落盘：
#   1) A(TUI) 启动渲染状态栏（能启动不崩）
#   2) A(TUI) 发送消息 → B 的 store 历史出现新条目（发送链路 + 对端 WS 落盘 OK）
#   3) B(TUI) 发送 → A(TUI) 保持运行，store-a 历史出现 B 消息（WS 实时接收落盘 OK）
#
# 前置：
#   - 服务端已就绪（默认 http://127.0.0.1:3901，可用 EINZ_SMOKE_SERVER 覆盖）；
#   - `demo/store-a.json` 与 `demo/store-b.json` 已绑定到**同一个**秘境
#     （由 TUI 引导创建/加入生成；两个 store 必须在同一空间才收得到对方消息）。
#   - 注意：store 历史只存密文信封，解密正确性由 shared 的加密测试与 App 侧覆盖，
#     本脚本验证的是"收发链路 + 落盘"。
import os, pty, subprocess, select, time, sys, json

CLI = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # cli/
SERVER = os.environ.get('EINZ_SMOKE_SERVER', 'http://127.0.0.1:3901')
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
    for path in (STORE_A, STORE_B):
        if not os.path.exists(path):
            print(f'❌ 缺少 {path}——先用 TUI 引导创建/加入同一个秘境')
            print('   例：cd cli && dart run bin/einz_tui.dart --store demo/store-a.json --server ' + SERVER)
            sys.exit(1)

    # 0) server 健康
    code = run_capture(['curl', '-s', '-o', '/dev/null', '-w', '%{http_code}', f'{SERVER}/entrances'])
    print(f'[0] server 探测: HTTP {code}')
    if code.startswith('000') or code.startswith('5'):
        print('❌ server 未就绪'); sys.exit(1)

    # 1) 两端 TUI 启动（B 静默运行，作为对端）
    print('[1] 启动 A/B 两个 TUI（pty）…')
    master_a, pa = start_tui('demo/store-a.json')
    master_b, pb = start_tui('demo/store-b.json')
    out = read_until(master_a, 'Einz', timeout=25)
    if 'Einz' not in out:
        print('❌ TUI 未渲染状态栏'); print(out[-600:]); cleanup(master_a, pa, master_b, pb); sys.exit(1)
    print('✅ TUI 状态栏渲染 OK')

    # 2) A 发送消息（中文，验证 utf8 输入解码）→ B 落盘
    print('[2] A(TUI) 发送中文消息，检查 B 落盘…')
    before_b = store_history_count(STORE_B)
    msg_a = f'TUI冒烟A{int(time.time())}'
    os.write(master_a, f'{msg_a}\r'.encode('utf-8'))
    time.sleep(6)  # 等发送 + B 的 WS message.new → 落盘
    after_b = store_history_count(STORE_B)
    if after_b > before_b:
        print(f'✅ A(TUI) 发送成功，B 已收到并落盘（history {before_b}→{after_b} 条）')
    else:
        print(f'❌ B 未收到 A 的消息（history {before_b}→{after_b} 条）')
        cleanup(master_a, pa, master_b, pb)
        sys.exit(1)

    # 3) B 发送 → A(TUI) WS 实时接收落盘
    print('[3] B(TUI) 发送，A(TUI) WS 实时接收…')
    before = store_history_count(STORE_A)
    before_seq = store_last_seq(STORE_A)
    msg_b = f'TUI冒烟B{int(time.time())}'
    os.write(master_b, f'{msg_b}\r'.encode('utf-8'))
    time.sleep(6)  # 等 WS message.new → 落盘
    after = store_history_count(STORE_A)
    after_seq = store_last_seq(STORE_A)
    if after > before and after_seq is not None and after_seq > (before_seq or 0):
        print(f'✅ A(TUI) 通过 WS 实时收到 B 的消息并落盘（history {before}→{after} 条，seq {before_seq}→{after_seq}）')
    else:
        print(f'❌ A 未实时收到 B 的消息（history {before}→{after} 条, seq {before_seq}→{after_seq}）')
        cleanup(master_a, pa, master_b, pb)
        sys.exit(1)

    print('\n🎉 TUI 双端实时收发冒烟全部通过')
    cleanup(master_a, pa, master_b, pb)

def cleanup(*pairs):
    for master, p in zip(pairs[0::2], pairs[1::2]):
        try:
            os.write(master, b'/exit\r')
        except OSError:
            pass
    time.sleep(0.5)
    for master, p in zip(pairs[0::2], pairs[1::2]):
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
