import { createHash, randomBytes, randomUUID } from "node:crypto";
import { getDb } from "./db.js";
import { ApiError, hashSessionToken } from "./auth.js";
import { pwhashStr, toB64 } from "./crypto.js";
import { parsePackage, type EscrowPackage } from "./escrow.js";
import { deriveSpaceAddress } from "./address.js";
import { loadConfig } from "./config.js";
import { normalizeEntranceName } from "./entranceName.js";
import { normalizeInstallUid } from "./installUid.js";
import { assertPartnerName } from "./partnerName.js";
import { assertSafeSpaceId } from "./safeId.js";

// Multiverse：多租户空间与一次性加入凭证（docs/PROTOCOL_MULTIVERSE.md §3/§4）。
// - space_address 由 space_public_key（创建者公钥）经 Keccak-256 + EIP-55 派生
//   （见 PROTOCOL_MULTIVERSE.md §1.3；地址只定位不授权）；
// - join token 授权语义完整（一次性、24h、只存 SHA-256 hash）；
// - 成员数事务约束完整（并发加入只有一个成功）；
// - 端点的成员认证：space 级端点走 guard.requireSpaceMember（2026-09-15 评审 C1 补齐）。

const BASE58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
const TOKEN_TTL_MS = 24 * 3600 * 1000; // token 默认 24h（老板 2026-09-10 拍板）
const SESSION_TTL_MS = 24 * 60 * 60 * 1000; // join 签发 session 有效期（同 v1）
// 邀请链接 base（兜底值）：正常由服务端按请求真实 Host 生成（TUI --server /
// app localConfig.json 覆盖服务器地址时链接同步正确，老板 2026-09-11）
const DEFAULT_LINK_BASE = "https://einz.tic.cc";

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
  createdByEntrance: string,
): { token: string; hash: string; expiresAt: number } {
  const token = "e1_" + base58url(randomBytes(32));
  const hash = createHash("sha256").update(token).digest("hex");
  const expiresAt = Date.now() + TOKEN_TTL_MS;
  getDb()
    .prepare(
      `INSERT INTO join_tokens (space_id, token_hash, created_by_entrance, expires_at, created_at)
       VALUES (?, ?, ?, ?, ?)`,
    )
    .run(spaceId, hash, createdByEntrance, expiresAt, Date.now());
  return { token, hash, expiresAt };
}

/** 创建 Space（首设备自举）：创建者为第一位成员（slot 0），返回首个
 *  join token 供分享。U2 密钥分发：可一并提交"口令加密的 Space Key 密封包"
 *  （escrow，按空间隔离）——后续加入方凭同一口令从 key-escrow 取回 Space Key
 *  （PROTOCOL_MULTIVERSE.md §5 ④）。sealedSpaceKey 与 escrowPassphrase 需成对。 */
/** 性别归一：统一存 male/female（接受中文/英文——老板 2026-09-10：前后端 id
 *  写法不匹配导致气泡全青色；非法值丢弃不入库）。 */
function normGender(g?: string): string | undefined {
  if (g == null) return undefined;
  const v = g.trim();
  if (v === "男" || v === "male") return "male";
  if (v === "女" || v === "female") return "female";
  return undefined;
}

