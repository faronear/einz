#!/usr/bin/env python3
# 引导中 /exit 应立即中断回归验证（2026-09-03 修复）：复现老板步骤——
# 新设备引导到"请输入设备名称"问答时输入 /exit。
# 修复前：引导继续执行（"系统将为您自动设置本设备名称"→"设备与空间绑定中"）
# 才退出；修复后：立即结束，不再输出后续引导提示。
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
        # 1) 冷启动 + 服务器地址问答（不可达→回车沿用）→ 出现"请输入您的名字"
        out += drain(master, 8)
        send(master, '\r')            # 服务器地址：回车沿用
        out += drain(master, 2)
        # 2) 名字问答：回车跳过 → 出现"请输入设备名称"
        send(master, '\r')
        out += drain(master, 2)
        if '请输入设备名称' not in out:
            print('❌ 未到达设备名称问答（引导流程变化？）')
            print(out[-600:])
            return 1
        print('✅ 已到达设备名称问答')
        # 3) 输入 /exit → 应立即退出，且不再出现后续引导提示
        send(master, '/exit\r')
        deadline = time.time() + 6
        while time.time() < deadline and p.poll() is None:
            out += drain(master, 0.5)
        exited = p.poll() is not None
        leaked = ('系统将为您自动设置本设备名称' in out) or ('设备与空间绑定中' in out)
        print('进程已退出:', exited)
        print('出现后续引导提示(应 False):', leaked)
        if exited and not leaked:
            print('✅ 修复生效：设备名称问答 /exit 后立即结束，无后续引导输出')
        else:
            print('❌ 未按预期退出或仍有后续提示')
            print(out[-800:])
            return 1
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
