# 服务端转写部署指南（方案 D'；双引擎 whisper.cpp / SenseVoice）

> 目的：让老板**亲自理解**部署原理，任何一台新 VPS（含未来海外搬迁）都能照着从零复原。
> 原则：转写能力 = **引擎（二进制或 addon）+ 模型文件 + 少量环境变量**，无数据库、无后台服务、无开机自启。

## 0. 心智模型（先懂再装）

```
Einz server (Node)                    引擎二选一（EINZ_ASR_ENGINE，缺省 sensevoice）
  POST /transcriptions                  whisper：whisper-cli 二进制 + ggml 模型
    ↓ 收到明文 wav（内存里）              sensevoice：sherpa-onnx node addon + 模型目录
    ↓ 管道喂子进程 / 进程内识别           音频全程内存，不落盘
    文本返回客户端（whisper 子进程用完即退）
```

要点：

1. **whisper 不是服务**：没有端口、没有 daemon，就是个命令行程序。server 每次转写 fork 一个子进程，转完退出。sensevoice 则是 node addon 进程内识别（recognizer 常驻复用）。两者都不需要 systemd/supervisor 之类的外挂服务。
2. **环境变量**是 server 与引擎的唯一耦合点（whisper 引擎：`EINZ_WHISPER_BIN` + `EINZ_WHISPER_MODEL`；sensevoice 引擎：`EINZ_SENSEVOICE_MODEL` 目录）。没配 = 转写端点报告未启用，server 其余功能完全不受影响。搬迁 = 新机器装好后改这几行再重启 server。引擎选择见 §6。
3. **模型文件是只读资产**，可打包随迁移带走（scp 拷走即可），新机器不必重新下载。
4. **音频明文全程只在内存**：不写磁盘、不进日志——这是隐私承诺的技术基础，部署时不要为了排障把音频落盘。

## 1. 前置依赖（一次性）

```bash
# Linux（裸 node 部署的常规路径；apt 没有 whisper-cli 包，必须源码编译）
sudo apt update && sudo apt install -y build-essential cmake git ffmpeg

# macOS 等价（2026-10-23 补：同流程，只差包管理器与并行度取法）
#   make/clang++ 随 Xcode Command Line Tools 已有，只缺 cmake：
brew install cmake
#   （后文 -j$(nproc) 在 macOS 用 -j$(sysctl -n hw.ncpu)）
```

- `build-essential` + `cmake`：编译 whisper.cpp 用（编译完可卸载，二进制自包含）
- `ffmpeg`：仅排障时手工转 16kHz wav 用，生产链路不需要（客户端传的就是 16kHz wav）

硬件要求：**内存是唯一硬约束**——加载 small 模型约需 1GB 空闲内存（`free -h` 确认）；
CPU 1 核即可跑，只是慢（1 分钟录音转 1-2 分钟）。磁盘：二进制 ~2MB + 模型 ~466MB。

## 2. 编译 whisper.cpp

```bash
sudo mkdir -p /opt/whisper && cd /opt/whisper
sudo git clone https://github.com/ggml-org/whisper.cpp
cd whisper.cpp
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j$(nproc)   # macOS: -j$(sysctl -n hw.ncpu)
```

> 仓库内的位置对应：开发机上这棵树就在 `server/models/whisper.cpp/`（两机同步目录，
> 整个 `server/models/` gitignore），`.env` 的 `EINZ_WHISPER_BIN` 直接指它的
> `build/bin/whisper-cli`；上文 `/opt/whisper/` 是 VPS 裸 node 部署的独立位置，两者
> 结构一致（源码 + build/ + models/ 同级）。

产物：`build/bin/whisper-cli`（还有 bench/server 等兄弟二进制，我们只用 cli）。
编译耗时约 2-5 分钟。**新机器迁移时可跳过编译**：直接 scp 老机器的
`whisper-cli` + 模型文件过去（同架构 x86_64 Linux 二进制可直接运行）。

## 3. 下载模型

```bash
cd /opt/whisper/whisper.cpp
bash ./models/download-ggml-model.sh small
```

模型档位（中文口语场景实测导向）：

| 模型 | 体积 | 中文质量 | 1 核 CPU 速度 | 内存占用 |
|---|---|---|---|---|
| base | 148MB | 错字多 | 快 | ~400MB |
| **small（起步推荐）** | 466MB | 可用 | 1min→1-2min | ~1GB |
| small-q5_1（量化） | ~180MB | 略降于 small | 更快 | ~600MB |
| medium | 1.5GB | 好 | 慢，小机吃力 | ~2GB |

