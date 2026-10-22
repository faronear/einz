#!/usr/bin/env python3
# 引导输入规则回归（老板 2026-09-11 立；2026-10-13 改为「回车回退」模型后重写）
#   0) create 问答链（秘境向导 c/j → 我的名字 → 我的性别 → 秘境类型 → 设置共享口令）：
#      无效输入原地重问；**空回车 = 退回上一问**（老板 2026-10-13）——本用例在口令步
#      起连续空回车，一路退到秘境入口，再边走边补答，验证回退与重问都正常
#      （旧规则是必填问答空回车静默拒绝，2026-09-23；/exit 逃生门 2026-10-13 废除）
#   1) 入网收尾 + 锁屏码规则：create 成功后**不再询问锁屏码**（2026-10-19 移除
#      _askSetPin，与 App 向导同口径——必设时代的遗留步骤，随时可 /pin 补设），
#      直接欢迎辞 → 5s 倒计时 → 清 system 消息进聊天态；锁屏码规则改在聊天态用
#      /pin 验证（与 App 一致：纯数字 + 至少 6 位）：字母 → 提示「锁屏码只能是
#      数字」；5 位数字 → 提示「锁屏码至少 6 位数字」；6 位数字 → 设置成功
#   2) join 口令验证：空回车 → 退回上一问（性别）；口令输错 → 停在口令环节提示重输，
#      且**同一个** join token 仍可用（旧实现先 joinSpace 消费 token 再验口令 →
#      一输错就被踢回通道码环节，已接受的 token 作废——老板 2026-09-12 反馈）
#
# 断言方法：TUI 全屏重绘，消息区**自下而上**绘制——一帧的字节流里**最新的消息排最前**。
# 故「最后一个完整帧里字节序最靠前的提问」= 当前提问（不受消息区历史文本干扰）。
# 每次输入后读到输出静默（quiet 秒无新字节），保证拿到完整帧。
#
# 运行：python3 cli/test/guide_input_rules_check.py
import json
import os, pty, re, select, subprocess, time, socket, tempfile, urllib.request, sys

# __file__ = <repo>/cli/test/x.py → 仓库根 = 上三级
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CLI = os.path.join(ROOT, 'cli')
WORK = tempfile.mkdtemp(prefix='einz-passphrase-')

ANSI = re.compile(r'\x1b\[[0-9;?]*[A-Za-z]')
CLEAR = '\x1b[2J'  # _render 每帧开头清屏
PROMPT_KEYS = [
    '❓ 设置共享口令', '❓ 验证共享口令', '❓ 秘境类型',
    '❓ 我的性别', '❓ 你的性别', '❓ 我的名字', '❓ 你的名字',
    '❓ 秘境向导', '❓ 输入通道码',
]


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


def drain_quiet(master, quiet=0.8, timeout=20):
    """读到输出静默（quiet 秒无新字节）或超时——保证拿到完整帧（防 pty 缓冲半帧）。"""
    out = ''
    deadline = time.time() + timeout
    last = time.time()
    while time.time() < deadline:
        chunk = drain(master, 0.2)
        if chunk:
            out += chunk
            last = time.time()
        elif time.time() - last >= quiet:
            break
    return out


def current_prompt(text):
    """最后一个完整帧里字节序最靠前的提问 = 当前提问（消息区自下而上绘制）。"""
    frames = text.split(CLEAR)
    frame = frames[-1] if len(frames) > 1 else text
    clean = ANSI.sub('', frame)
    best, bestpos = None, len(clean) + 1
    for k in PROMPT_KEYS:
        i = clean.find(k)
        if 0 <= i < bestpos:
            bestpos, best = i, k
    return best


def wait_prompt(master, expect, timeout=40):
    """等到当前提问为 expect（中途持续读）。"""
    out = ''
    deadline = time.time() + timeout
    while time.time() < deadline:
        out += drain(master, 0.5)
        if current_prompt(out) == expect:
            return out
    return out


def go(master, payload, expect, label=None, timeout=20):
    """发送 payload，静默后断言当前提问 = expect。"""
    send(master, payload)
    out = drain_quiet(master, timeout=timeout)
    cur = current_prompt(out)
    if cur != expect:
        print(f'❌ {label or payload!r}：当前提问是 {cur!r}，期望 {expect!r}')
        print(ANSI.sub('', out)[-500:])
        raise SystemExit(1)
    return out


