import { createHash, randomBytes, randomUUID } from "node:crypto";
import { getDb } from "./db.js";
import { ApiError } from "./auth.js";
import { pwhashStr, toB64 } from "./crypto.js";
import { parsePackage, type EscrowPackage } from "./escrow.js";

// Multiverse：多租户空间与一次性加入凭证（docs/PROTOCOL_MULTIVERSE.md §3/§4）。
// 骨架阶段说明：
// - space_address 为随机 hex 占位（正式版由 space_public_key 经 Keccak-256 +
//   EIP-55 派生，见 PROTOCOL_MULTIVERSE.md §1.3）；
// - join token 授权语义完整（一次性、24h、只存 SHA-256 hash）；
// - 成员数事务约束完整（并发加入只有一个成功）；
// - 端点的成员认证（Space-scoped session）由 U1 补齐，骨架暂免鉴权。

const BASE58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
const TOKEN_TTL_MS = 24 * 3600 * 1000; // token 默认 24h（老板 2026-09-10 拍板）
const SESSION_TTL_MS = 24 * 60 * 60 * 1000; // join 签发 session 有效期（同 v1）
const JOIN_LINK_PREFIX = "https://einz.tic.cc/join/";

/** base58url 编码（无歧义字符集；32B 随机数 → 43~44 字符）。 */
function base58url(bytes: Buffer): string {
  let n = BigInt("0x" + bytes.toString("hex"));
  let out = "";
  while (n > 0n) {
    out = BASE58_ALPHABET[Number(n % 58n)] + out;
    n /= 58n;
  }
  return out.padStart(43, "1");
}

/** 生成一次性 join token（e1_ 前缀），写库（只存 hash），返回明文与到期时间。 */
export function newJoinToken(
  spaceId: string,
  createdByDevice: string,
): { token: string; hash: string; expiresAt: number } {
  const token = "e1_" + base58url(randomBytes(32));
  const hash = createHash("sha256").update(token).digest("hex");
  const expiresAt = Date.now() + TOKEN_TTL_MS;
  getDb()
    .prepare(
      `INSERT INTO join_tokens (space_id, token_hash, created_by_device, expires_at, created_at)
       VALUES (?, ?, ?, ?, ?)`,
    )
    .run(spaceId, hash, createdByDevice, expiresAt, Date.now());
  return { token, hash, expiresAt };
}

/** 创建 Space（首设备自举）：创建者为第一位成员（partner_slot 0），返回首个
 *  join token 供分享。U2 密钥分发：可一并提交"口令加密的 Space Key 密封包"
 *  （escrow，按空间隔离）——后续加入方凭同一口令从 key-escrow 取回 Space Key
 *  （PROTOCOL_MULTIVERSE.md §5 ④）。sealedSpaceKey 与 escrowPassphrase 需成对。 */