选型顺序：先 small；小内存机（≤1GB）用 base 或 small-q5_1；海外用户多、对中文
要求不高时 small 足够。模型下载慢可用 hf-mirror：`HF_ENDPOINT=https://hf-mirror.com bash ./models/download-ggml-model.sh small`

## 4. 冒烟测试（部署验证的核心一步）

```bash
# 找任意一段中文语音（微信语音、录音都行），转成 16kHz 单声道 wav：
ffmpeg -i test.m4a -ar 16000 -ac 1 test.wav
/opt/whisper/whisper.cpp/build/bin/whisper-cli \
  -m /opt/whisper/whisper.cpp/models/ggml-small.bin -f test.wav -l zh -np
```

- 能输出中文文本 = 部署成功（`-np` 关掉非必要日志；`-l zh` 指定中文，比自动检测更准）
- 报错 `Illegal instruction` = 老机器 CPU 不支持，重新 cmake 加 `-DGGML_NATIVE=OFF -DGGML_CPU_ALL_VARIANTS=OFF`
- 报错内存不足 = 换小模型档位

**16kHz 单声道 wav 是硬规格**——Einz 客户端录音已是这个格式（§8），手工测试时
ffmpeg 转换参数别漏 `-ar 16000 -ac 1`。

## 5. 接入 Einz server

server 侧的环境变量（按引擎二选一，亦可同时配——选择逻辑见 §6）：

```bash
# server/docker/.env（或 pm2 ecosystem 的 env 块，与现有 EINZ_* 变量同处）
EINZ_WHISPER_BIN=/opt/whisper/whisper.cpp/build/bin/whisper-cli
EINZ_WHISPER_MODEL=/opt/whisper/whisper.cpp/models/ggml-small.bin
# sensevoice 引擎（与 App 本机同模型，中文质量/简体/ITN 对齐前端）：
EINZ_SENSEVOICE_MODEL=/opt/whisper/sensevoice   # 目录含 model.int8.onnx + tokens.txt
# 引擎选择：sensevoice（缺省，配了就用）/ whisper
EINZ_ASR_ENGINE=sensevoice
```

重启 server 生效：pm2 `pm2 restart einz` / docker `docker compose up -d`。

**⚠️ Docker 跑 server 的两条路**：

- **内置镜像（推荐，2026-10-22 已落地）**：`server/Dockerfile` 新增 whisper 编译阶段
  ——二进制 + libggml 动态库烤进镜像（`/opt/whisper/`），模型**不进镜像**，走卷
  `../models/whisper.cpp/models:/opt/whisper/models:ro`。compose（docker-compose.yml）已配
  `EINZ_WHISPER_BIN=/opt/whisper/whisper-cli` + `EINZ_WHISPER_MODEL=/opt/whisper/models/ggml-small.bin`。
  首次部署只剩一步：往 `server/models/whisper.cpp/models/` 放一份模型文件
  （**老板 2026-10-22 定**：模型是固定二进制资产，不进 `data/` 用户数据目录；
  2026-10-23 整合为 whisper.cpp 源码树的 `models/` 子目录（其官方下载脚本
  download-ggml-model.sh 的落点，§3 即下到这里）；整个 `server/models/` 目录
  gitignore，466MB+ 绝不可入库）
  优点：换服务器 = 搬镜像 + 搬模型目录，零宿主机依赖；换模型档位不用重新 build。
- **裸 Node + 宿主机 whisper**：§2-§5 的原方案，whisper 装宿主机、server 用绝对路径
  spawn（容器隔离问题不存在）。适合不想给镜像加编译时间的场景。

## 6. 引擎选择：whisper vs sensevoice（2026-10-24）

两个引擎可同时配置，选择逻辑（server/src/transcriptions.ts 的 resolveAsrEngine）：

1. `EINZ_ASR_ENGINE` 显式指定（`whisper` / `sensevoice`，大小写不敏感）——最高优先；
2. 缺省：**sensevoice 配了就用**，否则 whisper；都没有则转写未启用。

| | whisper.cpp（ggml-small） | SenseVoice-Small int8（推荐） |
|---|---|---|
| 中文质量 | 英文中心模型，small 档中文一般，输出繁体 | 与 App 本机同模型，中文强、简体、带 ITN |
| 语种 | 90+（small 档多数不佳） | 中/粤/英/日/韩自动识别 |
| 体积/内存 | 466MB / ~1GB | 239MB / ~500MB |
| 部署形态 | 宿主机二进制 + 子进程（stdin 管道） | sherpa-onnx node addon，进程内识别（npm 依赖自带平台二进制） |
| 小 VPS 适应性 | 4 核 Celeron N3150（无 AVX）上 medium 不可行（5-10 分钟/条） | 同硬件约 20-60s/条 |

