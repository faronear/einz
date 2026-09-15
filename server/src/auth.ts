import { getDb } from "./db.js";
import { getDevice, isActiveDevice, type ServerConfig } from "./config.js";
import { constantTimeEqualB64, randomBytes, sealFor, toB64 } from "./crypto.js";
import { createHash, randomBytes as nodeRandomBytes } from "node:crypto";

const CHALLENGE_TTL_MS = 5 * 60 * 1000; // 5 分钟
const SESSION_TTL_MS = 24 * 60 * 60 * 1000; // 24 小时

export interface ChallengeResult {
  challenge_id: string;
  sealed_challenge: string;
  expires_in: number;
}

export interface SessionResult {
  session_token: string;
  space_id: string;
  expires_in: number;
}

/** 阶段 1：生成密封 challenge（PROTOCOL.md §3）。仅白名单内 active 设备可发起。
 *  Multiverse：可选目标 spaceId（记录到 challenge，随后随 session 绑定；不带则
 *  legacy 回落——存量 v1 客户端行为不变）。 */
export async function createChallenge(cfg: ServerConfig, deviceId: string, spaceId?: string): Promise<ChallengeResult> {
  if (!isActiveDevice(cfg, deviceId)) {
    throw new ApiError("FORBIDDEN", "device not in whitelist", 403);
  }
  const device = getDevice(cfg, deviceId)!;
  const challenge = await randomBytes(32);
  const challengeId = toB64(await randomBytes(16));
  const sealed = await sealFor(device.public_key, challenge);

  getDb()
    .prepare(
      `INSERT INTO challenges (challenge_id, device_id, space_id, challenge, expires_at, used)
       VALUES (?, ?, ?, ?, ?, 0)`
    )
    .run(challengeId, deviceId, spaceId ?? null, toB64(challenge), Date.now() + CHALLENGE_TTL_MS);

  return { challenge_id: challengeId, sealed_challenge: sealed, expires_in: CHALLENGE_TTL_MS / 1000 };
}

/** 阶段 2：校验明文并签发 session（PROTOCOL.md §3）。challenge 一次性。
 *  Multiverse：session 绑定 challenge 记录的目标 Space（NULL → session 无空间，
 *  legacy 客户端不带 space_id——v2 下客户端必带）。 */
export function verifyChallenge(cfg: ServerConfig, challengeId: string, plaintextB64: string): SessionResult {
  const row = getDb()
    .prepare(`SELECT * FROM challenges WHERE challenge_id = ?`)
    .get(challengeId) as
    | { challenge_id: string; device_id: string; space_id: string | null; challenge: string; expires_at: number; used: number }
    | undefined;

  if (!row) throw new ApiError("INVALID_REQUEST", "unknown challenge", 400);
  if (row.used !== 0) throw new ApiError("CONFLICT", "challenge already used", 409);
  if (row.expires_at < Date.now()) throw new ApiError("INVALID_REQUEST", "challenge expired", 400);

  // 校验客户端解封出的明文是否等于当初的 challenge（常量时间比较）
  let ok = false;
  try {
    ok = constantTimeEqualB64(plaintextB64, row.challenge);
  } catch {
    ok = false; // base64 非法
  }
  if (!ok) throw new ApiError("UNAUTHORIZED", "challenge mismatch", 401);

  const db = getDb();
  db.prepare(`UPDATE challenges SET used = 1 WHERE challenge_id = ?`).run(challengeId);

  // session_token 用 Node crypto 同步生成（无需 await）
  const sessionToken = toB64(new Uint8Array(nodeRandomBytes(32)));
  const now = Date.now();
  const sessionSpaceId = row.space_id ?? ""; // v2：challenge 必带目标 Space（legacy 无空间 → 空串）
  db.prepare(
    `INSERT INTO sessions (session_token, device_id, space_id, expires_at, created_at) VALUES (?, ?, ?, ?, ?)`
  ).run(hashSessionToken(sessionToken), row.device_id, sessionSpaceId, now + SESSION_TTL_MS, now);

  return { session_token: sessionToken, space_id: sessionSpaceId, expires_in: SESSION_TTL_MS / 1000 };
}

/**
 * 会话 token 的存储形态：sha256 十六进制（明文只存在于客户端内存/存储）。
 *
 * 为什么（2026-09-15 评审 H4）：此前 sessions 表直存明文 session_token，而
 * join_tokens 表存 sha256——同一个库里两套标准。库文件或备份一旦外泄，
 * 明文会话可以直接拿来冒用（无需私钥），哈希形态则不可反推。
 */
export function hashSessionToken(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}

/** 通过 session_token 解析设备（Multiverse：附带 session 绑定的 space_id，
 *  NULL=ALTER 前的 legacy 存量会话，调用方按需回落）。
 *  库中存的是 token 的 sha256（见 hashSessionToken）——传入的是客户端持有的明文。 */
export function resolveSession(token: string): { device_id: string; space_id: string | null } {
  const stored = hashSessionToken(token);
  const row = getDb()
    .prepare(`SELECT device_id, space_id, expires_at FROM sessions WHERE session_token = ?`)
    .get(stored) as { device_id: string; space_id: string | null; expires_at: number } | undefined;
  if (!row) throw new ApiError("UNAUTHORIZED", "invalid session", 401);
  if (row.expires_at < Date.now()) {
    getDb().prepare(`DELETE FROM sessions WHERE session_token = ?`).run(stored);
    throw new ApiError("UNAUTHORIZED", "session expired", 401);
  }
  return { device_id: row.device_id, space_id: row.space_id };
}

export function touchLastSeen(deviceId: string): void {
  getDb().prepare(`UPDATE devices SET last_seen = ? WHERE device_id = ?`).run(Date.now(), deviceId);
}

/** 清理过期 challenge 与 session（可定期调用）。 */
export function cleanupExpired(): void {
  const db = getDb();
  db.prepare(`DELETE FROM challenges WHERE expires_at < ?`).run(Date.now());
  db.prepare(`DELETE FROM sessions WHERE expires_at < ?`).run(Date.now());
}

export class ApiError extends Error {
  constructor(
    public code: string,
    message: string,
    public httpStatus: number
  ) {
    super(message);
    this.name = "ApiError";
  }
}
