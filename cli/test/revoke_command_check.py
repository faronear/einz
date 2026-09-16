#!/usr/bin/env python3
# /devices 与 /revoke 回归（老板 2026-09-16）：
#   ① `/devices` 输出**同空间全部设备**（我 + 对方，不只自己的）：A 创建、B 以伴侣身份
#      加入后，A 的列表里应同时有「本机 A」和「在线 B」，并带序号（供 /revoke 使用）；
#   ② `/revoke` 三重确认（选设备 → 输入 yes → 密保口令）+ 口令校验：
#      - 口令错 → 提示且**目标毫发无损**（B 的 TUI 仍在跑、store 还在）；
#      - 正确口令 → 服务端撤销 → B 收到 device.revoked → **清空本地数据并退出**（store 被删）；
#   ③ 负例：不能撤销本机（拒绝后命令即结束，不会被后续输入喂成确认）；
#   ④ 撤销后 /devices 把该设备标为「已撤销」。
#
# 断言用**整帧**（snapshot：按清屏序列切出最后一屏）而不是原始流：消息区是从下往上
# 逐行定位重绘的，原始流里同一屏的行序是反的、且每屏重复出现，逐行解析会错。
#
# 运行：cd server && npm run build（本用例跑 dist）&& python3 cli/test/revoke_command_check.py
import fcntl, os, pty, re, select, socket, struct, subprocess, sys, tempfile, termios
import time, shutil, json, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CLI = f'{ROOT}/cli'
WORK = tempfile.mkdtemp(prefix='einz-revoke-cmd-')
PASSPHRASE = 'pass-123'
CREATOR = 'luk'
PARTNER = 'ali'
CLEAR_HOME = b'\x1b[2J\x1b[3J\x1b[H'
ANSI = re.compile(r'\x1b\[[0-9;]*[A-Za-z]')
ROW_POS = re.compile(r'\x1b\[(\d+);1H')  # TUI 逐行定位重绘的序列
_TAILS = {}

def free_port():
    s = socket.socket()
    s.bind(('127.0.0.1', 0))
    p = s.getsockname()[1]
    s.close()
    return p

def strip_ansi(s):
    return ANSI.sub('', s)

def drain(master, seconds=1.0):
    out = b''
    deadline = time.time() + seconds
    while time.time() < deadline:
        r, _, _ = select.select([master], [], [], 0.2)
        if r:
            try:
                out += os.read(master, 65536)
            except OSError:
                break
    return out

def send(master, s):
    os.write(master, s.encode())

def wait_text(master, text, timeout=40):
    """原始流匹配（引导阶段的问答提示用；与 snapshot 共用同一个流，靠 _TAILS 兜残留）。"""
    out = ''
    deadline = time.time() + timeout
    while text not in out and time.time() < deadline:
        out += strip_ansi(drain(master, 0.8).decode('utf-8', errors='replace'))
    return out

def start_tui(store, port, home=None, cols=130, rows=40):
    master, slave = pty.openpty()
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
    env = dict(os.environ, TERM='xterm-256color')
    if home:
        env['HOME'] = home
        env.setdefault('PUB_CACHE', os.path.expanduser('~/.pub-cache'))
    p = subprocess.Popen(
        ['dart', 'run', 'bin/einz_tui.dart', '--store', store,
         '--server', f'http://127.0.0.1:{port}'],
        stdin=slave, stdout=slave, stderr=slave, close_fds=True, cwd=CLI, env=env)
    os.close(slave)
    return master, p

def start_server(port, db_path):
    os.makedirs(os.path.dirname(db_path), exist_ok=True)
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

def frame_text(raw: bytes) -> str:
    """整帧 → 按**屏幕行**排好的纯文本。

    TUI 每行都用 `\\x1B[<row>;1H` 定位重绘：直接 strip_ansi 会把行间定位吞掉、把
    多行粘成一行（列表里两台设备挤在同一行 → 逐行解析序号必错）。这里先把定位序列
    换成换行，再去掉其余颜色码。"""
    s = ROW_POS.sub('\n', raw.decode('utf-8', errors='replace'))
    return strip_ansi(s)


def snapshot(master, wait=0.5):
    """取当前最后一帧（按屏幕行排好的纯文本）；还没有完整帧时返回 ''。"""
    raw = _TAILS.get(master, b'') + drain(master, wait)
    parts = raw.split(CLEAR_HOME)
    _TAILS[master] = parts[-1]
    for part in reversed(parts[:-1]):
        text = frame_text(part)
        if 'Einz TUI' in text:
            return text
    return ''

def wait_screen(master, cond, what, timeout=40):
    deadline = time.time() + timeout
    text = ''
    while time.time() < deadline:
        frame = snapshot(master)
        if frame:
            text = frame
            if cond(text):
                return text
        time.sleep(0.5)
    print(f'❌ 超时未等到「{what}」。最后一屏:\n{text[-1200:]}')
    raise SystemExit(1)

