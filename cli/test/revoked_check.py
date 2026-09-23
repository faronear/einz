#!/usr/bin/env python3
# 撤销语义回归（老板 2026-09-16 修订）：**只有"明确针对本通道的撤销"才清空本地数据**。
#
#   ① 在线被明确撤销（TUI 收到 entrance.revoked 帧）→ 提示"本通道已被撤销，本地数据已清除"
#      后自动退出，且 store 文件与附件缓存已删；
#   ② 离线期间被撤销（重启才认证，挑战返回 403 ENTRANCE_REVOKED）→ 同上；
#   ③ **后台数据库被清空/重置**（通道行不存在 → 403 FORBIDDEN）→ **绝不清数据**：
#      TUI 照常启动、提示"本通道未被服务器识别"、本地历史一条不少、进程不退出。
#
# 为什么要有 ③：服务端此前把"通道被撤销"和"通道不在册"都返回 403 FORBIDDEN，
# 客户端只能一律当撤销处理 → 运维清一次库，客户端就把本地消息全抹了（不可挽回）。
#
# 注：v1 的 /recover（全丢恢复）已整体移除（Multiverse 下"仅凭口令重置空间"既不
# 安全也做不到），故改用正常的撤销接口做本测试的触发源。
#
# 运行：cd server && npm run build（本用例跑 dist）&& python3 cli/test/revoked_check.py
import os, pty, subprocess, select, time, sys, socket, tempfile, shutil, json
import urllib.request, urllib.error

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CLI = f'{ROOT}/cli'
WORK = tempfile.mkdtemp(prefix='einz-revoked-')
PIN = '123456'
PASSPHRASE = 'pass-123'

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

def start_tui(store, port, home=None):
    """起 TUI。home 指定 HOME：撤销自毁会删 `$HOME/.einz/cache`，必须隔离到临时目录，
    否则会误删开发机上真实的附件缓存（同时让"缓存已删"这条断言有确定的落点）。"""
    master, slave = pty.openpty()
    env = dict(os.environ, TERM='xterm-256color')
    if home:
        env['HOME'] = home
        # 包解析仍用真实 pub cache（HOME 被换掉后 dart 默认会去找 $HOME/.pub-cache）
        env.setdefault('PUB_CACHE', os.path.expanduser('~/.pub-cache'))
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

