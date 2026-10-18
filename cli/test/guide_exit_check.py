#!/usr/bin/env python3
# 引导首问空回车退出回归（2026-10-13 回退模型重写；
# 旧版测的是「引导中 /exit 立即中断」——/exit 逃生门已按老板 2026-10-13 决策废除：
# TUI 里所有要求输入的地方都不认 /exit，唯一的退出手段是直接回车；向导首问
# （秘境入口 c/j）没有上一问可回退，空回车 = 退出整个 TUI）。
#
# 新通道 store 为空 → _onboard 自动设默认通道名 → 引导首问是「秘境向导 c/j」。
# 在此处直接回车：应立即退出进程，且不出现加入/创建等后续步骤输出。
import os, pty, re, select, subprocess, sys, tempfile, time

# 由脚本位置推导 cli 目录（仓库已迁移过，不硬编码）
CLI = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STORE = os.path.join(tempfile.mkdtemp(prefix='einz-guide-exit-'), 'store.json')
ANSI = re.compile(r'\x1b\[[0-9;?]*[A-Za-z]')


def start_tui():
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
        # 1) 冷启动：服务器地址问答（回车沿用）→ _onboard 生成身份+自动默认通道名
        #    → 引导首问「秘境向导」
        out += drain(master, 8)
        send(master, '\r')  # 服务器地址：回车沿用
        deadline = time.time() + 20
        while '秘境向导' not in out and time.time() < deadline and p.poll() is None:
            out += drain(master, 0.8)
        if '秘境向导' not in out:
            print('❌ 未到达「秘境向导」问答（引导流程变化？）')
            print(ANSI.sub('', out)[-800:])
            return 1
        print('✅ 已到达「秘境向导」首问（通道名已自动设置，无通道名问答）')
        # 2) 首问直接回车 = 退出整个 Tui：应立即结束，不再出现加入/创建等后续步骤
        send(master, '\r')
        deadline = time.time() + 10
        while time.time() < deadline and p.poll() is None:
            out += drain(master, 0.5)
        exited = p.poll() is not None
        leaked = '通道与空间绑定中' in out or '正在创建秘境' in out or '正在加入秘境' in out
        print('进程已退出:', exited)
        print('出现后续步骤输出(应 False):', leaked)
        if exited and not leaked:
            print('✅ 修复生效：首问空回车后立即退出，无后续步骤输出')
            return 0
        print('❌ 未按预期退出或仍有后续提示')
        print(ANSI.sub('', out)[-800:])
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
