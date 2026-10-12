/** `[req]` 控制台日志的统一前缀时间戳（老板 2026-10-12 要求每条都带）。
 *
 * 服务器日志是排障时对齐 App/服务端两侧时序的依据，本地时间 + 日期一起给
 * （pm2 日志跨天滚动，光有时刻不够）。格式：`2026-10-12 14:33:05`。 */
export function reqTimestamp (): string {
  const d = new Date()
  const pad = (n: number) => String(n).padStart(2, '0')
  return (
    `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ` +
    `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`
  )
}

/** 打一条 `[req]` 日志：时间戳在前，调用方给 `[req]` 之后的正文。 */
export function logReq (message: string): void {
  console.log(`[${reqTimestamp()}] [req] ${message}`)
}
