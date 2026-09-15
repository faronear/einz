import type { IncomingMessage } from "node:http";
import { ApiError } from "./auth.js";

/**
 * 请求体读取（带大小上限）。
 *
 * 为什么必须有上限（2026-09-15 评审 H1）：此前 readJson / 附件上传 / 头像上传
 * 都是 `for await` 全量 Buffer.concat 进内存——一个 Content-Length 巨大的请求
 * 就能把服务端内存打爆；`POST /spaces`、`/devices/enroll` 这类免认证端点更是
 * 公网直接可打。
 */

/** JSON 体上限（信封 / 口令 / 元数据）。1 MiB 对真实负载极为宽裕：最大的
 *  /messages 密文也只是长文本消息，量级远低于此。 */
export const MAX_JSON_BODY_BYTES = Number(process.env.EINZ_MAX_JSON_BYTES ?? 1 * 1024 * 1024);

/** 附件 blob 上限（图片/视频/语音/文件）。视频是最大项——64 MiB 覆盖手机
 *  拍的短视频；真要调，改环境变量 EINZ_MAX_ATTACHMENT_BYTES 即可，不必改代码。 */
export const MAX_ATTACHMENT_BYTES = Number(process.env.EINZ_MAX_ATTACHMENT_BYTES ?? 64 * 1024 * 1024);

/** 读取请求体到内存，超过 limitBytes 即 413 PAYLOAD_TOO_LARGE。 */
export async function readBody(req: IncomingMessage, limitBytes: number): Promise<Buffer> {
  // Content-Length 预检：所有自家客户端都会带 → 干净地 413，不必先收满才判超限
  const declared = Number(req.headers["content-length"] ?? 0);
  if (Number.isFinite(declared) && declared > limitBytes) {
    throw new ApiError("PAYLOAD_TOO_LARGE", `request body exceeds ${limitBytes} bytes`, 413);
  }
  const chunks: Buffer[] = [];
  let total = 0;
  for await (const chunk of req) {
    const buf = chunk as Buffer;
    total += buf.length;
    // 分块传输（无 Content-Length）时的兜底。超限即抛——for-await 中断会关掉
    // 请求流，客户端看到的是连接中断而非 JSON 错误；这是刻意的：宁可断也不
    // 继续把超限数据吃进内存/带宽。
    if (total > limitBytes) {
      throw new ApiError("PAYLOAD_TOO_LARGE", `request body exceeds ${limitBytes} bytes`, 413);
    }
    chunks.push(buf);
  }
  return Buffer.concat(chunks);
}

/** 读 JSON 体（上限 MAX_JSON_BODY_BYTES；空体视为 {}）。 */
export async function readJsonBody(req: IncomingMessage): Promise<Record<string, unknown>> {
  const text = (await readBody(req, MAX_JSON_BODY_BYTES)).toString("utf8");
  if (!text) return {};
  try {
    return JSON.parse(text) as Record<string, unknown>;
  } catch {
    throw new ApiError("INVALID_REQUEST", "invalid json body", 400);
  }
}
