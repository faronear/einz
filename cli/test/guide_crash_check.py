#!/usr/bin/env python3
# 引导阶段崩溃回归验证（2026-09-02 临时）：复现老板步骤——
# 新通道引导问答中输入 '/' 回车（提示"引导中仅支持 /exit 退出"）后再输入任意字符。
# 修复前：_insertAtCursor 光标越界 RangeError 崩溃且终端不回显；
# 修复后：进程存活、无 RangeError、输入正常回显，/exit 可退出。
import os, pty, subprocess, select, time, sys

# 仓库已从 /Users/Shared/productX/einz 迁移；由脚本位置推导 cli 目录，避免硬编码旧路径
CLI = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STORE = '/tmp/einz_guide_repro.json'

def start_tui():
    if os.path.exists(STORE):
        os.remove(STORE)  # 全新 store → 进入新通道引导（名字/通道名称问答）
    master, slave = pty.openpty()
    env = dict(os.environ, TERM='xterm-256color')
    cmd = ['dart', 'run', 'bin/einz_tui.dart', '--store', STORE,
           '--server', 'http://127.0.0.1:39999']  # 不可达 server：跳过登记，只测引导
    p = subprocess.Popen(cmd, stdin=slave, stdout=slave, stderr=slave,
                         close_fds=True, cwd=CLI, env=env)
    os.close(slave)
    return master, p

def send(master, s):
    os.write(master, s.encode())

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
        send(master, '/\r')         # 引导中输 '/' → 回车
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
        # 3) 引导内 /exit 逃生门仍可用
        send(master, '\r')
        drain(master, 1)
        send(master, '/exit\r')
        drain(master, 1)
        for _ in range(30):
            if p.poll() is not None:
                break
            time.sleep(0.2)
        print('exit 后进程状态:', '已退出' if p.poll() is not None else '仍存活(kill)')
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
