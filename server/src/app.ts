import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { WebSocketServer } from "ws";
import { loadConfig, type ServerConfig } from "./config.js";
import { getDb, openDb } from "./db.js";
import { cleanupExpired, ApiError, createChallenge, verifyChallenge } from "./auth.js";
import { postMessage, syncMessages } from "./messages.js";
import { getAttachmentBlob, storeAttachment, cleanupOrphanAttachments } from "./attachments.js";
import { getAvatar, storeAvatar } from "./avatars.js";
import { createInvite, enrollDevice, listDevices, revokeDevice, updateDeviceName, updatePersonName } from "./devices.js";
import { getSpace, registerPushToken, unregisterPushToken } from "./push.js";
import { deleteKeyEscrow, escrowForSpace, getKeyEscrow, recoverSpace, uploadKeyEscrow } from "./escrow.js";
import { attachWs, broadcastNewMessage, notifyKeyRotation, notifyRevoked, wsConnCount } from "./ws.js";
import { createJoinToken, createSpace, joinSpace, lookupSpace, preflightJoin } from "./spaces.js";

const PORT = Number(process.env.PORT ?? 3000);
const LOG_REQUESTS = (process.env.LOG_LEVEL ?? "info") !== "quiet";
const SERVER_VERSION = "1.0.0";
openDb(); // 先开库：loadConfig 需要从 db meta 读/生成 space_id
const cfg: ServerConfig = loadConfig();

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
attachWs(wss, cfg);

server.on("upgrade", (req, socket, head) => {
  const url = new URL(req.url ?? "/", "http://localhost");
  if (url.pathname !== "/ws") {
    socket.destroy();
    return;
  }
  wss.handleUpgrade(req, socket, head, (ws) => wss.emit("connection", ws, req));
});

