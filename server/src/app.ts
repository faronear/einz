import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { WebSocketServer } from "ws";
import { loadConfig, type ServerConfig } from "./config.js";
import { getDb, openDb } from "./db.js";
import { cleanupExpired, ApiError, createChallenge, verifyChallenge } from "./auth.js";
import { postMessage, syncMessages } from "./messages.js";
import { getReceipts, postReceipts } from "./receipts.js";
import { getAttachmentBlob, storeAttachment, cleanupOrphanAttachments } from "./attachments.js";
import { getAvatar, storeAvatar, MAX_AVATAR_BYTES } from "./avatars.js";
import { listDevices, revokeDevice, updateDeviceName, updatePersonName } from "./devices.js";
import { getSpace, registerPushToken, unregisterPushToken } from "./push.js";
import { deleteKeyEscrow, escrowForSpace, getKeyEscrow, uploadKeyEscrow } from "./escrow.js";
import { attachWs, broadcastNewMessage, broadcastProfileUpdated, notifyRevoked } from "./ws.js";
import { bearerToken, optionalBearerToken, requireSession, requireSpaceMember } from "./guard.js";
import { MAX_ATTACHMENT_BYTES, readBody, readJsonBody } from "./body.js";
import { limitByIp } from "./ratelimit.js";
import { createJoinToken, createSpace, joinSpace, lookupSpace, preflightJoin } from "./spaces.js";
import { logActivity, logSyncActivity, metaOf } from "./audit.js";

const PORT = Number(process.env.PORT ?? 3000);
const LOG_REQUESTS = (process.env.LOG_LEVEL ?? "info") !== "quiet";
const SERVER_VERSION = "1.0.0";
openDb(); // 先开库（所有路由依赖 db 就绪）
const cfg: ServerConfig = loadConfig();
// 免认证的 POST /spaces 会一直开着（新空间创建者没有任何凭证可用），所以
// maxSpaces 是"公网开放注册"的唯一总闸：0 = 不限 → 任何人都能无限建空间
// （2026-09-15 评审 H2）。这里只提醒，改配置由老板决定。
if (cfg.max_spaces === 0) {
  console.warn(
    "[einz] ⚠️ maxSpaces=0（不限）：POST /spaces 免认证，等于对公网开放建空间。" +
      "若不需要对外开放注册，请在 server/einz_server_config.json 设为实际预期值（如 1~2）后重启。"
  );
}

/** 邀请链接 base：按请求真实地址（Host + x-forwarded-proto）生成——TUI
 *  --server http://localhost:3000 / app local_config.json 覆盖服务器地址时，
 *  邀请链接与客户端实际使用的服务器一致（不再硬编码 einz.tic.cc，2026-09-11）。 */
function requestBaseUrl(req: IncomingMessage): string {
  const proto = String(req.headers["x-forwarded-proto"] ?? "http").split(",")[0].trim();
  const host = req.headers.host ?? `localhost:${PORT}`;
  return `${proto}://${host}`;
}

const server = createServer(async (req, res) => {
  const start = Date.now();
  // 请求/响应日志（pm2 log 式）：方法、路径、状态码、耗时；响应体不入日志（避免泄露密文）
  res.on("finish", () => {
    if (LOG_REQUESTS) {
      console.log(`[req] ${req.method ?? "-"} ${req.url ?? "-"} ${res.statusCode} ${Date.now() - start}ms`);
    }
  });
  try {
    await route(req, res);
  } catch (err) {
    if (err instanceof ApiError) {
      sendJson(res, err.httpStatus, { error: { code: err.code, message: err.message } });
    } else {
      console.error("[error]", err);
      sendJson(res, 500, { error: { code: "INTERNAL", message: "Internal Server Error" } });
    }
  }
});

const wss = new WebSocketServer({ noServer: true });
attachWs(wss);

server.on("upgrade", (req, socket, head) => {
  const url = new URL(req.url ?? "/", "http://localhost");
  if (url.pathname !== "/ws") {
    socket.destroy();
    return;
  }
  wss.handleUpgrade(req, socket, head, (ws) => wss.emit("connection", ws, req));
});

