/**
 * 审计查询 CLI：npm run audit -- <命令> [参数]
 *
 *   npm run audit -- devices                 每台设备：最近上线/下线、累计在线时长、掉线次数
 *   npm run audit -- timeline <device_id>    某台设备的完整时间线（上下线 + 活动明细）
 *   npm run audit -- online <space_id> [天]  某 Space 的上下线事件流（默认 7 天）
 *   npm run audit -- activity [n]            最近 n 条活动明细（默认 50）
 *   npm run audit -- receipts [space_id]     每台设备各自上报的送达/已读进度
 *   npm run audit -- search <device_id>      某设备的全部原始行（不限条数，便于导出）
 *
 * 依赖环境变量：EINZ_DB（可选，默认 server/data/einz.sqlite.db）。
 * 只读打开，绝不写入。
 */
import { openDb } from "../src/db.js";

// 复用服务端建表逻辑（幂等，存量库不会重复建表）；EINZ_DB 可指向生产库。
const db = openDb();

const args = process.argv.slice(2);
const command = (args[0] ?? "devices").toLowerCase();
const arg1 = args[1];
const arg2 = args[2];

function fmtTime(ms: number | null | undefined): string {
  if (ms == null || ms === 0) return "-";
  return new Date(ms).toLocaleString("zh-CN", { hour12: false });
}

function fmtDuration(ms: number | null | undefined): string {
  if (ms == null) return "-";
  const sec = Math.round(ms / 1000);
  if (sec < 60) return `${sec}s`;
  const min = Math.floor(sec / 60);
  if (min < 60) return `${min}m${sec % 60}s`;
  const hour = Math.floor(min / 60);
  return `${hour}h${min % 60}m`;
}

function daysAgoMs(days: number): number {
  return Date.now() - days * 86_400_000;
}

/** 设备名 -> 设备显示名（dev3 → "老板的 iPhone"），拿不到就回落 id。 */
const deviceNames = new Map<string, string>();
for (const r of db.prepare(`SELECT device_id, device_name FROM devices`).all() as Array<{ device_id: string; device_name: string | null }>) {
  deviceNames.set(r.device_id, r.device_name ?? r.device_id);
}
function nameOf(deviceId: string): string {
  return deviceNames.get(deviceId) ?? deviceId;
}

