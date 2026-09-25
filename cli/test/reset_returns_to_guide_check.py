#!/usr/bin/env python3
# /reset 「回到起点」回归（老板 2026-09-23）：
#   老板要求：`/reset` 之后**不要直接退出 TUI**，而是回到刚启动时的样子（重新入网）。
#   断言：
#     ① /reset 走完闸门后进程**仍在**，出现「重新入网」交代 + 全新「秘境向导」向导；
#     ② store 已重建：文件在、公钥与旧的不同、spaceId 为空（= 确实是一条全新通道）；
#     ③ 向导真的可用：再输 c → 走到「我的名字」问答。
#
# 运行：cd server && npm run build && python3 cli/test/reset_returns_to_guide_check.py
import json, re
import os, pty, subprocess, select, time, socket, tempfile, urllib.request, sys

ANSI = re.compile(r'\x1b\[[0-9;]*[A-Za-z]')


def strip(s):
    """失败诊断用：去掉 ANSI（否则整屏控制序列没法看）。"""
    return ANSI.sub('', s)

# __file__ = <repo>/cli/test/x.py → 仓库根 = 上三级
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CLI = os.path.join(ROOT, 'cli')
WORK = tempfile.mkdtemp(prefix='einz-reset-restart-')
PASSPHRASE = 'abc12345'  # ≥ 8 位（策略要求）
CREATOR = 'Lukas'
MEMBER = 'Alice'


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


def load_store(path):
    with open(path) as f:
        return json.load(f)


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

        # ---------- 入网：create（锁屏码留空跳过，/reset 就只需通道名一道闸门） ----------
        for expect, payload in [
            ('秘境向导', 'c\r'),
            ('我的名字', f'{CREATOR}\r'),
            ('我的性别', '1\r'),
            ('伴侣的名字', f'{MEMBER}\r'),
            ('伴侣的性别', '2\r'),
        ]:
            out = wait_text(m, expect, timeout=30)
            if expect not in out:
                print(f'❌ 未到「{expect}」问答'); print(strip(out[-600:])); return 1
            send(m, payload)
        out = wait_text(m, '设置共享口令', timeout=30)
        if '设置共享口令' not in out:
            print('❌ 未到口令问答'); print(strip(out[-600:])); return 1
        send(m, PASSPHRASE + '\r')
        out = wait_text(m, '成功创建秘境', timeout=40)
        if '成功创建秘境' not in out:
            print('❌ 未创建成功'); print(strip(out[-600:])); return 1
        # 锁屏码：留空回车 = 跳过（唯一允许空回车的向导问答）。
        # 注意：TUI 在 `processing`（_busy 打包/上传/建会话）期间**吞掉所有输入**
        # （:2517），所以不能"发一次就等"——按本仓库探针的惯例重发直到命中。
        out = ''
        for _ in range(10):
            send(m, '\r')
            out = wait_text(m, '没有设置锁屏码', timeout=5)
            if '没有设置锁屏码' in out:
                break
        if '没有设置锁屏码' not in out:
            print('❌ 未能跳过锁屏码'); print(strip(out[-1200:])); return 1
        print('✅ 入网完成（锁屏码已跳过）')

        old = load_store(store)
        old_pub = old.get('public_key')
        old_name = (old.get('entrance_name') or '').strip()
        if not old_pub:
            print('❌ store 里没有 public_key'); return 1

        # ---------- /reset：两道闸门（通道名 + 未设锁屏码则跳过）→ 期望回到起点 ----------
        # /reset：同样重发直到闸门出现（busy 期间会被吞）
        out = ''
        for _ in range(10):
            send(m, '/reset\r')
            out = wait_text(m, '以确认重置本通道', timeout=5)
            if '以确认重置本通道' in out:
                break
        if '以确认重置本通道' not in out:
            print('❌ /reset 未到通道名闸门'); print(strip(out[-1200:])); return 1
        send(m, (old_name or 'RESET') + '\r')

        # 只等**最后**出现的那一项，再在同一条缓冲里断言前面几项：
        # wait_text 命中即返回，会把同一批输出里更靠后的内容一起吞掉，分两次等会假阴性。
        out = wait_text(m, '秘境向导', timeout=60)
        if '重新入网' not in out:
            print('❌ /reset 后没看到「重新入网」交代'); print(strip(out[-1200:])); return 1
        # ① 进程仍在（没有 exit(0)）
        if p.poll() is not None:
            print('❌ /reset 把 TUI 退掉了（应停在新向导里）'); return 1
        # ② 回到向导：全新「秘境向导」
        if '秘境向导' not in out:
            print('❌ /reset 后没有回到「秘境向导」向导'); print(strip(out[-1200:])); return 1
        print('✅ ① /reset 后进程仍在，且回到「秘境向导」向导')

        # ③ store 已重建：新公钥、且还没绑定空间
        new = load_store(store)
        new_pub = new.get('public_key')
        if not new_pub:
            print('❌ /reset 后 store 未重建'); return 1
        if new_pub == old_pub:
            print('❌ 新通道公钥与旧的一样（应重新生成身份）'); return 1
        if new.get('space_id'):
            print('❌ 新 store 竟已绑定空间（应为全新通道）'); return 1
        print('✅ ② store 已重建（新公钥、未绑定空间）')

        # ④ 向导真的可用：再走一步
        send(m, 'c\r')
        out = wait_text(m, '我的名字', timeout=30)
        if '我的名字' not in out:
            print('❌ 回到起点后向导不可用（没走到「我的名字」）'); print(strip(out[-900:])); return 1
        if p.poll() is not None:
            print('❌ 向导中途进程退出'); return 1
        print('✅ ③ 向导可用（c → 我的名字）')
        print('🎉 /reset 回到起点全部通过')
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
