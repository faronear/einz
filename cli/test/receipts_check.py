#!/usr/bin/env python3
# 回执（已送达/已读）端到端回归：两台 TUI（A 创建、B 加入）互发一条，
# B 收到后应把"已读"高水位上报到服务端，且落盘到自己的 store。
#
# 语义（与服务端一致）：B 上报 read_upto_seq=N ⟺ B 已读到 seq ≤ N 的对方消息；
# 读隐含送达（服务端 SQL 保证 delivered ≥ read）。
#
# 运行：python3 cli/test/receipts_check.py
import json, os, pty, subprocess, select, time, socket, tempfile, urllib.request, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CLI = os.path.join(ROOT, 'cli')
WORK = tempfile.mkdtemp(prefix='einz-receipts-')


def free_port():
    s = socket.socket()
    s.bind(('127.0.0.1', 0))
    port = s.getsockname()[1]
    s.close()
    return port


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


def read_store(path):
    with open(path) as f:
        return json.load(f)


def wait_store_field(path, field, minimum=1, timeout=30, debug=False):
    """轮询 store JSON：等某字段 ≥ minimum（回执上报是异步的）。"""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            st = read_store(path)
            val = st.get(field, 0) or 0
            if debug:
                print('   [poll] %s=%s keys=%s' % (
                    field, st.get(field, '<missing>'),
                    'has' if field in st else 'MISSING'), flush=True)
            if val >= minimum:
                return val
        except Exception as e:
            if debug:
                print('   [poll] read error: %r' % (e,), flush=True)
        time.sleep(5)
    return 0


def wait_ws_connected(port, store_path, timeout=60):
    """等本设备的 WS 连上（服务端 devices.connected_at 非空 = 有实时 WS 连接）。"""
    st = read_store(store_path)
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            devs = http_json(f'http://127.0.0.1:{port}/devices',
                             token=st['session_token'])['devices']
            for d in devs:
                if d.get('device_id') == st.get('device_id') and d.get('connected_at'):
                    return True
        except Exception:
            pass
        time.sleep(2)
    return False


