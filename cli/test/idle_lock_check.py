#!/usr/bin/env python3
# 无操作自动锁屏回归（老板 2026-10-23，对齐 App；五个决策点的行为固化）：
# ① /lock 手动锁：锁后历史遮蔽（只显解锁提示）、错码挡住、空回车原地重问
#    （不退出——决策 #2）、对码恢复且历史回来；
# ② /lock <秒> 设阈值（越界拒绝）+ 看门狗到点自动锁 + 解锁恢复。
# 前置：demo/store-a.json（已绑定、无 PIN、无 token——离线可走完启动流进聊天）。
import os, pty, re, select, shutil, subprocess, sys, tempfile, time

CLI = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEMO_STORE = os.path.join(CLI, 'demo/store-a.json')
ANSI = re.compile(r'\x1b\[[0-9;?]*[A-Za-z]')
PIN = '123456'
WRONG = '000000'
MARKER = '✅ 锁屏码已设置'      # 锁定前加入的消息：锁定后应被遮蔽
LOCK_PROMPT = '❓ 输入锁屏码（Ctrl+C 退出）'
RESTORED = '✅ 锁屏码验证成功，已恢复'


# stderr 独立管道（调试/错误输出不与 TUI 的 ANSI 流交错）；start_tui 时赋值
_ERR_R = [None]
_ERR_BUF = ['']  # stderr 累积（失败时打印，定位用）


def start_tui(store):
    master, slave = pty.openpty()
    # stderr 走独立管道：调试日志不与 TUI 的 ANSI 输出交错（否则 [DBG] 行被搅碎）
    err_r, err_w = os.pipe()
    env = dict(os.environ, TERM='xterm-256color')
    cmd = ['dart', 'run', 'bin/einz_tui.dart', '--store', store,
           '--server', 'http://127.0.0.1:39999']  # 不可达：跳过登记/认证
    p = subprocess.Popen(cmd, stdin=slave, stdout=slave, stderr=err_w,
                         close_fds=True, cwd=CLI, env=env)
    os.close(slave)
    os.close(err_w)
    _ERR_R[0] = err_r
    return master, p


def drain(master, seconds=1.0):
    out = b''
    err = _ERR_R[0]
    fds = [master] + ([err] if err else [])
    deadline = time.time() + seconds
    while time.time() < deadline:
        r, _, _ = select.select(fds, [], [], 0.2)
        for fd in r:
            try:
                data = os.read(fd, 8192)
            except OSError:
                continue
            if not data:
                continue
            if fd == master:
                out += data
            else:
                _ERR_BUF[0] += data.decode('utf-8', errors='replace')
    return out.decode('utf-8', errors='replace')


def wait_for(master, out, needle, timeout):
    deadline = time.time() + timeout
    while needle not in out and time.time() < deadline:
        out += drain(master, 0.8)
    return out


def wait_count(master, out, needle, want, timeout):
    # 等 needle 出现满 want 次——区分重复出现的字符串（如"已恢复"），
    # 防止 wait_for 匹配到旧内容造成误报
    deadline = time.time() + timeout
    while out.count(needle) < want and time.time() < deadline:
        out += drain(master, 0.8)
    return out


def last_frame(out):
    # 最后一帧（_render 每帧以 \x1b[2J 清屏开头）剥 ANSI 后的可见内容
    return ANSI.sub('', out.split('\x1b[2J')[-1])


def send(master, s):
    os.write(master, s.encode())


