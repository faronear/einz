#!/usr/bin/env python3
# 引导阶段崩溃回归验证（2026-09-02 立；2026-10-13 随「回车回退」模型更新）：
# 引导问答里输入 '/' 回车（旧版提示"引导中仅支持 /exit 退出"）后再输入任意字符。
# 修复前：_insertAtCursor 光标越界 RangeError 崩溃且终端不回显；
# 修复后：进程存活、无 RangeError、输入正常回显。
# 2026-10-13 起 '/' 只是无效回答（提示"请输入 c 或 j"），不再是命令；
# 退出手段改为直接回车（首问空回车 = 退出整个 TUI——见 guide_exit_check）。
import os, pty, subprocess, select, time, sys, tempfile

# 仓库已从 /Users/Shared/productX/einz 迁移；由脚本位置推导 cli 目录，避免硬编码旧路径
CLI = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STORE = os.path.join(tempfile.mkdtemp(prefix='einz-guide-repro-'), 'store.json')


def start_tui():
    master, slave = pty.openpty()
    env = dict(os.environ, TERM='xterm-256color')
    cmd = ['dart', 'run', 'bin/einz_tui.dart', '--store', STORE,
           '--server', 'http://127.0.0.1:39999']  # 不可达 server：跳过登记，只测引导
    p = subprocess.Popen(cmd, stdin=slave, stdout=slave, stderr=slave,
                         close_fds=True, cwd=CLI, env=env)
    os.close(slave)
    return master, p


def send(master, s):
    try:
        os.write(master, s.encode())
    except OSError:
        pass  # 进程已退出：master 写入无意义


def drain(master, seconds=1.0):
    out = b''
    deadline = time.time() + seconds
    while time.time() < deadline:
        r, _, _ = select.select([master], [], [], 0.2)
        if r:
            try:
                data = os.read(master, 8192)
            except OSError:
                break
            if not data:
                break
            out += data
    return out.decode('utf-8', errors='replace')


def main():
    master, p = start_tui()
    try:
        # 1) 冷启动（dart run 2-5s）+ 引导问答渲染；不可达 server 会有地址问答，回车沿用
        out = drain(master, 8)
        send(master, '\r')          # 服务器地址：回车沿用当前值
        drain(master, 2)
        send(master, '/\r')         # 引导中输 '/' → 回车（无效回答：提示请输入 c 或 j）
        drain(master, 2)
        out += drain(master, 2)
        send(master, 'x')           # 再输入任意字符（修复前在此崩溃）
        drain(master, 1)
        out += drain(master, 2)
        alive = p.poll() is None
        crashed = 'RangeError' in out or 'Unhandled exception' in out
        print('进程存活:', alive)
        print('出现崩溃特征:', crashed)
        if alive and not crashed:
            print('✅ 修复生效：引导中 / 后输入字符不再崩溃')
        else:
            print('❌ 仍崩溃或异常退出')
            print(out[-800:])
            return 1
        # 2) 回显检查：再输入 ab，看输出是否含 ab（终端 echo 正常）
        send(master, 'ab')
        drain(master, 1)
        out2 = drain(master, 1)
        if 'ab' in out2:
            print('✅ 输入回显正常')
        else:
            print('⚠️ 未检测到回显（pty 渲染下可能被吞，仅提示）')
        # 3) 首问空回车 = 退出整个 Tui（2026-10-13 回退模型；/exit 已废除）。
        # 注意：输入行里可能还留着刚才回显测试的 'xab'——第一个回车提交它
        # （无效回答，停在首问），第二个回车才是空回车退出。
        for _ in range(3):
            if p.poll() is not None:
                break
            send(master, '\r')
            drain(master, 1.2)
        for _ in range(30):
            if p.poll() is not None:
                break
            time.sleep(0.2)
        print('空回车后进程状态:', '已退出' if p.poll() is not None else '仍存活(kill)')
        if p.poll() is None:
            p.kill()
        return 0
    finally:
        if p.poll() is None:
            p.kill()
        try:
            os.close(master)
        except OSError:
            pass


if __name__ == '__main__':
    sys.exit(main())
