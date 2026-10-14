#!/usr/bin/env python3
# 启动锁屏码解锁回归（老板 2026-10-13 重构 + bug 根因修复）：
#
# 被测行为（cli/bin/einz_tui.dart _unlockPin）：
#   ① 只认两种输入：输入内容 = 当 PIN 校验（错误重试）；直接回车 = 退出整个 TUI；
#   ② 这一步**不识别 /exit 等命令**——敲 /exit 只是错码，绝不禁令退出整个 TUI；
#   ③ PIN **不明文回显**（输入行回显 *）；
#   ④ bug 根因：中止（空回车/EOF）后**绝不**加载或渲染历史——旧实现中止后 main
#      不检查 running，把没验证的历史全屏渲染出来，再因输入循环吞掉所有按键挂死，
#      只能强杀进程。本用例断言"退出必须真的发生（进程消失、退出码 0）"。
#   ⑤ 身份零泄露（老板 2026-10-13 追加）：锁屏码验证通过前，标题栏/状态栏**只显示
#      产品名 Einz**——对方/我的名字、通道、WS 状态灯、命令提示一概不上屏；
#      解锁成功后恢复正常（场景 G）。
#
# 环境说明（断言口径的来源，改断言前先读）：
#   - 无需服务端（用不可达端口，走离线路径）；store 用 demo/store-a.json 的副本
#     （已绑定空间，跳过入网向导，直接到解锁/聊天态）。
#   - **不断言告别语**：main 收尾 `exit(0)` 与 stderr 异步 sink 竞速，pty 下
#     「已退出 Einz」稳定丢失（既有行为，与本次改动无关）——只断言进程退出码。
#   - **不测 Ctrl+C**：本 pty  harness 无控制终端，字节 3 被行规丢弃；补上
#     setsid+TIOCSCTTY 后也是内核 SIGINT 直接杀进程（不到应用代码）——空回车
#     场景走的是同一条 exitNow 退出序列，已覆盖。
#   - 输入用「反复重发直到落地」：启动后不久有 _busy 窗口（processing=true 时
#     输入循环吞按键——与 cliMultiverseE2E 的 send_when_ready 同一契约）。
#
# 运行：python3 cli/test/unlock_flow_check.py
import fcntl, json, os, pty, re, select, shutil, socket, struct, subprocess, sys, tempfile, termios, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CLI = f'{ROOT}/cli'
DEMO_STORE = f'{CLI}/demo/store-a.json'
PIN = '123456'
WRONG_PIN = '999999'
ANSI = re.compile(r'\x1b\[[0-9;?]*[A-Za-z]')
CHAT_READY = '机密线路激活失败'  # 离线路径的确定性信号：_busy 已结束、进入聊天态
UNLOCK_PROMPT = '输入锁屏码'
UNLOCK_ERROR = '锁屏码验证错误'
PIN_SET = '锁屏码已设置'
PIN_OK = '锁屏码验证成功'
# 场景 G：可辨身份信息（setup 预置进 store）与状态灯字符（解锁前一个都不能出现）
FAKE_NAME = 'Alice'
FAKE_ENTRANCE = '本机通道'
STATUS_DOTS = '●○↻✗⊘'
CHAT_HINT = '/help 查看命令'

WORK = tempfile.mkdtemp(prefix='einz-unlock-')
OUT = ''   # 当前场景的累积输出（ANSI 剥离）
RAW = b''  # 当前场景的累积原始输出（按清屏序列切帧用）


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
                d = os.read(master, 65536)
            except OSError:
                break
            if not d:
                break
            out += d
    return out


def send(master, s):
    try:
        os.write(master, s.encode())
    except OSError:
        pass  # 进程已退出：写 master 无意义


def consume(master, seconds=1.0):
    """读一段输出，同时累积进 OUT（剥离 ANSI）与 RAW（原始，切帧用）。"""
    global OUT, RAW
    raw = drain(master, seconds)
    RAW += raw
    seg = strip_ansi(raw.decode('utf-8', errors='replace'))
    OUT += seg
    return seg


def wait_text(master, text, timeout=40):
    """读输出直到 text 出现（累积进 OUT）；返回 OUT。
    先读一轮再判断——即使 text 已在 OUT 中也会消费新输出（调用方依赖这一点）。"""
    global OUT
    deadline = time.time() + timeout
    while True:
        consume(master, 0.8)
        if text in OUT or time.time() >= deadline:
            return OUT


