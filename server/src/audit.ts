import type { IncomingMessage } from "node:http";
import { getDb } from "./db.js";

/**
 * 审计日志（只追加，永久保留）。
 *
 * 目的：回答"谁（partner）在哪条通道（entrance）上、什么时候、做了什么"——
 * 上下线事件流、sync 拉取进度、回执上报明细、消息发送、push token 变更等。
 * 老板 2026-09-13 要求后台记录尽可能详尽。
 *
 * 边界（productLens §3.3 元数据边界 / §14 日志红线）：
 * - 只记元数据，**绝不记消息明文、nonce、密文、密钥**；
 * - 记来源 IP / User-Agent（老板确认需要，用于排查换网络/重装 App）；
 * - 审计表不参与业务语义：清空这些表不影响聊天功能。
 *
 * 容错：所有写入包 try/catch——审计失败只允许 console.error，绝不能
 * 抛出去拖垮收发消息主流程。
 */

export type ConnectionEventKind =
  | "connect" // WS 连上（上线）
  | "disconnect" // WS 断开（下线；close_code=4408 表示被同一通道的新连接顶掉）
  | "heartbeat_timeout"; // 心跳超时，被服务端 terminate

/** 请求侧元数据（IP / UA）——从 IncomingMessage 提取，审计落库用。 */
export interface RequestMeta {
  ip: string | null;
  userAgent: string | null;
}

/** 没有请求上下文时（如 WS 心跳超时）的占位。 */
export const NO_META: RequestMeta = { ip: null, userAgent: null };

/** 归一化 space_id：NULL 与空串统一成空串（与 messages 表一致，便于等值查询）。 */
function normalizeSpaceId(spaceId: string | null | undefined): string {
  return spaceId ?? "";
}

/**
 * 提取来源 IP 与 User-Agent。Caddy 反代下真实 IP 在 x-forwarded-for
 * （reverse_proxy 自动写入），取链首；缺失时回落 socket 地址。
 */
export function metaOf(req: IncomingMessage): RequestMeta {
  let ip: string | null = null;
  const fwd = req.headers["x-forwarded-for"];
  if (typeof fwd === "string" && fwd.length > 0) ip = fwd.split(",")[0]!.trim();
  else if (Array.isArray(fwd) && fwd.length > 0) ip = fwd[0]!.split(",")[0]!.trim();
  if (!ip || ip.length === 0) ip = req.socket?.remoteAddress ?? null;

  const ua = req.headers["user-agent"];
  return { ip, userAgent: typeof ua === "string" ? ua : null };
}

export interface ConnectionEventInput {
  entranceId: string;
  spaceId?: string | null;
  event: ConnectionEventKind;
  atMs?: number;
  /** disconnect 时填：本次在线时长（ms）。 */
  durationMs?: number | null;
  /** WS 关闭码（1006=异常断开；terminate 时为 null）。 */
  closeCode?: number | null;
  closeReason?: string | null;
  meta?: RequestMeta;
}

/** 记一条连接事件（上线 / 下线 / 被顶掉 / 心跳超时）。 */
export function logConnection(e: ConnectionEventInput): void {
  try {
    const meta = e.meta ?? NO_META;
    getDb()
      .prepare(
        `INSERT INTO connection_events
           (entrance_id, space_id, event, at_ms, duration_ms, close_code, close_reason, ip, user_agent)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`
      )
      .run(
        e.entranceId,
        normalizeSpaceId(e.spaceId),
        e.event,
        e.atMs ?? Date.now(),
        e.durationMs ?? null,
        e.closeCode ?? null,
        e.closeReason ?? null,
        meta.ip,
        meta.userAgent
      );
  } catch (err) {
    console.error("[audit] logConnection 失败（不影响主流程）", err);
  }
}

export interface ActivityInput {
  entranceId: string;
  spaceId?: string | null;
  /** 活动类型，见 docs/DATABASE.md §2.1。 */
  kind: string;
  atMs?: number;
  /** 各 kind 自己的字段（JSON 序列化后落库）。 */
  detail?: Record<string, unknown> | null;
  meta?: RequestMeta;
}

/** 记一条通道活动明细。 */
export function logActivity(e: ActivityInput): void {
  try {
    const meta = e.meta ?? NO_META;
    getDb()
      .prepare(
        `INSERT INTO entrance_activity
           (entrance_id, space_id, kind, at_ms, detail, ip, user_agent)
         VALUES (?, ?, ?, ?, ?, ?, ?)`
      )
      .run(
        e.entranceId,
        normalizeSpaceId(e.spaceId),
        e.kind,
        e.atMs ?? Date.now(),
        e.detail == null ? null : JSON.stringify(e.detail),
        meta.ip,
        meta.userAgent
      );
  } catch (err) {
    console.error("[audit] logActivity 失败（不影响主流程）", err);
  }
}

/**
 * 每通道每 Space 已记过的最高 last_sequence（进程内缓存，重启丢失只会多记一行）。
 *
 * 只记"进度前进"的 sync：例行轮询没拉到新消息时不产生记录
 * （老板 2026-09-13 定）。轮询频率：App WS 在线 30s / 离线 3s 退避到 60s，
 * TUI 固定 30s——若每次轮询都记，绝大多数行都是重复值且毫无信息量。
 * 通道"还在不在"由 connection_events 与 entrances.last_seen 负责。
 */
const lastSyncByEntrance = new Map<string, number>();

export interface SyncActivityInput {
  entranceId: string;
  spaceId?: string | null;
  /** 请求参数 after。 */
  afterSequence: number;
  /** 本次返回的最大 server_sequence（=该通道已拉取到的进度）。 */
  lastSequence: number;
  /** 本次返回的消息条数。 */
  count: number;
  hasMore: boolean;
  meta?: RequestMeta;
}

/**
 * 记 sync 拉取进度（=该通道的"接收"证据）。
 * 仅当 last_sequence 前进（真正拉到新消息）时落一条；没新结果的例行轮询不记。
 */
export function logSyncActivity(e: SyncActivityInput): void {
  const key = `${e.entranceId}|${normalizeSpaceId(e.spaceId)}`;
  // 首次：last_sequence=0（还没消息）也不记——没有"收到"发生
  if (e.lastSequence <= (lastSyncByEntrance.get(key) ?? 0)) return;
  lastSyncByEntrance.set(key, e.lastSequence);

  logActivity({
    entranceId: e.entranceId,
    spaceId: e.spaceId,
    kind: "sync",
    detail: {
      after_sequence: e.afterSequence,
      last_sequence: e.lastSequence,
      received: e.count,
      has_more: e.hasMore,
    },
    meta: e.meta,
  });
}