export async function createSpace(
  clientSpaceId?: string,
  creatorName?: string, // 创建者（第一人）的显示名——落 space_members，不落 spaces
  creatorGender?: string,
  peerName?: string,
  peerGender?: string,
  sealedSpaceKey?: unknown,
  escrowPassphrase?: string,
  publicKey?: string,
  entranceName?: string,
  installUid?: string, // 安装级设备标识（多空间：同一物理设备各空间一行同名）
  baseUrl?: string, // 邀请链接 base（按请求真实 Host 生成，2026-09-11）
): Promise<{
  spaceId: string;
  spaceAddress: string;
  joinToken: string;
  link: string;
  expiresAt: number;
  entranceId: string;
  creatorPartnerId: string;
  sessionToken: string;
}> {
  // 协议 §3.4：space_id/space_key 由客户端生成（包内容需含 space_id）——
  // 接受客户端 space_id（校验非空字符串），缺省回退服务端生成。
  // **字符集必须收紧**：客户端可自报，而 space_id 后续会被用作附件存储的一级
  // 目录名（per-space 分片）——放行 `/`、`.` 就等于给出"写任意路径"的原语
  // （见 safeId.assertSafeSpaceId）。服务端自生成的 randomUUID 恒合规。
  const spaceId = (clientSpaceId != null && clientSpaceId.trim().length > 0)
    ? (assertSafeSpaceId(clientSpaceId.trim()), clientSpaceId.trim())
    : randomUUID();
  // 空间数量上限（config.json 的 maxSpaces：0=不限；≥1 时现有空间数 ≥ 上限即
  // 禁止新建并返回 SPACE_LIMIT_REACHED——maxSpaces=1 即退回 v1 单空间模式，
  // 老板 2026-09-10）
  const cfg = loadConfig();
  if (cfg.max_spaces > 0) {
    const cnt = (getDb().prepare(`SELECT COUNT(*) AS n FROM spaces`).get() as { n: number }).n;
    if (cnt >= cfg.max_spaces) {
      throw new ApiError("SPACE_LIMIT_REACHED", "空间数量已达上限（maxSpaces）", 409);
    }
  }
  // 用户名称白名单（老板 2026-09-16）：create 录入的是**两人**的名字（我的 +
  // 伴侣），都是用户自己输入的 → 不合规直接 400，让客户端提示重输。
  // 只有传了才校验（未传维持现状——服务端不强制必填，必填由客户端引导负责）
  if (creatorName != null) assertPartnerName(creatorName);
  if (peerName != null) assertPartnerName(peerName);
  // 占位地址：正式版由 space_public_key 派生（Keccak-256 + EIP-55）
  const spacePublicKey = publicKey ?? "pending:" + randomUUID();
  // 地址 = Keccak-256(space_public_key) 后 20 字节 + EIP-55（确定性；公钥缺失回退随机）
  const spaceAddress = await deriveSpaceAddress(
    spacePublicKey,
    "0x" + randomBytes(20).toString("hex"),
  );
  const now = Date.now();
  getDb()
    .prepare(
      `INSERT INTO spaces (space_id, space_address, space_public_key, status, created_at, updated_at)
       VALUES (?, ?, ?, 'waiting', ?, ?)`,
    )
    .run(spaceId, spaceAddress, spacePublicKey, now, now);
  const creatorPartnerId = randomUUID();
  getDb()
    .prepare(
      `INSERT INTO space_members (space_id, partner_id, slot, display_name, gender, status, joined_at)
       VALUES (?, ?, 0, ?, ?, 'active', ?)`,
    )
    .run(spaceId, creatorPartnerId, creatorName ?? null, normGender(creatorGender) ?? null, now);
  // 伴侣（第二人）预置：名字/性别必填（老板 2026-09-10 定稿——create 时录入两人
  // 身份，join 时按身份选择而非自填名字）；status=pending 待加入，partner_id 由
  // 首个加入该 slot 的设备生成。
  getDb()
    .prepare(
      `INSERT INTO space_members (space_id, partner_id, slot, display_name, gender, status, joined_at)
       VALUES (?, NULL, 1, ?, ?, 'pending', NULL)`,
    )
    .run(spaceId, peerName ?? null, normGender(peerGender) ?? null);
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
  let entranceId = "";
  let sessionToken = "";
  if (publicKey != null && publicKey.length > 0) {
    entranceId = randomUUID();
    getDb()
      .prepare(
        `INSERT INTO entrances (entrance_id, partner_id, public_key, status, entrance_name, created_at, install_uid)
         VALUES (?, ?, ?, 'active', ?, ?, ?)`,
      )
      .run(entranceId, creatorPartnerId, publicKey, normalizeEntranceName(entranceName), now, normalizeInstallUid(installUid));
    sessionToken = toB64(new Uint8Array(randomBytes(32)));
    getDb()
      .prepare(
        `INSERT INTO sessions (session_token, entrance_id, space_id, expires_at, created_at)
         VALUES (?, ?, ?, ?, ?)`,
      )
      // 库中存 sha256（明文只回给客户端；见 auth.hashSessionToken）
      .run(hashSessionToken(sessionToken), entranceId, spaceId, now + SESSION_TTL_MS, now);
  }
  const t = newJoinToken(spaceId, "creator");
  return {
    spaceId,
    spaceAddress,
    joinToken: t.token,
    link: (baseUrl ?? DEFAULT_LINK_BASE) + "/join/" + t.token,
    expiresAt: t.expiresAt,
    entranceId,
    creatorPartnerId,
    sessionToken,
  };
}

