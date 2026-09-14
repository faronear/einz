#!/usr/bin/env python3
"""CLI Multiverse pty e2e：真实 server + 三台设备 create→join 实测（U4/U5 验收）。

前置：
  1. server 已在 3999 端口运行（PORT=3999 node v22 tsx src/app.ts）
  2. dart 在 PATH（flutter/bin）

用法：
  python3 aimemo/cliMultiverseE2E.py

流程（2026-09-10 老板定稿引导：第一步输入 C/create（创建）或 J/join（加入），
      大小写均可；create 录入两人名字/性别；join 按身份选择而非自填名字）：
  设备 A：输入 C → 名字 Lukas → 性别 男 → 伴侣名字 Alice → 伴侣性别 女
          → 口令 einzpass2026 → 抓邀请 token
  设备 B：输入 J → 粘贴 token → 选择身份 1（第二人 Alice）→ 口令 → 加入成功
  设备 C：第一人的其他设备——curl 生成第二个 token → 选择身份 0（第一人 Lukas）
          → 口令 → 加入成功（验证「同身份多设备」）
  断言①（老板 2026-09-14）：B 向导未按回车「显性进入聊天态」前，A 发的消息**不得**
          进 B 的消息流；B 回车后才由增量同步补齐。
  断言②：B/C 的空间地址与 A 一致（读 store 的 space_address，不抓终端渲染）。

注入：EINZ_E2E_PORT（默认 3999）、EINZ_E2E_SERVER 可覆盖。
"""
import json
import os
import pty
import re
import select
import subprocess
import sys
import time

CLI_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "cli")
# 端口可用 EINZ_E2E_PORT 覆盖（默认 3999 被占用时换一个，避免误杀别人的实例）
SERVER = os.environ.get(
    "EINZ_E2E_SERVER",
    f"http://localhost:{os.environ.get('EINZ_E2E_PORT', '3999')}",
)
STORE_A = "/tmp/einz-e2e-a.json"
STORE_B = "/tmp/einz-e2e-b.json"
STORE_C = "/tmp/einz-e2e-c.json"

# 密保口令：必须满足强度策略（≥10 位且含字母与数字，shared/passphrase_policy.dart）。
# 2026-09-14 起三端强制校验——原脚本用的 "abc123"（6 位）已被拒，脚本因此失效。
PASSPHRASE = "einzpass2026"

_ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


def strip_ansi(s: str) -> str:
    return _ANSI.sub("", s)


def spawn_tui(store: str):
    master, slave = pty.openpty()
    env = dict(os.environ, TERM="xterm-256color")
    p = subprocess.Popen(
        ["dart", "run", "bin/einz_tui.dart", "--store", store, "--server", SERVER],
        stdin=slave,
        stdout=slave,
        stderr=slave,
        env=env,
        cwd=CLI_DIR,
        close_fds=True,
    )
    os.close(slave)
    return p, master


def read_until(master, patterns, timeout=40, prefix=""):
    deadline = time.time() + timeout
    buf = ""
    while time.time() < deadline:
        r, _, _ = select.select([master], [], [], 0.5)
        if r:
            try:
                chunk = os.read(master, 4096).decode("utf-8", "replace")
            except OSError:
                break
            buf += chunk
            text = strip_ansi(buf)
            for name, pat in patterns:
                m = pat.search(text)
                if m:
                    return name, text, m
    return None, buf, None


def send(master, text):
    os.write(master, text.encode())


def store_address(path):
    """读 store 文件里的 space_address——比抓终端渲染可靠（pty 会按宽度折行截断；
    join 路径也不打印地址，只有 create 打印）。"""
    with open(path) as f:
        return json.load(f).get("space_address") or ""


def wait_welcome_and_enter(m, label, timeout=30):
    """向导收尾：跳过可能出现的锁屏码询问，等到欢迎辞后再回车显性进入聊天态。
    收尾前会每 2 秒补一个回车（跳过锁屏码）——锁屏码提示可能早于本次读取出现。"""
    deadline = time.time() + timeout
    while time.time() < deadline:
        name, out, _ = read_until(m, [("welcome", re.compile(r"输入回车"))],
                                  timeout=2, prefix=label)
        if name == "welcome":
            send(m, "\r")
            return True
        send(m, "\r")  # 仍在锁屏码询问：跳过（可空）
    return False


