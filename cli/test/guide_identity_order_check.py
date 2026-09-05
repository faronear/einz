#!/usr/bin/env python3
# 引导顺序回归验证（2026-09-05）：后续设备入网时，先问身份（personA/personB，
# 按需设名），再问设备名——与首设备"先名字后设备名"的顺序一致。
# 修复前：后续设备先问设备名，enroll 失败（INVALID_REQUEST）后才问身份。
import os, pty, subprocess, select, time, sys, json
from http.server import BaseHTTPRequestHandler, HTTPServer
import threading

# 仓库已从 /Users/Shared/productX/einz 迁移；由脚本位置推导 cli 目录，避免硬编码旧路径
CLI = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STORE = '/tmp/einz_guide_order.json'
PORT = 39123

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        # /health 返回 person 名称表（空间已有创建者 → 后续设备场景）
        if self.path.startswith('/health'):
            body = json.dumps({'status': 'ok', 'person_names': {'personA': 'Lukas'}}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, *args):
        pass

def start_tui():
    if os.path.exists(STORE):
        os.remove(STORE)  # 全新 store → 进入新设备引导
    master, slave = pty.openpty()
    env = dict(os.environ, TERM='xterm-256color')
    cmd = ['dart', 'run', 'bin/einz_tui.dart', '--store', STORE,
           '--server', f'http://127.0.0.1:{PORT}']
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
    server = HTTPServer(('127.0.0.1', PORT), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    master, p = start_tui()
    out = ''
    try:
        # 1) 冷启动：应直接进入身份问答（后续设备场景，personA 名称表非空）
        out += drain(master, 8)
        if '如果你是空间创建者' not in out:
            print('❌ 未出现身份问答（后续设备应先问身份）')
            print(out[-800:])
            return 1
        print('✅ 已出现身份问答（先问身份）')
        # 2) 选 personA（输入 1）→ 应接着问设备名
        send(master, '1\r')
        out += drain(master, 3)
        if '请输入设备名称' not in out:
            print('❌ 身份选择后未出现设备名称问答')
            print(out[-800:])
            return 1
        print('✅ 身份选择后出现设备名称问答（顺序正确：身份 → 设备名）')
        # 3) 顺序断言：身份问答必须先于设备名称问答
        id_idx = out.find('如果你是空间创建者')
        dev_idx = out.find('请输入设备名称')
        if id_idx == -1 or dev_idx == -1 or id_idx >= dev_idx:
            print('❌ 顺序错误：身份问答应出现在设备名称问答之前')
            return 1
        print('✅ 顺序断言通过（身份问答在设备名称问答之前）')
        # 4) 清理退出：设备名问答处 /exit 应结束
        send(master, '/exit\r')
        deadline = time.time() + 6
        while time.time() < deadline and p.poll() is None:
            out += drain(master, 0.5)
        if p.poll() is None:
            p.kill()
            print('❌ /exit 后进程未退出')
            return 1
        print('✅ /exit 正常退出')
        return 0
    finally:
        server.shutdown()
        server.server_close()
        if p.poll() is None:
            p.kill()
        try:
            os.close(master)
        except OSError:
            pass

if __name__ == '__main__':
    sys.exit(main())
