#!/usr/bin/env python3
# 引导中 /exit 应立即中断回归验证（适配"设备名自动设置"后的新引导流）：
# 新设备 store 为空 → _onboard 自动设默认设备名（不再有"请输入设备名称"问答）
# → 引导首个问答是"请输入您的名字"。在此处输入 /exit：
# 修复前：/exit 只让输入循环退出，引导继续（绑定中…）后才退；
# 修复后：立即结束引导（守卫 return），不再出现"设备与空间绑定中"等后续步骤。
import os, pty, subprocess, select, time, sys

CLI = '/Users/Shared/productX/einz/cli'
STORE = '/tmp/einz_guide_exit.json'

def start_tui():
    if os.path.exists(STORE):
        os.remove(STORE)
    master, slave = pty.openpty()
    env = dict(os.environ, TERM='xterm-256color')
    cmd = ['dart', 'run', 'bin/einz_tui.dart', '--store', STORE,
           '--server', 'http://127.0.0.1:39999']  # 不可达：跳过登记，只测引导问答
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
    out = ''
    try:
        # 1) 冷启动：服务器地址问答（回车沿用）→ _onboard 生成身份+自动默认设备名
        #    → 引导首个问答"请输入您的名字"
        out += drain(master, 8)
        send(master, '\r')  # 服务器地址：回车沿用
        deadline = time.time() + 20
        while '请输入您的名字' not in out and time.time() < deadline and p.poll() is None:
            out += drain(master, 0.8)
        if '请输入您的名字' not in out:
            print('❌ 未到达"请输入您的名字"问答（引导流程变化？）')
            print(out[-800:])
            return 1
        print('✅ 已到达"请输入您的名字"问答（设备名已自动设置，无设备名问答）')
        # 2) 在此输入 /exit → 应立即结束引导，不再出现绑定等后续步骤
        send(master, '/exit\r')
        deadline = time.time() + 8
        while time.time() < deadline and p.poll() is None:
            out += drain(master, 0.5)
        exited = p.poll() is not None
        leaked = '设备与空间绑定中' in out
        print('进程已退出:', exited)
        print('出现"绑定中"(应 False):', leaked)
        if exited and not leaked:
            print('✅ 修复生效：名字问答 /exit 后立即结束，无后续绑定输出')
            return 0
        print('❌ 未按预期退出或仍有后续提示')
        print(out[-800:])
        return 1
    finally:
        if p.poll() is None:
            p.kill()
        try:
            os.close(master)
        except OSError:
            pass

if __name__ == '__main__':
    sys.exit(main())
