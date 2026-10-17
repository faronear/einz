#!/usr/bin/env python3
# 内置文件浏览器回归（方案 B，老板 2026-10-17）：
#
#   `/attach` / `/avatar` 不带参数时，系统文件选择窗口不可用（或无 GUI）会落进
#   TUI 内置的文件浏览器：纯键盘列目录、↑↓ 移动、Enter 进入/选中、Backspace 上级、
#   q/Esc 取消、h 切换隐藏文件；/avatar 只放行图片。选中后把 `<命令> <路径>` 填进
#   输入行（不自动发送）。
#
# 为什么用 EINZ_TUI_PICKER=browser：测试机（CI/SSH）可能没有 GUI，也可能有
#   （macOS 有 osascript）——不固定模式就会随机走系统窗口弹对话框。browser 模式
#   强制走内置浏览器，断言才确定。
#
# 断言（pty 真实渲染，按光标定位序列还原成二维屏幕）：
#   ① 列出目录：`..` + 目录（带 /）+ 文件（带大小），头部是当前目录
#   ② 选中文件：输入行变成 `/attach <路径>`，浏览器退出
#   ③ q 取消：浏览器退出、输入行清空、进程存活
#   ④ Esc 取消（裸 Esc 走 50ms 超时判定）
#   ⑤ Enter 进子目录、Backspace 回上级
#   ⑥ /avatar 只放行图片：选 .txt 出提示且不退出，改选 .png 才填入
#   ⑦ h 切换隐藏文件
#   ⑧ 选中行有反显高亮（\x1b[7m）
#
# 运行：python3 cli/test/file_browser_check.py
import base64
import fcntl
import json
import os
import pty
import re
import select
import struct
import subprocess
import sys
import tempfile
import termios
import time

CLI = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROWS, COLS = 40, 110
ANSI = re.compile(rb'\x1b\[[0-9;?]*[A-Za-z]|\x1b[\(\)][A-Za-z0-9]')
CUP = re.compile(rb'\x1b\[(\d*)(?:;(\d*))?H')
DOWN, UP, CR, BS, ESC = b'\x1b[B', b'\x1b[A', b'\r', b'\x7f', b'\x1b'


def write_store(path):
    """手工造一个"已绑定空间"的 store：TUI 直接进聊天态，不必跑向导/服务端。"""
    store = {
        'entrance_id': 'dev-a1',
        'public_key': base64.b64encode(bytes(32)).decode(),
        'private_key': base64.b64encode(bytes(32)).decode(),
        'member_id': 'member-a',
        'member_name': 'Lukas',
        'entrance_name': 'dev-a1',
        'space_key': base64.b64encode(bytes(32)).decode(),
        'space_id': 'space-demo',
        'key_version': 1,
        'session_token': 'token-x',
        'history': [],
        'attachments': [],
        'pending': [],
    }
    with open(path, 'w') as f:
        json.dump(store, f)


def to_screen(buf):
    """按光标定位/清行序列把字节流还原成二维屏幕（TUI 是全屏重绘应用）。"""
    grid = [[' '] * COLS for _ in range(ROWS)]
    r = c = 0
    i = 0
    while i < len(buf):
        m = CUP.match(buf, i)
        if m:
            r = (int(m.group(1) or 1)) - 1
            c = (int(m.group(2) or 1)) - 1
            i = m.end()
            continue
        m = ANSI.match(buf, i)
        if m:
            seq = m.group(0)
            if seq.endswith(b'K'):
                mode = seq[2:-1]
                if mode in (b'', b'0'):
                    for k in range(c, COLS):
                        if 0 <= r < ROWS:
                            grid[r][k] = ' '
                elif mode == b'2' and 0 <= r < ROWS:
                    grid[r] = [' '] * COLS
            elif seq.endswith(b'J') and seq[2:-1] in (b'2', b'3'):
                grid = [[' '] * COLS for _ in range(ROWS)]
            i = m.end()
            continue
        ch = buf[i:i + 1]
        i += 1
        if ch == b'\r':
            c = 0
            continue
        if ch == b'\n':
            r += 1
            continue
        if ch[0] & 0xC0 == 0xC0:  # UTF-8 多字节
            n = 2 if ch[0] & 0xE0 == 0xC0 else 3 if ch[0] & 0xF0 == 0xE0 else 4
            ch = buf[i - 1:i - 1 + n]
            i = i - 1 + n
        if 0 <= r < ROWS and 0 <= c < COLS:
            try:
                text = ch.decode('utf-8')
            except Exception:
                text = '?'
            w = 2 if ord(text[0]) >= 0x1100 else 1
            for k in range(w):
                if c + k < COLS:
                    grid[r][c + k] = text if k == 0 else ''
            c += w
        else:
            c += 1
    return [''.join(row).rstrip() for row in grid]