def wait_count_grow(master, expect, base, timeout=15):
    """等待 expect 的出现次数超过 base（不发送任何输入——type_line 已发完）。"""
    global OUT
    deadline = time.time() + timeout
    while time.time() < deadline and OUT.count(expect) <= base:
        consume(master, 0.4)
    return OUT.count(expect) > base


def type_line(master, text, delay=0.15):
    """逐字符输入一行再回车——模拟真人按键（整串一次性写入时，回车与字符同属一个
    chunk，提交即清空输入，* 掩码来不及渲染；逐字符才有每键反馈）。"""
    for ch in text:
        send(master, ch)
        time.sleep(delay)
    send(master, '\r')


def send_until(master, line, expect, tries=10, per_try=4):
    """反复发送 line（带回车）直到 expect 的**出现次数增长**——应对 busy 吞按键。
    按计数增长判断（而非"文本出现过"）：expect 可能早已在 OUT 里（如状态条文案）。"""
    global OUT
    base = OUT.count(expect)
    for _ in range(tries):
        send(master, f'{line}\r')
        deadline = time.time() + per_try
        while time.time() < deadline and OUT.count(expect) <= base:
            consume(master, 0.4)
        if OUT.count(expect) > base:
            return True
    return OUT.count(expect) > base


def send_until_exit(master, p, line, tries=6):
    """反复发送 line（带回车）直到进程退出——应对 busy 吞按键。
    聊天态不能用 send_until：状态条每帧都渲染 '/exit 退出系统'，计数会被充气。"""
    for _ in range(tries):
        if p.poll() is not None:
            return True
        send(master, f'{line}\r')
        time.sleep(1.5)
    return p.poll() is not None


def wait_exit(p, master, timeout=20):
    deadline = time.time() + timeout
    while time.time() < deadline and p.poll() is None:
        drain(master, 0.3)
    return p.poll()


def start_tui(store, port):
    master, slave = pty.openpty()
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 130, 0, 0))
    env = dict(os.environ, TERM='xterm-256color')
    p = subprocess.Popen(
        ['dart', 'run', 'bin/einz_tui.dart', '--store', store,
         '--server', f'http://127.0.0.1:{port}'],
        stdin=slave, stdout=slave, stderr=slave, close_fds=True, cwd=CLI, env=env)
    os.close(slave)
    return master, p


def answer_server_prompt(master):
    """不可达服务器 → _onboard 追问地址；回车沿用（在解锁提示之前，仅此一次）。"""
    wait_text(master, '输入新服务器地址', timeout=90)
    if '输入新服务器地址' not in OUT:
        print('❌ 未出现服务器地址追问（启动流程变化？）')
        print(OUT[-800:])
        sys.exit(1)
    send(master, '\r')


def grab_frame(master, seconds=1.0):
    """取**当前稳定帧**（最近一次全量重绘的整屏内容，ANSI 剥离）。
    无输入/无消息时 TUI 不重绘——不能靠"新输出"取帧；改为从累积原始输出
    RAW 里按清屏序列（\x1b[2J，见 _clearHome）切最后一帧。返回帧文本
    （OUT 早已累积过这些字节，这里不重复加）。"""
    consume(master, seconds)
    parts = RAW.split(b'\x1b[2J')
    return strip_ansi(parts[-1].decode('utf-8', errors='replace'))


def make_store():
    path = f'{WORK}/pin-store.json'
    shutil.copy(DEMO_STORE, path)
    return path


def make_named_store():
    """带可辨身份的 store（场景 G）：预置我的名字 + 通道名 + entrance_id——
    解锁前这些一个字节都不能上屏；解锁后我的名字应恢复显示。"""
    path = f'{WORK}/named-store.json'
    shutil.copy(DEMO_STORE, path)
    with open(path) as f:
        data = json.load(f)
    data['member_name'] = FAKE_NAME
    data['entrance_name'] = FAKE_ENTRANCE
    with open(path, 'w') as f:
        json.dump(data, f)
    return path


