import { getDb } from "./db.js";
import { getDevice, isActiveDevice, type ServerConfig } from "./config.js";
import { constantTimeEqualB64, randomBytes, sealFor, toB64 } from "./crypto.js";
import { randomBytes as nodeRandomBytes } from "node:crypto";

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

/** 阶段 1：生成密封 challenge（PROTOCOL.md §3）。仅白名单内 active 设备可发起。 */
export async function createChallenge(cfg: ServerConfig, deviceId: string): Promise<ChallengeResult> {
  if (!isActiveDevice(cfg, deviceId)) {
    throw new ApiError("FORBIDDEN", "device not in whitelist", 403);
  }
  const device = getDevice(cfg, deviceId)!;
  const challenge = await randomBytes(32);
  const challengeId = toB64(await randomBytes(16));
  const sealed = await sealFor(device.public_key, challenge);

  getDb()
    .prepare(
      `INSERT INTO challenges (challenge_id, device_id, challenge, expires_at, used)
       VALUES (?, ?, ?, ?, 0)`
    )
    .run(challengeId, deviceId, toB64(challenge), Date.now() + CHALLENGE_TTL_MS);

  return { challenge_id: challengeId, sealed_challenge: sealed, expires_in: CHALLENGE_TTL_MS / 1000 };
}

/** 阶段 2：校验明文并签发 session（PROTOCOL.md §3）。challenge 一次性。 */
export function verifyChallenge(cfg: ServerConfig, challengeId: string, plaintextB64: string): SessionResult {
  const row = getDb()
    .prepare(`SELECT * FROM challenges WHERE challenge_id = ?`)
    .get(challengeId) as
    | { challenge_id: string; device_id: string; challenge: string; expires_at: number; used: number }
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
  db.prepare(
    `INSERT INTO sessions (session_token, device_id, expires_at, created_at) VALUES (?, ?, ?, ?)`
  ).run(sessionToken, row.device_id, now + SESSION_TTL_MS, now);

  return { session_token: sessionToken, space_id: cfg.space_id, expires_in: SESSION_TTL_MS / 1000 };
}

/** 通过 session_token 解析设备。 */
export function resolveSession(token: string): { device_id: string } {
  const row = getDb()
    .prepare(`SELECT device_id, expires_at FROM sessions WHERE session_token = ?`)
    .get(token) as { device_id: string; expires_at: number } | undefined;
  if (!row) throw new ApiError("UNAUTHORIZED", "invalid session", 401);
  if (row.expires_at < Date.now()) {
    getDb().prepare(`DELETE FROM sessions WHERE session_token = ?`).run(token);
    throw new ApiError("UNAUTHORIZED", "session expired", 401);
  }
  return { device_id: row.device_id };
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
