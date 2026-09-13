#!/usr/bin/env python3
# revoked 场景回归：第一设备入网 → 被撤销（用第二台设备调 DELETE /devices/:id，
# 服务端广播 device.revoked）→ 在线 TUI 提示后自动退出；重启也直接提示并退出。
#
# 注：v1 的 /recover（全丢恢复）已整体移除（Multiverse 下"仅凭口令重置空间"既不
# 安全也做不到），故改用正常的撤销接口做本测试的触发源。
import os, pty, subprocess, select, time, sys, socket, tempfile, shutil

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
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

        # 2) 第一设备入网（Multiverse 流程：入口 → 创建 → 名字/性别/伴侣 →
        #    密保口令 → 锁屏码）。注：本测试原为 v1 引导流程（直接问"我的名字"），
        #    v2 加了"选择秘境入口"后已失效，此处一并移植到当前流程。
        m1, p1 = start_tui(store, port)
        spawned.append((m1, p1))
        for expect, payload in [
            ('秘境入口', 'c\r'),
            ('我的名字', 'luk\r'),
            ('我的性别', '1\r'),
            ('伴侣的名字', 'ali\r'),
            ('伴侣的性别', '2\r'),
        ]:
            out = wait_text(m1, expect, timeout=30)
            if expect not in out:
                print(f'❌ 未到「{expect}」问答'); print(out[-600:]); return 1
            send(m1, payload)

        out = wait_text(m1, '设置密保口令', timeout=30)
        if '设置密保口令' not in out:
            print('❌ 未到 escrow 口令问答'); print(out[-600:]); return 1
        send(m1, 'pass-123\r')

        # 锁屏码：TUI 阻塞读键盘期间不重绘，提示要等下一次按键才出现 → 重发直到命中
        out = ''
        for _ in range(8):
            send(m1, '123456\r')
            out += wait_text(m1, '🔢', timeout=8)
            if '🔢' in out:
                break
        if '🔢' not in out:
            print('❌ 未设置锁屏码'); print(out[-600:]); return 1

        # 入网完成 + WS 连上（绿点）。两次等待的输出都累加——pty 可能把相邻渲染
        # 一起吐出，单看第二次 wait 的返回值未必能拿到前面的"一切就绪"。
        seen = wait_text(m1, '一切就绪', timeout=30) + wait_text(m1, '\x1b[32m●', timeout=25)
        if '一切就绪' not in seen:
            print('❌ 第一设备未完成入网'); print(repr(seen[-500:])); return 1
        if '\x1b[32m●' not in seen:
            import json as _json
            try:
                st = _json.load(open(store))
            except Exception as _e:
                st = {'read_err': str(_e)}
            print(f'❌ 第一设备 WS 未连上 (poll={p1.poll()} len={len(seen)})')
            print('session_token set:', st.get('session_token') is not None, 'space_id:', st.get('space_id'), 'device_id:', st.get('device_id'))
            print(repr(seen[-800:])); return 1
        print('✅ 第一设备入网并保持在线（WS 已连接）')

        # 3) 撤销第一设备 → 在线 TUI 应收到 device.revoked 广播并自动退出。
        #    DELETE /devices/:id 不允许撤销自己，故先用 HTTP 让"第二台设备"加入
        #    （生成加入码 → POST /spaces/join），再用它的 token 撤销第一设备。
        import json as _json, urllib.request as ur

        def http(method, path, body=None, token=None):
            data = _json.dumps(body).encode() if body is not None else None
            req = ur.Request(f'http://127.0.0.1:{port}{path}', data=data, method=method)
            req.add_header('Content-Type', 'application/json')
            if token:
                req.add_header('Authorization', f'Bearer {token}')
            with ur.urlopen(req, timeout=10) as r:
                return _json.load(r)

        st = _json.load(open(store))
        space_id, my_token, my_device = st['space_id'], st['session_token'], st['device_id']
        jt = http('POST', f'/spaces/{space_id}/join-tokens')['joinToken']
        revoker = http('POST', '/spaces/join', {
            'token': jt, 'public_key': 'pk-revoker',
            'partner_slot': 1, 'device_name': 'revoker'})
        http('DELETE', f'/devices/{my_device}', token=revoker['sessionToken'])

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
        print('✅ 撤销 → 在线 TUI 提示后自动退出')

        # 4) 第一设备重启 → 先解锁（本测试设了锁屏码），随后不进 TUI：
        #    直接提示"本设备已被撤销。"并自动退出
        m2, p2 = start_tui(store, port)
        spawned.append((m2, p2))
        out = wait_text(m2, '输入锁屏码', timeout=30)
        if '输入锁屏码' not in out:
            print('❌ 重启后未到锁屏码问答'); print(out[-600:]); return 1
        unlocked = ''
        for _ in range(6):
            send(m2, '123456\r')
            unlocked += wait_text(m2, '本设备已被撤销', timeout=8)
            if '本设备已被撤销' in unlocked:
                break
        out = unlocked
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