def setup_pin_store(port):
    """首启（无 PIN）：/pin 123456 设置锁屏码，再 /exit——供后续解锁场景复用。"""
    global OUT
    OUT = ''
    RAW = b''
    store = make_store()
    master, p = start_tui(store, port)
    try:
        answer_server_prompt(master)
        wait_text(master, CHAT_READY, timeout=90)
        if CHAT_READY not in OUT:
            print('❌ 设置阶段未进入聊天态')
            print(OUT[-800:])
            sys.exit(1)
        if not send_until(master, '/pin 123456', PIN_SET):
            print('❌ /pin 设置锁屏码失败')
            print(OUT[-800:])
            sys.exit(1)
        print('✅ 准备阶段：/pin 123456 设置成功')
        send_until_exit(master, p, '/exit')
        code = wait_exit(p, master)
        if code is None:
            print('❌ 设置阶段 /exit 后进程未退出')
            sys.exit(1)
        print(f'✅ 准备阶段：/exit 正常退出（code={code}）')
        return store
    finally:
        if p.poll() is None:
            p.kill()
        try:
            os.close(master)
        except OSError:
            pass


def scenario_wrong_and_exit_command(store, port):
    """错码重试 → /exit 只是错码（不退出）→ 正确 PIN → 进聊天态 → /exit。"""
    global OUT
    OUT = ''
    RAW = b''
    master, p = start_tui(store, port)
    try:
        answer_server_prompt(master)
        wait_text(master, UNLOCK_PROMPT, timeout=90)
        if UNLOCK_PROMPT not in OUT:
            print('❌ 未出现锁屏码解锁提示')
            print(OUT[-800:])
            return False
        print('✅ 场景 A：出现解锁提示「输入锁屏码（直接回车退出）」')

        # ① 错误 PIN（逐字符，掩码随按键增长）→ 验证错误重试，进程必须还在
        type_line(master, WRONG_PIN)
        if not wait_count_grow(master, UNLOCK_ERROR, OUT.count(UNLOCK_ERROR)):
            print('❌ 错误 PIN 未见「验证错误」提示')
            print(OUT[-800:])
            return False
        if p.poll() is not None:
            print('❌ 错误 PIN 后进程竟退出了')
            return False
        print('✅ 场景 A：错误 PIN → 「验证错误，请重新输入」且进程存活')

        # ② /exit 在解锁步**不识别**：按错码处理——错误计数必须增长，进程必须还在
        before = OUT.count(UNLOCK_ERROR)
        type_line(master, '/exit')
        if not wait_count_grow(master, UNLOCK_ERROR, before):
            print('❌ /exit 未被当作一次错误尝试处理')
            print(OUT[-800:])
            return False
        if p.poll() is not None:
            print('❌ /exit 在解锁步被当成退出命令了（回归！）')
            return False
        print('✅ 场景 A：/exit 只是错码（不退出、按错误尝试计）')

        # ③ PIN 不明文回显：错码与 /exit 原文都不能出现在输出里，* 掩码必须出现
        if WRONG_PIN in OUT:
            print(f'❌ PIN 被明文回显了（输出含 {WRONG_PIN}）')
            return False
        if '/exit' in OUT:
            print('❌ 输入行未隐藏（输出含 /exit 原文）')
            return False
        if '*' * 6 not in OUT:
            print('❌ 未见 * 掩码回显')
            print(OUT[-800:])
            return False
        print('✅ 场景 A：PIN 不明文回显（* 掩码）')

        # ④ 正确 PIN → 验证成功（仍不明文回显）
        type_line(master, PIN)
        if not wait_count_grow(master, PIN_OK, 0):
            print('❌ 正确 PIN 未见验证成功')
            print(OUT[-800:])
            return False
        if PIN in OUT:
            print(f'❌ 正确 PIN 也被明文回显了（输出含 {PIN}）')
            return False
        print('✅ 场景 A：正确 PIN → 验证成功（不明文回显）')

        # ⑤ 聊天态 /exit → 正常退出
        send_until_exit(master, p, '/exit')
        code = wait_exit(p, master)
        if code is None:
            print('❌ 聊天态 /exit 后进程未退出')
            return False
        print(f'✅ 场景 A：聊天态 /exit 正常退出（code={code}）')
        return True
    finally:
        if p.poll() is None:
            p.kill()
        try:
            os.close(master)
        except OSError:
            pass