def finish_onboarding(master, label):
    """入网收尾：锁屏码（空回车跳过）→ 欢迎辞倒计时 → 自动进聊天态。"""
    deadline = time.time() + 40
    text = ''
    while time.time() < deadline:
        send(master, '\r')
        text = snapshot(master, wait=1.0)
        if '一切就绪' in text:
            break
        time.sleep(1.0)
    else:
        print(f'❌ {label}: 未等到欢迎辞倒计时'); print(text[-900:]); raise SystemExit(1)
    deadline = time.time() + 40
    while time.time() < deadline:
        text = snapshot(master, wait=1.0)
        if 'Einz TUI' in text and '一切就绪' not in text:
            return text
        time.sleep(1.0)
    print(f'❌ {label}: 未进入聊天态'); print(text[-900:]); raise SystemExit(1)

def wait_connected(master, name, timeout=30):
    """等 WS 连上：标题栏右段出现「● <我的名字>」（未连上是 ○，连接中是 ↻/✗）。

    刻意用**整帧**判定而不是原始流里的绿色码：整帧由 snapshot 取（流已被前面的
    snapshot 轮询消费过），再去掉颜色码后凭「● 名字」判定，不存在"红点亮过但那一段
    流已经被读走"的竞态。"""
    deadline = time.time() + timeout
    frame = ''
    while time.time() < deadline:
        frame = snapshot(master, wait=1.0)
        if frame and '● %s' % name in frame:
            return frame
        time.sleep(0.5)
    print(f'❌ 未等到 WS 连上（标题栏应出现「● {name}」）:\n{frame[-900:]}')
    raise SystemExit(1)

def onboard_create(label, store, port, home):
    m, p = start_tui(store, port, home)
    for expect, payload in [
        ('秘境入口', 'c\r'),
        ('我的名字', f'{CREATOR}\r'),
        ('我的性别', '1\r'),
        ('伴侣的名字', f'{PARTNER}\r'),
        ('伴侣的性别', '2\r'),
    ]:
        out = wait_text(m, expect, timeout=30)
        if expect not in out:
            print(f'❌ {label}: 未到「{expect}」问答'); print(out[-600:]); raise SystemExit(1)
        send(m, payload)
    if '设置密保口令' not in wait_text(m, '设置密保口令', timeout=30):
        print(f'❌ {label}: 未到口令问答'); raise SystemExit(1)
    send(m, PASSPHRASE + '\r')
    finish_onboarding(m, label)
    wait_connected(m, CREATOR)
    print(f'✅ {label}: 创建并进入聊天态（WS 已连接）')
    return m, p

def onboard_join(label, store, port, token, home):
    m, p = start_tui(store, port, home)
    if '创建秘境' not in wait_text(m, '创建秘境', timeout=30):
        print(f'❌ {label}: 未等到入口'); raise SystemExit(1)
    send(m, 'j\r')
    wait_text(m, '输入邀请码', timeout=20)
    send(m, token + '\r')
    out = wait_text(m, '我是谁', timeout=20)
    if '我是谁' not in out:
        print(f'❌ {label}: 未到身份选择'); print(out[-600:]); raise SystemExit(1)
    send(m, PARTNER + '\r')
    wait_text(m, '验证密保口令', timeout=20)
    send(m, PASSPHRASE + '\r')
    if '成功加入秘境' not in wait_text(m, '成功加入秘境', timeout=30):
        print(f'❌ {label}: 加入未成功'); raise SystemExit(1)
    finish_onboarding(m, label)
    wait_connected(m, PARTNER)  # 等 B 的 WS 连上，A 侧才会看到它"在线"
    print(f'✅ {label}: 已加入并进入聊天态（WS 已连接）')
    return m, p

def http(port, method, path, body=None, token=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f'http://127.0.0.1:{port}{path}', data=data, method=method)
    req.add_header('Content-Type', 'application/json')
    req.add_header('X-Protocol-Version', '1')
    if token:
        req.add_header('Authorization', f'Bearer {token}')
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.load(r)

def new_join_token(port, store_path):
    st = json.load(open(store_path))
    return http(port, 'POST', f'/spaces/{st["space_id"]}/join-tokens',
                token=st['session_token'])['joinToken']

def parse_row_numbers(frame):
    """从设备列表帧里解析 (我的序号, 对方序号)。行形如 `  2) 🟢 DoomBase [ali] 在线 ...`。"""
    my_no = partner_no = None
    for line in frame.splitlines():
        m_no = re.match(r'\s*(\d+)\)', line)
        if not m_no:
            continue
        if '[%s]' % PARTNER in line:
            partner_no = int(m_no.group(1))
        elif '本机' in line:
            my_no = int(m_no.group(1))
    return my_no, partner_no

