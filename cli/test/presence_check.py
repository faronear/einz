#!/usr/bin/env python3
# 在线状态回归（老板 2026-09-16 实测）：同一身份的第二条通道 ≠ 对方
#
#   场景：A 创建空间（Lukas，伴侣 Alice 尚未加入）→ A 的第二条通道 C 用**同一身份**
#   Lukas 加入 → 两台 TUI 都把尚未加入的对方显示成绿灯在线。
#   根因：在线状态按 device 判定、却按 partner 展示——同一 partner 的新 device 被当成"对方"。
#
#   断言（抓 pty 真实渲染的标题栏最后一帧）：
#     ① A/C 两台 TUI：对方始终是 ○（离线），不得出现 "● Alice"（绿灯 + 对方名）；
#     ② 我的多通道计数生效：两台右段都显示 "#1/1"（其它通道 = 1 台，它在线；本机那台
#        由 "@通道名" 表示、不参与这对数字——老板 2026-09-16 改版）；
#     ③ 正控制：真正的第二人 B（Alice）加入后，A/C 显示 "● Alice"（绿灯没被改坏）。
#
#   附带覆盖（老板 2026-09-16 修复）：**对方尚未加入**时左段也要显示对方名字——
#   create 录入的伴侣预置名落盘 store.peer_name 兜底（此前是只读不写的死变量
#   peerPresetName，恒为 null → 一直显示 '-'）。
#
# 运行：cd server && npm run build（本用例跑 dist）&& python3 cli/test/presence_check.py
import fcntl
import json
import os
import pty
import select
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import time
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CLI = os.path.join(ROOT, 'cli')
WORK = tempfile.mkdtemp(prefix='einz-presence-')
PASSPHRASE = 'einzpass2026'
# 全屏重绘的清屏序列（TUI 每次全量渲染都以它开头）——据此切出"最后一帧"
CLEAR_HOME = b'\x1b[2J\x1b[3J\x1b[H'
ANSI = __import__('re').compile(r'\x1b\[[0-9;]*[A-Za-z]')
_TAILS = {}  # 每个 pty 尚未闭合的帧尾巴（留到下次拼接）


def free_port():
    s = socket.socket()
    s.bind(('127.0.0.1', 0))
    port = s.getsockname()[1]
    s.close()
    return port


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


def wait_text(master, text, timeout=60):
    out = ''
    deadline = time.time() + timeout
    while text not in out and time.time() < deadline:
        out += strip_ansi(drain(master, 0.8).decode('utf-8', errors='replace'))
    return out


def start_tui(store, port, cols=130, rows=30):
    master, slave = pty.openpty()
    # 默认 80 列会截断右段的「#n/m#通道名」（每段上限 = 全宽 1/3 - 1）
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
    env = dict(os.environ, TERM='xterm-256color')
    p = subprocess.Popen(
        ['dart', 'run', 'bin/einz_tui.dart', '--store', store,
         '--server', f'http://127.0.0.1:{port}'],
        stdin=slave, stdout=slave, stderr=slave, close_fds=True, cwd=CLI, env=env)
    os.close(slave)
    return master, p


def snapshot(master, wait=0.5):
    """取当前最后一帧（去色文本）；还没有完整帧时返回 ''。

    TUI 只在**状态变化**时全量重绘（敲空回车只重绘输入行）→ 不能靠"戳一戳"取屏，
    只能持续收流、按清屏序列切分：最后一段是写了一半的尾巴（留存拼接），从倒数
    第二段往回找第一个像样的帧（含标题栏 "Einz TUI"）。
    """
    raw = _TAILS.get(master, b'') + drain(master, wait)
    parts = raw.split(CLEAR_HOME)
    _TAILS[master] = parts[-1]
    for part in reversed(parts[:-1]):
        text = strip_ansi(part.decode('utf-8', errors='replace'))
        if 'Einz TUI' in text:
            return text
    return ''


def title_bar(frame):
    """从一帧里取出标题栏那一行（含品牌名 Einz TUI），去首尾空白。

    标题栏三段：左 = 对方「灯 名字 #n/m#通道名」、中 = 品牌名、右 = 我。
    直接断言整行里的子串会把两段混在一起（左段 "○ Alice" 与右段 "● Lukas" 都可
    误命中 "● …"），故按行取、再按 "Einz TUI" 切三段判定。
    """
    for line in frame.splitlines():
        if 'Einz TUI' in line:
            return line.strip()
    return ''


def split_bar(bar):
    """标题栏三段 → (左, 中, 右)。以品牌名 "Einz TUI" 为界切分。"""
    if 'Einz TUI' not in bar:
        return '', '', ''
    left, rest = bar.split('Einz TUI', 1)
    return left.strip(), 'Einz TUI', rest.strip()


def wait_screen(master, cond, what, timeout=70):
    deadline = time.time() + timeout
    text = ''
    while time.time() < deadline:
        frame = snapshot(master)
        if frame:
            text = frame
            if cond(text):
                return text
        time.sleep(1.0)
    print(f'FAIL: 超时未等到「{what}」。最后一屏:\n{text[-900:]}')
    sys.exit(1)