/** 精确查找 Space（仅最小公开信息：状态、成员数；custom_id 后置）。 */
export function lookupSpace(
  address?: string,
): { spaceId: string; status: string; memberCount: number } {
  const row = getDb()
    .prepare(`SELECT space_id, status FROM spaces WHERE space_address = ?`)
    .get(address ?? "") as { space_id: string; status: string } | undefined;
  if (!row) throw new ApiError("SPACE_NOT_FOUND", "space not found", 404);
  const memberCount = (
    getDb()
      .prepare(`SELECT COUNT(*) AS n FROM space_members WHERE space_id = ? AND status = 'active'`)
      .get(row.space_id) as { n: number }
  ).n;
  return { spaceId: row.space_id, status: row.status, memberCount };
}

/** join preflight：轻量校验 token（格式/未用/未过期/空间可加入）但**不消费**，
 *  返回空间公开信息供客户端确认（PROTOCOL_MULTIVERSE.md §5 ①/② fail-fast）。
 *  响应**不含空间名**（spaces.display_name 已删，2026-09-16）：join 方需要的"对方
 *  是谁"由 slots 里的身份名提供。 */
export function preflightJoin(
  token: string,
): {
  spaceId: string;
  status: string;
  memberCount: number;
  slots: { slot: number; displayName: string | null; gender: string | null; status: string }[];
} {
  const hash = createHash("sha256").update(token).digest("hex");
  const tk = getDb()
    .prepare(`SELECT space_id, expires_at, used_at FROM join_tokens WHERE token_hash = ?`)
    .get(hash) as { space_id: string; expires_at: number; used_at: number | null } | undefined;
  if (!tk) throw new ApiError("TOKEN_INVALID", "invalid join token", 400);
  if (tk.used_at != null) throw new ApiError("TOKEN_USED", "join token already used", 410);
  if (tk.expires_at < Date.now()) throw new ApiError("TOKEN_EXPIRED", "join token expired", 410);
  const sp = getDb()
    .prepare(`SELECT status FROM spaces WHERE space_id = ?`)
    .get(tk.space_id) as { status: string } | undefined;
  if (!sp || (sp.status !== "waiting" && sp.status !== "active")) {
    throw new ApiError("SPACE_NOT_FOUND", "space not found", 404);
  }
  // 成员（两身份 slot）公开信息：join 时客户端据此展示「选择是哪一个用户」——
  // 加入者可能是第二人，也可能是第一人的其他设备（老板 2026-09-10 定稿）
  const members = getDb()
    .prepare(
      `SELECT slot, display_name, gender, status FROM space_members
       WHERE space_id = ? ORDER BY slot`,
    )
    .all(tk.space_id) as {
    slot: number;
    display_name: string | null;
    gender: string | null;
    status: string;
  }[];
  const slots = members.map((m) => ({
    slot: m.slot,
    displayName: m.display_name,
    gender: m.gender,
    status: m.status,
  }));
  const memberCount = slots.filter((s) => s.status === "active").length;
  // 多设备语义（同一身份可多台设备）：不再有「满」——身份由加入者选择
  return { spaceId: tk.space_id, status: sp.status, memberCount, slots };
}

/** 加入 Space：事务内消费 token（未用/未过期/未满员）并插入第二位成员；
 *  满员后空间转 active。U3：加入设备登记（entrances，服务端分配 UUID）并签发
 *  绑定该 Space 的 session——加入后可立即进聊天（PROTOCOL_MULTIVERSE.md §4.1）。 */