class Tui:
    """一个跑在 pty 里的 TUI 实例（store/服务器/HOME 都可指定）。"""

    def __init__(self, store, home, picker='browser'):
        self.buf = b''
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ,
                    struct.pack('HHHH', ROWS, COLS, 0, 0))
        env = dict(os.environ, TERM='xterm-256color', HOME=home,
                   EINZ_TUI_PICKER=picker)
        cmd = ['dart', 'run', 'bin/einz_tui.dart', '--store', store,
               '--server', 'http://127.0.0.1:59999']  # 不可达：只走引导/聊天态
        self.p = subprocess.Popen(cmd, stdin=slave, stdout=slave,
                                  stderr=slave, close_fds=True, cwd=CLI,
                                  env=env)
        os.close(slave)

    def pump(self, seconds=1.0):
        deadline = time.time() + seconds
        while time.time() < deadline:
            r, _, _ = select.select([self.master], [], [], 0.2)
            if r:
                try:
                    data = os.read(self.master, 65536)
                except OSError:
                    break
                if not data:
                    break
                self.buf += data

    def clear_input(self):
        """为下一条命令清场：① 浏览器开着就先 q 关掉（浏览器态退格=回上级目录，
        不是删字符，300 个退格会把目录退到根）；② 再发 300 个退格清空输入行
        （选中文件后输入行是 `<命令> <绝对路径>`，实测可达 83 字符，80 个不够）。"""
        if '↑↓ 移动' in self.text():
            self.send(b'q')
            self.pump(2.0)
        self.send(BS * 300)
        self.pump(2.0)

    def send(self, keys):
        try:
            os.write(self.master, keys)
        except OSError:
            pass  # 进程已退出

    def screen(self):
        return to_screen(self.buf)

    def text(self):
        return '\n'.join(self.screen())

    def wait_chat(self, timeout=30):
        """等到聊天态（状态栏出现命令提示）；途中应答"服务器地址"问答。"""
        deadline = time.time() + timeout
        while time.time() < deadline:
            self.pump(1.0)
            if '/help 查看命令' in self.text():
                return True
            if '回车沿用' in self.text():  # 不可达 server 的地址问答：回车沿用
                self.send(CR)
                self.pump(1.5)
        return False

    def alive(self):
        return self.p.poll() is None

    def stop(self):
        try:
            self.p.terminate()
        except Exception:
            pass


def fail(msg):
    print('FAIL:', msg)
    sys.exit(1)