def start_server(port, db_path):
    p = subprocess.Popen(
        ['node', f'{ROOT}/server/dist/app.js'],
        env={**os.environ, 'PORT': str(port),
             'EINZ_DB': db_path, 'EINZ_FILES': f'{os.path.dirname(db_path)}/files'},
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(60):
        try:
            urllib.request.urlopen(f'http://127.0.0.1:{port}/health', timeout=1)
            return p
        except Exception:
            time.sleep(0.2)
    raise RuntimeError('server 未就绪')

def onboard(label, store, port, home):
    """入网全流程：入口 → 我的名字/性别 → 伴侣名字/性别 → 共享口令 → 锁屏码 → 进入聊天态。"""
    m, p = start_tui(store, port, home)
    for expect, payload in [
        ('秘境入口', 'c\r'),
        ('我的名字', f'{label}\r'),
        ('我的性别', '1\r'),
        ('伴侣的名字', f'{label}-p\r'),
        ('伴侣的性别', '2\r'),
    ]:
        out = wait_text(m, expect, timeout=30)
        if expect not in out:
            print(f'❌ {label}: 未到「{expect}」问答'); print(out[-600:]); raise SystemExit(1)
        send(m, payload)
    out = wait_text(m, '设置共享口令', timeout=30)
    if '设置共享口令' not in out:
        print(f'❌ {label}: 未到 escrow 口令问答'); print(out[-600:]); raise SystemExit(1)
    send(m, PASSPHRASE + '\r')
    # 锁屏码：TUI 阻塞读键盘期间不重绘，提示要等下一次按键才出现 → 重发直到命中
    out = ''
    for _ in range(8):
        send(m, PIN + '\r')
        out += wait_text(m, '🔢', timeout=8)
        if '🔢' in out:
            break
    if '🔢' not in out:
        print(f'❌ {label}: 未设置锁屏码'); print(out[-600:]); raise SystemExit(1)
    # 入网完成 + WS 连上（绿点）
    seen = wait_text(m, '一切就绪', timeout=30) + wait_text(m, '\x1b[32m●', timeout=25)
    if '一切就绪' not in seen or '\x1b[32m●' not in seen:
        print(f'❌ {label}: 未完成入网/WS 未连上 (poll={p.poll()})')
        print(repr(seen[-800:])); raise SystemExit(1)
    print(f'✅ {label}: 入网并保持在线（WS 已连接）')
    return m, p

def http_status(port, method, path, body=None, token=None):
    """发请求并返回 (status, body)；4xx/5xx **不抛异常**（本探针要断言错误码）。"""
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f'http://127.0.0.1:{port}{path}', data=data, method=method)
    req.add_header('Content-Type', 'application/json')
    # 协议版本头是硬校验（PROTOCOL.md §1）：缺头 → 400 PROTOCOL_VERSION_MISMATCH
    req.add_header('X-Protocol-Version', '1')
    if token:
        req.add_header('Authorization', f'Bearer {token}')

    def _parse(raw):
        try:
            return json.loads(raw.decode() or '{}')
        except Exception:
            return {}

    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, _parse(r.read())
    except urllib.error.HTTPError as e:
        return e.code, _parse(e.read())

def http(port, method, path, body=None, token=None):
    """成功才返回 body；4xx 打印响应体后抛出（调试用——只有状态码看不出去哪一步）。"""
    status, body = http_status(port, method, path, body, token)
    if status >= 400:
        print(f'❌ HTTP {status} {method} {path}: {body}')
        raise SystemExit(1)
    return body

def join_revoker(port, store_path):
    """让"另一条通道"从 HTTP 侧加入本空间，返回它的会话（撤销不允许撤自己，需要第三方）。"""
    st = json.load(open(store_path))
    # 签发加入码要**空间成员会话**（C1 回归后该端点必须带 Bearer；旧版探针漏了 → 401）
    jt = http(port, 'POST', f'/spaces/{st["space_id"]}/join-tokens',
              token=st['session_token'])['joinToken']
    revoker = http(port, 'POST', '/spaces/join', {
        'token': jt, 'public_key': 'pk-revoker',
        'slot': 1, 'entrance_name': 'revoker'})
    return revoker['sessionToken']

def revoke(port, entrance_id, passphrase, token):
    """POST /entrances/:id/revoke：撤销本空间另一条通道——**每次都要校验共享口令**（2026-09-16）。"""
    status, body = http_status(port, 'POST', f'/entrances/{entrance_id}/revoke',
                               {'passphrase': passphrase}, token)
    if status != 200:
        print(f'❌ 撤销失败 HTTP {status}: {body}')
        raise SystemExit(1)

def wait_exit(m, p, seconds=8):
    deadline = time.time() + seconds
    while time.time() < deadline and p.poll() is None:
        drain(m, 0.4)
    return p.poll() is not None