def finish_onboarding(master, label):
    """入网收尾：锁屏码（空回车跳过）→ 欢迎辞倒计时 6s → 自动进聊天态。"""
    deadline = time.time() + 40
    text = ''
    while time.time() < deadline:  # ① 锁屏码询问：空回车跳过，直到欢迎辞出现
        send(master, '\r')
        text = snapshot(master, wait=1.0)
        if '一切就绪' in text:
            break
        time.sleep(1.0)
    else:
        print(f'FAIL {label}: 未等到欢迎辞倒计时（锁屏码没跳过？）:\n{text[-900:]}')
        sys.exit(1)
    deadline = time.time() + 40  # ② 倒计时结束 → system 消息清空 = 进入聊天态
    while time.time() < deadline:
        text = snapshot(master, wait=1.0)
        if 'Einz TUI' in text and '一切就绪' not in text:
            return text
        time.sleep(1.0)
    print(f'FAIL {label}: 未进入聊天态:\n{text[-900:]}')
    sys.exit(1)


def join_flow(label, store, port, token, identity):
    """加入流程：J → 邀请码 → 完整名字选身份 → 口令 → 加入成功。"""
    master, p = start_tui(store, port)
    if '创建秘境' not in wait_text(master, '创建秘境'):
        print(f'FAIL {label}: 未等到创建/加入选择')
        sys.exit(1)
    send(master, 'J\r')
    wait_text(master, '输入开通码')
    send(master, token + '\r')
    out = wait_text(master, '完整输入我的名字')
    if '完整输入我的名字' not in out:
        print(f'FAIL {label}: 未等到身份选择（加入失败？）:\n{out[-600:]}')
        sys.exit(1)
    send(master, identity + '\r')
    wait_text(master, '验证共享口令')
    send(master, PASSPHRASE + '\r')
    if '成功加入秘境' not in wait_text(master, '成功加入秘境'):
        print(f'FAIL {label}: 加入未成功')
        sys.exit(1)
    print(f'{label}: 加入成功')
    return master, p


