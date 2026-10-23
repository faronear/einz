#!/usr/bin/env python3
# store 路径显示回归（老板 2026-10-23）：
# ① 新 store（向导路径）：身份横幅里带 📁 Store 行，且位于 ---------------- 分隔线**之前**
#    （Store 信息与身份信息合并为一条系统消息，不单独刷一条）；
# ② 已有 store（直接进聊天）：启动**不**自动输出 📁 Store——随问随答走 /store 命令。
# 背景：npm 包装脚本的 echo 会被 TUI 首帧清屏抹掉；直跑 dart run 时更没有提示。
import os, pty, re, select, shutil, subprocess, sys, tempfile, time

# 由脚本位置推导 cli 目录（仓库已迁移过，不硬编码）
CLI = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# 已绑定空间、无 PIN、无 session_token 的演示 store（离线可走完启动流：
# 认证必失败并给出警告，随后进入聊天输入态）
DEMO_STORE = os.path.join(CLI, 'demo/store-a.json')
ANSI = re.compile(r'\x1b\[[0-9;?]*[A-Za-z]')


def start_tui(store):
    master, slave = pty.openpty()
    env = dict(os.environ, TERM='xterm-256color')
    cmd = ['dart', 'run', 'bin/einz_tui.dart', '--store', store,
           '--server', 'http://127.0.0.1:39999']  # 不可达：跳过登记/认证，只走启动流
    p = subprocess.Popen(cmd, stdin=slave, stdout=slave, stderr=slave,
                         close_fds=True, cwd=CLI, env=env)
    os.close(slave)
    return master, p


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


def wait_for(master, out, needle, timeout):
    deadline = time.time() + timeout
    while needle not in out and time.time() < deadline:
        out += drain(master, 0.8)
    return out


def cleanup(master, p):
    if p.poll() is None:
        p.kill()
    try:
        os.close(master)
    except OSError:
        pass


def check_new_store():
    """① 新 store：横幅含 📁 Store 且在分隔线前（合并为一条消息）。"""
    store = os.path.join(tempfile.mkdtemp(prefix='esp-', dir='/tmp'), 'store.json')
    master, p = start_tui(store)
    out = ''
    try:
        out += drain(master, 8)
        os.write(master, b'\r')  # 服务器地址：回车沿用
        out = wait_for(master, out, '秘境向导', 25)
        clean = ANSI.sub('', out)
        needle = f'📁 Store: {store}'
        reached = '秘境向导' in out
        shown = needle in clean
        # 合并判据：消息区**从下往上堆叠**（见 _render 注释）——流里的顺序是视觉的倒序。
        # 视觉上 📁 在分隔线前、公钥行之后 ⟺ 流里 分隔线 < 📁 < 公钥行。
        # （若退回"单独一条系统消息"，📁 会排在分隔线**之前** → 断言失败）
        sep = clean.rfind('----------------')
        pub = clean.rfind('✅ 新通道公钥')
        merged = shown and sep != -1 and pub != -1 and sep < clean.rfind(needle) < pub
        print('[新 store] 到达向导首问:', reached, '| 📁 行出现:', shown,
              '| 位于分隔线前(已合并):', merged)
        if not (reached and shown and merged):
            print('---- 输出尾部 ----')
            print(clean[-1000:])
        return reached and shown and merged
    finally:
        cleanup(master, p)


def check_existing_store():
    """② 已有 store：启动不自动输出；/store 命令随问随答。"""
    store = os.path.join(tempfile.mkdtemp(prefix='esp-existing-', dir='/tmp'), 'store.json')
    shutil.copy(DEMO_STORE, store)
    master, p = start_tui(store)
    out = ''
    try:
        out += drain(master, 8)
        os.write(master, b'\r')  # 服务器地址：回车沿用
        # 引导跑完的标志：离线认证失败警告（演示 store 无 token → 必走这一步）
        out = wait_for(master, out, '机密线路激活失败', 30)
        time.sleep(5)  # 等 _activateAfterBind（同步/WS）收尾
        needle = f'📁 Store: {store}'
        auto = needle in ANSI.sub('', out)
        print('[已有 store] 启动自动输出 📁(应 False):', auto)
        if auto:
            return False
        os.write(master, b'/store\r')
        out = wait_for(master, out, needle, 15)
        shown = needle in ANSI.sub('', out)
        print('[已有 store] /store 命令输出路径:', shown)
        if not shown:
            print('---- 输出尾部 ----')
            print(ANSI.sub('', out)[-1000:])
        return shown
    finally:
        cleanup(master, p)


def main():
    if not os.path.exists(DEMO_STORE):
        print(f'❌ 缺少 {DEMO_STORE}')
        return 1
    ok1 = check_new_store()
    ok2 = check_existing_store()
    if ok1 and ok2:
        print('✅ store 路径显示两场景全部通过')
        return 0
    print('❌ 存在失败场景')
    return 1


if __name__ == '__main__':
    sys.exit(main())