def main():
    if not os.path.exists(DEMO_STORE):
        print('❌ 缺少 ' + DEMO_STORE)
        return 1
    store = os.path.join(tempfile.mkdtemp(prefix='esp-lock-', dir='/tmp'), 'store.json')
    shutil.copy(DEMO_STORE, store)
    master, p = start_tui(store)
    out = ''
    ok = True
    try:
        # 0) 进聊天态（离线：认证失败警告是引导跑完的标志）
        out += drain(master, 8)
        send(master, '\r')  # 服务器地址：回车沿用
        out = wait_for(master, out, '机密线路激活失败', 30)
        time.sleep(5)  # 等 _activateAfterBind 收尾，输入循环就绪
        if '机密线路激活失败' not in out:
            print('❌ 未进入聊天态')
            print(last_frame(out)[-800:])
            return 1
        print('[0] 已进入聊天态（未设 PIN，不锁）')

        # 1) 设 PIN
        send(master, '/pin ' + PIN + '\r')
        out = wait_for(master, out, MARKER, 15)
        print('[1] /pin 设码:', MARKER in out)
        ok = ok and MARKER in out

        # 2) /lock 手动锁 → 历史遮蔽 + 解锁提示
        send(master, '/lock\r')
        out = wait_for(master, out, LOCK_PROMPT, 15)
        frame = last_frame(out)
        hidden_ok = LOCK_PROMPT in frame and MARKER not in frame
        print('[2] /lock 锁屏：提示出现=%s，历史已遮蔽=%s' % (LOCK_PROMPT in frame, MARKER not in frame))
        ok = ok and hidden_ok

        # 3) 错码挡住
        send(master, WRONG + '\r')
        out = wait_for(master, out, '⚠️ 锁屏码验证错误', 15)
        frame = last_frame(out)
        still = LOCK_PROMPT in frame and MARKER not in frame
        print('[3] 错码仍锁:', still)
        ok = ok and still

        # 4) 空回车 = 原地重问（不退出——决策 #2）
        before = len(out)
        send(master, '\r')
        time.sleep(3)
        out += drain(master, 1)
        alive = p.poll() is None
        reask = '⚠️ 请输入锁屏码' in out[before:]
        print('[4] 空回车：进程存活=%s，原地重问=%s' % (alive, reask))
        ok = ok and alive and reask

        # 5) 对码恢复 + 历史回来（等"已恢复"第 1 次出现——计数区分，防旧内容误报）
        send(master, PIN + '\r')
        out = wait_count(master, out, RESTORED, 1, 15)
        frame = last_frame(out)
        restored = out.count(RESTORED) >= 1 and RESTORED in frame and MARKER in frame
        print('[5] 对码恢复：确认消息=%s，历史回归=%s' % (RESTORED in frame, MARKER in frame))
        ok = ok and restored

        # 6) /lock 越界拒绝 + 合法设置
        send(master, '/lock 5\r')
        out = wait_for(master, out, '⚠️ 阈值须为 20~1200 秒', 15)
        range_ok = '⚠️ 阈值须为 20~1200 秒' in out
        print('[6] /lock 5 越界拒绝:', range_ok)
        ok = ok and range_ok
        send(master, '/lock 20\r')
        out = wait_for(master, out, '✅ 无操作 20 秒后自动锁屏', 15)
        set_ok = '✅ 无操作 20 秒后自动锁屏' in out
        print('[6] /lock 20 设置生效:', set_ok)
        ok = ok and set_ok

        # 7) 看门狗：无操作 20s 后自动锁（不再发任何输入）。
        #    判定用**标题栏身份**：解锁帧标题栏右段有 '@dev-a1'（entrance 标签），
        #    锁定时 _identityHidden 把身份全藏了（只剩居中 Einz）。等标题栏身份
        #    消失 = 真锁了。
        #    （不能用"提示在帧里 + MARKER 不在"——解锁帧的滚动历史里就有旧提示词，
        #     而 MARKER 早滚出可视窗口，会立即误报；2026-10-23 实测踩过）
        deadline = time.time() + 40
        while time.time() < deadline:
            out += drain(master, 1.0)
            frame = last_frame(out)
            if 'dev-a1' not in frame[:120]:
                break
        frame = last_frame(out)
        auto = 'dev-a1' not in frame[:120]
        print('[7] 看门狗 20s 自动锁:', auto)
        ok = ok and auto

        # 8) 解锁恢复（等"已恢复"第 2 次出现）
        send(master, PIN + '\r')
        out = wait_count(master, out, RESTORED, 2, 15)
        restored2 = out.count(RESTORED) >= 2
        print('[8] 自动锁后解锁恢复:', restored2)
        ok = ok and restored2

        # 9) 重启走启动解锁（_promptUnlock exitOnEmpty=true 路径，重构重点覆盖）：
        #    提示语不同（直接回车退出）、错码挡住、空回车 = 退出整个 TUI、对码进聊天。
        send(master, '/exit\r')
        t_exit = time.time()
        while p.poll() is None and time.time() - t_exit < 12:
            out += drain(master, 0.3)
        print('[9] /exit 退出: %.1fs, code=%s' % (time.time() - t_exit, p.poll()))
        if p.poll() is None:
            print('[9] /exit 未退出？')
            print('---- 卡住时的最后一帧 ----')
            print(last_frame(out)[-1500:])
            ok = False
        try:
            os.close(master)
        except OSError:
            pass
        master, p = start_tui(store)
        out = ''
        out += drain(master, 8)
        send(master, '\r')  # 服务器地址：回车沿用
        out = wait_for(master, out, '❓ 输入锁屏码（直接回车退出）', 20)
        startup_prompt = '❓ 输入锁屏码（直接回车退出）' in out
        print('[9] 重启后启动解锁提示:', startup_prompt)
        ok = ok and startup_prompt
        send(master, WRONG + '\r')
        out = wait_for(master, out, '⚠️ 锁屏码验证错误', 15)
        startup_wrong = '⚠️ 锁屏码验证错误' in out
        print('[9] 启动解锁错码挡住:', startup_wrong)
        ok = ok and startup_wrong
        send(master, '\r')  # 启动解锁空回车 = 退出整个 TUI（与既有口径一致）
        time.sleep(3)
        out += drain(master, 2)
        startup_exit = p.poll() is not None
        print('[9] 启动解锁空回车即退:', startup_exit)
        ok = ok and startup_exit
        # 再启一次，对码进聊天
        try:
            os.close(master)
        except OSError:
            pass
        master, p = start_tui(store)
        out = ''
        out += drain(master, 8)
        send(master, '\r')
        out = wait_for(master, out, '❓ 输入锁屏码（直接回车退出）', 20)
        send(master, PIN + '\r')
        out = wait_for(master, out, '机密线路激活失败', 25)
        startup_ok = '机密线路激活失败' in out
        print('[9] 启动解锁对码进聊天:', startup_ok)
        ok = ok and startup_ok

        print('✅ 自动锁屏全场景通过' if ok else '❌ 存在失败场景')
        if not ok and _ERR_BUF[0].strip():
            print('---- TUI stderr（调试时间线，全量）----')
            print(_ERR_BUF[0])
        return 0 if ok else 1
    finally:
        if p.poll() is None:
            p.kill()
        try:
            os.close(master)
        except OSError:
            pass


if __name__ == '__main__':
    sys.exit(main())
