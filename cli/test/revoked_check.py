#!/usr/bin/env python3
# revoked 场景回归：第一设备入网 → /recover 撤销全部 → 第一设备重启应进入
# "仅可退出"模式：不显示历史、显示"当前设备已被撤销，您只能 /exit 退出"、
# 普通输入被拒（仅 /exit 放行）。
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

def main():
    port = free_port()
    server = None
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
        out = wait_text(m1, '请输入您的名字')
        if '请输入您的名字' not in out:
            print('❌ 未到名字问答'); print(out[-500:]); return 1
        send(m1, 'luk\r')
        out = wait_text(m1, '请设置内容安全口令')
        if '请设置内容安全口令' not in out:
            print('❌ 未到 escrow 口令问答'); print(out[-500:]); return 1
        send(m1, 'pass-123\r')
        out = wait_text(m1, '● 在线')
        if '● 在线' not in out:
            print('❌ 第一设备未进入在线状态'); print(out[-500:]); return 1
        send(m1, '/exit\r')
        time.sleep(2)
        if p1.poll() is None:
            p1.kill()
        try: os.close(m1)
        except OSError: pass
        print('✅ 第一设备入网并进入在线')

        # 3) /recover 撤销全部设备
        import urllib.request as ur
        req = ur.Request(f'http://127.0.0.1:{port}/recover',
                         data=b'{"passphrase":"pass-123"}',
                         headers={'Content-Type': 'application/json'}, method='POST')
        with ur.urlopen(req) as r:
            body = r.read().decode()
        if 'revoked' not in body:
            print('❌ /recover 未成功'); print(body); return 1
        print('✅ /recover 已撤销设备')

        # 4) 第一设备重启 → 应进入"仅可退出"模式
        m2, p2 = start_tui(store, port)
        out = wait_text(m2, '当前设备已被撤销')
        if '当前设备已被撤销，您只能 /exit 退出' not in out:
            print('❌ 未显示撤销提示'); print(out[-800:]); return 1
        if '设备已被撤销' not in out:
            print('❌ 状态栏未显示撤销态'); print(out[-500:])
        # 4a) 普通输入应被拒绝（再次出现提示，而不是发送成功）
        n_before = out.count('当前设备已被撤销')
        send(m2, 'hello 世界\r')
        out += wait_text(m2, '当前设备已被撤销', timeout=8)
        n_after = out.count('当前设备已被撤销')
        if n_after <= n_before:
            print('❌ 普通输入未被拒绝（无重复提示）'); print(out[-600:]); return 1
        print('✅ 普通输入被拒绝（提示重复出现）')
        # 4b) /exit 可退出
        send(m2, '/exit\r')
        deadline = time.time() + 8
        while time.time() < deadline and p2.poll() is None:
            drain(m2, 0.4)
        exited = p2.poll() is not None
        if not exited:
            p2.kill()
            print('❌ /exit 未能退出'); return 1
        print('✅ /exit 正常退出')
        print('🎉 revoked 场景全部通过')
        return 0
    finally:
        if server:
            server.terminate()
            try: server.wait(timeout=5)
            except Exception: server.kill()
        shutil.rmtree(WORK, ignore_errors=True)

if __name__ == '__main__':
    sys.exit(main())