async function route(req: IncomingMessage, res: ServerResponse): Promise<void> {
  const url = new URL(req.url ?? "/", `http://${req.headers.host ?? "localhost"}`);
  const path = url.pathname;
  const method = req.method ?? "GET";

  // 健康检查（免鉴权，供外部随时探测服务状态）
  if (method === "GET" && path === "/health") {
    const msgCount = (getDb()
      .prepare(`SELECT COUNT(*) AS n FROM messages`)
      .get() as { n: number }).n;
    // Multiverse：/health 只报告服务健康、协议版本与能力，不再返回全局
    // person 名称/性别表（多空间下避免跨空间泄漏成员元数据；空间状态由
    // 受保护 API 获取，见 PROTOCOL_MULTIVERSE.md §4.1）
    sendJson(res, 200, {
      status: "ok",
      protocol_version: cfg.protocol_version,
      version: SERVER_VERSION,
      uptime_sec: Math.floor(process.uptime()),
      capabilities: cfg.capabilities,
      legacy: {
        space_id: cfg.space_id,
        messages_count: msgCount,
      },
      ws_clients: wsConnCount(),
    });
    return;
  }

  // Multiverse：多租户空间（骨架，成员认证由 U1 Space-scoped session 补齐；
  // 见 docs/PROTOCOL_MULTIVERSE.md §4）
  if (method === "POST" && path === "/spaces") {
    const body = await readJson(req);
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
    );
    sendJson(res, 201, r);
    return;
  }
  if (method === "GET" && path === "/spaces/lookup") {
    const r = lookupSpace(url.searchParams.get("address") ?? undefined);
    sendJson(res, 200, r);
    return;
  }
  if (method === "POST" && path === "/spaces/join/preflight") {
    const body = await readJson(req);
    const r = preflightJoin(String(body?.token ?? ""));
    sendJson(res, 200, r);
    return;
  }
  if (method === "POST" && path === "/spaces/join") {
    const body = await readJson(req);
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
    const r = createJoinToken(spaceId);
    sendJson(res, 201, r);
    return;
  }
  if (method === "POST" && path.startsWith("/spaces/") && path.endsWith("/key-escrow")) {
    const spaceId = path.slice("/spaces/".length, -"/key-escrow".length);
    const body = await readJson(req);
    const r = await escrowForSpace(spaceId, body);
    sendJson(res, 200, r);
    return;
  }

  // 认证（challenge-response）
  if (method === "POST" && path === "/auth/challenge") {
    const body = await readJson(req);
    const deviceId = String(body?.device_id ?? "");
    // Multiverse：可选 target space（记录到 challenge→session；不带则 legacy 回落）
    const spaceId = body?.space_id == null ? undefined : String(body.space_id);
    const result = await createChallenge(cfg, deviceId, spaceId);
    sendJson(res, 200, result);
    return;
  }
  if (method === "POST" && path === "/auth/verify") {
    const body = await readJson(req);
    const result = verifyChallenge(cfg, String(body?.challenge_id ?? ""), String(body?.challenge_plaintext ?? ""));
    sendJson(res, 200, result);
    return;
  }

  // 消息与同步
  if (method === "POST" && path === "/messages") {
    const body = await readJson(req);
    const token = bearer(req);
    const result = postMessage(cfg, token, body);
    const envelope = body as { sender_device_id?: string };
    const stored = { ...(body as object), server_sequence: result.server_sequence, created_at: result.created_at };
    broadcastNewMessage(envelope.sender_device_id ?? "", stored as never);
    sendJson(res, 200, result);
    return;
  }
  if (method === "GET" && path === "/sync") {
    const token = bearer(req);
    const after = Number(url.searchParams.get("after") ?? 0);
    const limit = Number(url.searchParams.get("limit") ?? 100);
    sendJson(res, 200, syncMessages(cfg, token, after, limit));
    return;
  }

  // 附件
  if (method === "POST" && path === "/attachments") {
    const token = bearer(req);
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
    const chunks: Buffer[] = [];
    for await (const chunk of req) chunks.push(chunk as Buffer);
    const blob = Buffer.concat(chunks);
    sendJson(res, 200, storeAttachment(cfg, token, meta as never, blob));
    return;
  }
  const attMatch = path.match(/^\/attachments\/([^/]+)$/);
  if (method === "GET" && attMatch) {
    const token = bearer(req);
    const blob = getAttachmentBlob(cfg, token, attMatch[1]);
    res.writeHead(200, { "Content-Type": "application/octet-stream" });
    res.end(blob);
    return;
  }

  // 头像（per-person）：上传（token 认证，写本人头像文件）/ 获取（公开，404=未设置）
  if (method === "POST" && path === "/avatar") {
    const token = bearer(req);
    const chunks: Buffer[] = [];
    for await (const chunk of req) chunks.push(chunk as Buffer);
    const blob = Buffer.concat(chunks);
    sendJson(res, 200, storeAvatar(cfg, token, blob));
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
  if (method === "POST" && path === "/devices/enroll") {
    // 动态登记（免认证，邀请码即准入令牌）：新设备凭邀请码登记，立即生效无需重启
    const body = await readJson(req);
    sendJson(res, 200, enrollDevice(cfg, body));
    return;
  }
  if (method === "POST" && path === "/devices/name") {
    // 更新本设备名称（已登记设备 TUI 改名后同步后台，显示层用）
    const body = await readJson(req);
    sendJson(res, 200, updateDeviceName(cfg, bearer(req), body));
    return;
  }
  if (method === "POST" && path === "/devices/person-name") {
    // 更新本设备 person 显示名（/rename 命令，显示层用）
    const body = await readJson(req);
    sendJson(res, 200, updatePersonName(cfg, bearer(req), body));
    return;
  }
  if (method === "POST" && path === "/invites") {
    // 创建者生成邀请码（白名单外新设备加入用）
    const body = await readJson(req);
    sendJson(res, 200, createInvite(cfg, bearer(req), body));
    return;
  }
  if (method === "GET" && path === "/devices") {
    sendJson(res, 200, listDevices(cfg, bearer(req)));
    return;
  }
  const devMatch = path.match(/^\/devices\/([^/]+)$/);
  if (method === "DELETE" && devMatch) {
    const result = revokeDevice(cfg, bearer(req), devMatch[1]);
    notifyRevoked(devMatch[1]);
    // Space Key 轮换由剩余可信设备在客户端发起（E2EE.md §9.1）；
    // key.rotation 通知发给"除被撤销设备外"的所有剩余设备（含撤销发起者），
    // 用已入库消息的最大 key_version+1 作为建议版本（PROTOCOL.md §8.2）。
    const maxVersion = (getDb()
      .prepare(`SELECT COALESCE(MAX(key_version), 0) + 1 AS next FROM messages`)
      .get() as { next: number }).next;
    notifyKeyRotation(devMatch[1], maxVersion);
    sendJson(res, 200, result);
    return;
  }

  // 推送
  if (method === "POST" && path === "/push/register") {
    const body = await readJson(req);
    sendJson(res, 200, registerPushToken(cfg, bearer(req), body));
    return;
  }
  if (method === "DELETE" && path === "/push/register") {
    sendJson(res, 200, unregisterPushToken(cfg, bearer(req)));
    return;
  }

  // 密钥托管（口令托管，KEY_ESCROW.md §4）：Server 只存密文包，不解析内容
  if (method === "POST" && path === "/key-escrow") {
    const body = await readJson(req);
    sendJson(res, 200, uploadKeyEscrow(cfg, bearer(req), body));
    return;
  }
  if (method === "POST" && path === "/recover") {
    // 全丢恢复（免认证）：凭 escrow 口令验证后撤销全部设备，新设备可重新首设备自举
    const body = await readJson(req);
    sendJson(res, 200, await recoverSpace(cfg, body));
    return;
  }
  if (method === "GET" && path === "/key-escrow") {
    sendJson(res, 200, getKeyEscrow(cfg, bearer(req)));
    return;
  }
  if (method === "DELETE" && path === "/key-escrow") {
    sendJson(res, 200, deleteKeyEscrow(cfg, bearer(req)));
    return;
  }

  // 空间
  if (method === "GET" && path === "/space") {
    sendJson(res, 200, getSpace(cfg, bearer(req)));
    return;
  }

  sendJson(res, 404, { error: { code: "NOT_FOUND", message: "not found" } });
}

function bearer(req: IncomingMessage): string {
  const h = req.headers.authorization ?? "";
  const m = h.match(/^Bearer (.+)$/);
  if (!m) throw new ApiError("UNAUTHORIZED", "missing bearer token", 401);
  return m[1];
}

async function readJson(req: IncomingMessage): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) chunks.push(chunk as Buffer);
  const text = Buffer.concat(chunks).toString("utf8");
  if (!text) return {};
  try {
    return JSON.parse(text) as Record<string, unknown>;
  } catch {
    throw new ApiError("INVALID_REQUEST", "invalid json body", 400);
  }
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
  console.log(`[einz] server listening on :${PORT} space=${cfg.space_id}`);
});