def scenario_empty_enter_exits(store, port):
    """解锁提示直接回车 → 退出整个 TUI（必须真的退出，不挂死、不渲染历史）。"""
    global OUT
    OUT = ''
    RAW = b''
    master, p = start_tui(store, port)
    try:
        answer_server_prompt(master)
        wait_text(master, UNLOCK_PROMPT, timeout=90)
        if UNLOCK_PROMPT not in OUT:
            print('❌ 未出现锁屏码解锁提示')
            print(OUT[-800:])
            return False
        send(master, '\r')  # 直接回车 = 退出整个 TUI
        code = wait_exit(p, master, timeout=25)
        if code is None:
            print('❌ 空回车后进程未退出（挂死回归！旧 bug 正是如此）')
            return False
        # 历史消息绝不能被渲染：聊天态标志（/help 状态条）不应出现
        if '/help 查看命令' in OUT:
            print('❌ 未验证就渲染了聊天态（历史泄漏回归！）')
            return False
        print(f'✅ 场景 B：空回车 → 直接退出整个 TUI（code={code}，无历史渲染）')
        return True
    finally:
        if p.poll() is None:
            p.kill()
        try:
            os.close(master)
        except OSError:
            pass


def scenario_eof_exits(store, port):
    """解锁提示期 stdin EOF（关 master）→ 退出（onDone 释放问答等待，不挂死）。"""
    global OUT
    OUT = ''
    RAW = b''
    master, p = start_tui(store, port)
    try:
        answer_server_prompt(master)
        wait_text(master, UNLOCK_PROMPT, timeout=90)
        if UNLOCK_PROMPT not in OUT:
            print('❌ 未出现锁屏码解锁提示')
            print(OUT[-800:])
            return False
        os.close(master)  # EOF：终端关闭/重定向的模拟
        deadline = time.time() + 25
        while time.time() < deadline and p.poll() is None:
            time.sleep(0.3)
        code = p.poll()
        if code is None:
            print('❌ EOF 后进程未退出（挂死回归！）')
            p.kill()
            return False
        print(f'✅ 场景 D：EOF → 退出（code={code}）')
        return True
    finally:
        if p.poll() is None:
            p.kill()
        try:
            os.close(master)
        except OSError:
            pass


def scenario_switch_gate(pin_store, port):
    """会话内 /switch 到有 PIN 的目标：错码重试、空回车取消、/exit 不退出（统一策略）。"""
    global OUT
    OUT = ''
    RAW = b''
    plain_store = f'{WORK}/plain-store.json'  # 无 PIN 的运行中会话（当前空间）
    shutil.copy(DEMO_STORE, plain_store)
    master, p = start_tui(plain_store, port)
    try:
        answer_server_prompt(master)
        wait_text(master, CHAT_READY, timeout=90)
        if CHAT_READY not in OUT:
            print('❌ 场景 E：未进入聊天态')
            print(OUT[-800:])
            return False
        # /switch 到有 PIN 的目标 → 目标秘境锁屏码提示（隐藏回显）
        if not send_until(master, f'/switch {pin_store}', '目标秘境锁屏码'):
            print('❌ 场景 E：/switch 后未见目标锁屏码提示')
            print(OUT[-800:])
            return False
        print('✅ 场景 E：/switch 出现「目标秘境锁屏码」提示')

        # ① 错误 PIN → 验证错误重试，进程还在
        type_line(master, WRONG_PIN)
        if not wait_count_grow(master, '锁屏码验证错误', OUT.count('锁屏码验证错误')):
            print('❌ 场景 E：错误 PIN 未见重试提示')
            print(OUT[-800:])
            return False
        if p.poll() is not None:
            print('❌ 场景 E：错误 PIN 后进程竟退出了')
            return False
        print('✅ 场景 E：/switch 错误 PIN → 重试且进程存活')

        # ② /exit 在这里也不认（按错误尝试），进程还在
        before = OUT.count('锁屏码验证错误')
        type_line(master, '/exit')
        if not wait_count_grow(master, '锁屏码验证错误', before):
            print('❌ 场景 E：/exit 未被当作错误尝试')
            print(OUT[-800:])
            return False
        if p.poll() is not None:
            print('❌ 场景 E：/exit 在锁屏码验证步被当成退出命令了（回归！）')
            return False
        print('✅ 场景 E：/exit 只是错码（不退出）')

        # ③ 不明文回显 + 空回车 = 取消切换（未做任何改动），进程还在
        if WRONG_PIN in OUT:
            print(f'❌ 场景 E：PIN 被明文回显了（输出含 {WRONG_PIN}）')
            return False
        send(master, '\r')
        if not wait_count_grow(master, '已取消切换', 0):
            print('❌ 场景 E：空回车未见「已取消切换」')
            print(OUT[-800:])
            return False
        if p.poll() is not None:
            print('❌ 场景 E：取消切换后进程竟退出了')
            return False
        print('✅ 场景 E：PIN 不明文回显；空回车 = 取消切换（进程存活）')

        # ④ 原会话照常可用：/exit 正常退出
        send_until_exit(master, p, '/exit')
        code = wait_exit(p, master)
        if code is None:
            print('❌ 场景 E：取消切换后 /exit 未退出')
            return False
        print(f'✅ 场景 E：原会话照常，/exit 正常退出（code={code}）')
        return True
    finally:
        if p.poll() is None:
            p.kill()
        try:
            os.close(master)
        except OSError:
            pass