/**
 * 路由表（手写）。
 *
 * **鉴权约定（2026-09-15 评审后收口，新增端点务必遵守）**：
 * - 每条处理受保护资源的路径，都必须显式回答"凭什么能访问"——二选一：
 *   ① 在路由里调 `requireSession(token)`（设备级）或
 *      `requireSpaceMember(token, spaceId)`（空间级，见 guard.ts）；
 *   ② 把 token 交给**已内置鉴权**的模块函数（各模块第一件事就是
 *      resolveSession + isActiveDevice，例如 messages/receipts/devices/escrow/push）。
 * - 免鉴权端点只有这几个，且都是有意为之：`GET /health`、`GET /join/:token`（落地页）、
 *   `POST /spaces`（空间自举，创建者还没有凭证）、`POST /spaces/join{,/preflight}`、
 *   `GET /spaces/lookup`（按地址定位，给未入网者用）、
 *   `GET /avatar/:personId`（本人自愿上传的展示图）、
 *   `POST /spaces/{id}/key-escrow` 的**口令取包分支**（加入方只有口令）。
 *   新增免鉴权端点必须在此处登记并说明理由。
 */
async function route(req: IncomingMessage, res: ServerResponse): Promise<void> {
  const url = new URL(req.url ?? "/", `http://${req.headers.host ?? "localhost"}`);
  const path = url.pathname;
  const method = req.method ?? "GET";

  // 全站兜底限速（按 IP；真正的刷量防护在反代/云侧，这里只防误用与粗暴刷）
  limitByIp(req, "global");

  // 健康检查（免鉴权，供外部随时探测服务状态）
  if (method === "GET" && path === "/health") {
    // 只报告服务健康、协议版本与能力：**不返回消息总量 / 在线连接数 / 成员元数据**
    // （2026-09-15 评审：免鉴权公网端点吐业务量属元数据泄露；Multiverse 下更要避免
    // 跨空间泄漏，空间状态由受保护 API 获取，见 PROTOCOL_MULTIVERSE.md §4.1）
    sendJson(res, 200, {
      status: "ok",
      protocol_version: cfg.protocol_version,
      version: SERVER_VERSION,
      uptime_sec: Math.floor(process.uptime()),
      capabilities: cfg.capabilities,
    });
    return;
  }
  // 落地页：邀请链接（https://einz.tic.cc/join/<token>）在浏览器打开时显示指引页
  // （无 web 客户端——告诉用户这是 Einz 私密空间邀请、用 App 加入；老板 2026-09-10）
  if (method === "GET" && path.startsWith("/join/")) {
    const token = path.slice("/join/".length);
    if (!/^[A-Za-z0-9_-]+$/.test(token)) {
      sendJson(res, 404, { error: { code: "NOT_FOUND", message: "not found" } });
      return;
    }
    const page = `<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Einz 私密空间邀请</title>
<style>
  body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;background:#FFF5FA;color:#33415A;display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0;padding:20px}
  .card{max-width:480px;background:#fff;border:1px solid #E9D5E0;border-radius:16px;padding:32px;box-shadow:0 4px 16px rgba(51,65,90,.08);text-align:center}
  h1{font-size:20px;color:#2271F7;margin:0 0 12px}
  p{font-size:14px;line-height:1.7;margin:8px 0}
  .token{display:inline-block;margin:16px 0 4px;padding:10px 16px;background:#FDD6ED;color:#D6529C;border-radius:10px;font-family:ui-monospace,Menlo,monospace;font-size:13px;word-break:break-all}
  .hint{font-size:12px;color:#8a93a6}
</style>
</head>
<body>
<div class="card">
  <h1>💌 Einz 私密空间邀请</h1>
  <p>这是一份 <strong>Einz</strong>（双人私密加密聊天空间）的加入邀请。</p>
  <p>请使用 Einz App 打开本链接，或在 App 中加入时粘贴下面的邀请码：</p>
  <div class="token">${token}</div>
  <p class="hint">邀请码 24 小时内有效、仅可使用一次。</p>
</div>
</body>
</html>`;
    res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
    res.end(page);
    return;
  }

  // Multiverse：多租户空间（空间本身自举：POST /spaces 免认证——新空间创建者
  // 还没有任何凭证；其余 /spaces/* 端点一律要求该空间成员会话，见 guard.ts）
  if (method === "POST" && path === "/spaces") {
    limitByIp(req, "spaceCreate");
    const body = await readJsonBody(req);
    const r = await createSpace(
      body?.space_id == null ? undefined : String(body.space_id),
      body?.display_name == null ? undefined : String(body.display_name),
      body?.gender == null ? undefined : String(body.gender),
      body?.partner_name == null ? undefined : String(body.partner_name),
      body?.partner_gender == null ? undefined : String(body.partner_gender),
      body?.sealed_space_key,
      body?.escrow_passphrase == null ? undefined : String(body.escrow_passphrase),
      body?.public_key == null ? undefined : String(body.public_key),
      body?.device_name == null ? undefined : String(body.device_name),
      requestBaseUrl(req), // 邀请链接按请求真实 Host 生成
    );
    sendJson(res, 201, r);
    return;
  }
  if (method === "GET" && path === "/spaces/lookup") {
    limitByIp(req, "auth");
    const r = lookupSpace(url.searchParams.get("address") ?? undefined);
    sendJson(res, 200, r);
    return;
  }
  if (method === "POST" && path === "/spaces/join/preflight") {
    limitByIp(req, "auth");
    const body = await readJsonBody(req);
    const r = preflightJoin(String(body?.token ?? ""));
    sendJson(res, 200, r);
    return;
  }
  if (method === "POST" && path === "/spaces/join") {
    limitByIp(req, "auth");
    const body = await readJsonBody(req);
    const r = joinSpace(
      String(body?.token ?? ""),
      String(body?.public_key ?? ""),
      body?.device_name == null ? undefined : String(body.device_name),
      body?.display_name == null ? undefined : String(body.display_name),
      body?.gender == null ? undefined : String(body.gender),
      body?.partner_slot == null ? undefined : Number(body.partner_slot),
    );
    sendJson(res, 200, r);
    return;
  }
  if (method === "POST" && path.startsWith("/spaces/") && path.endsWith("/join-tokens")) {
    const spaceId = path.slice("/spaces/".length, -"/join-tokens".length);
    // C1 修复：签发邀请凭证 = 空间级操作，必须持该空间成员会话（此前任何人
    // 拿到 spaceId 就能自签邀请码、以 partner_slot=0 冒充创建者加设备）
    requireSpaceMember(optionalBearerToken(req), spaceId);
    const r = createJoinToken(spaceId, requestBaseUrl(req));
    sendJson(res, 201, r);
    return;
  }
  if (method === "POST" && path.startsWith("/spaces/") && path.endsWith("/key-escrow")) {
    const spaceId = path.slice("/spaces/".length, -"/key-escrow".length);
    const body = await readJsonBody(req);
    // 口令取包分支免认证（加入方尚无 session），上传分支在 escrowForSpace 内校验成员
    const r = await escrowForSpace(optionalBearerToken(req), spaceId, body);
    sendJson(res, 200, r);
    return;
  }

  // 认证（challenge-response）
  // 签发 session = 设备重新取得访问权（App 冷启动/会话过期重登），审计记一笔
  if (method === "POST" && path === "/auth/verify") {
    const body = await readJsonBody(req);
    const result = verifyChallenge(String(body?.challenge_id ?? ""), String(body?.challenge_plaintext ?? ""));
    const challengeDevice = getDb()
      .prepare(`SELECT device_id, space_id FROM challenges WHERE challenge_id = ?`)
      .get(String(body?.challenge_id ?? "")) as { device_id: string; space_id: string | null } | undefined;
    if (challengeDevice) {
      logActivity({
        deviceId: challengeDevice.device_id,
        spaceId: result.space_id || challengeDevice.space_id,
        kind: "auth.login",
        detail: { expires_in: result.expires_in },
        meta: metaOf(req),
      });
    }
    sendJson(res, 200, result);
    return;
  }
  if (method === "POST" && path === "/auth/challenge") {
    limitByIp(req, "auth");
    const body = await readJsonBody(req);
    const deviceId = String(body?.device_id ?? "");
    // space 必填：会话必须绑定空间（v1 收敛后不再有"无 space 会话"这种形态）
    const result = await createChallenge(deviceId, String(body?.space_id ?? ""));
    sendJson(res, 200, result);
    return;
  }
  // 消息与同步
  if (method === "POST" && path === "/messages") {
    const body = await readJsonBody(req);
    const token = bearerToken(req);
    const sess = requireSession(token);
    const result = postMessage(token, body);
    const envelope = body as { sender_device_id?: string; type?: string };
    const stored = { ...(body as object), server_sequence: result.server_sequence, created_at: result.created_at };
    broadcastNewMessage(envelope.sender_device_id ?? "", stored as never);
    // 审计：消息「发送」证据（设备级；只记元数据，不碰密文）
    logActivity({
      deviceId: sess.device_id,
      spaceId: sess.space_id,
      kind: "message.post",
      detail: {
        message_id: result.message_id,
        server_sequence: result.server_sequence,
        type: envelope.type ?? null,
      },
      meta: metaOf(req),
    });
    sendJson(res, 200, result);
    return;
  }
  if (method === "GET" && path === "/sync") {
    const token = bearerToken(req);
    const sess = requireSession(token);
    const after = Number(url.searchParams.get("after") ?? 0);
    const limit = Number(url.searchParams.get("limit") ?? 100);
    const result = syncMessages(token, after, limit);
    // 审计：消息「接收」证据（该设备拉到第几条；空闲轮询受节流，见 audit.ts）
    logSyncActivity({
      deviceId: sess.device_id,
      spaceId: sess.space_id,
      afterSequence: after,
      lastSequence: result.last_sequence,
      count: result.messages.length,
      hasMore: result.has_more,
      meta: metaOf(req),
    });
    sendJson(res, 200, result);
    return;
  }
  // 消息回执（已送达/已读）：单调高水位，按 (space, person) 一行
  if (method === "POST" && path === "/receipts") {
    const body = await readJsonBody(req);
    const token = bearerToken(req);
    const sess = requireSession(token);
    const b = (body ?? {}) as Record<string, unknown>;
    const result = postReceipts(token, body);
    // 审计：回执上报明细（设备级；receipts 表本身仍是 person 级 HWM，语义不变）
    logActivity({
      deviceId: sess.device_id,
      spaceId: sess.space_id,
      kind: "receipt",
      detail: {
        reported_delivered: b.delivered_upto_seq ?? null,
        reported_read: b.read_upto_seq ?? null,
        delivered_upto_seq: result.delivered_upto_seq,
        read_upto_seq: result.read_upto_seq,
      },
      meta: metaOf(req),
    });
    sendJson(res, 200, result);
    return;
  }
  if (method === "GET" && path === "/receipts") {
    sendJson(res, 200, getReceipts(bearerToken(req)));
    return;
  }

  // 附件（两条都要求有效会话 + 在册设备：收口在 requireSession，模块内仍各自校验空间归属）
  if (method === "POST" && path === "/attachments") {
    const token = bearerToken(req);
    requireSession(token);
    // P2 修复：x-attachment-meta 缺失/坏 JSON 应返回 400，而非崩溃成 500（PROTOCOL.md §9）
    const rawMeta = req.headers["x-attachment-meta"];
    let meta: unknown;
    if (typeof rawMeta !== "string" || rawMeta.length === 0) {
      throw new ApiError("INVALID_REQUEST", "missing x-attachment-meta header", 400);
    }
    try {
      meta = JSON.parse(rawMeta);
    } catch {
      throw new ApiError("INVALID_REQUEST", "malformed x-attachment-meta header", 400);
    }
    // H1：附件 blob 上限（默认 64 MiB，EINZ_MAX_ATTACHMENT_BYTES 可覆盖）
    const blob = await readBody(req, MAX_ATTACHMENT_BYTES);
    sendJson(res, 200, storeAttachment(token, meta as never, blob));
    return;
  }
  const attMatch = path.match(/^\/attachments\/([^/]+)$/);
  if (method === "GET" && attMatch) {
    const token = bearerToken(req);
    requireSession(token);
    const blob = getAttachmentBlob(token, attMatch[1]);
    res.writeHead(200, { "Content-Type": "application/octet-stream" });
    res.end(blob);
    return;
  }

  // 头像（per-person）：上传（token 认证，写本人头像文件）/ 获取（公开，404=未设置）
  if (method === "POST" && path === "/avatar") {
    const token = bearerToken(req);
    const { device_id } = requireSession(token);
    // H1：头像上限 2MB（与 storeAvatar 内的校验同一个常量，提前在这里拒绝）
    const blob = await readBody(req, MAX_AVATAR_BYTES);
    const stored = storeAvatar(token, blob);
    // 广播：伴侣（及本人其他设备）在线时立即重拉头像——否则要等重启 App
    // （客户端静态缓存只在进程内失效——老板 2026-09-11）
    broadcastProfileUpdated(device_id, { device_id, person_id: stored.person_id });
    sendJson(res, 200, stored);
    return;
  }
  const avatarMatch = path.match(/^\/avatar\/([^/]+)$/);
  if (method === "GET" && avatarMatch) {
    const blob = getAvatar(decodeURIComponent(avatarMatch[1]));
    if (blob == null) {
      sendJson(res, 404, { error: { code: "AVATAR_NOT_FOUND", message: "no avatar set" } });
      return;
    }
    res.writeHead(200, { "Content-Type": "image/png" });
    res.end(blob);
    return;
  }

  // 设备
  if (method === "POST" && path === "/devices/name") {
    // 更新本设备名称（已登记设备 TUI 改名后同步后台，显示层用）
    const body = await readJsonBody(req);
    const token = bearerToken(req);
    const sess = requireSession(token);
    const b = (body ?? {}) as Record<string, unknown>;
    sendJson(res, 200, updateDeviceName(token, body));
    logActivity({
      deviceId: sess.device_id,
      spaceId: sess.space_id,
      kind: "device.rename",
      detail: { device_name: b.device_name ?? null },
      meta: metaOf(req),
    });
    return;
  }
  if (method === "POST" && path === "/devices/person-name") {
    // 更新本设备 person 显示名（/rename 命令，显示层用）
    const body = await readJsonBody(req);
    const token = bearerToken(req);
    const sess = requireSession(token);
    const b = (body ?? {}) as Record<string, unknown>;
    sendJson(res, 200, updatePersonName(token, body));
    logActivity({
      deviceId: sess.device_id,
      spaceId: sess.space_id,
      kind: "person.rename",
      detail: { person_name: b.person_name ?? null },
      meta: metaOf(req),
    });
    return;
  }
  if (method === "GET" && path === "/devices") {
    sendJson(res, 200, listDevices(bearerToken(req)));
    return;
  }
  const devMatch = path.match(/^\/devices\/([^/]+)$/);
  if (method === "DELETE" && devMatch) {
    const token = bearerToken(req);
    const caller = requireSession(token);
    const result = revokeDevice(token, devMatch[1]);
    // 审计：设备撤销（谁撤的、撤了谁）
    logActivity({
      deviceId: caller.device_id,
      spaceId: caller.space_id,
      kind: "device.revoke",
      detail: { target_device_id: devMatch[1] },
      meta: metaOf(req),
    });
    notifyRevoked(devMatch[1]);
    // 注：这里原先还会 notifyKeyRotation()（PROTOCOL.md §8.2 key.rotation），提示剩余
    // 设备轮换 Space Key。2026-09-14 决策：产品不做密钥轮换（App/TUI 无入口、分发链路
    // 不成立、ROI 极低），该通知与 `key_rotation_required` 一并撤除，见 docs/SECURITY.md。
    sendJson(res, 200, result);
    return;
  }

  // 推送
  if (method === "POST" && path === "/push/register") {
    const body = await readJsonBody(req);
    const token = bearerToken(req);
    const sess = requireSession(token);
    const b = (body ?? {}) as Record<string, unknown>;
    sendJson(res, 200, registerPushToken(token, body));
    // 审计：Push Token 变更（换机/重装 App 会体现为 token 变化）
    // 只记 platform 与 token 指纹前缀，不落完整 token（避免推送凭证扩散到审计表）
    const rawToken = typeof b.token === "string" ? b.token : "";
    logActivity({
      deviceId: sess.device_id,
      spaceId: sess.space_id,
      kind: "push.register",
      detail: { platform: b.platform ?? null, token_prefix: rawToken.slice(0, 8) },
      meta: metaOf(req),
    });
    return;
  }
  if (method === "DELETE" && path === "/push/register") {
    const token = bearerToken(req);
    const sess = requireSession(token);
    sendJson(res, 200, unregisterPushToken(token));
    logActivity({ deviceId: sess.device_id, spaceId: sess.space_id, kind: "push.unregister", meta: metaOf(req) });
    return;
  }

  // 密钥托管（口令托管，KEY_ESCROW.md §4）：Server 只存密文包，不解析内容
  if (method === "POST" && path === "/key-escrow") {
    const body = await readJsonBody(req);
    sendJson(res, 200, uploadKeyEscrow(bearerToken(req), body));
    return;
  }
  if (method === "GET" && path === "/key-escrow") {
    sendJson(res, 200, getKeyEscrow(bearerToken(req)));
    return;
  }
  if (method === "DELETE" && path === "/key-escrow") {
    sendJson(res, 200, deleteKeyEscrow(bearerToken(req)));
    return;
  }

  // 空间
  if (method === "GET" && path === "/space") {
    sendJson(res, 200, getSpace(bearerToken(req)));
    return;
  }

  sendJson(res, 404, { error: { code: "NOT_FOUND", message: "not found" } });
}

function sendJson(res: ServerResponse, status: number, data: unknown): void {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(data));
}

// 定期清理过期 challenge/session 与孤儿附件（两阶段上传失败残留的 blob）
setInterval(() => {
  cleanupExpired();
  cleanupOrphanAttachments();
}, 60 * 60 * 1000).unref();

server.listen(PORT, () => {
  console.log(`[einz] server listening on :${PORT}`);
});
