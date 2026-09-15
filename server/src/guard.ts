import type { IncomingMessage } from "node:http";
import { getDb } from "./db.js";
import { ApiError, resolveSession } from "./auth.js";
import { getDevice, isActiveDevice } from "./config.js";

/**
 * 鉴权守卫：路由里"取 token → resolveSession → 白名单校验（→ 空间成员校验）"
 * 的统一入口。
 *
 * 为什么要有这个文件（2026-09-15 评审 C1）：app.ts 是手写路由，鉴权靠每个分支
 * 自己记得写——`POST /spaces/{id}/join-tokens` 与 `POST /spaces/{id}/key-escrow`
 * 上传分支就是漏写了的两个，任何人拿到 spaceId 就能给自己签邀请码、或覆盖掉
 * 口令托管包。把校验收口成显式调用（漏挂会一眼看出来），是这类漏洞的结构性解法。
 *
 * 约定：
 * - 本文件只做认证/授权判定，**不刷新 last_seen**（轮询端点不应让自己"永远新鲜"，
 *   见 devices.ts listDevices 注释），需要时调用方自己 touchLastSeen；
 * - space 级端点一律用 requireSpaceMember：必须显式回答"这个设备凭什么能操作这个空间"；
 * - **会话必须带 space**（2026-09-15 v1 收敛后）：Multiverse 下所有数据都按 space 隔离，
 *   没有 space 的会话什么也访问不了——所以这里直接拒绝，而不是让每个调用点各自
 *   `?? ""` 回落（v1 时代那 8 处回落既是复杂度也是漏洞温床）。
 */

/** 会话 + 设备身份（person_id 用于空间成员判定）。space_id 保证非空。 */
export interface DeviceSession {
  device_id: string;
  space_id: string;
  person_id: string;
}

/** 取 Bearer token，缺失即 401。 */
export function bearerToken(req: IncomingMessage): string {
  const token = optionalBearerToken(req);
  if (token == null) throw new ApiError("UNAUTHORIZED", "missing bearer token", 401);
  return token;
}

/** 取 Bearer token，缺失返回 null（供"同一端点有免认证分支"的场景，
 *  如 /spaces/{id}/key-escrow 的口令取包分支）。 */
export function optionalBearerToken(req: IncomingMessage): string | null {
  const h = req.headers.authorization ?? "";
  const m = h.match(/^Bearer (.+)$/);
  return m?.[1] ?? null;
}

/**
 * 认证 + 白名单校验 + **会话必须绑定 space**。
 * token 为 null（未带凭证）→ 401；设备未登记/已撤销 → 403；
 * 会话没有 space（v1 遗留会话）→ 401（重新认证即可拿到绑定 space 的会话）。
 */
export function requireSession(token: string | null): DeviceSession {
  if (token == null || token.length === 0) {
    throw new ApiError("UNAUTHORIZED", "missing bearer token", 401);
  }
  const { device_id, space_id } = resolveSession(token);
  if (!isActiveDevice(device_id)) {
    throw new ApiError("FORBIDDEN", "device not in whitelist", 403);
  }
  if (space_id == null || space_id.length === 0) {
    // v1 遗留会话（challenge 未带 space_id）：数据全按 space 隔离，这种会话无可访问内容。
    // 不静默当空串处理——那正是 v1 时代 8 处回落的来源。
    throw new ApiError("UNAUTHORIZED", "session has no space, re-authenticate", 401);
  }
  return { device_id, space_id, person_id: getDevice(device_id)?.person_id ?? "" };
}

/** 该 person 是否为该空间的在册成员（status='active'）。 */
export function isSpaceMember(spaceId: string, personId: string): boolean {
  if (spaceId.length === 0 || personId.length === 0) return false;
  const row = getDb()
    .prepare(`SELECT 1 FROM space_members WHERE space_id = ? AND person_id = ? AND status = 'active'`)
    .get(spaceId, personId);
  return row != null;
}

/**
 * 认证 + **该设备身份属于目标 space**（space 级端点的统一入口）。
 * 判定依据是 devices.person_id → space_members(space_id)，而不是会话里的
 * space_id：同一身份多台设备、或将来一个设备持多空间会话都不受影响。
 */
export function requireSpaceMember(token: string | null, spaceId: string): DeviceSession {
  const sess = requireSession(token);
  if (!isSpaceMember(spaceId, sess.person_id)) {
    throw new ApiError("FORBIDDEN", "not a member of this space", 403);
  }
  return sess;
}

/**
 * "这个会话能看见哪些设备"的 WHERE 子句（C2 隔离修复的唯一实现处）。
 *
 * devices 表在 v1 就是一张**全局表**（没有 space_id 列），因此所有列设备的接口
 * 都必须自己过滤，此前 /space 与 /devices 都漏了——A 空间设备能看到 B 空间设备
 * 的 person、在线状态与公钥（2026-09-15 评审 C2）。
 *
 * v1 收敛后 spaceId 恒非空（requireSession 保证），因此**不再有 legacy 分支**：
 * 只返回该空间在册成员名下的设备。调用方须给 devices 表起别名 `d`。
 */
export function deviceScopeClause(spaceId: string): { sql: string; params: string[] } {
  return {
    sql: `d.person_id IN (SELECT person_id FROM space_members WHERE space_id = ? AND person_id IS NOT NULL)`,
    params: [spaceId],
  };
}