def scenario_reset_gate(pin_store, port):
    """/reset 的本机锁屏码闸门：错码 → 拒绝且不做任何改动；/exit 也不退出（统一策略）。"""
    global OUT
    OUT = ''
    RAW = b''
    master, p = start_tui(pin_store, port)
    try:
        answer_server_prompt(master)
        wait_text(master, UNLOCK_PROMPT, timeout=90)
        if not send_until(master, PIN, PIN_OK):
            print('❌ 场景 F：解锁失败')
            print(OUT[-800:])
            return False
        wait_text(master, CHAT_READY, timeout=60)
        # /reset 闸门①：通道名（demo store 无名字 → 固定确认词 RESET）
        if not send_until(master, '/reset', 'RESET'):
            print('❌ 场景 F：/reset 未见确认词提示')
            print(OUT[-800:])
            return False
        send_until(master, 'RESET', '输入本机锁屏码')
        if '输入本机锁屏码' not in OUT:
            print('❌ 场景 F：未见本机锁屏码闸门')
            print(OUT[-800:])
            return False
        print('✅ 场景 F：/reset 进入本机锁屏码闸门')
        # 错误 PIN → 拒绝且未做任何改动（进程还在、store 还在）
        type_line(master, WRONG_PIN)
        if not wait_count_grow(master, '锁屏码错误', 0):
            print('❌ 场景 F：错误 PIN 未见拒绝提示')
            print(OUT[-800:])
            return False
        if p.poll() is not None:
            print('❌ 场景 F：错误 PIN 后进程竟退出了')
            return False
        if not os.path.exists(pin_store):
            print('❌ 场景 F：store 竟被删了（未做任何改动违反！）')
            return False
        print('✅ 场景 F：错误 PIN → 拒绝且未做任何改动（store 仍在）')
        # /exit 在锁屏码闸门也不认（按错码拒绝，不退出整个 TUI）
        send_until(master, '/reset', 'RESET')
        send_until(master, 'RESET', '输入本机锁屏码')
        type_line(master, '/exit')
        if not wait_count_grow(master, '锁屏码错误', OUT.count('锁屏码错误')):
            print('❌ 场景 F：/exit 未被当作错误尝试')
            print(OUT[-800:])
            return False
        if p.poll() is not None:
            print('❌ 场景 F：/exit 在锁屏码闸门被当成退出命令了（回归！）')
            return False
        print('✅ 场景 F：/exit 只是错码（不退出）')
        # 原会话照常：/exit 正常退出
        send_until_exit(master, p, '/exit')
        code = wait_exit(p, master)
        if code is None:
            print('❌ 场景 F：最终 /exit 未退出')
            return False
        print(f'✅ 场景 F：原会话照常，/exit 正常退出（code={code}）')
        return True
    finally:
        if p.poll() is None:
            p.kill()
        try:
            os.close(master)
        except OSError:
            pass


def assert_no_identity(frame, stage):
    """解锁前帧的身份零泄露断言（老板 2026-10-13）：只许有产品名 Einz。"""
    if 'Einz' not in frame:
        print(f'❌ 场景 G[{stage}]：产品名 Einz 没显示')
        return False
    if frame.count('Einz') < 2:
        print(f'❌ 场景 G[{stage}]：Einz 应同时在标题栏与状态栏（实见 {frame.count("Einz")} 次）')
        return False
    leaks = [
        ('我的名字', FAKE_NAME in frame),
        ('通道名', FAKE_ENTRANCE in frame),
        ('entrance_id', 'dev-a1' in frame),
        ('占位 ?', '?' in frame),
        ('WS/对方状态灯', any(d in frame for d in STATUS_DOTS)),
        ('底部命令提示', CHAT_HINT in frame),
        ('旧解锁 status', '🔒' in frame),
    ]
    bad = [name for name, hit in leaks if hit]
    if bad:
        print(f'❌ 场景 G[{stage}]：解锁前泄露了 {bad}')
        print(frame[-600:])
        return False
    return True


