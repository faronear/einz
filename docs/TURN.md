# TURN（coturn）部署手册 — 语音通话跨网打洞

> **为什么需要**：跨网（一台 4G、一台 WiFi；或跨运营商）时 P2P 打洞失败率很高。
> 2026-09-26 实测：同 WiFi 双机能通，**跨网无 TURN 打不通**，部署 coturn 后打通。
> 所以 TURN 是**必需**，不是可选优化。
> 方案背景：`aimemo/voiceCall.zhcn.md` §3 / Phase C。

---

## 0. 它不削弱 E2EE

TURN 只是把 **UDP 包原样转发**，媒体是 DTLS-SRTP 端到端加密，TURN 手里没有密钥。
它和 Einz 的哑转发服务器同性质：只搬密文，代价是带宽，不是信任。
（对照：SFU/MCU 那类会收流解码混音，那才拿得到明文。）

---

## 1. 部署（国内机 `einz.yuanjinx.com`）

```bash
cd <仓库>/deployment
cp coturn/turnserver.conf.example coturn/turnserver.conf
# 改三处：user= 的密码、realm、external-ip（云主机有公网网卡就不用填）
#   生成密码：openssl rand -hex 16

docker compose -f docker-compose.coturn.yml up -d
docker compose -f docker-compose.coturn.yml logs -f
```

用 **host 网络**：TURN 要用 49152–65535 这一大段 UDP 端口，且需要真实公网 IP；
走 docker 桥接 + 端口映射既麻烦又容易在 `external-ip` 上踩坑。

### 必须放行的端口（最容易漏）

| 端口 | 协议 | 用途 |
| ---- | ---- | ---- |
| 3478 | UDP **和** TCP | STUN + TURN 信令/分配 |
| 49152–65535 | UDP | 媒体中继 |

**只开 3478 不够**——`nc -vz -u host 3478` 通了不代表能用；中继端口段不通的话，
表现仍是「一直正在接通…最后连接失败」。

---

## 2. 客户端接进来

凭据走 `dart-define`（**不写死在代码里**）：

```bash
# app/localConfig.turn.json —— 被 app/.gitignore 忽略，不进仓库
{
  "VOICE_TURN_URLS": "turn:einz.yuanjinx.com:3478",
  "VOICE_TURN_USERNAME": "einz",
  "VOICE_TURN_CREDENTIAL": "<turnserver.conf 里同一个密码>"
}
```

打包时带上（本地）：

```bash
cd app
flutter build apk --debug --dart-define-from-file=localConfig.turn.json
flutter build ipa --release --export-options-plist=ios/exportOptionsAdhoc.plist \
  --dart-define-from-file=localConfig.turn.json
```

- `app/ios/buildIos.sh` **会自动带上**该文件（不存在就跳过并提示，不拦打包）。
- CI（GitHub Actions）走仓库 secrets：`VOICE_TURN_URLS` / `VOICE_TURN_USERNAME` /
  `VOICE_TURN_CREDENTIAL`，缺了也能出包，只是没有 TURN。

> TURN 凭据下发到客户端是 WebRTC 常态，**藏不住也不必藏**：客户端要用就得拿到。
> 防滥用靠 coturn 的配额（`user-quota` / `max-bps`）与拒绝中继到私有网段
> （见 `turnserver.conf.example` 的 `denied-peer-ip`），不是靠保密。

---

## 3. 验证

1. 端口：`nc -vz -u einz.yuanjinx.com 3478`
2. 端到端（最可靠）：一台走 4G、一台走 WiFi，发起通话 → 能听到对方。
3. ICE 成功时**优先走 P2P**（host/srflx 候选），只有打不通才吃 TURN 中继带宽——
   所以同 WiFi 通话不会绕服务器。

---

## 4. 排障

| 现象 | 多半是 |
| ---- | ------ |
| 同 WiFi 通、跨网不通 | 没带 TURN（构建时漏 dart-define），或中继端口段没放行 |
| 一直「正在接通…」30 秒后失败 | 同上；或 coturn 容器没起来（`docker compose ps`） |
| 通了但单向无声 | 音频路由问题，不是 TURN |