def back(master, expect, label, timeout=20):
    """空回车 = 退回上一问：静默后断言当前提问 = expect（上一问的提问）。"""
    send(master, '\r')
    out = drain_quiet(master, timeout=timeout)
    cur = current_prompt(out)
    if cur != expect:
        print(f'❌ {label}：空回车后当前提问是 {cur!r}，期望退回 {expect!r}')
        print(ANSI.sub('', out)[-500:])
        raise SystemExit(1)
    if '↩️ 已返回' not in out:
        print(f'⚠️ {label}：未见「↩️ 已返回」反馈（仅提示）')
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

        store = os.path.join(WORK, 'a.json')
        m, p = start_tui(store, port)
        spawned.append((m, p))

        # ---------- create 问答链：前进 → 逐级回退 → 重走补答 ----------
        out = wait_prompt(m, '❓ 秘境向导')
        if current_prompt(out) != '❓ 秘境向导':
            print('❌ 未到「秘境向导」问答')
            print(ANSI.sub('', out)[-600:])
            return 1
        go(m, 'c\r', '❓ 我的名字', 'create 首问')
        go(m, 'Lukas\r', '❓ 我的性别', '名字步')
        go(m, '1\r', '❓ 秘境类型', '性别步')
        go(m, '1\r', '❓ 设置共享口令', '类型步')  # 1=双人秘境
        print('✅ create：问答链前进正常（c → 名字 → 性别 → 类型 → 口令）')

        # 口令步起连续空回车：口令 → 类型 → 性别 → 名字 → 秘境入口
        back(m, '❓ 秘境类型', '口令步回退')
        back(m, '❓ 我的性别', '类型步回退')
        back(m, '❓ 我的名字', '性别步回退')
        back(m, '❓ 秘境向导', '名字步回退')
        print('✅ create：空回车逐级回退（口令→类型→性别→名字→秘境入口）')

        # 从秘境入口重走问答链，补输口令 → 创建成功
        go(m, 'c\r', '❓ 我的名字', '重走首问')
        go(m, 'Lukas\r', '❓ 我的性别', '重走名字')
        go(m, '1\r', '❓ 秘境类型', '重走性别')
        go(m, '1\r', '❓ 设置共享口令', '重走类型')
        send(m, 'abc12345\r')  # ≥ kPassphraseMinLength=8 位——老板 2026-09-15 起
        out = ''
        deadline = time.time() + 40
        while '成功创建秘境' not in out and time.time() < deadline:
            out += drain(m, 0.8)
        if '成功创建秘境' not in out:
            print('❌ 输入口令后未创建成功')
            print(ANSI.sub('', out)[-600:])
            return 1
        print('✅ create：回退后重走问答链，补输口令创建成功')

        def input_until(payload, expect, tries=6, timeout=8):
            out = ''
            for _ in range(tries):
                send(m, payload)
                out = wait_text(m, expect, timeout=timeout)
                if expect in out:
                    break
            return out

        def wait_text(master, text, timeout=40):
            out = ''
            deadline = time.time() + timeout
            while text not in out and time.time() < deadline:
                out += drain(master, 0.8)
            return out

        # ---------- 入网收尾：欢迎辞倒计时 → 聊天态（PIN 询问已移除，2026-10-19） ----------
        # create 成功后不再问锁屏码（_askSetPin 删除）：直接 _finalizeOnboarding——
        # 欢迎辞 → 5s 倒计时（processing 吞输入）→ 清空 system 消息 = 进聊天态。
        out = wait_text(m, '一切就绪', timeout=40)
        if '一切就绪' not in out:
            print('❌ 建空间后未出现欢迎辞倒计时'); print(ANSI.sub('', out)[-800:]); return 1
        deadline = time.time() + 40
        while time.time() < deadline:
            chunk = drain(m, 0.8)
            # 聊天态 = 出现不含欢迎辞块的完整帧（标题栏 'Einz' 在，倒计时/分隔线已清）
            if chunk and 'Einz' in chunk and '一切就绪' not in chunk and '----------------' not in chunk:
                break
        else:
            print('❌ 倒计时后未进入聊天态（system 消息未清空）'); print(ANSI.sub('', out)[-800:]); return 1
        print('✅ 入网完成：欢迎辞倒计时后直接进入聊天态（PIN 询问已移除）')

        # ---------- 锁屏码规则：聊天态 /pin（纯数字 + 至少 6 位） ----------
        # 规则与 _pinError 实现未变，只是入口从向导询问改为 /pin 命令：
        # 字母 → 「锁屏码只能是数字」；5 位 → 「锁屏码至少 6 位数字」；6 位 → 已设置
        for wrong, expect in (
            ('/pin abc\r', '锁屏码只能是数字'),       # 字母
            ('/pin 12345\r', '锁屏码至少 6 位数字'),  # 位数不足
        ):
            out = input_until(wrong, expect)
            if expect not in out:
                print(f'❌ {wrong.strip()!r} 未被拦住（未提示「{expect}」）')
                print(ANSI.sub('', out)[-800:])
                return 1
            if '锁屏码已设置' in out:
                print(f'❌ 非法锁屏码 {wrong.strip()!r} 竟被接受'); return 1
        out = input_until('/pin 123456\r', '锁屏码已设置')
        if '锁屏码已设置' not in out:
            print('❌ 6 位数字锁屏码未被接受'); print(ANSI.sub('', out)[-800:]); return 1
        # 无参数：报当前状态 + 用法卡片
        out = input_until('/pin\r', '【🔧 用法】')
        if '锁屏码：已设置' not in out:
            print('❌ /pin 无参数未报当前状态'); print(ANSI.sub('', out)[-800:]); return 1
        print('✅ 锁屏码规则：/pin 字母/不足 6 位被拒，6 位数字通过，无参数报状态')

        # ---------- 通道 B：join 口令验证：空回车回退 + 输错停在口令步 ----------
        with open(store) as f:
            store_a = json.load(f)
        # 签发通道码是空间级操作，必须带本空间成员会话（server C1 修复后要求
        # 认证——此前裸 POST 也能签，现已 400）
        req = urllib.request.Request(
            f'http://127.0.0.1:{port}/spaces/{store_a["space_id"]}/join-tokens',
            method='POST',
            data=json.dumps({'purpose': 'invite'}).encode(),  # B 是开新身份（invite 流才问名字）
            headers={'Authorization': f'Bearer {store_a["session_token"]}',
                     'Content-Type': 'application/json',
                     'X-Protocol-Version': '3'})
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                join_token = json.load(r)['joinToken']
        except urllib.error.HTTPError as e:
            print(f'❌ 签发通道码失败（HTTP {e.code}）: {e.read().decode("utf-8", "replace")[:300]}')
            return 1

        store_b = os.path.join(WORK, 'b.json')
        m2, p2 = start_tui(store_b, port)
        spawned.append((m2, p2))
        out = wait_prompt(m2, '❓ 秘境向导')
        if current_prompt(out) != '❓ 秘境向导':
            print('❌ B 未到「秘境向导」问答')
            print(ANSI.sub('', out)[-600:])
            return 1
        go(m2, 'j\r', '❓ 输入通道码', 'B 首问')
        go(m2, join_token + '\r', '❓ 你的名字', 'B 通道码')
        go(m2, 'Alice\r', '❓ 你的性别', 'B 名字')
        go(m2, '2\r', '❓ 验证共享口令', 'B 性别')
        print('✅ join：问答链前进正常（j → 通道码 → 名字 → 性别 → 口令）')

        # 口令步空回车 → 退回性别步；补答性别后回到口令步
        back(m2, '❓ 你的性别', 'B 口令步回退')
        go(m2, '2\r', '❓ 验证共享口令', 'B 回退补答')
        print('✅ join：口令步空回车退回性别，补答后回到口令步')

        # ---------- 口令错误：必须停在口令环节重输，且不能烧掉 join token ----------
        # （旧实现：先 joinSpace 消费一次性 token 再验口令 → 失败即落到「加入秘境
        #   失败」并退回通道码环节，已接受的 token 作废——老板 2026-09-12 反馈）
        send(m2, 'wrong-pass\r')
        out = ''
        deadline = time.time() + 30
        while '口令错误，请重新输入' not in out and time.time() < deadline:
            out += drain(m2, 0.8)
        if '口令错误，请重新输入' not in out:
            print('❌ B 输错口令未被拦在口令环节（未提示重新输入）')
            print(ANSI.sub('', out)[-800:])
            return 1
        # 当前提问必须仍是口令步（停在环节里重输）
        out2 = drain_quiet(m2, timeout=10)
        if current_prompt(out + out2) != '❓ 验证共享口令':
            print('❌ B 输错口令后当前提问变了（应仍在口令步）')
            print(ANSI.sub('', out + out2)[-800:])
            return 1

        # 同一个 token：重输正确口令 → 应加入成功（token 未被消耗）
        send(m2, 'abc12345\r')
        out = ''
        deadline = time.time() + 40
        while '成功加入秘境' not in out and time.time() < deadline:
            out += drain(m2, 0.8)
        if '成功加入秘境' not in out:
            print('❌ B 输错后重输正确口令未加入成功（token 应仍有效）')
            print(ANSI.sub('', out)[-800:])
            return 1

        print('✅ join：空回车回退正常、输错停在口令环节重输，补输后加入成功')
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
