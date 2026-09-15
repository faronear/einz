import type { IncomingMessage } from "node:http";
import { ApiError } from "./auth.js";
import { metaOf } from "./audit.js";

/**
 * 按来源 IP 的固定窗口限速（进程内状态，重启即清空）。
 *
 * 为什么要有（2026-09-15 评审 H2）：此前除口令取包外全站无限速，而
 * `POST /spaces`（新建空间）是**免认证**端点——服务端一旦暴露公网，任何人都能
 * 无限建空间，与"双人私密空间"的产品定位矛盾。
 *
 * 定位：这是"防误用与防粗暴刷"的护栏，不是抗 DDoS（真被打要靠反代/云防护）。
 * 计数按 IP（反代下取 x-forwarded-for 链首，见 audit.metaOf）——注意同一公网
 * 出口下的多台设备共享额度，所以阈值都给得较宽松。
 *
 * 阈值可用环境变量覆盖，便于测试与运维调参。
 */

interface Window {
  count: number;
  resetAt: number;
}

const windows = new Map<string, Window>();

/** 新空间创建：每小时（按 IP）。真实用户一辈子建一个，20 只防批量刷。 */
const SPACE_CREATE_MAX = Number(process.env.EINZ_RATELIMIT_SPACE_CREATE ?? 20);
const SPACE_CREATE_WINDOW_MS = 60 * 60 * 1000;

/** 认证与加入类端点（challenge / join / lookup / enroll）：5 分钟。 */
// 30 → 60（2026-09-15）：一次"加入秘境"要消耗 preflight + join 两个请求，
// 口令试错又会回到流程重来，两个人自用很容易打满 → 表现为"输入邀请码总是失败"。
// 安全性没实质下降：join token 是 32B 随机不可猜，口令爆破由 escrow 自己的
// 失败计数兜（10 次/15 分钟）；这里只防"无限造 DB 行 / 无脑刷"。
const AUTH_MAX = Number(process.env.EINZ_RATELIMIT_AUTH ?? 60);
const AUTH_WINDOW_MS = 5 * 60 * 1000;

/** 全站兜底：每分钟。App 3s 轮询 /sync + TUI 30s + 附件 = 远低于此；
 *  同一公网出口下多台设备共享额度，别调太小。 */
const GLOBAL_MAX = Number(process.env.EINZ_RATELIMIT_GLOBAL ?? 600);
const GLOBAL_WINDOW_MS = 60 * 1000;

export type RateLimitBucket = "spaceCreate" | "auth" | "global";

function limitOf(bucket: RateLimitBucket): { max: number; windowMs: number } {
  switch (bucket) {
    case "spaceCreate":
      return { max: SPACE_CREATE_MAX, windowMs: SPACE_CREATE_WINDOW_MS };
    case "auth":
      return { max: AUTH_MAX, windowMs: AUTH_WINDOW_MS };
    case "global":
      return { max: GLOBAL_MAX, windowMs: GLOBAL_WINDOW_MS };
  }
}

/** 清掉过期窗口（懒清理：只在表变大时才扫，避免每请求遍历）。 */
function sweepIfLarge(now: number): void {
  if (windows.size <= 1024) return;
  for (const [key, w] of windows) {
    if (w.resetAt <= now) windows.delete(key);
  }
}

/** 计数并判定；超限抛 429（带剩余等待秒数）。 */
export function checkRateLimit(key: string, max: number, windowMs: number): void {
  const now = Date.now();
  sweepIfLarge(now);
  const w = windows.get(key);
  if (w == null || w.resetAt <= now) {
    windows.set(key, { count: 1, resetAt: now + windowMs });
    return;
  }
  w.count += 1;
  if (w.count > max) {
    const retryAfterMs = w.resetAt - now;
    throw new ApiError(
      "RATE_LIMITED",
      `too many requests, retry after ${Math.ceil(retryAfterMs / 1000)}s`,
      429
    );
  }
}

/** 按来源 IP 限速的便捷入口（路由直接调用）。 */
export function limitByIp(req: IncomingMessage, bucket: RateLimitBucket): void {
  const { max, windowMs } = limitOf(bucket);
  const ip = metaOf(req).ip ?? "unknown";
  checkRateLimit(`${bucket}|${ip}`, max, windowMs);
}
