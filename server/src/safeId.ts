import { ApiError } from "./auth.js";

/** 消息信封 message_id 的字符集白名单（P1 路径遍历防御）：
 *  仅允许字母/数字/下划线/连字符，杜绝 `/`、`\`、`.` 等路径字符。
 *
 *  为什么需要：message_id 会被**客户端**当作文件路径片段——App 的媒体解密缓存
 *  按 `einz_media_<message_id>.<ext>` 命名文件（app/lib/data/media_cache.dart）。
 *  `POST /messages` 此前只校验"非空字符串"，对端即可发 `message_id = "a/../../evil"`，
 *  受害者点一次播放就把解密后的附件字节写到缓存目录之外
 *  （老板 2026-09-14 排查出的缺口）。
 *
 *  与 attachments.ts 里那份 assertSafeId 的分工：那个 ID 会被服务端**直接**用作
 *  存储文件名（`${shard}/${attachment_id}`），所以收得更紧（仅 hex + 连字符）；
 *  message_id 只在客户端落地成文件名，故按"路径安全 + 长度有界"收口即可——客户端
 *  另有一层文件名白名单化兜底（纵深防御）。
 *  不设 8 字符下限：不凭空给既有客户端加约束（服务端过去从未据此做过任何事）。 */
export const SAFE_MESSAGE_ID_RE = /^[A-Za-z0-9_-]{1,64}$/;

export function assertSafeMessageId(id: string): void {
  if (typeof id !== "string" || !SAFE_MESSAGE_ID_RE.test(id)) {
    throw new ApiError("INVALID_REQUEST", "invalid message_id: illegal characters", 400);
  }
}