export async function createSpace(
  clientSpaceId?: string,
  displayName?: string,
  sealedSpaceKey?: unknown,
  escrowPassphrase?: string,
  publicKey?: string,
  deviceName?: string,
): Promise<{
  spaceId: string;
  spaceAddress: string;
  joinToken: string;
  link: string;
  expiresAt: number;
  deviceId: string;
  creatorPersonId: string;
  sessionToken: string;
}> {
  // 协议 §3.4：space_id/space_key 由客户端生成（包内容需含 space_id）——
  // 接受客户端 space_id（校验非空字符串），缺省回退服务端生成
  const spaceId = (clientSpaceId != null && clientSpaceId.trim().length > 0)
    ? clientSpaceId.trim()
    : randomUUID();
  // 占位地址：正式版由 space_public_key 派生（Keccak-256 + EIP-55）
  const spaceAddress = "0x" + randomBytes(20).toString("hex");
  const spacePublicKey = "pending:" + randomUUID();
  const now = Date.now();
  getDb()
    .prepare(
      `INSERT INTO spaces (space_id, space_address, space_public_key, display_name, status, created_at, updated_at)
       VALUES (?, ?, ?, ?, 'waiting', ?, ?)`,
    )
    .run(spaceId, spaceAddress, spacePublicKey, displayName ?? null, now, now);
  const creatorPersonId = randomUUID();
  getDb()
    .prepare(
      `INSERT INTO space_members (space_id, person_id, partner_slot, display_name, status, joined_at)
       VALUES (?, ?, 0, ?, 'active', ?)`,
    )
    .run(spaceId, creatorPersonId, displayName ?? null, now);
  // U2：Space Key 口令密封包（可选；成对提供时写入 key_escrow）
  if (sealedSpaceKey != null || (escrowPassphrase != null && escrowPassphrase.length > 0)) {
    if (sealedSpaceKey == null) {
      throw new ApiError(
        "INVALID_REQUEST",
        "sealedSpaceKey 与 escrowPassphrase 需同时提供",
        400,
      );
    }
    const pkg = parsePackage(sealedSpaceKey) as EscrowPackage;
    const passphraseHash =
      escrowPassphrase != null && escrowPassphrase.length > 0
        ? await pwhashStr(escrowPassphrase)
        : null;
    getDb()
      .prepare(
        `INSERT INTO key_escrow (space_id, package, passphrase_hash, updated_at)
         VALUES (?, ?, ?, ?)`,
      )
      .run(spaceId, JSON.stringify(pkg), passphraseHash, now);
  }
  // U3：创建者设备登记（提供 publicKey 时）+ 签发绑定该 Space 的 session——
  // 创建者可立即进聊天，无需二次流程
  let deviceId = "";
  let sessionToken = "";
  if (publicKey != null && publicKey.length > 0) {
    deviceId = randomUUID();
    getDb()
      .prepare(
        `INSERT INTO devices (device_id, person_id, public_key, status, device_name, created_at)
         VALUES (?, ?, ?, 'active', ?, ?)`,
      )
      .run(deviceId, creatorPersonId, publicKey, deviceName ?? null, now);
    sessionToken = toB64(new Uint8Array(randomBytes(32)));
    getDb()
      .prepare(
        `INSERT INTO sessions (session_token, device_id, space_id, expires_at, created_at)
         VALUES (?, ?, ?, ?, ?)`,
      )
      .run(sessionToken, deviceId, spaceId, now + SESSION_TTL_MS, now);
  }
  const t = newJoinToken(spaceId, "creator");
  return {
    spaceId,
    spaceAddress,
    joinToken: t.token,
    link: JOIN_LINK_PREFIX + t.token,
    expiresAt: t.expiresAt,
    deviceId,
    creatorPersonId,
    sessionToken,
  };
}

/** 精确查找 Space（仅最小公开信息：名称、状态、成员数；custom_id 后置）。 */
export function lookupSpace(
  address?: string,
): { spaceId: string; displayName: string | null; status: string; memberCount: number } {
  const row = getDb()
    .prepare(`SELECT space_id, display_name, status FROM spaces WHERE space_address = ?`)
    .get(address ?? "") as { space_id: string; display_name: string | null; status: string } | undefined;
  if (!row) throw new ApiError("SPACE_NOT_FOUND", "space not found", 404);
  const memberCount = (
    getDb()
      .prepare(`SELECT COUNT(*) AS n FROM space_members WHERE space_id = ? AND status = 'active'`)
      .get(row.space_id) as { n: number }
  ).n;
  return { spaceId: row.space_id, displayName: row.display_name, status: row.status, memberCount };
}

/** join preflight：轻量校验 token（格式/未用/未过期/空间可加入）但**不消费**，
 *  返回空间公开信息供客户端确认（PROTOCOL_MULTIVERSE.md §5 ①/② fail-fast）。 */
export function preflightJoin(
  token: string,
): { spaceId: string; displayName: string | null; status: string; memberCount: number } {
  const hash = createHash("sha256").update(token).digest("hex");
  const tk = getDb()
    .prepare(`SELECT space_id, expires_at, used_at FROM join_tokens WHERE token_hash = ?`)
    .get(hash) as { space_id: string; expires_at: number; used_at: number | null } | undefined;
  if (!tk) throw new ApiError("TOKEN_INVALID", "invalid join token", 400);
  if (tk.used_at != null) throw new ApiError("TOKEN_USED", "join token already used", 410);
  if (tk.expires_at < Date.now()) throw new ApiError("TOKEN_EXPIRED", "join token expired", 410);
  const sp = getDb()
    .prepare(`SELECT display_name, status FROM spaces WHERE space_id = ?`)
    .get(tk.space_id) as { display_name: string | null; status: string } | undefined;
  if (!sp || (sp.status !== "waiting" && sp.status !== "active")) {
    throw new ApiError("SPACE_NOT_FOUND", "space not found", 404);
  }
  const memberCount = (
    getDb()
      .prepare(`SELECT COUNT(*) AS n FROM space_members WHERE space_id = ? AND status = 'active'`)
      .get(tk.space_id) as { n: number }
  ).n;
  if (memberCount >= 2) throw new ApiError("SPACE_FULL", "space is full", 409);
  return { spaceId: tk.space_id, displayName: sp.display_name, status: sp.status, memberCount };
}

