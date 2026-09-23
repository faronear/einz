#!/usr/bin/env python3
# 引导输入规则回归（老板 2026-09-11）
#   0) create 各必填问答（秘境入口/我的名字/我的性别/伴侣的名字/伴侣的性别）
#      留空回车 → 必须被**静默拒绝**：不提交、不前进，也**不打印任何提示**
#      （老板 2026-09-23：早先会打一条「请输入内容」，每按一次回车就把提问往上顶
#       一行、屏幕跟着跳；提示还在上面、光标还在输入行就够了）
#   1) create 口令必填：走到「设置共享口令」留空回车 → 同样静默拒绝、不进入创建；
#      补输口令后创建成功
#      （向导里**只有锁屏码**可以空回车跳过——`_askSetPin` 不带 required）
#   2) 锁屏码规则（与 App 一致：纯数字 + 至少 6 位）：字母 → 提示「锁屏码只能是
#      数字」；5 位数字 → 提示「锁屏码至少 6 位数字」；6 位数字 → 设置成功
#   3) join 口令必填：第二条通道走到「验证共享口令」留空回车 → 同样静默拒绝
#      （不进入加入——否则会先 joinSpace 再取不到 Space Key，通道卡在
#      "已登记但无密钥"的坏状态）；补输同一口令后加入成功
#   4) join 口令输错：应停在口令环节提示重输，且**同一个** join token 仍可用
#      （旧实现先 joinSpace 消费 token 再验口令 → 一输错就被踢回邀请码环节，
#      已接受的 token 作废——老板 2026-09-12 反馈）
#
# 运行：python3 cli/test/guide_input_rules_check.py
import json
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


