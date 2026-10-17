#!/usr/bin/env python3
# Tab 路径补全回归（方案 C，老板 2026-10-17）：
#
#   聊天态按 Tab 补全光标所在的路径 token——"大致知道图片在哪、记不清每段叫啥"
#   时用键盘敲完：唯一匹配直接补全（目录补到带 /），多个匹配扩展到最长公共前缀
#   并列候选，没有匹配给提示、不改输入。~ 形式在输入行保留原样。
#
# 只补"路径样子"的词：含 / 或以 ~ 开头，或 /attach /avatar /backup /switch 的参数
#   （裸名按 TUI 的 cwd 解析，与 shell 一致）。聊天词、行首命令名一律不补。
#   浏览器态（方案 B）是模态的，Tab 无效。
#
# 断言（pty 真实渲染，按光标定位序列还原二维屏幕）：
#   ① 唯一匹配直接补全
#   ② 多个匹配 → 最长公共前缀 + 候选消息（候选前带文件图标 📄）
#   ③ 目录补到带 /（可接着 Tab 进下一层）
#   ④ 没有匹配：输入不动 + 消息流提示（不落底部通知条——老板 2026-10-18）
#   ⑤ 裸名按 cwd 补全（cli 目录下 pubs → pubspec.，因 pubs.lock/yaml 两个候选）
#   ⑥ 聊天消息里的词不补
#   ⑦ 行首命令名不补
#   ⑧ 浏览器态 Tab 无效（浏览器不关、不补全）
#   ⑨ 连按多次 Tab 只保留一条候选消息（替换而非堆积）
#   ⑩ 候选列表带类型图标：目录 📁 / 文件 📄（混排时可区分——老板 2026-10-18）
#   ⑪ 目录读不了：提示同样进消息流（不落底部通知条——老板 2026-10-18）
#
# 运行：python3 cli/test/tab_complete_check.py
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
TAB = b'\t'


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
        if ch[0] & 0xC0 == 0xC0:
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
    """一个跑在 pty 里的 TUI 实例（store 手工造：已绑定空间，直接进聊天态）。"""

    def __init__(self, store, home, picker=None):
        self.buf = b''
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ,
                    struct.pack('HHHH', ROWS, COLS, 0, 0))
        env = dict(os.environ, TERM='xterm-256color', HOME=home)
        if picker:
            env['EINZ_TUI_PICKER'] = picker
        cmd = ['dart', 'run', 'bin/einz_tui.dart', '--store', store,
               '--server', 'http://127.0.0.1:59999']  # 不可达：只走聊天态
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

    def send(self, keys):
        try:
            os.write(self.master, keys)
        except OSError:
            pass

    def screen(self):
        return to_screen(self.buf)

    def text(self):
        return '\n'.join(self.screen())

    def input_line(self):
        for line in reversed(self.screen()):
            if line.strip().startswith('[我]'):
                return line.strip()
        return ''

    def wait_chat(self, timeout=30):
        deadline = time.time() + timeout
        while time.time() < deadline:
            self.pump(1.0)
            if '/help 查看命令' in self.text():
                return True
            if '回车沿用' in self.text():
                self.send(b'\r')
                self.pump(1.5)
        return False

    def wait_for(self, needle, timeout=10):
        """等到屏幕上出现 needle（轮询泵帧）；比固定 pump 确定（负载下不抖）。"""
        deadline = time.time() + timeout
        while time.time() < deadline:
            if needle in self.text():
                return True
            self.pump(0.4)
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
    # HOME 造一个受控目录（候选可预期）；cwd = cli/（裸名补全基准）
    home = tempfile.mkdtemp(prefix='einz-tab-')
    work = tempfile.mkdtemp(prefix='einz-tab-store-')
    pics = os.path.join(home, 'Pictures')
    os.makedirs(os.path.join(pics, 'wallpaper'))
    for name in ('photo.png', 'photo2.png', 'pic.jpg'):
        with open(os.path.join(pics, name), 'w') as f:
            f.write('x')
    store = os.path.join(work, 'store.json')
    with open(store, 'w') as f:
        json.dump({
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
            'history': [], 'attachments': [], 'pending': [],
        }, f)

    t = Tui(store, home)
    try:
        if not t.wait_chat():
            fail('TUI 未进入聊天态（30s 超时）')
        print('聊天态就绪')

        def tab(typed, expect, timeout=10):
            # 先清空输入行（200 退格覆盖任何长度）：上一步补全的结果还留在行里，
            # 不清会把下一步的输入拼成残句；再发「输入 + Tab」并等到预期输入行
            t.send(b'\x7f' * 200)
            t.pump(1.0)
            t.send(typed.encode() + TAB)
            return t.wait_for(expect, timeout)

        # ① 唯一匹配直接补全（photo. 只剩 photo.png）
        if not tab('/attach ~/Pictures/photo.', '[我] /attach ~/Pictures/photo.png'):
            fail(f'① 唯一匹配未补全：{t.input_line()!r}')
        print('① 唯一匹配补全 OK（photo. → photo.png）')

        # ② 多个匹配 → 最长公共前缀 + 候选消息（候选前带文件图标）
        if not tab('/attach ~/Pictures/pho', '[我] /attach ~/Pictures/photo'):
            fail(f'② 未扩展到最长公共前缀：{t.input_line()!r}')
        text = t.text()
        if '匹配 2 项' not in text or 'photo.png' not in text or 'photo2.png' not in text:
            fail('② 候选消息缺失或不完整')
        if '📄 photo.png' not in text or '📄 photo2.png' not in text:
            fail('② 候选前缺少文件图标（老板 2026-10-18）')
        print('② 多匹配 LCP + 候选消息 OK（pho → photo，列出 2 项，带 📄）')

        # ③ 目录补到带 /
        if not tab('/attach ~/Pictures/wall', '[我] /attach ~/Pictures/wallpaper/'):
            fail(f'③ 目录未补到带 /：{t.input_line()!r}')
        print('③ 目录补全加 / OK')

        # ④ 没有匹配：输入不动 + 消息流提示（提示在消息区、不在底部状态行）
        t.send(b'\x7f' * 200)
        t.pump(1.0)
        t.send(b'/attach ~/Pictures/zzz' + TAB)
        if not t.wait_for('没有以'):
            fail('④ 无匹配时无提示')
        if t.input_line() != '[我] /attach ~/Pictures/zzz':
            fail(f'④ 无匹配时输入被改动：{t.input_line()!r}')
        rows = t.screen()
        if '没有以' in rows[-1]:
            fail('④ 提示仍出现在底部状态行（应进消息流——老板 2026-10-18）')
        if not any('没有以' in line for line in rows[:-1]):
            fail('④ 提示不在消息区')
        print('④ 无匹配：输入不动 + 消息流提示（非状态行）OK')

        # ⑤ 裸名按 cwd 补全（cli 目录下 pubs → pubspec.，lock/yaml 两个候选）
        if not tab('/attach pubs', '[我] /attach pubspec.'):
            fail(f'⑤ 裸名未按 cwd 补全：{t.input_line()!r}')
        print('⑤ 裸名按 cwd 补全 OK（pubs → pubspec.，两候选取 LCP）')

        # ⑥ 聊天消息里的词不补
        t.send(b'\x7f' * 200)
        t.pump(1.0)
        t.send(b'hello wor' + TAB)
        t.pump(2.0)
        if t.input_line() != '[我] hello wor':
            fail(f'⑥ 聊天词被补全了：{t.input_line()!r}')
        t.send(b'\x7f' * 200)
        t.pump(1.0)
        print('⑥ 聊天词不补 OK')

        # ⑦ 行首命令名不补（Tab 无动作）
        t.send(b'/att' + TAB)
        t.pump(2.0)
        if t.input_line() != '[我] /att':
            fail(f'⑦ 行首命令名被补全了：{t.input_line()!r}')
        t.send(b'\x7f' * 200)
        t.pump(1.0)
        print('⑦ 行首命令名不补 OK')

        # ⑧ 浏览器态 Tab 无效（强制 browser 模式：不弹系统对话框）
        t2 = Tui(store, home, picker='browser')
        try:
            if not t2.wait_chat():
                fail('⑧ 第二个 TUI 未进入聊天态')
            t2.send(b'/attach\r')
            t2.pump(4)
            if '↑↓ 移动' not in t2.text():
                fail('⑧ 浏览器未打开')
            t2.send(TAB)
            t2.pump(2.0)
            if '↑↓ 移动' not in t2.text():
                fail('⑧ 浏览器态按 Tab 被关掉了')
            if '匹配' in t2.text():
                fail('⑧ 浏览器态按 Tab 触发了补全')
            if not t2.alive():
                fail('⑧ 浏览器态按 Tab 后进程退出')
            print('⑧ 浏览器态 Tab 无效 OK（不关浏览器、不补全）')
        finally:
            t2.stop()

        # ⑨ 连按多次 Tab：候选消息只留一条（替换而非堆积）
        t.send(b'/attach ~/Pictures/p' + TAB + TAB + TAB)
        if not t.wait_for('匹配 3 项'):
            fail('⑨ 未出现候选消息')
        t.pump(1.5)
        count = t.text().count('匹配 3 项')
        if count != 1:
            fail(f'⑨ 候选消息应只有 1 条，实际 {count} 条')
        print('⑨ 重复 Tab 只保留一条候选消息 OK')

        # ⑩ 候选列表带类型图标：目录 📁 / 文件 📄（混排时可区分）
        t.send(b'\x7f' * 200)
        t.pump(1.0)
        t.send(b'/attach ~/Pictures/' + TAB)
        if not t.wait_for('匹配 4 项'):
            fail('⑩ 未列出整个目录的候选')
        text = t.text()
        if '📁 wallpaper/' not in text:
            fail('⑩ 目录候选前缺少 folder 图标（或目录名未带 /）')
        if '📄 photo.png' not in text:
            fail('⑩ 文件候选前缺少文件图标')
        print('⑩ 候选图标 OK（📁 目录 / 📄 文件，各就各位）')

        # ⑪ 目录读不了（不存在/无权限）：提示进消息流、不在底部状态行
        t.send(b'\x7f' * 200)
        t.pump(1.0)
        t.send(b'/attach ~/NoSuchDir/x' + TAB)
        if not t.wait_for('目录不存在或读不了'):
            fail('⑪ 目录读不了时无提示')
        rows = t.screen()
        if '目录不存在或读不了' in rows[-1]:
            fail('⑪ 目录读不了的提示仍出现在底部状态行（应进消息流）')
        if not any('目录不存在或读不了' in line for line in rows[:-1]):
            fail('⑪ 目录读不了的提示不在消息区')
        print('⑪ 目录读不了：消息流提示（非状态行）OK')

        if not t.alive():
            fail('收尾：进程已退出')
        print('\n全部通过：Tab 路径补全（方案 C）')
    finally:
        t.stop()


if __name__ == '__main__':
    main()
