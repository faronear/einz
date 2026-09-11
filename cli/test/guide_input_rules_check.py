#!/usr/bin/env python3
# 引导输入规则回归（老板 2026-09-11）
#   1) create 口令必填：走到「设置密保口令」留空回车 → 必须被拦住（提示
#      「此项不能为空」，且不进入创建）；补输口令后创建成功
#   2) 锁屏码规则（与 App 一致：纯数字 + 至少 6 位）：字母 → 提示「锁屏码只能是
#      数字」；5 位数字 → 提示「锁屏码至少 6 位数字」；6 位数字 → 设置成功
#   3) join 口令必填：第二台设备走到「验证密保口令」留空回车 → 同样被拦住
#      （不进入加入——否则会先 joinSpace 再取不到 Space Key，设备卡在
#      "已登记但无密钥"的坏状态）；补输同一口令后加入成功
#
# 运行：python3 cli/test/guide_input_rules_check.py
import json
import os, pty, subprocess, select, time, socket, tempfile, urllib.request, sys

# __file__ = <repo>/cli/test/x.py → 仓库根 = 上三级
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CLI = os.path.join(ROOT, 'cli')
WORK = tempfile.mkdtemp(prefix='einz-passphrase-')


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

        steps = [
            ('秘境入口', 'c\r'),
            ('我的名字', 'Lukas\r'),
            ('我的性别', '1\r'),
            ('伴侣的名字', 'Alice\r'),
            ('伴侣的性别', '2\r'),
        ]
        for expect, payload in steps:
            out = wait_text(m, expect)
            if expect not in out:
                print(f'❌ 未到「{expect}」问答')
                print(out[-600:])
                return 1
            send(m, payload)

        # 关键：口令留空回车 → 必须拦住
        out = wait_text(m, '设置密保口令')
        if '设置密保口令' not in out:
            print('❌ 未到口令问答')
            print(out[-600:])
            return 1
        send(m, '\r')
        out = wait_text(m, '此项不能为空', timeout=10)
        if '此项不能为空' not in out:
            print('❌ 留空口令未被拦住（未提示此项不能为空）')
            print(out[-600:])
            return 1
        if '正在创建秘境' in out or '成功创建秘境' in out:
            print('❌ 留空口令竟继续创建空间')
            print(out[-600:])
            return 1

        # 补输口令 → 创建成功
        send(m, 'abc123\r')
        out = wait_text(m, '成功创建秘境', timeout=40)
        if '成功创建秘境' not in out:
            print('❌ 输入口令后未创建成功')
            print(out[-600:])
            return 1

        print('✅ create：口令留空被拦下，补输后创建成功')

        # ---------- 锁屏码规则：纯数字 + 至少 6 位 ----------
        # 注意：TUI 在阻塞读键盘期间不会重绘（已知行为——提示要等下一次按键才
        # 出现），故不先等提示，直接发；未命中就重发（非法值会被拒，重发无害）。
        def input_until(payload, expect, tries=6, timeout=8):
            out = ''
            for _ in range(tries):
                send(m, payload)
                out = wait_text(m, expect, timeout=timeout)
                if expect in out:
                    break
            return out

        for wrong, expect in (
            ('abc\r', '锁屏码只能是数字'),      # 字母
            ('12345\r', '锁屏码至少 6 位数字'),  # 位数不足
        ):
            out = input_until(wrong, expect)
            if expect not in out:
                print(f'❌ 锁屏码 {wrong.strip()!r} 未被拦住（未提示「{expect}」）')
                print(out[-800:])
                return 1
            if '锁屏码已设置' in out:
                print(f'❌ 非法锁屏码 {wrong.strip()!r} 竟被接受')
                return 1
        out = input_until('123456\r', '锁屏码已设置')
        if '锁屏码已设置' not in out:
            print('❌ 6 位数字锁屏码未被接受')
            print(out[-800:])
            return 1
        print('✅ 锁屏码规则：字母/不足 6 位被拒，6 位数字通过')

        # ---------- 设备 B：join 的口令也必须必填 ----------
        with open(store) as f:
            store_a = json.load(f)
        req = urllib.request.Request(
            f'http://127.0.0.1:{port}/spaces/{store_a["space_id"]}/join-tokens',
            method='POST')
        with urllib.request.urlopen(req, timeout=5) as r:
            join_token = json.load(r)['joinToken']

        store_b = os.path.join(WORK, 'b.json')
        m2, p2 = start_tui(store_b, port)
        spawned.append((m2, p2))
        for expect, payload in [
            ('秘境入口', 'j\r'),
            ('输入邀请码', join_token + '\r'),
            ('我是谁', 'Alice\r'),
        ]:
            out = wait_text(m2, expect)
            if expect not in out:
                print(f'❌ B 未到「{expect}」问答')
                print(out[-600:])
                return 1
            send(m2, payload)

        out = wait_text(m2, '验证密保口令')
        if '验证密保口令' not in out:
            print('❌ B 未到口令问答')
            print(out[-600:])
            return 1
        send(m2, '\r')
        out = wait_text(m2, '此项不能为空', timeout=10)
        if '此项不能为空' not in out:
            print('❌ B 留空口令未被拦住（未提示此项不能为空）')
            print(out[-600:])
            return 1
        if '正在加入秘境' in out or '成功加入秘境' in out:
            print('❌ B 留空口令竟继续加入（会卡在无 Space Key 的坏状态）')
            print(out[-600:])
            return 1

        send(m2, 'abc123\r')
        out = wait_text(m2, '成功加入秘境', timeout=40)
        if '成功加入秘境' not in out:
            print('❌ B 输入口令后未加入成功')
            print(out[-600:])
            return 1

        print('✅ join：口令留空被拦下，补输后加入成功')
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
