import type { IncomingMessage } from "node:http";
import { getDb } from "./db.js";

/**
 * 审计日志（只追加，永久保留）。
 *
 * 目的：回答"谁（person）在哪台设备（device）上、什么时候、做了什么"——
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
  | "disconnect" // WS 断开（下线；close_code=4408 表示被同一设备的新连接顶掉）
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
  deviceId: string;
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
           (device_id, space_id, event, at_ms, duration_ms, close_code, close_reason, ip, user_agent)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`
      )
      .run(
        e.deviceId,
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
  deviceId: string;
  spaceId?: string | null;
  /** 活动类型，见 docs/DATABASE.md §2.1。 */
  kind: string;
  atMs?: number;
  /** 各 kind 自己的字段（JSON 序列化后落库）。 */
  detail?: Record<string, unknown> | null;
  meta?: RequestMeta;
}

/** 记一条设备活动明细。 */
export function logActivity(e: ActivityInput): void {
  try {
    const meta = e.meta ?? NO_META;
    getDb()
      .prepare(
        `INSERT INTO device_activity
           (device_id, space_id, kind, at_ms, detail, ip, user_agent)
         VALUES (?, ?, ?, ?, ?, ?, ?)`
      )
      .run(
        e.deviceId,
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
 * sync 空闲节流窗口（秒）：同一设备同一 Space 在 last_sequence **没有前进**
 * 的情况下，多久才补记一条 idle 记录。0 = 每次轮询都记（最详尽，也最占空间）。
 *
 * 为什么节流：App 聊天页活跃时每 3s 轮询一次（chat_page.dart），全量记录
 * 一天就是近 3 万行/设备且全是重复值；真正有价值的是"进度前进"（=真正
 * 收到新消息），空闲轮询只需低频证明"设备还在"。
 */
const IDLE_SYNC_GAP_MS = Math.max(0, Number(process.env.EINZ_AUDIT_IDLE_SYNC_SEC ?? 300)) * 1000;

/** 上次 sync 记录（进程内缓存；仅用于节流，丢掉只是多记一行）。 */
const lastSyncByDevice = new Map<string, { atMs: number; lastSequence: number }>();

export interface SyncActivityInput {
  deviceId: string;
  spaceId?: string | null;
  /** 请求参数 after。 */
  afterSequence: number;
  /** 本次返回的最大 server_sequence（=该设备已拉取到的进度）。 */
  lastSequence: number;
  /** 本次返回的消息条数。 */
  count: number;
  hasMore: boolean;
  meta?: RequestMeta;
}

/**
 * 记 sync 拉取进度（=该设备的"接收"证据）。
 * last_sequence 前进 → 必记；未前进 → 受 IDLE_SYNC_GAP_MS 节流。
 */
export function logSyncActivity(e: SyncActivityInput): void {
  const key = `${e.deviceId}|${normalizeSpaceId(e.spaceId)}`;
  const atMs = Date.now();
  const prev = lastSyncByDevice.get(key);
  const advanced = prev == null || e.lastSequence > prev.lastSequence;
  const idleGapElapsed = prev == null || atMs - prev.atMs >= IDLE_SYNC_GAP_MS;
  if (!advanced && !idleGapElapsed) return;

  lastSyncByDevice.set(key, { atMs, lastSequence: e.lastSequence });
  logActivity({
    deviceId: e.deviceId,
    spaceId: e.spaceId,
    kind: "sync",
    atMs,
    detail: {
      after_sequence: e.afterSequence,
      last_sequence: e.lastSequence,
      received: e.count,
      has_more: e.hasMore,
      // idle=true 表示这次没有拉到新消息（仅证明设备仍在轮询）
      idle: !advanced,
    },
    meta: e.meta,
  });
}
