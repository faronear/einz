#!/usr/bin/env python3
# partner 预置名走查：首设备 TUI 入网时，名字问答后应追加"第二用户的名字"问答；
# 输入 steffi → enroll 自举附 peer_name → /health 名称表 partnerB=steffi。
import os, pty, subprocess, select, time, sys, socket, tempfile, shutil, urllib.request

ROOT = '/Users/Shared/productX/einz'
CLI = f'{ROOT}/cli'
WORK = tempfile.mkdtemp(prefix='einz-partner-')

def free_port():
    s = socket.socket(); s.bind(('127.0.0.1', 0)); p = s.getsockname()[1]; s.close(); return p

def drain(master, seconds=1.0):
    out = b''; deadline = time.time() + seconds
    while time.time() < deadline:
        r, _, _ = select.select([master], [], [], 0.2)
        if r:
            try: d = os.read(master, 8192)
            except OSError: break
            if not d: break
            out += d
    return out.decode('utf-8', errors='replace')

def send(master, s): os.write(master, s.encode())

def wait_text(master, text, timeout=40):
    out = ''; deadline = time.time() + timeout
    while text not in out and time.time() < deadline:
        out += drain(master, 0.8)
    return out

def start_tui(store, port):
    master, slave = pty.openpty()
    env = dict(os.environ, TERM='xterm-256color')
    p = subprocess.Popen(['dart', 'run', 'bin/einz_tui.dart', '--store', store,
                          '--server', f'http://127.0.0.1:{port}'],
                         stdin=slave, stdout=slave, stderr=slave, close_fds=True, cwd=CLI, env=env)
    os.close(slave)
    return master, p

def main():
    port = free_port(); server = None
    try:
        server = subprocess.Popen(['node', f'{ROOT}/server/dist/app.js'],
            env={**os.environ, 'PORT': str(port), 'EINZ_DB': f'{WORK}/einz.sqlite.db',
                 'EINZ_FILES': f'{WORK}/files'},
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(50):
            try: urllib.request.urlopen(f'http://127.0.0.1:{port}/health', timeout=1); break
            except Exception: time.sleep(0.2)

        m, p = start_tui(f'{WORK}/a.json', port)
        out = wait_text(m, '请输入您的名字')
        if '请输入您的名字' not in out:
            print('❌ 未到名字问答'); print(out[-400:]); return 1
        send(m, 'luk\r')
        # 关键断言：名字问答后应出现"第二用户的名字"问答
        out = wait_text(m, '第二用户的名字')
        if '第二用户的名字' not in out:
            print('❌ 未出现第二用户名字问答'); print(out[-400:]); return 1
        send(m, 'steffi\r')
        out = wait_text(m, '请设置内容安全口令')
        if '请设置内容安全口令' not in out:
            print('❌ 未到 escrow 口令问答'); print(out[-400:]); return 1
        send(m, 'pass-123\r')
        out = wait_text(m, '● 在线')
        if '● 在线' not in out:
            print('❌ 未进入在线'); print(out[-400:]); return 1
        send(m, '/exit\r')
        time.sleep(1.5)
        if p.poll() is None: p.kill()
        try: os.close(m)
        except OSError: pass

        # /health 名称表应含 partnerB=steffi
        names = {}
        for _ in range(20):
            try:
                names = json_load(f'http://127.0.0.1:{port}/health')['partner_names']; break
            except Exception: time.sleep(0.3)
        if names.get('partnerB') != 'steffi':
            print(f'❌ partnerB 名称未预置: {names}'); return 1
        print(f'✅ /health 名称表 partnerB={names["partnerB"]}（预置成功）')
        print('🎉 partner 预置名走查通过')
        return 0
    finally:
        if server:
            server.terminate()
            try: server.wait(timeout=5)
            except Exception: server.kill()
        shutil.rmtree(WORK, ignore_errors=True)

def json_load(url):
    import json
    with urllib.request.urlopen(url) as r: return json.loads(r.read().decode())

if __name__ == '__main__':
    sys.exit(main())
