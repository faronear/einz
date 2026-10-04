import { createHash, randomBytes, randomUUID } from "node:crypto";
import { getDb } from "./db.js";
import { ApiError, hashSessionToken } from "./auth.js";
import { pwhashStr, toB64 } from "./crypto.js";
import { parsePackage, type EscrowPackage } from "./escrow.js";
import { deriveSpaceAddress } from "./address.js";
import { loadConfig } from "./config.js";
import { normalizeEntranceName } from "./entranceName.js";
import { normalizeInstallUid } from "./installUid.js";
import { assertMemberName, isSameMemberName } from "./memberName.js";
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

/** 生成一次性 join token（e1_ 前缀），写库（只存 hash），返回明文与到期时间。
 *
 *  两个维度（2026-10-04 收敛，见 createJoinToken 的说明）：
 *  - purpose：`invite` = 开**新身份**；`attach` = 进**已有身份**
 *  - targetMemberId：attach 时"进谁的身份"（null = 存量 token，退回看 issuer）
 *
 *  issuerMemberId：签发者身份——attach token 用它兜存量、并给 preflight 报
 *  精确的"是谁发的"；invite token 只用于后者。两种 purpose 都应当传。 */
export function newJoinToken(
  spaceId: string,
  createdByEntrance: string,
  purpose: "invite" | "attach" = "attach",
  issuerMemberId?: string,
  targetMemberId?: string,
): { token: string; hash: string; expiresAt: number } {
  const token = "e1_" + base58url(randomBytes(32));
  const hash = createHash("sha256").update(token).digest("hex");
  const expiresAt = Date.now() + TOKEN_TTL_MS;
  getDb()
    .prepare(
      `INSERT INTO join_tokens (space_id, token_hash, created_by_entrance, purpose, issuer_member_id, target_member_id, expires_at, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
    )
    .run(
      spaceId,
      hash,
      createdByEntrance,
      purpose,
      issuerMemberId ?? null,
      targetMemberId ?? null,
      expiresAt,
      Date.now(),
    );
  return { token, hash, expiresAt };
}

/** 读空间 mode（'duo' | 'group'；未知空间 undefined）——创建时定死、永不改变
 *  （2026-10-04 老板拍板取消升格，见 createSpace）。 */
export function getSpaceMode(spaceId: string): string | undefined {
  const row = getDb()
    .prepare(`SELECT mode FROM spaces WHERE space_id = ?`)
    .get(spaceId) as { mode: string } | undefined;
  return row?.mode;
}

/** 空间内 active 成员（身份）数——同身份多通道只计一次。 */
export function countActiveMembers(spaceId: string): number {
  return (
    getDb()
      .prepare(
        `SELECT COUNT(*) AS n FROM space_members WHERE space_id = ? AND status = 'active'`,
      )
      .get(spaceId) as { n: number }
  ).n;
}

/** 创建 Space（首通道自举）：创建者为第一位成员（slot 0），返回首个
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
  sealedSpaceKey?: unknown,
  escrowPassphrase?: string,
  publicKey?: string,
  entranceName?: string,
  installUid?: string, // 安装级标识（多空间：同一物理设备各空间一行同名）
  baseUrl?: string, // 邀请链接 base（按请求真实 Host 生成，2026-09-11）
  modeRaw?: string, // 空间模式（'duo' | 'group'，2026-10-04 起**创建时定死**）
): Promise<{
  spaceId: string;
  spaceAddress: string;
  joinToken: string;
  link: string;
  expiresAt: number;
  entranceId: string;
  creatorMemberId: string;
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
  // 用户名称白名单（老板 2026-09-16）：create 录入的是创建者自己的名字 →
  // 不合规直接 400，让客户端提示重输。
  // 只有传了才校验（未传维持现状——服务端不强制必填，必填由客户端引导负责）。
  // 群聊一期（2026-10-03）：create 不再预置对方名字——partner 加入时自己填名。
  if (creatorName != null) assertMemberName(creatorName);
  // 占位地址：正式版由 space_public_key 派生（Keccak-256 + EIP-55）
  const spacePublicKey = publicKey ?? "pending:" + randomUUID();
  // 地址 = Keccak-256(space_public_key) 后 20 字节 + EIP-55（确定性；公钥缺失回退随机）
  const spaceAddress = await deriveSpaceAddress(
    spacePublicKey,
    "0x" + randomBytes(20).toString("hex"),
  );
  const now = Date.now();
  // 空间模式（2026-10-04 老板拍板）：**创建时定死，永不改变**——
  //   duo = 二人私密空间（成员上限恒 2、可语音通话）；
  //   group = 群空间（上限 maxMembersPerSpace、禁语音通话）。
  // 没有"升格"：duo 想变群只能另建空间（历史消息留在旧空间）。
  // 所以 mode 在这条 INSERT 之后就再也不会被 UPDATE（无状态机、无单向往返）。
  // 缺省/非法值回退 'duo'（存量客户端 v2 的 create 不带这个字段）。
  const mode = modeRaw === "group" ? "group" : "duo";
  getDb()
    .prepare(
      `INSERT INTO spaces (space_id, space_address, space_public_key, status, mode, created_at, updated_at)
       VALUES (?, ?, ?, 'waiting', ?, ?, ?)`,
    )
    .run(spaceId, spaceAddress, spacePublicKey, mode, now, now);
  const creatorMemberId = randomUUID();
  getDb()
    .prepare(
      `INSERT INTO space_members (space_id, member_id, slot, display_name, gender, status, joined_at)
       VALUES (?, ?, 0, ?, ?, 'active', ?)`,
    )
    .run(spaceId, creatorMemberId, creatorName ?? null, normGender(creatorGender) ?? null, now);
  // 群聊一期（2026-10-03）：**不再预置伴侣行**——create 只录创建者；partner 用
  // invite token 加入时由 join 的"新身份"路径分配最小空 slot、自己填名。
  // （存量库的 pending 行无需清理：其语义自然退化为"未预置名字的空槽"。）
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
  // U3：创建者通道登记（提供 publicKey 时）+ 签发绑定该 Space 的 session——
  // 创建者可立即进聊天，无需二次流程
  let entranceId = "";
  let sessionToken = "";
  if (publicKey != null && publicKey.length > 0) {
    entranceId = randomUUID();
    getDb()
      .prepare(
        `INSERT INTO entrances (entrance_id, member_id, public_key, status, entrance_name, created_at, install_uid)
         VALUES (?, ?, ?, 'active', ?, ?, ?)`,
      )
      .run(entranceId, creatorMemberId, publicKey, normalizeEntranceName(entranceName), now, normalizeInstallUid(installUid));
    sessionToken = toB64(new Uint8Array(randomBytes(32)));
    getDb()
      .prepare(
        `INSERT INTO sessions (session_token, entrance_id, space_id, expires_at, created_at)
         VALUES (?, ?, ?, ?, ?)`,
      )
      // 库中存 sha256（明文只回给客户端；见 auth.hashSessionToken）
      .run(hashSessionToken(sessionToken), entranceId, spaceId, now + SESSION_TTL_MS, now);
  }
  // created_by_entrance 列存的是**创建者角色字面量**（"creator"/"member"），
  // 不是某条 entrance_id——列名沿用历史，勿据此列反查通道。
  // purpose='invite'：创建后回传的首张链接是"邀请伴侣"（群聊一期 2026-10-03）。
  // issuer 记创建者身份：preflight 的 inviterName 才能精确到人（见 preflightJoin）。
  const t = newJoinToken(spaceId, "creator", "invite", creatorMemberId);
  return {
    spaceId,
    spaceAddress,
    joinToken: t.token,
    link: (baseUrl ?? DEFAULT_LINK_BASE) + "/join/" + t.token,
    expiresAt: t.expiresAt,
    entranceId,
    creatorMemberId,
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
  mode: string;
  memberCount: number;
  /** token 类型（2026-10-04 收敛）：
   *  - `invite` = 开**新身份**（新成员加入，自己填名字；受人数上限约束）
   *  - `attach` = 进**已有身份**（我在新设备接入 / 帮别人找回身份） */
  purpose: "invite" | "attach";
  /** 签发者显示名——invite 显示"XX 邀请你"，attach 显示"XX 的链接"。 */
  inviterName: string | null;
  /** attach 时"要进入的那个身份"的显示名（invite 恒为 null）。
   *  客户端据此显示「回到 <名字> 的身份」并**跳过填名字那一步**（那是同一个身份，
   *  名字已经有了；要改走菜单里的「我的身份」）。 */
  targetName: string | null;
  /** attach 的目标是不是**签发者自己**（true = "我在另一台设备接入"；
   *  false = "别人帮我找回"）。客户端据此选文案——不能靠名字比字符串：
   *  同名成员是允许的。 */
  targetIsIssuer: boolean;
  slots: { slot: number; displayName: string | null; gender: string | null; status: string }[];
} {
  const hash = createHash("sha256").update(token).digest("hex");
  const tk = getDb()
    .prepare(
      `SELECT space_id, expires_at, used_at, purpose, issuer_member_id, target_member_id FROM join_tokens WHERE token_hash = ?`,
    )
    .get(hash) as {
    space_id: string;
    expires_at: number;
    used_at: number | null;
    purpose: string;
    issuer_member_id: string | null;
    target_member_id: string | null;
  } | undefined;
  if (!tk) throw new ApiError("TOKEN_INVALID", "invalid join token", 400);
  if (tk.used_at != null) throw new ApiError("TOKEN_USED", "join token already used", 410);
  if (tk.expires_at < Date.now()) throw new ApiError("TOKEN_EXPIRED", "join token expired", 410);
  const sp = getDb()
    .prepare(`SELECT status, mode FROM spaces WHERE space_id = ?`)
    .get(tk.space_id) as { status: string; mode: string } | undefined;
  if (!sp || (sp.status !== "waiting" && sp.status !== "active")) {
    throw new ApiError("SPACE_NOT_FOUND", "space not found", 404);
  }
  // 成员公开信息（群聊一期不再用于"选择身份"——身份由 purpose 决定；保留给
  // 客户端确认页展示"空间里已有谁"）
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
  // 受邀人名字：**精确取签发者**（join_tokens.issuer_member_id → space_members
  // .display_name）。created_by_entrance 存的是角色字面量（"creator"/"member"，
  // 见 createSpace），追溯不到人——2026-10-04 审查改为签发时一律回填 issuer，
  // 确认页才不会把 B 发的邀请显示成 A 的名字。
  // 存量/无 issuer 的 token 退回"第一个有名字的 active 成员"近似。
  const nameOfMember = (memberId: string | null): string | null =>
    memberId == null
      ? null
      : ((
          getDb()
            .prepare(
              `SELECT display_name FROM space_members WHERE space_id = ? AND member_id = ?`,
            )
            .get(tk.space_id, memberId) as { display_name: string | null } | undefined
        )?.display_name ?? null);
  const inviterName =
    nameOfMember(tk.issuer_member_id) ??
    slots.find((s) => s.status === "active" && s.displayName != null)?.displayName ??
    null;
  const purpose: "invite" | "attach" = tk.purpose === "invite" ? "invite" : "attach";
  // attach 的目标身份：新的看 target_member_id（可指向别人 = 帮对方找回）；
  // 存量老 token（target NULL）退回 issuer_member_id（那时只能指向自己）
  const attachTargetId =
    purpose === "attach" ? (tk.target_member_id ?? tk.issuer_member_id) : null;
  return {
    spaceId: tk.space_id,
    status: sp.status,
    mode: sp.mode === "group" ? "group" : "duo",
    memberCount,
    purpose,
    inviterName,
    // attach 的目标身份：新的看 target_member_id，存量老 token 退回 issuer（那时候
    // "attach 只能指向自己"）
    targetName: purpose === "attach"
      ? (nameOfMember(tk.target_member_id ?? tk.issuer_member_id) ??
         slots.find((s) => s.displayName != null)?.displayName ??
         null)
      : null,
    targetIsIssuer:
      purpose === "attach" &&
      attachTargetId != null &&
      attachTargetId === tk.issuer_member_id,
    slots,
  };
}

/** 加入 Space：事务内消费 token（未用/未过期/未满员）并插入第二位成员；
 *  满员后空间转 active。U3：加入通道登记（entrances，服务端分配 UUID）并签发
 *  绑定该 Space 的 session——加入后可立即进聊天（PROTOCOL_MULTIVERSE.md §4.1）。 */export function joinSpace(
  token: string,
  publicKey: string,
  entranceName?: string,
  slot?: number,
  installUid?: string, // 安装级标识（多空间：同一物理设备各空间一行同名）
  memberDisplayName?: string, // 新身份自填名字（群聊一期：invite 流必填，channel 流不带）
  memberGender?: string, // 新身份自填性别（同上）
): {
  spaceId: string;
  memberId: string;
  slot: number;
  sessionToken: string;
  entranceId: string;
  spaceAddress: string;
  /** 这次 join 是否**新建了身份**（false = 已有成员加通道）。WS 广播据此决定
   *  要不要发 member.joined——自己的另一台设备接入不该让别人以为"来了新人"。 */
  isNewMember: boolean;
} {
  if (publicKey.length === 0) {
    throw new ApiError("INVALID_REQUEST", "publicKey 必填（加入通道公钥）", 400);
  }
  const hash = createHash("sha256").update(token).digest("hex");
  const tk = getDb()
    .prepare(`SELECT space_id, expires_at, used_at, purpose, issuer_member_id, target_member_id FROM join_tokens WHERE token_hash = ?`)
    .get(hash) as {
    space_id: string;
    expires_at: number;
    used_at: number | null;
    purpose: string;
    issuer_member_id: string | null;
    target_member_id: string | null;
  } | undefined;
  if (!tk) throw new ApiError("TOKEN_INVALID", "invalid join token", 400);
  if (tk.used_at != null) throw new ApiError("TOKEN_USED", "join token already used", 410);
  if (tk.expires_at < Date.now()) throw new ApiError("TOKEN_EXPIRED", "join token expired", 410);
  // purpose × slot 显式语义（2026-10-04 收敛为两种）：
  // - invite → 开新身份：**必须不带 slot**（服务端分配最小空槽、生成新 member_id）
  // - attach → 进已有身份：身份由 token 的 target_member_id 决定（客户端**不需要**
  //   知道 slot 这个内部概念）；客户端显式带 slot 时必须与目标一致（防错用）。
  //   存量老 token（purpose='channel' 回填、target NULL）退回看 issuer_member_id；
  //   两者都没有（更老的库）才要求客户端带 slot。
  const purpose: "invite" | "attach" = tk.purpose === "invite" ? "invite" : "attach";
  // attach 要进入的目标身份：新 token 看 target_member_id（可指向**别人**——
  // 帮丢了设备的成员找回身份）；存量老 token（target NULL）退回 issuer_member_id
  // （那时 attach 只能指向签发者自己）。
  const attachTargetId =
    purpose === "attach" ? (tk.target_member_id ?? tk.issuer_member_id) : null;
  if (purpose === "invite" && slot != null) {
    throw new ApiError("INVALID_REQUEST", "invite token 不能指定 slot（将开新身份）", 400);
  }
  // 新成员自填的名字同样过白名单（2026-10-04 补：create 一直在校验 creator_name，
  // 而 join 这条"名字也是用户手输"的路径此前漏了——CLI/手搓请求能塞进任意串）。
  // attach **不该**带名字：那是已有身份，名字早就有了（要改走 /members/name）。
  if (memberDisplayName != null) assertMemberName(memberDisplayName);

  const doJoin = getDb().transaction(() => {
    const sp = getDb()
      .prepare(`SELECT status, space_address, mode FROM spaces WHERE space_id = ?`)
      .get(tk.space_id) as { status: string; space_address: string; mode: string } | undefined;
    if (!sp || (sp.status !== "waiting" && sp.status !== "active")) {
      throw new ApiError("SPACE_NOT_FOUND", "space not found", 404);
    }
    // 成员（身份）数量上限 chokepoint——**必须在事务内**计（与通道上限同理：
    // preflight 不消费 token，并发 join 会双双通过预检）。只数 active 身份
    // （同身份多通道不重复计数，与通道闸互补）；已有身份加通道不新增身份，
    // 天然不受限，所以校验放在"确定是新身份"之后（见下）。
    //
    // 2026-10-04 起上限由**创建时定死的 mode** 决定，没有升格这条路径：
    // - duo：恒 2（第 3 个身份 → DUO_FULL 409，永远不会变成群）
    // - group：max_members_per_space（0=不限；超了 → SPACE_FULL 409）
    const cfg = loadConfig();
    const mode = sp.mode === "group" ? "group" : "duo";
    // 判定"这次 join 是否会新增身份"放在 slot 解析之后（下方 chosenSlot 逻辑），
    // 故计数校验延后到 member 行确定处执行（见下）。
    // 身份 slot（群聊一期显式语义，无老客户端兼容）：
    // - 不带 slot = 新身份：分配最小空 slot、生成新 member_id（自己填名）；
    // - 带 slot = 已有成员加通道：slot 必须已有人（member_id 非 NULL），否则报错；
    //   （purpose 校验在调用层 joinSpace 之外做——见 app.ts：invite 不带 slot、
    //   channel 必带且等于发起人 slot；此处按 slot 参数语义兜底。）
    let chosenSlot: number;
    let isExistingIdentity = false;
    let member: { member_id: string | null; status: string } | undefined;
    if (slot != null || (purpose === "attach" && attachTargetId != null)) {
      // attach：身份由 token 的 target 决定 → 服务端自动解析它的 slot（客户端
      // 无需知道 slot 这个内部概念）；客户端显式带 slot 时必须与目标一致（防错用）。
      // 存量 attach token（target/issuer 皆为 NULL）才需要客户端带 slot。
      if (purpose === "attach" && attachTargetId != null) {
        const bound = getDb()
          .prepare(`SELECT slot FROM space_members WHERE space_id = ? AND member_id = ?`)
          .get(tk.space_id, attachTargetId) as { slot: number } | undefined;
        if (!bound) {
          throw new ApiError("INVALID_REQUEST", "这条链接指向的身份已不存在", 403);
        }
        if (slot != null && Math.floor(slot) !== bound.slot) {
          throw new ApiError("INVALID_REQUEST", "这条链接与指定身份不匹配", 403);
        }
        chosenSlot = bound.slot;
      } else {
        chosenSlot = Math.floor(slot!);
      }
      const existing = getDb()
        .prepare(`SELECT member_id, status FROM space_members WHERE space_id = ? AND slot = ?`)
        .get(tk.space_id, chosenSlot) as { member_id: string | null; status: string } | undefined;
      if (!existing || existing.member_id == null) {
        throw new ApiError("INVALID_REQUEST", "该 slot 无已有成员（进已有身份需绑定已有身份）", 400);
      }
      isExistingIdentity = true;
      member = existing;
    } else {
      // 新身份：**最小空 slot**。空 = 没有这一行，**或**这一行还是 pending
      // （member_id NULL）。后者是存量库的"伴侣预置位"——v3 起 create 不再预置，
      // 存量 pending 行的语义退化为"未预置名字的空槽"，伴侣拿 invite 链接加入
      // 就该坐进去（aimemo/groupChatDesign.md「一次性升级步骤」第 4 条）；
      // 跳过它的话，存量情侣空间的第二人会落到 slot 2、slot 1 留一个永远填不上
      // 的幽灵行，连带"同性别第二人取青色"（判据 slot=1）也一起失效。
      const rows = getDb()
        .prepare(`SELECT slot, member_id FROM space_members WHERE space_id = ? ORDER BY slot`)
        .all(tk.space_id) as { slot: number; member_id: string | null }[];
      const taken = new Set(
        rows.filter((r) => r.member_id != null).map((r) => r.slot),
      );
      chosenSlot = 0;
      while (taken.has(chosenSlot)) chosenSlot++;
      // 命中 pending 行 → 复用它（下方 UPDATE），否则新建（下方 INSERT）
      const pending = rows.find((r) => r.slot === chosenSlot && r.member_id == null);
      member = pending == null ? undefined : { member_id: null, status: "pending" };
    }
    if (!isExistingIdentity) {
      // 成员数上限（新增身份才检查）：duo 恒 2、group 看配置。
      const activeCount = countActiveMembers(tk.space_id);
      if (mode === "duo" && activeCount >= 2) {
        throw new ApiError(
          "DUO_FULL",
          "这是双人秘境，成员已满（2 人）——需要更多人请另建群组秘境",
          409,
        );
      }
      if (
        mode === "group" &&
        cfg.max_members_per_space > 0 &&
        activeCount >= cfg.max_members_per_space
      ) {
        throw new ApiError(
          "SPACE_FULL",
          `群成员数量已达上限（${cfg.max_members_per_space}）`,
          409,
        );
      }
    }
    let memberId = member?.member_id ?? null;
    if (memberId == null && member != null) {
      // 命中的是**存量 pending 行**（member_id NULL）：就地坐进去，不改 slot。
      // 创建者预置的那个名字由加入者自填的名字覆盖——v3 起名字归属本人。
      memberId = randomUUID();
      getDb()
        .prepare(
          `UPDATE space_members
              SET member_id = ?, display_name = ?, gender = ?, status = 'active', joined_at = ?
            WHERE space_id = ? AND slot = ? AND member_id IS NULL`,
        )
        .run(
          memberId,
          memberDisplayName ?? null,
          normGender(memberGender) ?? null,
          Date.now(),
          tk.space_id,
          chosenSlot,
        );
    } else if (memberId == null) {
      // 新身份首加入：建行 + 生成 member_id（join 方自填名字/性别，群聊一期：
      // 名字来自 join 请求的 member_name/性别 member_gender，缺省 NULL）
      memberId = randomUUID();
      getDb()
        .prepare(
          `INSERT INTO space_members (space_id, member_id, slot, display_name, gender, status, joined_at)
           VALUES (?, ?, ?, ?, ?, 'active', ?)`,
        )
        .run(
          tk.space_id,
          memberId,
          chosenSlot,
          memberDisplayName ?? null,
          normGender(memberGender) ?? null,
          Date.now(),
        );
    } else if (member!.status !== "active") {
      getDb()
        .prepare(
          `UPDATE space_members SET status = 'active', joined_at = ? WHERE space_id = ? AND slot = ?`,
        )
        .run(Date.now(), tk.space_id, chosenSlot);
    }
    // 同一台设备（install_uid）在这个空间里**已经有通道** → 拒绝再次加入。
    //
    // 为什么要有（老板 2026-09-23 定：前后端保持一致）：一台设备对一个空间只该有一条
    // 通道。客户端（setup_page._verifyJoinToken）已经先拦一道，这里再拦一道兜住
    // 旧客户端 / 并发 / 本地状态被清过的情况——否则会插进第二条，把第一条变成孤儿
    // （客户端侧凭证被覆盖，服务端这条却还活着、还占着通道额度）。
    //
    // 只数**未撤销**的：status='revoked' = 那条通道已主动退役，允许重新加入。
    // install_uid 缺失/非法（存量行、未升级客户端）为 null → 不拦（客户端那道闸门仍在）。
    //
    // 注意：这是**否决**（denylist），不是授权——与 installUid.ts 的定位不冲突：
    // 它绝不参与任何操作的授权、也不决定任何破坏性操作的范围。
    const uid = normalizeInstallUid(installUid);
    if (uid != null) {
      const dup = getDb()
        .prepare(
          `SELECT 1 FROM entrances e
           JOIN space_members sm ON sm.member_id = e.member_id
           WHERE sm.space_id = ? AND e.install_uid = ? AND e.status != 'revoked'
           LIMIT 1`,
        )
        .get(tk.space_id, uid);
      if (dup) {
        throw new ApiError(
          "ENTRANCE_ALREADY_EXISTS",
          "本设备在该空间已有通道",
          409,
        );
      }
    }
    // 通道数量上限（serverConfig.json 的 maxEntrancesPerSpace：0=不限）——
    // **必须在事务内**计：preflight 不消费 token，并发两个 join 会同时通过预检
    // 然后双双插通道 → 超额。计数按"该空间登记过的通道总数"，**含已撤销**：
    // 销毁/撤销是软标记（entrances.status='revoked'，行不删），若只数 active，
    // "开通→销毁→再开通"就能无限刷额度，防滥用等于没做（老板 2026-09-23 定）。
    // （成员数上限 chokepoint 已在上方新身份分支计过——两道闸各自独立计数。）
    if (cfg.max_entrances_per_space > 0) {
      const cnt = (
        getDb()
          .prepare(
            `SELECT COUNT(*) AS n FROM entrances d
             JOIN space_members sm ON sm.member_id = d.member_id
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
    // 一次性：先标记 token 已用，再插通道（同事务，防并发双加入）
    getDb()
      .prepare(`UPDATE join_tokens SET used_at = ? WHERE token_hash = ?`)
      .run(Date.now(), hash);
    // 加入通道登记（同一身份多通道共享 member_id）+ 签发绑定该 Space 的 session
    const entranceId = randomUUID();
    getDb()
      .prepare(
        `INSERT INTO entrances (entrance_id, member_id, public_key, status, entrance_name, created_at, install_uid)
         VALUES (?, ?, ?, 'active', ?, ?, ?)`,
      )
      .run(entranceId, memberId, publicKey, normalizeEntranceName(entranceName), Date.now(), normalizeInstallUid(installUid));
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
    return {
      spaceId: tk.space_id,
      memberId,
      slot: chosenSlot,
      sessionToken,
      entranceId,
      spaceAddress: sp.space_address,
      isNewMember: !isExistingIdentity,
    };
  });
  return doJoin();
}

