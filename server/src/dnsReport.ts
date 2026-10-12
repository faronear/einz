/**
 * DNS 污染上报（2026-10-11）。
 *
 * 背景：部分网络（家庭路由器 / 运营商网关）对明文 UDP-53 查询做抢答注入，
 * 客户端系统解析被污染（假 IP + TTL 3600）。客户端兜底（DoH 重解析）成功后
 * 向本端点 fire-and-forget 上报一次，服务端聚合看清"哪些网络在污染"，
 * 早于用户投诉发现问题。
 *
 * 免认证理由：污染发生在启动探测阶段，此时客户端尚未（也无法）完成认证——
 * 被污染网络下连认证握手都可能发不出去。滥用面由按 IP 限速（dnsReport 桶）
 * + 严格入参校验兜住；表只追加、30 天懒清理，不参与业务语义。
 */

import type { IncomingMessage } from "node:http";
import { getDb } from "./db.js";
import { metaOf } from "./audit.js";
import { ApiError } from "./auth.js";

const RETENTION_MS = 30 * 24 * 60 * 60 * 1000;

/** 域名白名单式的形状校验（不锁具体值——将来加域名不用改服务端）：
 *  小写字母数字点横线，两段以上，总长 ≤253。挡灌表垃圾即可。 */
const DOMAIN_RE = /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/;
const IPV4_RE = /^(\d{1,3}\.){3}\d{1,3}$/;

export function insertDnsReport(
  domain: string,
  dohIp: string | undefined,
  req: IncomingMessage
): void {
  const db = getDb();
  const meta = metaOf(req);
  db.prepare(
    `INSERT INTO dns_reports (at_ms, domain, doh_ip, ip, user_agent)
     VALUES (?, ?, ?, ?, ?)`
  ).run(Date.now(), domain, dohIp ?? null, meta.ip ?? null, meta.userAgent ?? null);
  // 懒清理：过期行顺手删（上报频率极低，不值得定时器）
  db.prepare("DELETE FROM dns_reports WHERE at_ms < ?").run(Date.now() - RETENTION_MS);
}

/** 聚合：按 UTC 日 + 域名计数，近 30 天。不暴露 IP（此端点公开可读）。 */
export interface DnsReportSummary {
  day: string;
  domain: string;
  count: number;
}

export function summarizeDnsReports(): DnsReportSummary[] {
  const rows = getDb()
    .prepare(
      `SELECT date(at_ms / 1000, 'unixepoch') AS day, domain, COUNT(*) AS count
       FROM dns_reports
       WHERE at_ms >= ?
       GROUP BY day, domain
       ORDER BY day DESC, count DESC`
    )
    .all(Date.now() - RETENTION_MS) as { day: string; domain: string; count: number }[];
  return rows;
}

/** 入参校验（防御性）：形状不对 → 400，不进表。 */
export function validateDnsReportBody(body: unknown): {
  domain: string;
  dohIp?: string;
} {
  if (body == null || typeof body !== "object") {
    throw new ApiError("INVALID_REQUEST", "body must be an object", 400);
  }
  const { domain, doh_ip } = body as Record<string, unknown>;
  if (typeof domain !== "string" || domain.length > 253 || !DOMAIN_RE.test(domain)) {
    throw new ApiError("INVALID_REQUEST", "invalid domain", 400);
  }
  let resolvedIp: string | undefined;
  if (doh_ip != null) {
    if (
      typeof doh_ip !== "string" ||
      doh_ip.length > 45 ||
      !IPV4_RE.test(doh_ip) ||
      doh_ip.split(".").some((p) => Number(p) > 255)
    ) {
      throw new ApiError("INVALID_REQUEST", "invalid doh_ip", 400);
    }
    resolvedIp = doh_ip;
  }
  return { domain, dohIp: resolvedIp };
}