export function joinSpace(
  token: string,
  publicKey: string,
  entranceName?: string,
  slot?: number,
  installUid?: string, // 安装级设备标识（多空间：同一物理设备各空间一行同名）
): { spaceId: string; partnerId: string; slot: number; sessionToken: string; spaceAddress: string } {
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
      .prepare(`SELECT status, space_address FROM spaces WHERE space_id = ?`)
      .get(tk.space_id) as { status: string; space_address: string } | undefined;
    if (!sp || (sp.status !== "waiting" && sp.status !== "active")) {
      throw new ApiError("SPACE_NOT_FOUND", "space not found", 404);
    }
    // 身份 slot：加入者选择（0=第一人/创建者，1=第二人/伴侣）；缺省第二人。
    // 同一身份可有多台设备（创建者换设备加入选 0）——不再有「满」。
    const chosenSlot = slot === 0 || slot === 1 ? slot : 1;
    let member = getDb()
      .prepare(`SELECT partner_id, status FROM space_members WHERE space_id = ? AND slot = ?`)
      .get(tk.space_id, chosenSlot) as { partner_id: string | null; status: string } | undefined;
    if (!member) {
      // 容错：slot 行缺失（理论上 create 已预置两身份）→ 补建
      getDb()
        .prepare(
          `INSERT INTO space_members (space_id, partner_id, slot, status, joined_at)
           VALUES (?, NULL, ?, 'active', ?)`,
        )
        .run(tk.space_id, chosenSlot, Date.now());
      member = { partner_id: null, status: "active" };
    }
    let partnerId = member.partner_id;
    if (partnerId == null) {
      // 该身份首次加入：生成 partner_id 并激活
      partnerId = randomUUID();
      getDb()
        .prepare(
          `UPDATE space_members SET partner_id = ?, status = 'active', joined_at = ?
           WHERE space_id = ? AND slot = ?`,
        )
        .run(partnerId, Date.now(), tk.space_id, chosenSlot);
    } else if (member.status !== "active") {
      getDb()
        .prepare(
          `UPDATE space_members SET status = 'active', joined_at = ? WHERE space_id = ? AND slot = ?`,
        )
        .run(Date.now(), tk.space_id, chosenSlot);
    }
    // 通道数量上限（serverConfig.json 的 maxEntrancesPerSpace：0=不限）——
    // **必须在事务内**计：preflight 不消费 token，并发两个 join 会同时通过预检
    // 然后双双插设备 → 超额。计数按"该空间登记过的通道总数"，**含已撤销**：
    // 销毁/撤销是软标记（entrances.status='revoked'，行不删），若只数 active，
    // "开通→销毁→再开通"就能无限刷额度，防滥用等于没做（老板 2026-09-23 定）。
    const cfg = loadConfig();
    if (cfg.max_entrances_per_space > 0) {
      const cnt = (
        getDb()
          .prepare(
            `SELECT COUNT(*) AS n FROM entrances d
             JOIN space_members sm ON sm.partner_id = d.partner_id
             WHERE sm.space_id = ?`,
          )
          .get(tk.space_id) as { n: number }
      ).n;
      if (cnt >= cfg.max_entrances_per_space) {
        throw new ApiError(
          "ENTRANCE_LIMIT_REACHED",
          `通道数量已达上限（${cfg.max_entrances_per_space}）`,
          409,
        );
      }
    }
    // 一次性：先标记 token 已用，再插设备（同事务，防并发双加入）
    getDb()
      .prepare(`UPDATE join_tokens SET used_at = ? WHERE token_hash = ?`)
      .run(Date.now(), hash);
    // 加入设备登记（同一身份多设备共享 partner_id）+ 签发绑定该 Space 的 session
    const entranceId = randomUUID();
    getDb()
      .prepare(
        `INSERT INTO entrances (entrance_id, partner_id, public_key, status, entrance_name, created_at, install_uid)
         VALUES (?, ?, ?, 'active', ?, ?, ?)`,
      )
      .run(entranceId, partnerId, publicKey, normalizeEntranceName(entranceName), Date.now(), normalizeInstallUid(installUid));
    const sessionToken = toB64(new Uint8Array(randomBytes(32)));
    getDb()
      .prepare(
        `INSERT INTO sessions (session_token, entrance_id, space_id, expires_at, created_at)
         VALUES (?, ?, ?, ?, ?)`,
      )
      // 库中存 sha256（明文只回给客户端；见 auth.hashSessionToken）
      .run(hashSessionToken(sessionToken), entranceId, tk.space_id, Date.now() + SESSION_TTL_MS, Date.now());
    getDb()
      .prepare(`UPDATE spaces SET status = 'active', updated_at = ? WHERE space_id = ?`)
      .run(Date.now(), tk.space_id);
    return { spaceId: tk.space_id, partnerId, slot: chosenSlot, sessionToken, entranceId, spaceAddress: sp.space_address };
  });
  return doJoin();
}

/** 生成一次性邀请 token（骨架：成员认证由 U1 Space-scoped session 补齐）。 */
export function createJoinToken(
  spaceId: string,
  baseUrl?: string, // 邀请链接 base（按请求真实 Host 生成，2026-09-11）
): { joinToken: string; link: string; expiresAt: number } {
  const sp = getDb().prepare(`SELECT 1 FROM spaces WHERE space_id = ?`).get(spaceId);
  if (!sp) throw new ApiError("SPACE_NOT_FOUND", "space not found", 404);
  const t = newJoinToken(spaceId, "member");
  return { joinToken: t.token, link: (baseUrl ?? DEFAULT_LINK_BASE) + "/join/" + t.token, expiresAt: t.expiresAt };
}