def scenario_identity_hidden_until_unlock(port):
    """场景 G（老板 2026-10-13）：验证通过前标题栏/状态栏只显示产品名——
    对方/我的名字、通道、WS 状态灯、命令提示一概不上屏；解锁成功后恢复。"""
    global OUT
    OUT = ''
    RAW = b''
    store = make_named_store()

    # setup：无 PIN 的 named store → /pin 设置 → /exit（供解锁场景复用）
    master, p = start_tui(store, port)
    try:
        answer_server_prompt(master)
        wait_text(master, CHAT_READY, timeout=90)
        if not send_until(master, '/pin 123456', PIN_SET):
            print('❌ 场景 G：/pin 设置失败')
            print(OUT[-800:])
            return False
        send_until_exit(master, p, '/exit')
        if wait_exit(p, master) is None:
            print('❌ 场景 G：setup /exit 后进程未退出')
            return False
    finally:
        if p.poll() is None:
            p.kill()
        try:
            os.close(master)
        except OSError:
            pass
    print('✅ 场景 G：准备完成（named store + PIN）')

    # 正式验证：启动 → 解锁提示出现后的**稳定帧**必须零身份信息
    OUT = ''
    RAW = b''
    master, p = start_tui(store, port)
    try:
        answer_server_prompt(master)
        wait_text(master, UNLOCK_PROMPT, timeout=90)
        if UNLOCK_PROMPT not in OUT:
            print('❌ 场景 G：未出现锁屏码解锁提示')
            print(OUT[-800:])
            return False
        if not assert_no_identity(grab_frame(master), '解锁提示态'):
            return False
        print('✅ 场景 G：解锁提示态只显示产品名（名字/通道/状态灯/命令提示均不上屏）')

        # 输错 PIN 后的帧同样干净（错误提示可以显示，身份不行）
        type_line(master, WRONG_PIN)
        if not wait_count_grow(master, UNLOCK_ERROR, OUT.count(UNLOCK_ERROR)):
            print('❌ 场景 G：错误 PIN 未见重试提示')
            return False
        if not assert_no_identity(grab_frame(master), '错误重试态'):
            return False
        print('✅ 场景 G：错误重试态同样零泄露')

        # 正确 PIN → 进聊天态 → 身份恢复（名字 + 命令提示回到屏上）
        type_line(master, PIN)
        if not wait_count_grow(master, PIN_OK, 0):
            print('❌ 场景 G：正确 PIN 未见验证成功')
            print(OUT[-800:])
            return False
        frame = grab_frame(master, seconds=2.0)
        if FAKE_NAME not in frame:
            print('❌ 场景 G：解锁后我的名字没恢复显示')
            print(frame[-600:])
            return False
        if CHAT_HINT not in frame:
            print('❌ 场景 G：解锁后状态栏命令提示没恢复')
            print(frame[-600:])
            return False
        print('✅ 场景 G：解锁成功 → 名字/状态栏恢复正常')

        send_until_exit(master, p, '/exit')
        if wait_exit(p, master) is None:
            print('❌ 场景 G：最终 /exit 未退出')
            return False
        return True
    finally:
        if p.poll() is None:
            p.kill()
        try:
            os.close(master)
        except OSError:
            pass


def main():
    port = free_port()
    store = setup_pin_store(port)
    results = [
        scenario_wrong_and_exit_command(store, port),
        scenario_empty_enter_exits(store, port),
        scenario_eof_exits(store, port),
        scenario_switch_gate(store, port),
        scenario_reset_gate(store, port),
        scenario_identity_hidden_until_unlock(port),
    ]
    shutil.rmtree(WORK, ignore_errors=True)
    if all(results):
        print('🎉 解锁流程全部通过')
        return 0
    print('❌ 存在失败场景')
    return 1


if __name__ == '__main__':
    sys.exit(main())
