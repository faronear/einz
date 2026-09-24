/**
 * wire 协议版本（PROTOCOL.md §1）：REST 用请求头 `X-Protocol-Version`，
 * WS 用握手 query `?pv=`。
 *
 * 改了**任何** wire 契约（字段名 / 路径 / WS 事件名 / 错误码）都必须 bump：
 * - `1` = device→entrance / person→member 全量改名**之前**的旧 wire；
 * - `2` = 该次改名之后的 wire（`sender_device_id`→`sender_entrance_id`、
 *   `person_id`→`member_id`、WS 帧 `device.revoked`→`entrance.revoked`、
 *   认证错误码 `DEVICE_REVOKED`→`ENTRANCE_REVOKED`、`/devices/*`→`/entrances/*` 等，
 *   见 docs/GLOSSARY.md「wire 字段改名」）。改名时无兼容窗口，故不双接受 v1。
 *   注：2026-09-24 的串术语改名 `partner`→`member`（`/partners/name`→`/members/name`、
 *   审计 `partner.rename`→`member.rename`、各 `partner_*` 字段→`member_*`）**合入同一
 *   个尚未发布的 v2 窗口**，不另起 v3。
 *
 * **单一来源**：REST 校验（app.ts）与 WS 校验（ws.ts）都从这里取，别再各写一份
 * 字面量（历史上 ws.ts 就曾与 app.ts 各存一个 "1"，改一处漏一处）。
 */
export const PROTOCOL_VERSION = "2";
