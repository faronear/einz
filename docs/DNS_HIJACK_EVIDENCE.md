# DNS 劫持证据链（einz.yuanjinx.com / file.yuanjinx.com 抢答注入）

> 用途：向运营商投诉 / 12321 申诉的技术证据包。
> 采集时间：2026-10-11（下午至晚间，北京时间）。
> 采集环境：中国移动家宽（测试机 IPv6 前缀 `2409:8a20:` 可证），macOS 15 测试机，网关下测试。
> 所有命令可原样复跑；结论分【实测事实】与【推断】两类，投诉引用请以实测事实为准。

## 1. 事件概述

自 2026-10-11 起发现，在本地宽带下，个人自用域名 `einz.yuanjinx.com` 与
`file.yuanjinx.com` 的明文 DNS（UDP 53）解析结果与权威 DNS 不一致：被替换为
固定的无效 IP（TCP 80/443 全部拒绝连接），导致依赖这两个域名的服务
（自建加密通讯 App、自建 Seafile 网盘）在受影响网络下无法连接。
同日新注册、指向同一服务器的对照域名 `einz.farinear.cn` / `einz.bittic.cn`
解析正常。假 IP 的末八位均为 .114，具备明显的基础设施指纹（见 §4）。

## 2. 环境与对象

| 项目 | 值 |
| --- | --- |
| 受影响域名 | `einz.yuanjinx.com`（自建加密通讯服务）、`file.yuanjinx.com`（自建 Seafile 网盘） |
| 真实服务器 IP | `36.154.238.42`（中国移动，机房托管，ICP 备案域名） |
| 权威 DNS | Cloudflare（`koa.ns.cloudflare.com` / `serenity.ns.cloudflare.com`），域名已启用 DNSSEC |
| 对照域名（同机同 IP） | `einz.farinear.cn`、`einz.bittic.cn`（2026-10-10 新注册） |
| 本地解析配置 | `/etc/resolv.conf` → `nameserver 223.5.5.5`（阿里公共 DNS） |
| 采集机 | macOS，处于家用宽带（运营商见 §6 申告部分） |

## 3. 实测事实

### 3.1 权威 DNS 答案正确（排除域名自身配置问题）

```bash
$ dig @koa.ns.cloudflare.com einz.yuanjinx.com A +dnssec +noall +answer
einz.yuanjinx.com.   300  IN  A      36.154.238.42
einz.yuanjinx.com.   300  IN  RRSIG  A 13 3 300 ... yuanjinx.com. DETME/FBu+AGih1PlydDrDevVjlfxzRuDzG7EWJRpkm+Q/...
$ dig @koa.ns.cloudflare.com file.yuanjinx.com A +short
36.154.238.42
$ dig @koa.ns.cloudflare.com einz.farinear.cn A +short
36.154.238.42
```

【事实】权威侧（DNSSEC 已签名）三个域名答案一致且正确，TTL 300。
`dig +trace` 亦验证全链路（根 → com → cloudflare NS）答案一致。

### 3.2 本地明文解析返回固定假 IP（UDP 53）

```bash
$ dig einz.yuanjinx.com +short          # 系统路径
23.248.192.114                          # ← 与权威答案不符
$ dscacheutil -q host -a name einz.yuanjinx.com
ip_address: 23.248.192.114
$ for i in $(seq 10); do dig +time=1 +tries=1 @223.5.5.5 einz.yuanjinx.com +short; done | sort | uniq -c
   5 23.248.192.114     # ← 假
   4 36.154.238.42      # ← 真
   1 (超时)
$ for i in $(seq 4);  do dig +time=1 +tries=1 @223.5.5.5 file.yuanjinx.com A +short; done | sort | uniq -c
   4 182.16.61.114      # ← file 子域 100% 假
```

【事实】同一解析器、同一时刻，对同一域名的应答在真假之间**随机分裂**
（约 50%），且假答案的 TTL 被改写为 **3600**（权威为 300）：

```bash
$ dig @223.5.5.5 einz.yuanjinx.com（假应答包）
... IN  A  23.248.192.114   TTL 3600   ← 权威 TTL 只有 300
```

