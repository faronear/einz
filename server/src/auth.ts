import { getDb } from "./db.js";
import { getDevice, getDeviceStatus } from "./config.js";
import { constantTimeEqualB64, randomBytes, sealFor, toB64 } from "./crypto.js";
import { createHash, randomBytes as nodeRandomBytes } from "node:crypto";
import { assertSafeSpaceId } from "./safeId.js";

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

/** 阶段 1：生成密封 challenge（PROTOCOL.md §3）。仅在册且未撤销的设备可发起。
 *
 * 两种拒绝**必须给不同 code**（老板 2026-09-16）：
 * - 设备被明确撤销 → `DEVICE_REVOKED`（客户端据此自毁本地数据）；
 * - 设备不在册（库被清/从未登记）→ `FORBIDDEN`（客户端**只应警告**，绝不销毁数据）。
 * 此前两者都返回 FORBIDDEN，导致"后台数据库被重置"被客户端误判为"本设备被撤销"
 * 而清空本地数据——运维失误造成不可挽回的数据损失。
 *
 * **spaceId 必填**（2026-09-15 v1 收敛后）：数据全按 space 隔离，会话必须绑定一个
 * space。v1 时代允许不带（落 NULL 的 legacy 会话），那类会话什么都访问不了，
 * 却让下游 8 处代码各自 `?? ""` 回落——现在在入口就拒绝。 */
export async function createChallenge(deviceId: string, spaceId: string): Promise<ChallengeResult> {
  const deviceStatus = getDeviceStatus(deviceId);
  if (deviceStatus === "revoked") {
    throw new ApiError("DEVICE_REVOKED", "device revoked", 403);
  }
  if (deviceStatus === "missing") {
    throw new ApiError("FORBIDDEN", "device not in whitelist", 403);
  }
  if (spaceId == null || spaceId.length === 0) {
    throw new ApiError("INVALID_REQUEST", "space_id 必填（Multiverse：会话必须绑定空间）", 400);
  }
  // 字符集收紧：space_id 由客户端自报，且后续会成为会话的绑定空间、进而被用作附件
  // 存储的一级目录名（per-space 分片）——放行 `/`、`.` 就是"写任意路径"的原语
  assertSafeSpaceId(spaceId);
  const device = getDevice(deviceId)!;
  const challenge = await randomBytes(32);
  const challengeId = toB64(await randomBytes(16));
  const sealed = await sealFor(device.public_key, challenge);

  getDb()
    .prepare(
      `INSERT INTO challenges (challenge_id, device_id, space_id, challenge, expires_at, used)
       VALUES (?, ?, ?, ?, ?, 0)`
    )
    .run(challengeId, deviceId, spaceId, toB64(challenge), Date.now() + CHALLENGE_TTL_MS);

  return { challenge_id: challengeId, sealed_challenge: sealed, expires_in: CHALLENGE_TTL_MS / 1000 };
}

/** 阶段 2：校验明文并签发 session（PROTOCOL.md §3）。challenge 一次性。
 *  session 继承 challenge 的 space（challenge 必带 space，见 createChallenge）。 */
export function verifyChallenge(challengeId: string, plaintextB64: string): SessionResult {
  const row = getDb()
    .prepare(`SELECT * FROM challenges WHERE challenge_id = ?`)
    .get(challengeId) as
    | { challenge_id: string; device_id: string; space_id: string | null; challenge: string; expires_at: number; used: number }
    | undefined;

  if (!row) throw new ApiError("INVALID_REQUEST", "unknown challenge", 400);
  if (row.used !== 0) throw new ApiError("CONFLICT", "challenge already used", 409);
  if (row.expires_at < Date.now()) throw new ApiError("INVALID_REQUEST", "challenge expired", 400);
  // v1 时代签发的 challenge（无 space）已不可用：拒绝而不是发一个空空间会话
  if (row.space_id == null || row.space_id.length === 0) {
    throw new ApiError("INVALID_REQUEST", "challenge has no space, re-issue it", 400);
  }

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
  const sessionSpaceId = row.space_id; // 上面已保证非空
  // 同一设备在同一 Space 只保留一个会话：重装/换机/续期后旧 token 立即失效。
  // 此前旧会话会一直累积到过期（24h），而产品上唯一的吊销手段是"整体撤销设备"
  // （2026-09-15 评审）。COALESCE 兼容 ALTER 前写入的 NULL 行。
  db.prepare(`DELETE FROM sessions WHERE device_id = ? AND COALESCE(space_id, '') = ?`).run(
    row.device_id,
    sessionSpaceId
  );
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
 *  NULL 只可能来自 v1 收敛前的存量行；新写入一律带 space（createChallenge 强制），
 *  调用方不必再回落——guard.requireSession 直接拒绝无 space 的会话。
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
