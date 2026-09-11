#!/usr/bin/env python3
# 创建空间口令必填回归：引导 create 走到「设置密保口令」时留空回车 → 必须被拦住
# （提示「此项不能为空」，且不进入创建）；补输口令后创建成功。
#
# 运行：python3 cli/test/create_passphrase_required_check.py
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

        print('✅ 创建空间口令必填：留空被拦下，补输后创建成功')
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