TTL 篡改 + 随机抢答是**链路注入**的典型特征，而非解析器自身配置错误。

### 3.3 假 IP 指纹：非真实服务、来源可疑、成对出现

| 被劫持域名 | 假 IP | WHOIS | 特征 |
| --- | --- | --- | --- |
| einz.yuanjinx.com | `23.248.192.114` | RedLuff, LLC（ARIN，美国；NetName RL-925，2025-09-05 分配） | ICMP 可通；**TCP 80 / 443 全部 Connection refused**；无反向解析 |
| file.yuanjinx.com | `182.16.61.114` | Netsec Limited（APNIC，香港；NETSEC-HK） | 同上：ICMP 可通、TCP 80/443 全死 |

```bash
$ curl -sv --connect-timeout 8 https://einz.yuanjinx.com/health
* connect to 23.248.192.114 port 443 ... failed: Connection refused
$ curl -s -m 6 -H 'Host: file.yuanjinx.com' http://182.16.61.114/ -w '%{http_code}'
000                      # 无任何 HTTP 服务
```

【事实】两个假 IP 末八位均为 **.114**，均"ICMP 活、TCP 全死"、均无任何真实
业务——典型的黑洞/引流基础设施指纹，且**长期恒定不变**（当日多次测试 12+ 小时
跨度内假 IP 从未变化），说明是静态映射而非随机故障。

### 3.4 加密 DoH 对照：真 IP 可确认，且污染已进入递归缓存

```bash
# 腾讯 DoH（HTTPS 加密，链路无法篡改；TLS 证书校验通过）
$ curl -s 'https://doh.pub/dns-query?name=einz.yuanjinx.com&type=A' -H 'accept: application/dns-json'
{...,"Answer":[{"name":"einz.yuanjinx.com.","TTL":300,"data":"36.154.238.42"}]}   ← 真 IP，TTL 正常

# 阿里 DoH 同为加密通道，但该时刻其缓存返回过假 IP（TTL 3600）：
{...,"Answer":[{"name":"einz.yuanjinx.com.","TTL":3600,"data":"23.248.192.114"}]}
```

【事实】加密通道（证书校验通过、链路不可篡改）能拿到真 IP，**证明真答案存在且
可恢复**；同时阿里 DoH 的缓存中出现过假条目，说明污染不限于单一家庭网关，
已波及部分公共递归解析器的缓存/上游路径（与其任意播节点状态有关，呈点状分布）。

### 3.5 对照实验：污染按 FQDN 精确命中，与服务器 IP 无关

2026-10-11，同一台机器、同一网络、同一时刻：

| 域名 | 指向 | 解析结果 | 状态 |
| --- | --- | --- | --- |
| `einz.yuanjinx.com`（灰云，使用 3 周） | 36.154.238.42 | 混入 `23.248.192.114` | **被劫持** |
| `file.yuanjinx.com`（灰云，使用数周） | 36.154.238.42 | 稳定 `182.16.61.114` | **被劫持** |
| `yuanjinx.com` / `www`（橙云） | Cloudflare 边缘 | 正常边缘 IP | 正常 |
| `einz.farinear.cn`（灰云，1 天） | 36.154.238.42 | 正常（偶见配置期遗留缓存，见 §5） | 正常 |
| `einz.bittic.cn`（灰云，1 天） | 36.154.238.42 | 正常 | 正常 |

【事实】四个域名指向**同一台服务器同一 IP**，仅老域名/老子域被劫持，新域名
干净；TCP 53 查询全程干净（只有 UDP 被注入）。
【推断（有事实支撑）】劫持按**完整域名精确匹配**，命中对象为"在受影响网络上
被持续明文查询过的 yuanjinx.com 子域"；与服务器 IP、内容均无关（对照域名同
IP 同内容但干净）。

### 3.6 影响实证