def new_join_token(port, store_path):
    """用空间成员会话签发一次性加入凭证（需 Bearer + 协议版本头）。"""
    with open(store_path) as f:
        store = json.load(f)
    req = urllib.request.Request(
        f'http://127.0.0.1:{port}/spaces/{store["space_id"]}/join-tokens',
        method='POST',
        headers={'Authorization': 'Bearer ' + store['session_token'],
                 'X-Protocol-Version': '1'})
    with urllib.request.urlopen(req, timeout=5) as r:
        return json.load(r)['joinToken']


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
        for _ in range(60):
            try:
                urllib.request.urlopen(f'http://127.0.0.1:{port}/health', timeout=1)
                break
            except Exception:
                time.sleep(0.3)
        else:
            print('FAIL: server 未就绪（先在 server/ 跑 npm run build）')
            sys.exit(1)

        # ---------- A：创建空间（我 Lukas / 伴侣 Alice）----------
        store_a = os.path.join(WORK, 'a.json')
        m_a, p_a = start_tui(store_a, port)
        spawned += [p_a]
        if '创建秘境' not in wait_text(m_a, '创建秘境'):
            print('FAIL A: 未等到创建/加入选择')
            sys.exit(1)
        send(m_a, 'C\r')
        wait_text(m_a, '我的名字')
        send(m_a, 'Lukas\r')
        wait_text(m_a, '我的性别')
        send(m_a, '1\r')
        wait_text(m_a, '伴侣的名字')
        send(m_a, 'Alice\r')
        wait_text(m_a, '伴侣的性别')
        send(m_a, '2\r')
        wait_text(m_a, '设置共享口令')
        send(m_a, PASSPHRASE + '\r')
        if '成功创建秘境' not in wait_text(m_a, '成功创建秘境'):
            print('FAIL A: 空间创建未成功')
            sys.exit(1)
        finish_onboarding(m_a, 'A')
        print('A: 空间创建完成并进入聊天态')

        # 基线：只有 A 一条通道 → 右段无 #n/m（我的其它通道 0 台，整段省略）；
        # 对方未加入 → 左段 "○ Alice"（create 录入的伴侣预置名；partner 表里查不到他）
        text = wait_screen(m_a, lambda t: '○ Alice' in t or '● Alice' in t,
                           'A 进入稳定态（左段显示对方名字）')
        left, _, right = split_bar(title_bar(text))
        if '● Alice' in left:
            print('FAIL 基线: A 只有一条通道时对方就显示在线:\n', text[-600:])
            sys.exit(1)
        if left != '○ Alice':
            print(f'FAIL 基线: 对方未加入时左段应为「○ Alice」（预置名兜底），实际「{left}」:\n',
                  text[-600:])
            sys.exit(1)
        if '#' in right:
            print(f'FAIL 基线: A 只有一条通道时右段不该有通道计数，实际「{right}」:\n',
                  text[-600:])
            sys.exit(1)
        print(f'A: 基线通过（左段 {left}、右段 {right} 无计数）')

        # 附（老板 2026-09-16）：对方未加入时 partner 表里没有他，"/myname 不许与对方
        # 同名"的判据也要算上预置名（否则我能改成和伴侣预置名一样，加入时撞同名）
        send(m_a, '/myname Alice\r')
        wait_screen(m_a, lambda t: '名字不能与对方相同' in t,
                    'A 拒绝改成对方预置名 Alice')
        print('A: /myname Alice 被拒（判据含预置名）✓')
        # 正控制：不冲突的名字应改成功，再改回来（不影响后续右段名字断言）
        send(m_a, '/myname LukasX\r')
        wait_screen(m_a, lambda t: '我的名字已更新' in t, 'A 改名 LukasX')
        send(m_a, '/myname Lukas\r')
        wait_screen(m_a, lambda t: '我的名字已更新: LukasX → Lukas' in t, 'A 改回 Lukas')
        print('A: /myname LukasX → Lukas 正常 ✓（判据没误伤）')

        # ---------- C：A 的第二条通道（选同一身份 Lukas）----------
        store_c = os.path.join(WORK, 'c.json')
        m_c, p_c = join_flow('C', store_c, port, new_join_token(port, store_a), 'Lukas')
        spawned += [p_c]
        finish_onboarding(m_c, 'C')

        # ① ②：C 上线后两台右段都该显示 #1/1（我的另一条通道在线），且对方仍离线
        # （修复后同一人的通道上下线不再互推广播，A 要等下一次 30s 轮询才刷新计数）
        for label, m in (('C', m_c), ('A', m_a)):
            t = wait_screen(m, lambda t: '#1/1' in t or '● Alice' in t,
                            f'{label} 更新我的通道计数', timeout=90)
            left, _, right = split_bar(title_bar(t))
            if '● Alice' in left:
                print(f'FAIL {label}: 同身份通道上线后，尚未加入的对方被显示在线:\n', t[-600:])
                sys.exit(1)
            if left != '○ Alice':
                print(f'FAIL {label}: 尚未加入的对方应显示「○ Alice」（预置名兜底），实际「{left}」:\n',
                      t[-600:])
                sys.exit(1)
            if '#1/1' not in right:
                print(f'FAIL {label}: 右段应显示「#1/1」（我的另一条通道在线），实际「{right}」:\n',
                      t[-600:])
                sys.exit(1)
            print(f'{label}: #1/1 ✓ 且对方仍离线（○ Alice）✓')

        # ---------- ③ 正控制：真正的第二人 B（Alice）加入 → 双方应亮绿灯 ----------
        store_b = os.path.join(WORK, 'b.json')
        m_b, p_b = join_flow('B', store_b, port, new_join_token(port, store_a), 'Alice')
        spawned += [p_b]
        finish_onboarding(m_b, 'B')
        for label, m in (('A', m_a), ('C', m_c)):
            t = wait_screen(m, lambda t: '● Alice' in t, f'{label} 显示 ● Alice', timeout=60)
            left, _, _ = split_bar(title_bar(t))
            if not left.startswith('● Alice'):
                print(f'FAIL {label}: 对方 Alice 上线后左段应为「● Alice」，实际「{left}」:\n',
                      t[-600:])
                sys.exit(1)
            print(f'{label}: 对方 Alice 上线 → ● Alice ✓（绿灯未被改坏）')

        # ---------- ④ 对方改名 → 预置名快照要跟上（否则同名判据卡住旧名字）----------
        # B 把名字改成 Alicia：A/C 左段应跟着变；此后 "Alice" 这个名字已无人使用，
        # A 应该能改成它（判据里若还留着旧预置名 "Alice" 就会被误拒）。
        send(m_b, '/myname Alicia\r')
        if '我的名字已更新' not in wait_text(m_b, '我的名字已更新'):
            print('FAIL B: 改名 Alicia 未成功')
            sys.exit(1)
        for label, m in (('A', m_a), ('C', m_c)):
            t = wait_screen(m, lambda t: '● Alicia' in t, f'{label} 跟随对方改名', timeout=60)
            left, _, _ = split_bar(title_bar(t))
            if not left.startswith('● Alicia'):
                print(f'FAIL {label}: 对方改名后左段应为「● Alicia」，实际「{left}」:\n', t[-600:])
                sys.exit(1)
            print(f'{label}: 对方改名 → ● Alicia ✓')
        send(m_a, '/myname Alice\r')
        wait_screen(m_a, lambda t: '我的名字已更新: Lukas → Alice' in t,
                    'A 可以改用已空出的旧预置名 Alice')
        print('A: /myname Alice 成功 ✓（预置名快照已跟上改名，未误拒）')
        print('PASS: 多通道在线状态回归 4 项全过')
    finally:
        for p in spawned:
            try:
                p.kill()
            except Exception:
                pass
        if server:
            server.terminate()


if __name__ == '__main__':
    main()