def assert_silent_required(master, label, forbid, wait=1.5):
    """必填问答留空回车：必须**静默拒绝**（老板 2026-09-23）。

    判据：① 不出现「请输入内容」这类反馈；② 后续步骤的提示不出现（说明没被接受而前进）。
    forbid 可为字符串或字符串列表。
    """
    forbids = [forbid] if isinstance(forbid, str) else list(forbid)
    send(master, '\r')
    out = ''
    deadline = time.time() + wait
    while time.time() < deadline:
        out += drain(master, 0.4)  # 本探针的 drain 已解码（无 strip_ansi）
    if '请输入内容' in out:
        print(f'❌ {label}：留空回车仍打印了提示（应为静默拒绝）')
        print(out[-500:]); raise SystemExit(1)
    for f in forbids:
        if f and f in out:
            print(f'❌ {label}：留空回车竟被接受（出现了「{f}」）')
            print(out[-500:]); raise SystemExit(1)
    return out


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
        for i, (expect, payload) in enumerate(steps):
            out = wait_text(m, expect)
            if expect not in out:
                print(f'❌ 未到「{expect}」问答')
                print(out[-600:])
                return 1
            # 必填：留空回车静默拒绝（老板 2026-09-23）——不提交、不打提示
            nxt = steps[i + 1][0] if i + 1 < len(steps) else '设置共享口令'
            assert_silent_required(m, f'「{expect}」', nxt)
            send(m, payload)

        # 关键：口令留空回车 → 必须拦住
        out = wait_text(m, '设置共享口令')
        if '设置共享口令' not in out:
            print('❌ 未到口令问答')
            print(out[-600:])
            return 1
        assert_silent_required(m, '设置共享口令', ['正在创建秘境', '成功创建秘境'])

        # 补输口令 → 创建成功（≥ kPassphraseMinLength=8 位——老板 2026-09-15 起）
        send(m, 'abc12345\r')
        out = wait_text(m, '成功创建秘境', timeout=40)
        if '成功创建秘境' not in out:
            print('❌ 输入口令后未创建成功')
            print(out[-600:])
            return 1

        print('✅ create：口令留空被拦下，补输后创建成功')

        # ---------- 锁屏码规则：纯数字 + 至少 6 位 ----------
        # 注意：TUI 在阻塞读键盘期间不会重绘（已知行为——提示要等下一次按键才
        # 出现），故不先等提示，直接发；未命中就重发（非法值会被拒，重发无害）。
        def input_until(payload, expect, tries=6, timeout=8):
            out = ''
            for _ in range(tries):
                send(m, payload)
                out = wait_text(m, expect, timeout=timeout)
                if expect in out:
                    break
            return out

        # 文案实为「✅ 锁屏码 🔢 已设置」：中间有 emoji，且渲染会插入 ANSI 着色，
        # 不能整串匹配——🔢 在全 TUI 仅此一处，作为"锁屏码已设置"的判定锚点。
        def pin_set(out):
            return '🔢' in out

        for wrong, expect in (
            ('abc\r', '锁屏码只能是数字'),      # 字母
            ('12345\r', '锁屏码至少 6 位数字'),  # 位数不足
        ):
            out = input_until(wrong, expect)
            if expect not in out:
                print(f'❌ 锁屏码 {wrong.strip()!r} 未被拦住（未提示「{expect}」）')
                print(out[-800:])
                return 1
            if pin_set(out):
                print(f'❌ 非法锁屏码 {wrong.strip()!r} 竟被接受')
                return 1
        out = input_until('123456\r', '🔢')
        if not pin_set(out):
            print('❌ 6 位数字锁屏码未被接受')
            print(out[-800:])
            return 1
        print('✅ 锁屏码规则：字母/不足 6 位被拒，6 位数字通过')

        # ---------- 通道 B：join 的口令也必须必填 ----------
        with open(store) as f:
            store_a = json.load(f)
        # 签发邀请码是空间级操作，必须带本空间成员会话（server C1 修复后要求
        # 认证——此前裸 POST 也能签，现已 400）
        req = urllib.request.Request(
            f'http://127.0.0.1:{port}/spaces/{store_a["space_id"]}/join-tokens',
            method='POST',
            headers={'Authorization': f'Bearer {store_a["session_token"]}',
                     'X-Protocol-Version': '1'})
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                join_token = json.load(r)['joinToken']
        except urllib.error.HTTPError as e:
            print(f'❌ 签发邀请码失败（HTTP {e.code}）: {e.read().decode("utf-8", "replace")[:300]}')
            return 1

        store_b = os.path.join(WORK, 'b.json')
        m2, p2 = start_tui(store_b, port)
        spawned.append((m2, p2))
        b_steps = [
            ('秘境入口', 'j\r'),
            ('输入开通码', join_token + '\r'),
            ('完整输入我的名字', 'Alice\r'),
        ]
        for i, (expect, payload) in enumerate(b_steps):
            out = wait_text(m2, expect)
            if expect not in out:
                print(f'❌ B 未到「{expect}」问答')
                print(out[-600:])
                return 1
            nxt = b_steps[i + 1][0] if i + 1 < len(b_steps) else '验证共享口令'
            assert_silent_required(m2, f'B「{expect}」', nxt)
            send(m2, payload)

        out = wait_text(m2, '验证共享口令')
        if '验证共享口令' not in out:
            print('❌ B 未到口令问答')
            print(out[-600:])
            return 1
        assert_silent_required(m2, 'B 验证共享口令', ['正在加入秘境', '成功加入秘境'])

        # ---------- 口令错误：必须停在口令环节重输，且不能烧掉 join token ----------
        # （旧实现：先 joinSpace 消费一次性 token 再验口令 → 失败即落到「加入秘境
        #   失败」并退回邀请码环节，已接受的 token 作废——老板 2026-09-12 反馈）
        send(m2, 'wrong-pass\r')
        out = wait_text(m2, '口令错误', timeout=30)
        if '口令错误，请重新输入' not in out:
            print('❌ B 输错口令未被拦在口令环节（未提示重新输入）')
            print(out[-800:])
            return 1
        if '加入秘境失败' in out or '输入开通码' in out:
            print('❌ B 输错口令竟退回邀请码环节（token 被烧掉）')
            print(out[-800:])
            return 1

        # 同一个 token：重输正确口令 → 应加入成功（token 未被消耗）
        send(m2, 'abc12345\r')
        out = wait_text(m2, '成功加入秘境', timeout=40)
        if '成功加入秘境' not in out:
            print('❌ B 输错后重输正确口令未加入成功（token 应仍有效）')
            print(out[-800:])
            return 1

        print('✅ join：口令留空被拦下、输错停在口令环节重输，补输后加入成功')
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
