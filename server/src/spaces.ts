import { createHash, randomBytes, randomUUID } from "node:crypto";
import { getDb } from "./db.js";
import { ApiError } from "./auth.js";

// Multiverse：多租户空间与一次性加入凭证（docs/PROTOCOL_MULTIVERSE.md §3/§4）。
// 骨架阶段说明：
// - space_address 为随机 hex 占位（正式版由 space_public_key 经 Keccak-256 +
//   EIP-55 派生，见 PROTOCOL_MULTIVERSE.md §1.3）；
// - join token 授权语义完整（一次性、24h、只存 SHA-256 hash）；
// - 成员数事务约束完整（并发加入只有一个成功）；
// - 端点的成员认证（Space-scoped session）由 U1 补齐，骨架暂免鉴权。

const BASE58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
const TOKEN_TTL_MS = 24 * 3600 * 1000; // token 默认 24h（老板 2026-09-10 拍板）
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

/** 创建 Space（首设备自举；sealedSpaceKey 等 E2EE 字段由 U2 补齐）：创建者为
 *  第一位成员（partner_slot 0），返回首个 join token 供分享。 */
export function createSpace(
  displayName?: string,
): { spaceId: string; spaceAddress: string; joinToken: string; link: string; expiresAt: number } {
  const spaceId = randomUUID();
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
  getDb()
    .prepare(
      `INSERT INTO space_members (space_id, person_id, partner_slot, display_name, status, joined_at)
       VALUES (?, ?, 0, ?, 'active', ?)`,
    )
    .run(spaceId, randomUUID(), displayName ?? null, now);
  const t = newJoinToken(spaceId, "creator");
  return {
    spaceId,
    spaceAddress,
    joinToken: t.token,
    link: JOIN_LINK_PREFIX + t.token,
    expiresAt: t.expiresAt,
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

/** 加入 Space：事务内消费 token（未用/未过期/未满员）并插入第二位成员；
 *  满员后空间转 active。sessionToken 由 U1 认证整合补齐。 */
export function joinSpace(
  token: string,
  displayName?: string,
  gender?: string,
): { spaceId: string; personId: string; partnerSlot: number } {
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
    return { spaceId: tk.space_id, personId, partnerSlot: slot + 1 };
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