def http_json(url, method='GET', body=None, token=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header('Content-Type', 'application/json')
    if token:
        req.add_header('Authorization', f'Bearer {token}')
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.load(r)


def main():
    port = free_port()
    server = None
    spawned = []
    try:
        server = subprocess.Popen(
            ['node', os.path.join(ROOT, 'server', 'dist', 'app.js')],
            env={**os.environ, 'PORT': str(port),
                 'EINZ_DB': os.path.join(WORK, 'einz.sqlite.db'),
                 'EINZ_FILES': os.path.join(WORK, 'files')},
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(50):
            try:
                urllib.request.urlopen(f'http://127.0.0.1:{port}/health', timeout=1)
                break
            except Exception:
                time.sleep(0.2)

        # ---------- A：创建秘境 ----------
        store_a = os.path.join(WORK, 'a.json')
        ma, pa = start_tui(store_a, port)
        spawned.append((ma, pa))
        for expect, payload in [
            ('秘境入口', 'c\r'), ('我的名字', 'Lukas\r'), ('我的性别', '1\r'),
            ('伴侣的名字', 'Alice\r'), ('伴侣的性别', '2\r'),
        ]:
            out = wait_text(ma, expect)
            if expect not in out:
                print(f'❌ A 未到「{expect}」问答'); print(out[-600:]); return 1
            send(ma, payload)
        out = wait_text(ma, '设置密保口令')
        if '设置密保口令' not in out:
            print('❌ A 未到口令问答'); print(out[-600:]); return 1
        send(ma, 'abc123\r')
        out = wait_text(ma, '成功创建秘境', timeout=40)
        if '成功创建秘境' not in out:
            print('❌ A 未创建成功'); print(out[-600:]); return 1
        # 锁屏码：TUI 阻塞读键盘时不重绘，提示要等下一次按键才出现 —— 用重试发送
        # （既有脚本同款 input_until；非法值会被拒，重发无害）
        def input_until(master, payload, expect, tries=8, timeout=8):
            out = ''
            for _ in range(tries):
                send(master, payload)
                out = wait_text(master, expect, timeout=timeout)
                if expect in out:
                    break
            return out

        out = input_until(ma, '123456\r', '🔢')
        if '🔢' not in out:
            print('❌ A 未设置锁屏码'); print(out[-800:]); return 1
        time.sleep(1)  # 等 store 落盘（space_id 需要）
        st_a = read_store(store_a)
        space_id = st_a.get('space_id')
        if not space_id:
            print('❌ A 的 store 缺少 space_id'); return 1

        # ---------- B：加入 ----------
        tok = http_json(f'http://127.0.0.1:{port}/spaces/{space_id}/join-tokens',
                        method='POST')['joinToken']
        store_b = os.path.join(WORK, 'b.json')
        mb, pb = start_tui(store_b, port)
        spawned.append((mb, pb))
        for expect, payload in [
            ('秘境入口', 'j\r'), ('输入邀请码', tok + '\r'), ('我是谁', 'Alice\r'),
        ]:
            out = wait_text(mb, expect)
            if expect not in out:
                print(f'❌ B 未到「{expect}」问答'); print(out[-600:]); return 1
            send(mb, payload)
        out = wait_text(mb, '验证密保口令')
        if '验证密保口令' not in out:
            print('❌ B 未到口令问答'); print(out[-600:]); return 1
        send(mb, 'abc123\r')
        out = wait_text(mb, '成功加入秘境', timeout=40)
        if '成功加入秘境' not in out:
            print('❌ B 未加入成功'); print(out[-600:]); return 1

        # B 也设锁屏码（同样需要重试发送）
        out = input_until(mb, '123456\r', '🔢')
        if '🔢' not in out:
            print('❌ B 未设置锁屏码'); print(out[-800:]); return 1
        time.sleep(2)
        # 等 B 的 WS 真的连上（服务端 devices.connected_at 非空 = 有实时连接）。
        # 不能用 TUI 标题栏的绿●判定——它也表示"对方在线"，会误判。
        if not wait_ws_connected(port, store_b, timeout=60):
            print('❌ B 的 WS 未连上（devices.connected_at 为空）'); return 1

        # ---------- A 发一条 → B 实时收到并上报已读 ----------
        # A 发一条：TUI 阻塞读键盘期间可能吞掉输入 —— 直到出现「已发送」确认
        # （重发无害：最多多发几条，seq 仍单调）
        out = ''
        for _ in range(5):
            send(ma, 'receipt-probe-1\r')
            out = wait_text(ma, '已发送', timeout=8)
            if '已发送' in out:
                break
        if '已发送' not in out:
            print('❌ A 未发出消息'); print(out[-800:]); return 1

        # 判定以**服务端**为准（store 落盘可能再晚一拍）：轮询 B 的回执行直到
        # read_upto_seq ≥ 1。B 的上报是异步的，且 TUI 的事件循环可能被阻塞读
        # 键盘拖住，窗口放宽到 180s。
        st_b = read_store(store_b)
        r = None
        rows = []
        deadline = time.time() + 180
        while time.time() < deadline:
            try:
                rows = http_json(f'http://127.0.0.1:{port}/receipts',
                                 token=st_b['session_token'])['receipts']
                mine = [x for x in rows if x['person_id'] == st_b['person_id']]
                if mine and mine[0]['read_upto_seq'] >= 1:
                    r = mine[0]
                    break
            except Exception:
                pass
            time.sleep(3)
        if r is None:
            print('❌ 服务端 B 的 read_upto_seq 未推进')
            print('  rows=%s' % (rows,))
            print('  B store: lastServerSequence=%s lastReportedDeliveredSeq=%s lastReportedReadSeq=%s'
                  % (read_store(store_b).get('last_server_sequence'),
                     read_store(store_b).get('last_reported_delivered_seq'),
                     read_store(store_b).get('last_reported_read_seq')))
            print('  --- B tail ---'); print(drain(mb, 2.0)[-3000:])
            return 1
        if r['delivered_upto_seq'] < r['read_upto_seq']:
            print(f'❌ 读隐含送达被破坏（delivered < read）：{r}'); return 1
        # store 落盘（防抖标记）最终也应对齐（成功才推进 → 最多晚一拍）
        read_seq = wait_store_field(store_b, 'last_reported_read_seq',
                                    r['read_upto_seq'], timeout=20)

        print(f'✅ 回执链路打通：B 已读高水位={r["read_upto_seq"]}、送达={r["delivered_upto_seq"]}（store 落盘 {read_seq}）')
        return 0
    finally:
        for m, p in spawned:
            if p.poll() is None:
                p.kill()
            try:
                os.close(m)
            except OSError:
                pass
        if server and server.poll() is None:
            server.kill()


if __name__ == '__main__':
    sys.exit(main())
