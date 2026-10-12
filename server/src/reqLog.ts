/** `[req]` 控制台日志的统一前缀时间戳（老板 2026-10-12 要求每条都带）。
 *
 * **UTC + `Z` 后缀**（老板 2026-10-12：时区无关的格式）——服务器/VPS 常在
 * 不同时区、pm2 日志跨机器比对，本地时间没有可比性；UTC 字符串排序即时间序。
 * 格式：`2026-10-12T03:23:40Z`。 */
export function reqTimestamp (): string {
  const d = new Date()
  const pad = (n: number) => String(n).padStart(2, '0')
  return (
    `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}` +
    `T${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}:${pad(d.getUTCSeconds())}Z`
  )
}

/** 打一条 `[req]` 日志：时间戳在前，调用方给 `[req]` 之后的正文。 */
export function logReq (message: string): void {
  console.log(`[${reqTimestamp()}] [req] ${message}`)
}