switch (command) {
  case "devices": {
    console.log("每台设备的在线概况：\n");
    const rows = db
      .prepare(
        `SELECT device_id,
                COUNT(*)                                             AS events,
                SUM(CASE WHEN event = 'connect' THEN 1 ELSE 0 END)    AS connects,
                SUM(CASE WHEN event <> 'connect' THEN 1 ELSE 0 END)   AS disconnects,
                SUM(CASE WHEN event = 'heartbeat_timeout' THEN 1 ELSE 0 END) AS timeouts,
                SUM(CASE WHEN event <> 'connect' THEN duration_ms ELSE 0 END) AS online_ms,
                MAX(at_ms)                                           AS last_event_at
         FROM connection_events GROUP BY device_id ORDER BY device_id`
      )
      .all() as Array<Record<string, number | string>>;
    if (rows.length === 0) console.log("（尚无连接事件——可能还没有设备建立过 WS 连接）");
    for (const r of rows) {
      const last = db
        .prepare(`SELECT event FROM connection_events WHERE device_id = ? ORDER BY at_ms DESC LIMIT 1`)
        .get(r.device_id) as { event: string } | undefined;
      console.log(
        `${r.device_id}  ${nameOf(String(r.device_id))}\n` +
          `   上线次数 ${r.connects}｜断开 ${r.disconnects}（其中心跳超时 ${r.timeouts}）｜累计在线 ${fmtDuration(Number(r.online_ms))}\n` +
          `   最后一次事件 ${last?.event ?? "-"} @ ${fmtTime(Number(r.last_event_at))} → 当前${last?.event === "connect" ? "在线" : "离线"}`
      );
    }
    break;
  }

  case "timeline": {
    if (!arg1) throw new Error("用法: npm run audit -- timeline <device_id>");
    console.log(`设备 ${arg1}（${nameOf(arg1)}）的时间线：\n`);
    const conns = db
      .prepare(
        `SELECT at_ms, event, duration_ms, close_code, close_reason, ip
         FROM connection_events WHERE device_id = ? ORDER BY at_ms`
      )
      .all(arg1) as Array<{ at_ms: number; event: string; duration_ms: number | null; close_code: number | null; close_reason: string | null; ip: string | null }>;
    const acts = db
      .prepare(`SELECT at_ms, kind, detail FROM device_activity WHERE device_id = ? ORDER BY at_ms`)
      .all(arg1) as Array<{ at_ms: number; kind: string; detail: string | null }>;
    const merged = [
      ...conns.map((c) => ({ at: c.at_ms, line: `  [连接] ${c.event.padEnd(17)} 在线 ${fmtDuration(c.duration_ms)}  code=${c.close_code ?? "-"} ${c.close_reason ?? ""} ip=${c.ip ?? "-"}` })),
      ...acts.map((a) => ({ at: a.at_ms, line: `  [活动] ${a.kind.padEnd(17)} ${a.detail ?? ""}` })),
    ].sort((x, y) => x.at - y.at);
    if (merged.length === 0) console.log("（无记录）");
    for (const m of merged) console.log(`${fmtTime(m.at)}  ${m.line}`);
    break;
  }

  case "online": {
    if (!arg1) throw new Error("用法: npm run audit -- online <space_id> [天数]");
    const since = daysAgoMs(Number(arg2 ?? 7));
    console.log(`Space ${arg1} 最近 ${arg2 ?? 7} 天的上下线事件流：\n`);
    const rows = db
      .prepare(
        `SELECT at_ms, device_id, event, duration_ms, close_code, ip
         FROM connection_events WHERE space_id = ? AND at_ms >= ? ORDER BY at_ms`
      )
      .all(arg1, since) as Array<{ at_ms: number; device_id: string; event: string; duration_ms: number | null; close_code: number | null; ip: string | null }>;
    if (rows.length === 0) console.log("（该 Space 在所选时间窗内无连接事件）");
    for (const r of rows) {
      console.log(
        `${fmtTime(r.at_ms)}  ${r.event.padEnd(17)} ${r.device_id.padEnd(6)} ${nameOf(r.device_id).padEnd(14)}` +
          `${r.event === "connect" ? "" : `在线 ${fmtDuration(r.duration_ms)}`} code=${r.close_code ?? "-"} ip=${r.ip ?? "-"}`
      );
    }
    break;
  }

  case "activity": {
    const limit = Number(arg1 ?? 50);
    console.log(`最近 ${limit} 条活动明细：\n`);
    const rows = db
      .prepare(`SELECT at_ms, device_id, space_id, kind, detail, ip FROM device_activity ORDER BY activity_id DESC LIMIT ?`)
      .all(limit) as Array<{ at_ms: number; device_id: string; space_id: string; kind: string; detail: string | null; ip: string | null }>;
    for (const r of rows) {
      console.log(`${fmtTime(r.at_ms)}  ${r.device_id.padEnd(6)} ${r.kind.padEnd(17)} ${r.detail ?? ""} ip=${r.ip ?? "-"}`);
    }
    break;
  }

  case "receipts": {
    console.log("每台设备最近一次上报的送达/已读进度（receipts 表本身仍是 person 级）：\n");
    const rows = db
      .prepare(
        `SELECT device_id, space_id, at_ms, detail
         FROM device_activity a
         WHERE kind = 'receipt'
           AND activity_id = (SELECT MAX(activity_id) FROM device_activity b
                              WHERE b.kind = 'receipt' AND b.device_id = a.device_id AND b.space_id = a.space_id)
         ORDER BY device_id`
      )
      .all() as Array<{ device_id: string; space_id: string; at_ms: number; detail: string | null }>;
    if (rows.length === 0) console.log("（尚无回执上报记录）");
    for (const r of rows) {
      const d = r.detail ? (JSON.parse(r.detail) as Record<string, unknown>) : {};
      console.log(
        `${r.device_id.padEnd(6)} ${nameOf(r.device_id).padEnd(14)} space=${r.space_id || "-"}  ` +
          `送达≤${d.delivered_upto_seq ?? "-"}  已读≤${d.read_upto_seq ?? "-"}  @ ${fmtTime(r.at_ms)}`
      );
    }
    break;
  }

  case "search": {
    if (!arg1) throw new Error("用法: npm run audit -- search <device_id>");
    console.log(`# 设备 ${arg1}（${nameOf(arg1)}）的全部审计行\n`);
    const c = db.prepare(`SELECT * FROM connection_events WHERE device_id = ? ORDER BY at_ms`).all(arg1) as Array<Record<string, unknown>>;
    const a = db.prepare(`SELECT * FROM device_activity WHERE device_id = ? ORDER BY at_ms`).all(arg1) as Array<Record<string, unknown>>;
    console.log(`## connection_events (${c.length})`);
    for (const r of c) console.log(JSON.stringify(r));
    console.log(`\n## device_activity (${a.length})`);
    for (const r of a) console.log(JSON.stringify(r));
    break;
  }

  default: {
    console.log(`未知命令: ${command}`);
    console.log("可用: devices | timeline <device_id> | online <space_id> [天] | activity [n] | receipts | search <device_id>");
    process.exit(1);
  }
}