def main():
    port_a, port_c = free_port(), free_port()
    server_a, server_c = None, None
    spawned = []
    try:
        # ---------- 场景 ①②：明确撤销 ----------
        server_a = start_server(port_a, f'{WORK}/a/einz.sqlite.db')
        store_a = f'{WORK}/a.json'
        m1, p1 = onboard('luk', store_a, port_a, WORK)
        spawned.append((m1, p1))

        st = json.load(open(store_a))
        my_entrance = st['entrance_id']

        # 离线撤销的对照组：撤销前备份 store（模拟"通道离线时被撤销，本地数据还在"）
        store_offline = f'{WORK}/a-offline.json'
        shutil.copy2(store_a, store_offline)
        # 预置一个假的附件缓存文件，验证自毁确实清了缓存（真实下载才产生，这里造一个）
        cache_dir = f'{WORK}/.einz/cache'
        os.makedirs(cache_dir, exist_ok=True)
        open(f'{cache_dir}/dummy.bin', 'wb').write(b'should-be-wiped')

        revoker_token = join_revoker(port_a, store_a)

        # 口令校验（老板 2026-09-16 定稿：同 space 内可互撤，但每次撤销都要验共享口令）：
        # ① 口令错 → 401，且通道**毫发无损**（在线 TUI 不得退出、不得清盘）；
        # ② 不带口令 → 400。两条都在"正确口令"之前跑，确保撤销确实被拦住。
        bad_status, bad_body = http_status(
            port_a, 'POST', f'/entrances/{my_entrance}/revoke',
            {'passphrase': 'wrong-passphrase'}, revoker_token)
        if bad_status != 401 or bad_body.get('error', {}).get('code') != 'ESCROW_VERIFY_FAILED':
            print(f'❌ 口令错误应 401 ESCROW_VERIFY_FAILED，实际 {bad_status} {bad_body}')
            return 1
        no_pass_status, _ = http_status(
            port_a, 'POST', f'/entrances/{my_entrance}/revoke', {}, revoker_token)
        if no_pass_status != 400:
            print(f'❌ 不带口令应 400，实际 {no_pass_status}')
            return 1
        time.sleep(1.5)
        if p1.poll() is not None:
            print('❌ 撤销被口令拦下，但在线 TUI 却退出了（口令校验没生效？）')
            return 1
        print('✅ 口令错 → 401、缺口令 → 400，且通道未受影响（在线 TUI 仍运行）')

        revoke(port_a, my_entrance, PASSPHRASE, revoker_token)

        # ① 在线被撤销：收到 entrance.revoked 帧 → 清盘 + 提示 + 自退
        out = wait_text(m1, '本通道已被撤销', timeout=15)
        if '本通道已被撤销' not in out:
            print('❌ 在线 TUI 未收到撤销广播'); print(out[-800:]); return 1
        if not wait_exit(m1, p1):
            p1.kill()
            print('❌ 在线 TUI 收到广播后未自动退出'); return 1
        kill_proc(p1, m1)
        if os.path.exists(store_a):
            print('❌ 明确撤销后 store 文件仍在（应为"本地数据已清除"）'); return 1
        if os.path.exists(cache_dir):
            print('❌ 明确撤销后附件缓存目录仍在'); return 1
        print('✅ ① 在线撤销 → 提示后自退，store 与附件缓存已清除')

        # ② 离线期间被撤销（重启才发现）：挑战 403 ENTRANCE_REVOKED → 同样清盘退出
        m2, p2 = start_tui(store_offline, port_a, WORK)
        spawned.append((m2, p2))
        out = wait_text(m2, '输入锁屏码', timeout=30)
        if '输入锁屏码' not in out:
            print('❌ 重启后未到锁屏码问答'); print(out[-600:]); return 1
        unlocked = ''
        for _ in range(6):
            send(m2, PIN + '\r')
            unlocked += wait_text(m2, '本通道已被撤销', timeout=8)
            if '本通道已被撤销' in unlocked:
                break
        if '本通道已被撤销' not in unlocked:
            print('❌ 离线撤销的通道重启后未提示撤销'); print(unlocked[-800:]); return 1
        if not wait_exit(m2, p2):
            p2.kill()
            print('❌ 撤销通道重启后未自动退出'); return 1
        kill_proc(p2, m2)
        if os.path.exists(store_offline):
            print('❌ 明确撤销后 store 文件仍在'); return 1
        print('✅ ② 离线撤销（重启认证 403 ENTRANCE_REVOKED）→ 提示后自退，store 已清除')

        # ---------- 场景 ③：后台库被清空（通道不在册）→ 只警告，绝不清数据 ----------
        server_c = start_server(port_c, f'{WORK}/c/einz.sqlite.db')
        store_c = f'{WORK}/c.json'
        m3, p3 = onboard('sam', store_c, port_c, WORK)
        spawned.append((m3, p3))
        # 发一条消息，确保本地有真实历史（"仍可查看本地消息流"要有东西可看）
        send(m3, 'hello-from-c\r')
        if 'hello-from-c' not in wait_text(m3, 'hello-from-c', timeout=15):
            print('❌ 场景③：消息未上屏（无法验证本地历史）'); return 1
        time.sleep(1.5)  # 等落盘

        before = json.load(open(store_c))
        if not before.get('history'):
            print('❌ 场景③：store 里没有历史消息，断言会失去意义'); return 1
        space_key_before = before.get('space_key')

        # 清空后台库：停服 → 删库（含 WAL/SHM）→ 同端口同路径重启（空库）
        server_c.terminate()
        try: server_c.wait(timeout=5)
        except Exception: server_c.kill()
        db = f'{WORK}/c/einz.sqlite.db'
        for suffix in ['', '-wal', '-shm']:
            try: os.remove(db + suffix)
            except FileNotFoundError: pass
        server_c = start_server(port_c, db)
        print('🧹 后台库已清空并重启（模拟运维失误/重置）')

        # 重启 TUI：解锁后应"只警告、不退出、不删数据"
        m4, p4 = start_tui(store_c, port_c, WORK)
        spawned.append((m4, p4))
        out = wait_text(m4, '输入锁屏码', timeout=30)
        if '输入锁屏码' not in out:
            print('❌ 场景③：未到锁屏码问答'); print(out[-600:]); return 1
        warning = ''
        for _ in range(6):
            send(m4, PIN + '\r')
            warning += wait_text(m4, '本通道未被服务器识别', timeout=8)
            if '本通道未被服务器识别' in warning:
                break
        if '本通道未被服务器识别' not in warning:
            print('❌ 场景③：库被清空后未给出"未被服务器识别"警告'); print(warning[-900:]); return 1
        if p4.poll() is not None:
            print('❌ 场景③：库被清空后 TUI 竟然退出了（应只警告并继续）'); return 1
        if 'hello-from-c' not in warning:
            print('❌ 场景③：本地历史没有显示出来（"仍可查看本地消息流"不成立）')
            print(warning[-900:]); return 1
        after = json.load(open(store_c))
        if not after.get('history'):
            print('❌ 场景③：本地历史被清空了！'); return 1
        if after.get('space_key') != space_key_before:
            print('❌ 场景③：Space Key 被改动了（本地数据被动过）'); return 1
        print('✅ ③ 后台库被清空 → 只警告「本通道未被服务器识别」，进程仍在、本地历史完好')

        # 收尾：/exit 正常退出（不因警告而无法使用）
        send(m4, '/exit\r')
        if not wait_exit(m4, p4):
            p4.kill()
            print('❌ 场景③：/exit 未能正常退出'); return 1
        kill_proc(p4, m4)
        if not os.path.exists(store_c):
            print('❌ 场景③：正常退出后 store 不应被删'); return 1
        print('✅ ④ 警告状态下 /exit 正常退出，store 保留')

        print('🎉 revoked 场景全部通过（明确撤销=自毁；库被重置=只警告）')
        return 0
    finally:
        for m, p in spawned:
            if p.poll() is None:
                p.kill()
            try: os.close(m)
            except OSError: pass
        for s in (server_a, server_c):
            if s:
                s.terminate()
                try: s.wait(timeout=5)
                except Exception: s.kill()
        shutil.rmtree(WORK, ignore_errors=True)

if __name__ == '__main__':
    sys.exit(main())