/** 加入 Space：事务内消费 token（未用/未过期/未满员）并插入第二位成员；
 *  满员后空间转 active。U3：加入设备登记（devices，服务端分配 UUID）并签发
 *  绑定该 Space 的 session——加入后可立即进聊天（PROTOCOL_MULTIVERSE.md §4.1）。 */
export function joinSpace(
  token: string,
  publicKey: string,
  deviceName?: string,
  displayName?: string,
  gender?: string,
): { spaceId: string; personId: string; partnerSlot: number; sessionToken: string } {
  if (publicKey.length === 0) {
    throw new ApiError("INVALID_REQUEST", "publicKey 必填（加入设备公钥）", 400);
  }
  const hash = createHash("sha256").update(token).digest("hex");
  const tk = getDb()
    .prepare(`SELECT space_id, expires_at, used_at FROM join_tokens WHERE token_hash = ?`)
    .get(hash) as { space_id: string; expires_at: number; used_at: number | null } | undefined;
  if (!tk) throw new ApiError("TOKEN_INVALID", "invalid join token", 400);
  if (tk.used_at != null) throw new ApiError("TOKEN_USED", "join token already used", 410);
  if (tk.expires_at < Date.now()) throw new ApiError("TOKEN_EXPIRED", "join token expired", 410);

  const doJoin = getDb().transaction(() => {
    const sp = getDb()
      .prepare(`SELECT status FROM spaces WHERE space_id = ?`)
      .get(tk.space_id) as { status: string } | undefined;
    if (!sp || (sp.status !== "waiting" && sp.status !== "active")) {
      throw new ApiError("SPACE_NOT_FOUND", "space not found", 404);
    }
    const cnt = (
      getDb()
        .prepare(`SELECT COUNT(*) AS n FROM space_members WHERE space_id = ? AND status = 'active'`)
        .get(tk.space_id) as { n: number }
    ).n;
    if (cnt >= 2) throw new ApiError("SPACE_FULL", "space is full", 409);
    // 一次性：先标记 token 已用，再插入成员（同事务，防并发双加入）
    getDb()
      .prepare(`UPDATE join_tokens SET used_at = ? WHERE token_hash = ?`)
      .run(Date.now(), hash);
    const slot = (
      getDb()
        .prepare(`SELECT MAX(partner_slot) AS m FROM space_members WHERE space_id = ?`)
        .get(tk.space_id) as { m: number | null }
    ).m ?? -1;
    const personId = randomUUID();
    getDb()
      .prepare(
        `INSERT INTO space_members (space_id, person_id, partner_slot, display_name, gender, status, joined_at)
         VALUES (?, ?, ?, ?, ?, 'active', ?)`,
      )
      .run(tk.space_id, personId, slot + 1, displayName ?? null, gender ?? null, Date.now());
    getDb()
      .prepare(`UPDATE spaces SET status = 'active', updated_at = ? WHERE space_id = ?`)
      .run(Date.now(), tk.space_id);
    // U3：加入设备登记（服务端分配 device_id UUID）+ 签发绑定该 Space 的 session
    const deviceId = randomUUID();
    getDb()
      .prepare(
        `INSERT INTO devices (device_id, person_id, public_key, status, device_name, created_at)
         VALUES (?, ?, ?, 'active', ?, ?)`,
      )
      .run(deviceId, personId, publicKey, deviceName ?? null, Date.now());
    const sessionToken = toB64(new Uint8Array(randomBytes(32)));
    getDb()
      .prepare(
        `INSERT INTO sessions (session_token, device_id, space_id, expires_at, created_at)
         VALUES (?, ?, ?, ?, ?)`,
      )
      .run(sessionToken, deviceId, tk.space_id, Date.now() + SESSION_TTL_MS, Date.now());
    return { spaceId: tk.space_id, personId, partnerSlot: slot + 1, sessionToken, deviceId };
  });
  return doJoin();
}

/** 生成一次性邀请 token（骨架：成员认证由 U1 Space-scoped session 补齐）。 */
export function createJoinToken(
  spaceId: string,
): { joinToken: string; link: string; expiresAt: number } {
  const sp = getDb().prepare(`SELECT 1 FROM spaces WHERE space_id = ?`).get(spaceId);
  if (!sp) throw new ApiError("SPACE_NOT_FOUND", "space not found", 404);
  const t = newJoinToken(spaceId, "member");
  return { joinToken: t.token, link: JOIN_LINK_PREFIX + t.token, expiresAt: t.expiresAt };
}