/** 生成一次性开通码（英文仍称 token；成员认证由 U1 Space-scoped session 补齐）。
 *
 *  两种 purpose（2026-10-04 收敛，替掉原来的 invite/channel）：
 *  - `invite`：开**新身份**（邀请一个新人进来，自己填名字）。受人数上限约束——
 *    duo 满 2 人一律 DUO_FULL（双人秘境永远不会有第三个人）。
 *  - `attach`：进**已有身份**。targetMemberId 指向谁就进谁：
 *    · == 签发者自己 → "我在另一台设备接入"（原 channel）
 *    · == 别人 → **帮对方找回身份**（他丢了/换了设备，而他没有安装可自己签发）
 *    这条能力让"只要还有一个安装存在，空间就永续"成为结构性的保证，而不是
 *    给 duo 打的补丁（group 里成员丢设备同样适用）。
 *
 *  **签发不做任何空间级副作用**（2026-10-04 老板拍板取消升格）：早期版本在这里
 *  做 duo → group 自动升格，导致"我只是想邀请个人"会静默把空间变成不可逆的群、
 *  还掐掉通话能力。现在 mode 创建时就定死了，这里只发码。
 *
 *  对**别人的身份**动手（attach 指向他人）需要调用方先校验共享口令——与"撤销
 *  别人的通道"同一档授权，见 app.ts 的 /join-tokens 路由。 */
