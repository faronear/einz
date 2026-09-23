import { ApiError } from "./auth.js";

/**
 * 安装级设备标识（`entrances.install_uid`）：客户端生成、随 create/join 上报，
 * 用来把**同一台物理设备在不同空间里的多个 entrance_id** 关联起来。
 *
 * 定位（老板 2026-09-22 定）：
 * - 只做**服务端侧认知**（运维/审计/将来"整机退役"用），不承担任何客户端功能，
 *   **不参与任何破坏性操作的授权或范围判断**——那是本机独占因子（设备名 + 锁屏码）的事。
 * - 生命周期 = **安装级**：卸载重装即新标识；用户主动「重置设备」时轮换。
 * - **绝不进任何响应体**：`/space`、`/entrances`、WS 广播都不带，成员之间互不可见。
 *
 * 格式约束：8–64 位 `[0-9A-Za-z_-]`（客户端发的是 32 位 hex）。
 * 形状要求这么紧，是为了让这一列能安全地出现在日志/管理脚本里。
 */
export const INSTALL_UID_RE = /^[0-9A-Za-z_-]{8,64}$/;

/** 规范化：合法返回本身，非法/缺失返回 null（**不抛**）。 */
export function normalizeInstallUid(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const v = raw.trim();
  return INSTALL_UID_RE.test(v) ? v : null;
}

/** 显式补登（POST /entrances/uid）用：非法直接 400，让客户端的问题暴露出来。 */
export function assertInstallUid(raw: unknown): string {
  const v = normalizeInstallUid(raw);
  if (v == null) {
    throw new ApiError("INVALID_REQUEST", "install_uid 必须是 8–64 位 [0-9A-Za-z_-]", 400);
  }
  return v;
}
