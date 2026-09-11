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
          → 口令 abc123 → 抓邀请 token
  设备 B：输入 J → 粘贴 token → 选择身份 1（第二人 Alice）→ 口令 → 加入成功
  设备 C：第一人的其他设备——curl 生成第二个 token → 选择身份 0（第一人 Lukas）
          → 口令 → 加入成功（验证「同身份多设备」）
  断言：B/C 的空间地址与 A 一致。
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
SERVER = "http://localhost:3999"
STORE_A = "/tmp/einz-e2e-a.json"
STORE_B = "/tmp/einz-e2e-b.json"
STORE_C = "/tmp/einz-e2e-c.json"

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


def join_flow(label, store, token, slot):
    """通用 join 流程：输入 J（join）→ 粘贴 token → 选身份 → 口令 → 加入。
    返回加入成功后的累计输出。"""
    p, m = spawn_tui(store)
    name, out, _ = read_until(m, [
        ("ask_choice", re.compile(r"创建新秘境")),
        ("fail", re.compile(r"无法连接服务器|未检测到交互终端")),
    ], prefix=label)
    if name != "ask_choice":
        print(f"FAIL {label}: 未等到创建/加入选择。输出:\n", out[-800:])
        sys.exit(1)
    send(m, "J\r")  # 输入 J（join）——大小写均可
    name, out, _ = read_until(m, [
        ("ask_token", re.compile(r"粘贴伴侣的邀请链接或 token")),
    ], prefix=label)
    send(m, token + "\r")
    name, out, _ = read_until(m, [
        ("ask_slot", re.compile(r"你是哪一个用户")),
        ("joined", re.compile(r"已加入空间")),
        ("fail", re.compile(r"加入空间失败")),
    ], prefix=label)
    if name == "ask_slot":
        send(m, str(slot) + "\r")
        name, out, _ = read_until(m, [
            ("ask_passphrase", re.compile(r"输入空间密保口令")),
        ], prefix=label)
        send(m, "abc123\r")
        name, out, _ = read_until(m, [
            ("joined", re.compile(r"已加入空间")),
            ("fail", re.compile(r"加入空间失败|口令错误")),
        ], prefix=label)
    if name != "joined":
        print(f"FAIL {label}: 加入未成功。输出:\n", out[-1000:])
        sys.exit(1)
    m_addr = re.search(r"地址: (0x[0-9a-fA-F]+)", out)
    addr = m_addr.group(1) if m_addr else None
    print(f"{label}: 加入成功, 地址 =", addr)
    return p, m, addr


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
        ("ask_choice", re.compile(r"创建新秘境")),
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
    send(m_a, "abc123\r")
    name, out, _ = read_until(m_a, [
        ("created", re.compile(r"空间已创建")),
        ("fail", re.compile(r"创建空间失败")),
    ], prefix="A")
    if name != "created":
        print("FAIL A: 空间创建未成功。输出:\n", out[-1000:])
        sys.exit(1)
    _, out2, _ = read_until(m_a, [
        ("token", re.compile(r"e1_[A-Za-z0-9_-]+")),
    ], timeout=15, prefix="A-token")
    out = out + out2
    m_link = re.search(r"(e1_[A-Za-z0-9_-]+)", out)
    m_addr = re.search(r"地址: (0x[0-9a-fA-F]+)", out)
    if not m_link or not m_addr:
        print("FAIL A: 未抓到邀请 token 或地址。输出:\n", out[-1000:])
        sys.exit(1)
    token1 = m_link.group(1)
    addr_a = m_addr.group(1)
    print("A: 空间创建成功, 地址 =", addr_a, ", token1 =", token1)

    # ---------- 设备 B：第二人加入（选身份 1 = Alice）----------
    p_b, m_b, addr_b = join_flow("B", STORE_B, token1, slot=1)

    # ---------- 设备 C：第一人的其他设备（选身份 0 = Lukas）----------
    # 验证 /invite 命令工作（输出新设备绑定邀请——渲染帧交错导致抓 token 不可靠，
    # 故 join 用同端点 curl 生成的 token 验证 join 链路——createJoinToken 同一端点）。
    # A create 后可能卡在锁屏码询问（_askSetPin——onboarded=true）：先回车跳过
    send(m_a, "\r")
    send(m_a, "/invite\r")
    name, out3, _ = read_until(m_a, [
        ("invite", re.compile(r"新设备绑定邀请")),
        ("fail", re.compile(r"邀请生成失败")),
    ], timeout=20, prefix="A-invite")
    if name != "invite":
        print("FAIL A: /invite 未生成绑定邀请。输出:\n", out3[-600:])
        sys.exit(1)
    print("A: /invite 命令工作（生成新设备绑定邀请）")
    with open(STORE_A) as f:
        store_a = json.load(f)
    req = urllib.request.Request(
        SERVER + "/spaces/" + store_a["space_id"] + "/join-tokens", method="POST"
    )
    with urllib.request.urlopen(req, timeout=5) as r:
        t2 = json.load(r)
    token2 = t2["joinToken"]
    print("C: 生成新 token =", token2)
    p_c, m_c, addr_c = join_flow("C", STORE_C, token2, slot=0)

    # ---------- 断言 ----------
    ok_b = (addr_b or "")[:20] == addr_a[:20]
    ok_c = (addr_c or "")[:20] == addr_a[:20]
    print("B 空间地址一致:", ok_b, "| C 空间地址一致:", ok_c)
    if not (ok_b and ok_c):
        print("FAIL: 空间地址不一致")
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