def main():
    home = tempfile.mkdtemp(prefix='einz-browse-')
    work = tempfile.mkdtemp(prefix='einz-browse-store-')
    os.makedirs(os.path.join(home, 'sub'))
    with open(os.path.join(home, 'a.txt'), 'w') as f:
        f.write('x')
    with open(os.path.join(home, 'b.png'), 'w') as f:
        f.write('yy')
    with open(os.path.join(home, 'sub', 'c.txt'), 'w') as f:
        f.write('zzz')
    with open(os.path.join(home, '.hidden.txt'), 'w') as f:
        f.write('h')
    store = os.path.join(work, 'store.json')
    write_store(store)

    t = Tui(store, home)
    try:
        if not t.wait_chat():
            fail('TUI 未进入聊天态（30s 超时）')
        print('聊天态就绪')

        # ① 列出目录
        t.send(b'/attach\r')
        t.pump(4)
        text = t.text()
        for needle in ['..', 'sub/', 'a.txt', 'b.png',
                       '↑↓ 移动', 'Enter 进入/选中', 'Backspace 上级', 'q 取消']:
            if needle not in text:
                fail(f'① 浏览器列表缺少 {needle!r}')
        if home not in text:
            fail('① 头部未显示当前目录')
        if ' 目录 / ' not in text:
            fail('① 头部未显示目录/文件计数')
        print('① 目录列表 OK（.. + sub/ + a.txt + b.png + 提示行 + 头部）')

        # ② 选中文件（光标 0=.. → ↓↓ 到 a.txt）→ 输入行填 `/attach <路径>`
        t.send(DOWN)
        t.pump(1.5)
        t.send(DOWN)
        t.pump(1.5)
        t.send(CR)
        t.pump(2.5)
        text = t.text()
        if f'/attach {home}/a.txt' not in text:
            fail(f'② 选中 a.txt 后输入行未填入路径：{text[-200:]!r}')
        if '↑↓ 移动' in text:
            fail('② 选中后浏览器未退出')
        print('② 选中文件 → 输入行 /attach <路径>，浏览器退出')

        # ③ q 取消
        t.clear_input()
        t.send(b'/attach\r')
        t.pump(4)
        t.send(b'q')
        t.pump(2.5)
        text = t.text()
        if '↑↓ 移动' in text:
            fail('③ q 未退出浏览器')
        input_line = [l for l in t.screen() if l.strip().startswith('[我]')]
        if input_line and input_line[-1].strip() != '[我]':
            fail(f'③ q 取消后输入行应清空，实际 {input_line[-1]!r}')
        if not t.alive():
            fail('③ q 取消后进程退出')
        print('③ q 取消 OK（退出 + 输入行清空 + 进程存活）')

        # ④ Esc 取消（裸 Esc：50ms 超时判定）
        t.clear_input()
        t.send(b'/attach\r')
        t.pump(4)
        t.send(ESC)
        t.pump(2.5)
        if '↑↓ 移动' in t.text():
            fail('④ Esc 未退出浏览器')
        print('④ Esc 取消 OK')

        # ⑤ Enter 进子目录 + Backspace 回上级
        t.clear_input()
        t.send(b'/attach\r')
        t.pump(4)
        t.send(DOWN)  # .. → sub/
        t.pump(1.5)
        t.send(CR)
        t.pump(2.5)
        if f'{home}/sub' not in t.text() or 'c.txt' not in t.text():
            fail('⑤ 进入子目录失败')
        t.send(BS)
        t.pump(2.5)
        text = t.text()
        if home not in text or 'a.txt' not in text:
            fail('⑤ Backspace 未回上级目录')
        print('⑤ 进子目录 / Backspace 回上级 OK')

        # ⑥ /avatar 只放行图片
        t.clear_input()
        t.send(b'/avatar\r')
        t.pump(4)
        t.send(DOWN)  # .. → sub/
        t.pump(1.5)
        t.send(DOWN)  # sub/ → a.txt
        t.pump(1.5)
        t.send(CR)
        t.pump(2.5)
        text = t.text()
        if '头像只能是图片' not in text:
            fail('⑥ 选非图片未给提示')
        if '↑↓ 移动' not in text:
            fail('⑥ 选非图片后浏览器不应退出')
        t.send(DOWN)  # a.txt → b.png
        t.pump(1.5)
        t.send(CR)
        t.pump(2.5)
        if f'/avatar {home}/b.png' not in t.text():
            fail('⑥ 选图片未填入 /avatar <路径>')
        print('⑥ /avatar 只放行图片 OK（拦 .txt 有提示，放行 .png）')

        # ⑦ h 切换隐藏文件
        t.clear_input()
        t.send(b'/attach\r')
        t.pump(4)
        if '.hidden.txt' in t.text():
            fail('⑦ 默认不应显示隐藏文件')
        t.send(b'h')
        t.pump(2.5)
        text = t.text()
        if '.hidden.txt' not in text or '含隐藏' not in text:
            fail('⑦ 按 h 未显示隐藏文件')
        print('⑦ h 切换隐藏文件 OK')

        # ⑧ 选中行反显高亮
        if b'\x1b[7m' not in t.buf:
            fail('⑧ 选中行无反显高亮')
        print('⑧ 选中行反显 OK')

        if not t.alive():
            fail('收尾：进程已退出')
        print('\n全部通过：内置文件浏览器（方案 B）')
    finally:
        t.stop()


if __name__ == '__main__':
    main()