export function createJoinToken(
  spaceId: string,
  baseUrl?: string, // 邀请链接 base（按请求真实 Host 生成，2026-09-11）
  purpose: "invite" | "attach" = "attach",
  issuerMemberId?: string, // 签发者身份（由调用层从 session 取）
  targetMemberId?: string, // attach 的目标身份；缺省 = 签发者自己
): { joinToken: string; link: string; expiresAt: number } {
  const sp = getDb()
    .prepare(`SELECT mode FROM spaces WHERE space_id = ?`)
    .get(spaceId) as { mode: string } | undefined;
  if (!sp) throw new ApiError("SPACE_NOT_FOUND", "space not found", 404);
  let target: string | undefined;
  if (purpose === "attach") {
    target = targetMemberId ?? issuerMemberId;
    if (target == null) {
      throw new ApiError("INVALID_REQUEST", "attach token 必须指明要进入的身份", 400);
    }
    // 目标必须是**本空间的成员**（否则等于给一个不存在的身份发码；也挡住
    // "拿别的空间的 member_id 来试"这种越权探测）
    const ok = getDb()
      .prepare(`SELECT 1 FROM space_members WHERE space_id = ? AND member_id = ?`)
      .get(spaceId, target);
    if (!ok) {
      throw new ApiError("INVALID_REQUEST", "目标身份不属于本空间", 400);
    }
  } else if (targetMemberId != null) {
    // invite 是"开新身份"，带 target 说明客户端把两种语义搞混了 → 明确报错，
    // 不要静默忽略（静默忽略会让客户端以为"定向成功"）
    throw new ApiError("INVALID_REQUEST", "invite token 不能指定目标身份", 400);
  }
  // 兜底：duo 满 2 人的空间**签不出开新身份的 invite**（永远不会有第三个人进来）。
  // 客户端已经隐藏这个入口，这里防的是老客户端/手搓请求——让它当场拿到明确
  // 错误，而不是拿着一张注定 join 失败的码去分享。
  // 注意：**attach 不受此限**——"帮对方找回身份"必须永远可用（2026-10-04）。
  if (purpose === "invite" && sp.mode !== "group" && countActiveMembers(spaceId) >= 2) {
    throw new ApiError(
      "DUO_FULL",
      "这是双人秘境，不可增加成员——需要更多人请另建群组秘境",
      409,
    );
  }
  const t = newJoinToken(spaceId, "member", purpose, issuerMemberId, target);
  return { joinToken: t.token, link: (baseUrl ?? DEFAULT_LINK_BASE) + "/join/" + t.token, expiresAt: t.expiresAt };
}