def join_flow(label, store, token, identity_name, wrong_token=None, quit_after_wrong=False):
    """通用 join 流程：输入 J（join）→ 粘贴 token → 输入名字选身份 → 口令 → 加入。
    若给 wrong_token：先贴错误 token，断言被拒后直接重输 token（不回到
    create/join 首问——老板 2026-09-10），再贴正确 token。
    返回加入成功后的累计输出。"""
    p, m = spawn_tui(store)
    name, out, _ = read_until(m, [
        ("ask_choice", re.compile(r"创建秘境")),
        ("fail", re.compile(r"无法连接服务器|未检测到交互终端")),
    ], prefix=label)
    if name != "ask_choice":
        print(f"FAIL {label}: 未等到创建/加入选择。输出:\n", out[-800:])
        sys.exit(1)
    send(m, "J\r")  # 输入 J（join）——大小写均可
    name, out, _ = read_until(m, [
        ("ask_token", re.compile(r"输入邀请码")),
    ], prefix=label)
    if wrong_token:
        send(m, wrong_token + "\r")
        # 先等被拒反馈（_spaceJoin 处理完成）；"创建新秘境"文本会一直留在
        # 消息区（重绘再现），不可用作"回到首问"信号——若真的回到首问，
        # 重输 token 提示等不到（read_until 超时）即失败
        name, out, _ = read_until(m, [
            ("rejected", re.compile(r"加入秘境失败|邀请码验证失败|邀请码无效")),
        ], prefix=label)
        if name != "rejected":
            print(f"FAIL {label}: 错误 token 未被拒绝。输出:\n", out[-600:])
            sys.exit(1)
        name, out, _ = read_until(m, [
            ("ask_token_again", re.compile(r"输入邀请码")),
        ], prefix=label)
        if name != "ask_token_again":
            print(f"FAIL {label}: 被拒后未直接重输 token（回到首问？）。输出:\n", out[-600:])
            sys.exit(1)
        print(f"{label}: 错误 token 被拒后直接重输 token ✓")
        if quit_after_wrong:
            # 仅验证"错误 token 直接重输"——退出本会话（pty 渲染/输入竞态下
            # 继续 join 不可靠；join 链路由后续正常流程验证）
            p.terminate()
            try:
                p.wait(timeout=3)
            except Exception:
                p.kill()
            return None
        time.sleep(2.0)
    send(m, token + "\r")
    name, out, _ = read_until(m, [
        ("ask_slot", re.compile(r"我是谁")),
        ("joined", re.compile(r"成功加入秘境")),
        ("fail", re.compile(r"加入秘境失败")),
    ], prefix=label)
    if name == "ask_slot":
        send(m, identity_name + "\r")  # 输入完整名字选择身份（老板 2026-09-10——不再输编号）
        name, out, _ = read_until(m, [
            ("ask_passphrase", re.compile(r"验证密保口令")),
        ], prefix=label)
        send(m, PASSPHRASE + "\r")
        name, out, _ = read_until(m, [
            ("joined", re.compile(r"成功加入秘境")),
            ("fail", re.compile(r"加入秘境失败|口令错误|找不到受托管")),
        ], prefix=label)
    if name != "joined":
        print(f"FAIL {label}: 加入未成功。输出:\n", out[-1000:])
        sys.exit(1)
    print(f"{label}: 加入成功（随后进入向导收尾：锁屏码 → 欢迎辞回车）")
    return p, m


