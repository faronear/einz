#!/bin/bash
# 在 cn1 上裸 Node 更新并重启 einz-server（生产 systemd 服务）
# 用法：npm run server-update-remote-bare
# 等价于手工：ssh cn1 'cd /faronear/einz/; git pull; cd server; npm ci; npm run build; sudo systemctl restart einz-server'
#
# 注意（2026-10-28）：
#   · npm ci 每次都删 node_modules 重装（7 个直接依赖 / 93MB，含 better-sqlite3 原生
#     预编译与 sherpa-onnx-linux-x64）。大陆网络冷缓存时这是唯一高频失败点 →
#     先 --prefer-offline（缓存命中就不联网），失败自动重试一次。
#   · 两次都失败即中止，**旧进程继续服务**——restart 刻意放在最后。
#   · 不要为绕过失败把 registry 改镜像再顺手 npm install：那会把
#     registry.npmmirror.com 写进 package-lock.json 的 resolved（2026-10-28 已清理回归
#     官方源）。真要救急就用环境变量或 Dockerfile 的 --build-arg，不改文件。

set -e
echo "▶ cn1 bare-node update..."
bash ssh.sh cn1 '
set -e
cd /faronear/einz/
echo "▶ git pull..."
git pull --ff-only

cd server
echo "▶ npm ci --prefer-offline ..."
if ! npm ci --prefer-offline; then
  echo "⚠ npm ci 失败，重试一次（同样 --prefer-offline）..."
  npm ci --prefer-offline
fi

echo "▶ npm run build..."
npm run build

echo "▶ systemctl restart einz-server..."
sudo systemctl restart einz-server

sleep 2
echo "▶ 服务状态："
systemctl is-active einz-server
# /health 免协议版本头（app.ts assertProtocolVersion 白名单），不必硬编码版本号
curl -s http://127.0.0.1:3000/health || echo "(health 未就绪，可稍后 journalctl -u einz-server 查看)"
echo
'
echo "✅ done"

