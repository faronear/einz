#!/bin/bash
# 在 cn1 上裸 Node 更新并重启 einz-server（生产 systemd 服务）
# 用法：npm run server-update-remote-bare
# 等价于手工：ssh cn1 'cd /faronear/einz/; git pull; cd server; npm ci; npm run build; sudo systemctl restart einz-server'

set -e
echo "▶ cn1 bare-node update..."
bash ssh.sh cn1 '
set -e
cd /faronear/einz/
echo "▶ git pull..."
git pull --ff-only

cd server
echo "▶ npm ci（lockfile 驱动，含 sherpa-onnx-linux-x64）..."
npm ci

echo "▶ npm run build..."
npm run build

echo "▶ systemctl restart einz-server..."
sudo systemctl restart einz-server

sleep 2
echo "▶ 服务状态："
systemctl is-active einz-server
curl -s -H "X-Protocol-Version: 3" http://127.0.0.1:3000/health || echo "(health 未就绪，可稍后 journalctl -u einz-server 查看)"
echo
'
echo "✅ done"