```bash
$ curl -sv --connect-timeout 8 https://einz.yuanjinx.com/health
* IPv4: 23.248.192.114
* connect to 23.248.192.114 port 443 ... failed: Connection refused
* Failed to connect to einz.yuanjinx.com port 443 after 69 ms
```

- 自建通讯 App：启动即连接失败（假 IP 拒连），且假应答 TTL 3600 导致客户端
  系统缓存被污染后**持续约 1 小时不可恢复**；
- 自建 Seafile：`file.yuanjinx.com` 在受影响网络下 100% 解析到黑洞 IP，服务
  完全不可用；
- 同机服务的两个对照域名当日均正常。

## 4. 时间线（2026-10-11）

| 时间（约） | 事件 |
| --- | --- |
| 上午 | 用户报告 App 无法连接；`ping einz.yuanjinx.com` 得到 23.248.192.114 |
| 上午 | 权威验证（DNSSEC）→ 排除域名配置问题；卸载本机代理软件后依旧复现 → 排除本机 |
| 下午 | 10 连测确认 UDP 53 随机抢答；DoH 对照拿到真 IP |
| 下午 | 部署客户端侧 DoH 自动兜底 + 多域名对照（farinear/bittic 上线即干净） |
| 晚间 | 发现 file 子域同样被劫持（182.16.61.114），确认 zone 级定点模式 |

## 5. 已排除项（避免误诉）

- **域名自身配置**：权威答案正确、DNSSEC 完好、TTL 正常 —— 无问题；
- **服务器/证书**：直连 36.154.238.42 时 TLS 证书（Let's Encrypt）验证通过，服务正常 —— 无问题；
- **本机软件**：卸载本机代理后复现 —— 非本机软件；
- **/etc/hosts**：无相关条目；
- `einz.farinear.cn` 偶发的 `141.193.154.146`（Cloudflare 段）应答：为域名建立
  当日曾短暂开启 Cloudflare 橙云代理所致的**配置期遗留缓存**，与本次劫持无关
  （已确认并会随 TTL 自然过期），投诉时请勿引用该现象。

## 6. 复现方法（投诉受理方可验证）

在受影响网络下（本例为中国移动家宽，DNS 设为 223.5.5.5）：

```bash
# 1) 权威答案（正确值）
dig @koa.ns.cloudflare.com einz.yuanjinx.com A +short        # → 36.154.238.42

# 2) 本地明文解析（观察真假分裂；多跑几次）
dig @223.5.5.5 einz.yuanjinx.com +short                       # → 混出 23.248.192.114
dig @223.5.5.5 file.yuanjinx.com +short                       # → 182.16.61.114

# 3) 假 IP 无服务
curl -m 5 https://23.248.192.114/ -k -o /dev/null -w '%{http_code}\n'   # 连不上
curl -m 5 -H 'Host: file.yuanjinx.com' http://182.16.61.114/ -w '%{http_code}\n'

# 4) 加密 DoH 拿真 IP（证明真实服务存活）
curl -s 'https://doh.pub/dns-query?name=einz.yuanjinx.com&type=A' -H 'accept: application/dns-json'
```

## 7. 后续补充证据（待办）

- [ ] 多地域分布证据：客户端新版（带 DoH 兜底 + 上报）发布后，聚合接口
      `GET https://einz.yuanjinx.com/network/dns-report` 的跨省数据
      （证明影响面不止一台设备一条宽带）；
- [ ] `dig +trace` 全文与抓包（Wireshark 过滤 `dns`，观察伪造应答与真应答
      的到达时序及源地址）——如受理方需要报文级证据再补充；
- [ ] 不同时段多轮采样（观察劫持的持续性）。

## 8. 已部署的缓解（不影响投诉事实）

- 客户端：探测失败自动改用加密 DoH 解析并直连（TLS 仍按域名校验，无安全降级）；
- 服务多域名冗余：farinear.cn / bittic.cn 备用入口，被劫持域名自动切换；
- 自研巡检：`npm run dns-audit`（系统解析 vs DoH 双通道比对，分歧即告警）。

> 缓解措施证明了真实服务持续存活，但不改变"用户明文解析被劫持"这一事实本身。