**cn1（Debian，4 核 Celeron N3150 @1.6GHz，8GB）结论**：whisper medium 不可行
（Braswell 无 AVX，whisper.cpp 的 SIMD 优化全废；且吃 2-3GB 内存）；sensevoice 是唯一
现实选择——非自回归单次前向，60s 语音约 20-60s，质量还与前端一致。

**sensevoice 模型文件获取**（与 App 本机同款，二选一）：

```bash
# ① 从 App 已安装目录整目录拷走（macOS 开发机）：
#    ~/Library/Containers/cc.tic.einz/Data/Library/Application Support/cc.tic.einz/
#      voice_transcript/2024-07-17-int8/{model.int8.onnx,tokens.txt}
# ② 或从 HF 下（csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17）：
mkdir -p /opt/whisper/sensevoice && cd /opt/whisper/sensevoice
wget https://hf-mirror.com/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/model.int8.onnx
wget https://hf-mirror.com/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/tokens.txt
```

放到 `server/models/sensevoice/`（整个 `server/models/` 已 gitignore）亦可，
`EINZ_SENSEVOICE_MODEL` 指过去即可。node 依赖随 `npm ci` 自动装平台二进制
（linux-x64 / darwin-arm64），无需额外编译。

### Docker 部署与引擎开关（2026-10-24）

compose 三个变体已内置 sensevoice（卷 + 环境变量，与 whisper 同 pattern）：

- 卷：`../models/sensevoice:/opt/sensevoice:ro`（宿主 `server/models/sensevoice/`
  缺文件时 Docker 会建个空目录 → 该引擎未配置 → 自动回落 whisper，graceful 退场）；
- 环境：`EINZ_SENSEVOICE_MODEL=/opt/sensevoice`（容器内路径。.env 里那个**宿主机**
  路径只服务于裸 node 跑法，不进容器——和 whisper 两个变量一样由 compose 硬编码覆盖）；
- 开关：`EINZ_ASR_ENGINE`（写 `server/docker/.env` 或 shell 前缀，两处跑法同语义）：
  - 不设 = 自动：sensevoice 配了（模型两文件齐全）就用，否则 whisper；
  - `whisper` = 强制 whisper（装了 sensevoice 也不理）；
  - `sensevoice` = 强制 sensevoice（没配好则端点报 TRANSCRIBE_DISABLED，**不静默回落**）。
- 镜像需在 sherpa-onnx-node 进 package.json 之后**重新 build**
  （`docker compose build server`）——否则容器里没有 node addon，请求报
  `TRANSCRIBE_FAILED: sherpa-onnx-node unavailable`（错误明确，不静默）。

**验证切换生效**：`curl -s http://127.0.0.1:3000/health` 应含
`"asr_engine":"sensevoice"`（未配时不出现 transcribe/asr_engine 键）。
## 7. 验证与运维

1. App 设置里选「服务端转写」→ 对一条语音点转写 → 出文本 = 全链路通。
2. server 日志应出现转写事件行（**只有事件与耗时，没有内容**）——部署后务必看一眼
   确认没有音频内容进日志，这是隐私承诺。
3. 限流已内置（per-IP + 请求上限，见 ratelimit.ts `transcribe` 桶），无需额外配置。
4. CPU 被转写打满影响聊天？whisper-cli spawn 时已限单线程（`-t 1`），多核机器可
   在 env 里加 `EINZ_WHISPER_THREADS` 调大。

## 7. 搬迁 checklist（海外服务器迁移时照抄）

- [ ] 新机器 `apt install build-essential cmake git`（或直接 scp 二进制跳过编译）
- [ ] `scp -r` 老机器 `/opt/whisper/whisper.cpp/build/bin/whisper-cli` + `models/ggml-*.bin`
      （模型文件与老机器版本一致，不必重新下载）
- [ ] 新机器冒烟测试（§4，用同一段 test.wav 对比新旧机器输出一致）
- [ ] server/docker/.env 两个变量指到新路径
- [ ] 重启 server + App 端到端验证一条
- [ ] DNS 切换后观察 `pm2 logs` 第一条转写事件的耗时（新机房到用户的延迟）

## 8. 升级 whisper.cpp / 换模型

- 升级：`cd /opt/whisper/whisper.cpp && git pull && cmake --build build -j$(nproc)`——
  路径不变，server 无感；转写文本的 modelId 不变，客户端无需任何动作。
- 换模型：下载新 bin 到 models/，改 `EINZ_WHISPER_MODEL` 指过去，重启 server。
  客户端 `LocalVoiceTranscripts.modelId` 会记新档位名（如 `whisper-small-q5_1`），
  stale 重算语义自动生效。
