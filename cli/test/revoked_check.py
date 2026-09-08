#!/usr/bin/env python3
# revoked 场景回归：第一设备入网 → /recover 撤销全部 → 第一设备重启应直接在
# 终端提示"本设备已被撤销。"并自动退出（不再进入 TUI，无"仅可退出"模式）。
import os, pty, subprocess, select, time, sys, socket, tempfile, shutil

ROOT = '/Users/Shared/productX/einz'
CLI = f'{ROOT}/cli'
WORK = tempfile.mkdtemp(prefix='einz-revoked-')

def free_port():
    s = socket.socket()
    s.bind(('127.0.0.1', 0))
    p = s.getsockname()[1]
    s.close()
    return p

def drain(master, seconds=1.0):
    out = b''
    deadline = time.time() + seconds
    while time.time() < deadline:
        r, _, _ = select.select([master], [], [], 0.2)
        if r:
            try:
                d = os.read(master, 8192)
            except OSError:
                break
            if not d:
                break
            out += d
    return out.decode('utf-8', errors='replace')

def send(master, s):
    os.write(master, s.encode())

def wait_text(master, text, timeout=40):
    """持续读取直到输出中出现 text，返回累计输出。"""
    out = ''
    deadline = time.time() + timeout
    while text not in out and time.time() < deadline:
        out += drain(master, 0.8)
    return out

def start_tui(store, port):
    master, slave = pty.openpty()
    env = dict(os.environ, TERM='xterm-256color')
    p = subprocess.Popen(
        ['dart', 'run', 'bin/einz_tui.dart', '--store', store,
         '--server', f'http://127.0.0.1:{port}'],
        stdin=slave, stdout=slave, stderr=slave, close_fds=True, cwd=CLI, env=env)
    os.close(slave)
    return master, p

def kill_proc(p, m):
    if p.poll() is None:
        p.kill()
    try: os.close(m)
    except OSError: pass

def main():
    port = free_port()
    server = None
    spawned = []  # 记录已启动的 TUI 进程，失败路径兜底清理
    try:
        # 1) 临时服务器
        server = subprocess.Popen(
            ['node', f'{ROOT}/server/dist/app.js'],
            env={**os.environ, 'PORT': str(port),
                 'EINZ_DB': f'{WORK}/einz.sqlite.db', 'EINZ_FILES': f'{WORK}/files'},
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        # 等待就绪
        import urllib.request
        for _ in range(50):
            try:
                urllib.request.urlopen(f'http://127.0.0.1:{port}/health', timeout=1)
                break
            except Exception:
                time.sleep(0.2)

        store = f'{WORK}/a.json'

        # 2) 第一设备入网（首设备自举 + 设置 escrow 口令 pass-123）
        m1, p1 = start_tui(store, port)
        spawned.append((m1, p1))
        out = wait_text(m1, '输入我的名字')
        if '输入我的名字' not in out:
            print('❌ 未到名字问答'); print(out[-500:]); return 1
        send(m1, 'luk\r')
        out = wait_text(m1, '输入伴侣的名字')
        if '输入伴侣的名字' not in out:
            print('❌ 未到伴侣名字问答'); print(out[-500:]); return 1
        send(m1, '\r')  # 伴侣名字：跳过（默认 personB）
        out = wait_text(m1, '设置密保口令')
        if '设置密保口令' not in out:
            print('❌ 未到 escrow 口令问答'); print(out[-500:]); return 1
        send(m1, 'pass-123\r')
        out = wait_text(m1, '设置锁屏码')
        if '设置锁屏码' not in out:
            print('❌ 未到锁屏码问答'); print(out[-500:]); return 1
        send(m1, '\r')  # 锁屏码：跳过（不设置）
        # 一次等待同时收集：入网完成 + WS 连上（状态栏绿点 \x1b[32m●）。
        # 不能分两次 wait_text——pty 缓冲会把相邻多次渲染一起吐出，第一次
        # wait 可能连带吞掉绿点渲染，第二次 wait 就永远等不到（20s 静默）。
        out = wait_text(m1, '\x1b[32m●', timeout=25)
        if '🎉 一切就绪' not in out:
            print('❌ 第一设备未完成入网'); print(repr(out[-500:])); return 1
        if '\x1b[32m●' not in out:
            import json as _json
            try:
                st = _json.load(open(store))
            except Exception as _e:
                st = {'read_err': str(_e)}
            print(f'❌ 第一设备 WS 未连上 (poll={p1.poll()} len={len(out)})')
            print('session_token set:', st.get('session_token') is not None, 'space_id:', st.get('space_id'), 'device_id:', st.get('device_id'))
            print(repr(out[-800:])); return 1
        print('✅ 第一设备入网并保持在线（WS 已连接）')

        # 3) /recover 撤销全部设备 → 在线 TUI 应收到 device.revoked 广播并自动退出
        import urllib.request as ur
        req = ur.Request(f'http://127.0.0.1:{port}/recover',
                         data=b'{"passphrase":"pass-123"}',
                         headers={'Content-Type': 'application/json'}, method='POST')
        with ur.urlopen(req) as r:
            body = r.read().decode()
        if 'revoked' not in body:
            print('❌ /recover 未成功'); print(body); return 1
        out = wait_text(m1, '本设备已被撤销', timeout=15)
        if '本设备已被撤销。' not in out:
            print('❌ 在线 TUI 未收到撤销广播'); print(out[-800:]); return 1
        # 进程应自行退出（无需 /exit）
        deadline = time.time() + 8
        while time.time() < deadline and p1.poll() is None:
            drain(m1, 0.4)
        exited = p1.poll() is not None
        if not exited:
            p1.kill()
            print('❌ 在线 TUI 收到广播后未自动退出'); return 1
        kill_proc(p1, m1)
        print('✅ /recover 撤销 → 在线 TUI 提示后自动退出')

        # 4) 第一设备重启 → 不进 TUI：终端直接提示"本设备已被撤销。"并自动退出
        m2, p2 = start_tui(store, port)
        spawned.append((m2, p2))
        out = wait_text(m2, '本设备已被撤销')
        if '本设备已被撤销。' not in out:
            print('❌ 未显示撤销提示'); print(out[-800:]); return 1
        # 进程应自行退出（无需 /exit）
        deadline = time.time() + 8
        while time.time() < deadline and p2.poll() is None:
            drain(m2, 0.4)
        exited = p2.poll() is not None
        if not exited:
            p2.kill()
            print('❌ 撤销设备未自动退出'); return 1
        kill_proc(p2, m2)
        print('✅ 撤销设备提示后自动退出')
        print('🎉 revoked 场景全部通过')
        return 0
    finally:
        for m, p in spawned:
            if p.poll() is None:
                p.kill()
            try: os.close(m)
            except OSError: pass
        if server:
            server.terminate()
            try: server.wait(timeout=5)
            except Exception: server.kill()
        shutil.rmtree(WORK, ignore_errors=True)

if __name__ == '__main__':
    sys.exit(main())