def main():
    port = free_port()
    server = None
    spawned = []
    try:
        server = start_server(port, f'{WORK}/db/einz.sqlite.db')
        store_a, store_b = f'{WORK}/a.json', f'{WORK}/b.json'
        m_a, p_a = onboard_create('A', store_a, port, WORK)
        spawned.append((m_a, p_a))

        # ---------- ① /devices：同空间全部设备（先只有自己） ----------
        send(m_a, '/devices\r')
        frame = wait_screen(m_a, lambda t: '设备列表' in t, 'A 的设备列表')
        if '同空间 1 台' not in frame or '本机' not in frame:
            print(f'❌ ① 只有 A 时应为 1 台且标「本机」:\n{frame[-800:]}'); return 1

        m_b, p_b = onboard_join('B', store_b, port, new_join_token(port, store_a), WORK)
        spawned.append((m_b, p_b))
        time.sleep(2.0)  # 等 A 侧刷新在线状态与名称表

        send(m_a, '/devices\r')
        frame = wait_screen(m_a,
                            lambda t: '同空间 2 台' in t and '在线' in t,
                            'A 看到同空间 2 台（含对方）')
        my_no, partner_no = parse_row_numbers(frame)
        if my_no is None or partner_no is None:
            print(f'❌ ① 未能解析序号（本机={my_no} 对方={partner_no}）:\n{frame[-900:]}'); return 1
        if '[%s]' % PARTNER not in frame:
            print(f'❌ ① 列表应含对方 person「{PARTNER}」:\n{frame[-900:]}'); return 1
        print(f'✅ ① /devices 列出同空间 2 台（本机 #{my_no}、对方 #{partner_no} 在线、带序号）')

        # ---------- ② 口令错 → 撤销不生效（目标毫发无损） ----------
        send(m_a, f'/revoke {partner_no}\r')
        frame = wait_screen(m_a, lambda t: '确认请输入 yes' in t, '撤销二次确认')
        if '清空本地数据' not in frame:
            print(f'❌ ② 确认提示应写明不可逆后果:\n{frame[-900:]}'); return 1
        send(m_a, 'yes\r')
        wait_screen(m_a, lambda t: '输入密保口令' in t, '撤销要求密保口令')
        send(m_a, 'wrong-passphrase\r')
        frame = wait_screen(m_a, lambda t: '密保口令错误' in t, '口令错提示')
        if '目标设备毫发无损' not in frame:
            print(f'❌ ② 口令错应说明目标未受影响:\n{frame[-900:]}'); return 1
        time.sleep(2.0)
        if p_b.poll() is not None:
            print('❌ ② 口令错却把对方撤销了（B 已退出）'); return 1
        if not os.path.exists(store_b):
            print('❌ ② 口令错却清掉了对方的本地数据'); return 1
        print('✅ ② 口令错 → 提示且目标毫发无损（B 仍在运行、store 仍在）')

        # ---------- ③ 不能撤销本机（且命令立即结束，不吃后续输入） ----------
        send(m_a, f'/revoke {my_no}\r')
        frame = wait_screen(m_a, lambda t: '不能撤销本机' in t, '拒绝撤销本机')
        send(m_a, '/devices\r')
        frame = wait_screen(m_a, lambda t: '设备列表' in t and '同空间 2 台' in t,
                            '③ 后仍能正常执行命令')
        print('✅ ③ /revoke 本机 → 拒绝（未进入确认流程，命令已结束）')

        # ---------- ④ 正确口令 → 撤销生效：对方清空本地数据并退出 ----------
        send(m_a, '/revoke\r')  # 无参：走"列出设备 → 询问序号"的交互路径
        wait_screen(m_a, lambda t: '输入要撤销的设备序号' in t, '无参 /revoke 询问序号')
        send(m_a, f'{partner_no}\r')
        wait_screen(m_a, lambda t: '确认请输入 yes' in t, '④ 二次确认')
        send(m_a, 'yes\r')
        wait_screen(m_a, lambda t: '输入密保口令' in t, '④ 口令输入')
        send(m_a, PASSPHRASE + '\r')
        frame = wait_screen(m_a, lambda t: f'已撤销 #{partner_no}' in t, '④ 撤销成功')
        deadline = time.time() + 20
        while time.time() < deadline and p_b.poll() is None:
            drain(m_b, 0.5)
        if p_b.poll() is None:
            p_b.kill()
            print('❌ ④ 被撤销的 B 未自动退出'); return 1
        if os.path.exists(store_b):
            print('❌ ④ 被撤销的 B 未清空本地数据（store 仍在）'); return 1
        print('✅ ④ 正确口令 → 撤销生效：B 清空本地数据并退出')

        # ---------- ⑤ 撤销后列表标注「已撤销」 ----------
        send(m_a, '/devices\r')
        frame = wait_screen(m_a, lambda t: '设备列表' in t and '已撤销' in t, '列表标注已撤销')
        print('✅ ⑤ 撤销后 /devices 把该设备标为「已撤销」')

        send(m_a, '/exit\r')
        time.sleep(1.5)
        if p_a.poll() is None:
            p_a.kill()
        print('🎉 /devices 与 /revoke 全部通过')
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
