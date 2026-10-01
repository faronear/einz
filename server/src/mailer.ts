import nodemailer from "nodemailer";

/**
 * 邮件管道：整个服务端**唯一**的出站网络调用。
 *
 * 为什么要有它（老板 2026-10-01）：Einz 没上应用商店 → 没有后台推送通道，对方离线期间
 * 的来信他完全不知道，只能等下次打开 App 才发现。邮件系统自带推送，是唯一能低成本补上
 * "把人拉回来"这条链路的手段（详见 notifier.ts 的节流设计）。
 *
 * 边界：
 * - **只发邮件，不读邮件**：不做 IMAP 轮询、不接 inbound，退退订只靠链接，不管回信。
 * - **没有配置就整体关闭**（返回 null），不抛异常、不影响聊天主流程——区别于必须的
 *   `EINZ_DB_BACKUP_KEY`（backup.ts:59，缺失即拒绝启动）：邮件通知是可选项，一个没有
 *   SMTP 凭据的部署应该照常收发消息，只是不发信。
 * - **正文里永远不会有消息内容**：服务端只有 ciphertext。不是妥协，是刻意的——邮件会
 *   明文躺在对方邮箱里好几年，安全等级低于 App 内的密文。
 */
export interface MailConfig {
  host: string;
  port: number;
  /** true = 465 直连 TLS；false = 587 提交端口 + STARTTLS（Oracle Email Delivery 用这个）。 */
  secure: boolean;
  user: string;
  pass: string;
  /** 发件地址。Oracle Email Delivery 要求先在控制台把它登记为 approved sender，
   *  并且域名要配 SPF/DKIM，否则发出去就是垃圾箱或者直接被拒。 */
  from: string;
  /** 邮件里链接（验证 / 退订）的站点基地址；默认唯一备案域名 einz.yuanjinx.com。 */
  baseUrl: string;
}

export interface OutgoingMail {
  to: string;
  subject: string;
  /** 纯文本正文（UTF-8；中文由 nodemailer 做 MIME 编码，别自己拼 encoded-word）。 */
  text: string;
  /** 退订链接（同时会写进 List-Unsubscribe 头，邮件客户端据此提供一键退订）。 */
  unsubscribeUrl?: string;
}

/** 发送失败。`permanent=true` 表示目标地址永久不可用（硬退信），不应重试。 */
export class MailError extends Error {
  constructor(
    message: string,
    public readonly permanent: boolean
  ) {
    super(message);
    this.name = "MailError";
  }
}

/**
 * 从环境变量读 SMTP 配置；缺任何一项就返回 null（功能整体关闭）。
 *
 * 环境变量（沿用 `EINZ_*` 惯例，见 config.ts / attachments.ts / escrow.ts）：
 * - `EINZ_SMTP_HOST` 必填（例：`smtp.email.us-ashburn-1.oraclecloud.com`）
 * - `EINZ_SMTP_PORT` 默认 587
 * - `EINZ_SMTP_SECURE` `1/true` = 直连 TLS；默认按端口推（465 → true）
 * - `EINZ_SMTP_USER` / `EINZ_SMTP_PASS` 必填（Oracle 是 `ocid1.user.…` + SMTP 凭据）
 * - `EINZ_MAIL_FROM` 必填
 * - `EINZ_MAIL_BASE_URL` 默认 `https://einz.yuanjinx.com`
 */
export function loadMailConfig(): MailConfig | null {
  const host = (process.env.EINZ_SMTP_HOST ?? "").trim();
  const user = (process.env.EINZ_SMTP_USER ?? "").trim();
  const pass = process.env.EINZ_SMTP_PASS ?? "";
  const from = (process.env.EINZ_MAIL_FROM ?? "").trim();
  if (host.length === 0 || user.length === 0 || pass.length === 0 || from.length === 0) {
    return null;
  }
  const rawPort = Number(process.env.EINZ_SMTP_PORT ?? 587);
  const port = Number.isFinite(rawPort) && rawPort > 0 ? Math.trunc(rawPort) : 587;
  const rawSecure = process.env.EINZ_SMTP_SECURE;
  const secure = rawSecure == null ? port === 465 : /^(1|true|yes)$/i.test(rawSecure.trim());
  const baseUrl = (process.env.EINZ_MAIL_BASE_URL ?? "https://einz.yuanjinx.com").replace(/\/+$/, "");
  return { host, port, secure, user, pass, from, baseUrl };
}

export interface Mailer {
  send(mail: OutgoingMail): Promise<void>;
  readonly config: MailConfig;
}

/**
 * 构造发送器。每条邮件**单独建连接**——一天几封的量不值得维持连接池，
 * 长连接池反而会在 NAT / 反代空闲超时后留下一条看着健康、实际已死的 socket。
 */
export function createMailer(config: MailConfig): Mailer {
  return {
    config,
    async send(mail: OutgoingMail): Promise<void> {
      const transport = nodemailer.createTransport({
        host: config.host,
        port: config.port,
        secure: config.secure,
        auth: { user: config.user, pass: config.pass },
        // 提交端口上强制 STARTTLS 升级：凭据不该有走明文的可能。
        // 465 直连 TLS 时不需要（socket 本身就是 TLS），nodemailer 也不允许两者同时开。
        requireTLS: !config.secure,
        tls: { minVersion: "TLSv1.2" },
        connectionTimeout: 15_000,
        greetingTimeout: 15_000,
        socketTimeout: 30_000,
      });
      try {
        await transport.sendMail({
          from: config.from,
          to: mail.to,
          subject: mail.subject,
          text: mail.text,
          headers: {
            // RFC 8058：让邮件客户端（含各家网页版）显示"退订"按钮，而不是让用户
            // 把这封邮件标记为垃圾邮件——后者才会真正伤害域名信誉。
            ...(mail.unsubscribeUrl
              ? {
                  "List-Unsubscribe": `<${mail.unsubscribeUrl}>`,
                  "List-Unsubscribe-Post": "List-Unsubscribe=One-Click",
                }
              : {}),
            "Auto-Submitted": "auto-generated",
            "X-Einz-Notice": "no-message-content-here", // 排障时能一眼确认"这是通知件"
          },
        });
      } catch (err) {
        throw classifyError(err);
      } finally {
        transport.close();
      }
    },
  };
}

/**
 * 把 nodemailer 的失败翻译成"要不要再试"。
 *
 * 判据只有一个：SMTP 响应码。5xx = 服务器明确拒收（地址不存在、域名没配 SPF 等），
 * 重试只会重复污染信誉 → 记为硬退信永久停发；4xx = 临时拒绝（限流、灰名单、网络），
 * 下一次 tick 再试。连不上（无响应码）同样按临时失败处理。
 */
function classifyError(err: unknown): MailError {
  const e = (err ?? {}) as { responseCode?: unknown; response?: unknown; message?: unknown; code?: unknown };
  const responseCode = Number(e.responseCode);
  const response = typeof e.response === "string" ? e.response.trim() : "";
  const message = typeof e.message === "string" ? e.message : String(err);
  const code = typeof e.code === "string" ? e.code : "";

  if (Number.isFinite(responseCode) && responseCode >= 500) {
    return new MailError(`SMTP ${responseCode} ${response || message}`, true);
  }
  const suffix = [code, response].filter((s) => s.length > 0).join(" ");
  return new MailError(suffix.length > 0 ? `${message} [${suffix}]` : message, false);
}