def main():
    import urllib.request

    for f in (STORE_A, STORE_B, STORE_C):
        if os.path.exists(f):
            os.remove(f)
    for _ in range(20):
        try:
            with urllib.request.urlopen(SERVER + "/health", timeout=2) as r:
                if r.status == 200:
                    break
        except Exception:
            time.sleep(0.5)
    else:
        print("FAIL: server 未就绪（请先起 PORT=3999 的 server）")
        sys.exit(1)

    # ---------- 设备 A：输入 C（create，伴侣名字/性别必填）----------
    p_a, m_a = spawn_tui(STORE_A)
    name, out, _ = read_until(m_a, [
        ("ask_choice", re.compile(r"创建秘境")),
        ("fail", re.compile(r"无法连接服务器|未检测到交互终端")),
    ], prefix="A")
    if name != "ask_choice":
        print("FAIL A: 未等到创建/加入选择。输出:\n", out[-800:])
        sys.exit(1)
    send(m_a, "C\r")  # 输入 C（create）——大小写均可
    name, out, _ = read_until(m_a, [
        ("ask_name", re.compile(r"我的名字")),
    ], prefix="A")
    send(m_a, "Lukas\r")
    name, out, _ = read_until(m_a, [
        ("ask_gender", re.compile(r"我的性别")),
    ], prefix="A")
    send(m_a, "1\r")  # 我的性别：1=男（数字输入——老板定稿）
    name, out, _ = read_until(m_a, [
        ("ask_partner_name", re.compile(r"伴侣的名字")),
    ], prefix="A")
    send(m_a, "Alice\r")
    name, out, _ = read_until(m_a, [
        ("ask_partner_gender", re.compile(r"伴侣的性别")),
    ], prefix="A")
    send(m_a, "2\r")  # 伴侣性别：2=女（数字输入——老板定稿）
    name, out, _ = read_until(m_a, [
        ("ask_passphrase", re.compile(r"设置密保口令")),
    ], prefix="A")
    send(m_a, PASSPHRASE + "\r")
    name, out, _ = read_until(m_a, [
        ("created", re.compile(r"成功创建秘境")),
        ("fail", re.compile(r"创建空间失败")),
    ], prefix="A")
    if name != "created":
        print("FAIL A: 空间创建未成功。输出:\n", out[-1000:])
        sys.exit(1)
    m_addr = re.search(r"地址: (0x[0-9a-fA-F]+)", out)
    if not m_addr:
        print("FAIL A: 未抓到空间地址。输出:\n", out[-1000:])
        sys.exit(1)
    addr_a = m_addr.group(1)
    print("A: 空间创建成功, 地址 =", addr_a)

    # join token 走服务端接口生成：pty 里抓邀请链接会被终端按宽度折行截断
    #（实测抓到的 token 哈希与服务端不符 → preflight 400），不可靠。
    def new_join_token():
        with open(STORE_A) as f:
            store_a = json.load(f)
        req = urllib.request.Request(
            SERVER + "/spaces/" + store_a["space_id"] + "/join-tokens", method="POST")
        with urllib.request.urlopen(req, timeout=5) as r:
            return json.load(r)["joinToken"]

    token1 = new_join_token()
    print("B: 生成 token =", token1)

    # ---------- 设备 B：第二人加入（选身份 1 = Alice）----------
    # B1：错误 token 被拒后直接重输验证（会话到此退出——不 join）
    join_flow("B", STORE_B, token1, identity_name="Alice",
              wrong_token="e1_WrongToken999", quit_after_wrong=True)
    # B2：第二人正常加入（选身份 1 = Alice）——join 链路由本流程验证
    # 注意：join_flow 返回时 B 才刚「加入成功」，仍在向导里（锁屏码 → 欢迎辞回车）。
    p_b, m_b = join_flow("B", STORE_B, token1, identity_name="Alice")

    # ---------- 设备 C：第一人的其他设备（选身份 0 = Lukas）----------
    # A 先走完自己的向导（跳过锁屏码 → 欢迎辞回车显性进入聊天态），否则后面的
    # /invite 与聊天消息会被未完成的向导问答吞掉。
    if not wait_welcome_and_enter(m_a, "A"):
        print("FAIL A: 未等到欢迎辞（向导收尾失败）")
        sys.exit(1)
    print("A: 向导收尾完成（回车进入聊天态）")
    send(m_a, "/invite\r")
    name, out3, _ = read_until(m_a, [
        ("invite", re.compile(r"邀请新设备")),
        ("fail", re.compile(r"邀请生成失败")),
    ], timeout=20, prefix="A-invite")
    if name != "invite":
        print("FAIL A: /invite 未生成绑定邀请。输出:\n", out3[-600:])
        sys.exit(1)
    print("A: /invite 命令工作（生成新设备绑定邀请）")

    # ---------- 断言①：向导未显性结束前，对方消息不得进消息流（老板 2026-09-14）----------
    # 此刻 B 仍停在向导里（锁屏码询问，尚未按回车进聊天态）。
    # 探测文本默认 ASCII：pty 注入非 ASCII 的字节序列在按键层未必被逐字正确解析，
    # 用 ASCII 让失败原因唯一（只可能是"消息插队"，不是"文本没打进去"）。
    # 需要验证中文输入时用 EINZ_GATE_TEXT 覆盖。
    GATE_TEXT = os.environ.get("EINZ_GATE_TEXT", "gate-probe-msg")
    send(m_a, GATE_TEXT + "\r")
    # 先确认 A 真的发出去了（状态栏「已发送」）——否则失败原因会在 A 侧而不在 B 侧，
    # 断言会误导（曾出现一次 A 未发出导致的假失败）。
    name, out_a_send, _ = read_until(m_a, [("sent", re.compile(r"已发送"))],
                                     timeout=15, prefix="A-send")
    if name != "sent":
        print("FAIL A: 消息未发出（未见「已发送」状态）。A 屏幕:\n",
              strip_ansi(out_a_send)[-700:])
        sys.exit(1)
    print("A: 消息已发出 ✓")
    _, out_gate, _ = read_until(m_b, [("never", re.compile(r"§不存在的锚点§"))],
                                timeout=3, prefix="B-gate")
    if GATE_TEXT in out_gate:
        print("FAIL B: 未按回车结束向导前就收到了对方消息（应等显性进入聊天态）。输出:\n",
              out_gate[-800:])
        sys.exit(1)
    print("B: 向导期间未收到对方消息 ✓（不插队）")
    # B 走完向导 → 回车进入聊天态 → 该消息应由「回车后的增量同步」补齐
    if not wait_welcome_and_enter(m_b, "B"):
        print("FAIL B: 未等到欢迎辞（向导收尾失败）")
        sys.exit(1)
    name, out_after, _ = read_until(m_b, [
        ("got", re.compile(GATE_TEXT)),
    ], timeout=25, prefix="B-after")
    if name != "got":
        print("FAIL B: 回车进入聊天态后仍未收到该消息。输出:\n", out_after[-1000:])
        sys.exit(1)
    print("B: 回车进入聊天态后收到该消息 ✓（增量同步补齐，未插进向导消息之间）")

    token2 = new_join_token()
    print("C: 生成新 token =", token2)
    p_c, m_c = join_flow("C", STORE_C, token2, identity_name="Lukas")

    # ---------- 断言②：三台设备的空间地址一致（读 store，不抓终端）----------
    addr_a = store_address(STORE_A)
    addr_b = store_address(STORE_B)
    addr_c = store_address(STORE_C)
    ok_b = bool(addr_a) and addr_b == addr_a
    ok_c = bool(addr_a) and addr_c == addr_a
    print("A 地址 =", addr_a)
    print("B 空间地址一致:", ok_b, "| C 空间地址一致:", ok_c)
    if not (ok_b and ok_c):
        print(f"FAIL: 空间地址不一致（B={addr_b} C={addr_c}）")
        sys.exit(1)

    # 收尾：跳过可能的锁屏码询问后退出
    for p, m in ((p_a, m_a), (p_b, m_b), (p_c, m_c)):
        try:
            send(m, "\r")
        except OSError:
            pass
        try:
            send(m, "/exit\r")
        except OSError:
            pass
        try:
            p.wait(timeout=5)
        except Exception:
            p.kill()
    print("PASS: CLI Multiverse create→join→多设备 e2e 全通")


if __name__ == "__main__":
    main()
