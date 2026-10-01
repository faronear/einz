import { randomBytes } from "node:crypto";
import { getDb } from "./db.js";
import { ApiError } from "./auth.js";
import { requireSession } from "./guard.js";
import { logActivity, NO_META } from "./audit.js";
import { getConnectedAt } from "./ws.js";
import {
  createMailer,
  loadMailConfig,
  MailError,
  type MailConfig,
  type Mailer,
  type OutgoingMail,
} from "./mailer.js";

/**
 * 邮件通知：**把离线的人拉回 App**（2026-10-01）。
 *
 * ── 这件事的全部难点是「忍住不发」─────────────────────────────────────────
 * 服务端存的是密文，邮件里不可能有正文——它不是"预告内容"，而是"拍一下肩膀"。
 * 拍得太勤，人会把邮件规则一设，功能等于死了。所以一封信的价值不在于及时，
 * 而在于**没有第二封**。四道闸门，缺一不发：
 *
 *   ① **真有未读**：该 member 有晚于自己读取水位、且不是自己发的消息
 *      （口径完全同 `receipts.unreadCount`，不另起一套判定，免得两处漂移）；
 *   ② **真的走开了**：名下**所有**通道都没有 WS 连接，且最后活动证据
 *      （max(last_seen, offline_since)）**早于**最新那条未读消息——"消息到了之后
 *      他没有回来过"。这一条顺带覆盖了"回来过了"：回来过就有 REST/WS 活动刷新
 *      last_seen（touchLastSeen / 心跳），这条未读就再也不会被翻出来打扰他；
 *   ③ **安静了 2 分钟**（静默窗）：连珠炮 20 条消息 = 1 封邮件；
 *   ④ **距上封 ≥ 30 分钟**（冷却）+ **每天 ≤ 8 封**（日上限）：持续轰炸的下界与天花板。
 *
 * ── 为什么是"派生"而不是"待发账本"───────────────────────────────────────
 * 直觉写法是 postMessage 时写一张 pending 表，到点清表发信。但这需要额外挂两个钩子：
 * 上线要取消 pending、postMessage 要记账；而"是否该发"依赖的状态（未读、在线、最后活动）
 * **在没有任何消息时也在变**——人回来了就得作废。既然这些状态全在库里，每轮 tick
 * 直接现算一遍是最短的路径：没有 pending 表、没有取消钩子、没有"账本和现实不一致"这类 bug。
 * 数据量是几个空间几条消息，全表扫的代价远小于多一张表的维护代价。
 *
 * ── 为什么按"邮箱地址"而不是按"人"节流───────────────────────────────────
 * member_id 是按空间生成的（spaces.ts create/join 各 randomUUID），同一个人在别的空间
 * 是另一行，服务端**没有跨空间的"人"**。好在退一步想：噪声是在**收件箱**里发生的，
 * 去重该发生在收件箱那一层——同一个地址在 3 个空间有未读 → 合并成**一封**摘要信。
 * 于是既不引入 person 表，又不会一个人收三封。
 */
export interface NotifyParams {
  /** tick 间隔（ms）。 */
  tickMs: number;
  /** 静默窗：最新一条未读消息之后必须安静这么久才允许发（防抖）。 */
  quietMs: number;
  /** 冷却：同一个地址两封信之间的最小间隔。 */
  cooldownMs: number;
  /** 日上限：每天最多几封（到点后本日不再发）。 */
  dailyMax: number;
}

/** 参数都可用环境变量覆盖（改参数不必改代码，重启即生效）。默认值＝老板 2026-10-01 选定档。 */
export function notifyParams(): NotifyParams {
  const num = (name: string, fallback: number): number => {
    const raw = Number(process.env[name]);
    return Number.isFinite(raw) && raw >= 0 ? Math.trunc(raw) : fallback;
  };
  return {
    tickMs: num("EINZ_NOTIFY_TICK_MS", 60_000),
    quietMs: num("EINZ_NOTIFY_QUIET_MS", 120_000),
    cooldownMs: num("EINZ_NOTIFY_COOLDOWN_MS", 30 * 60_000),
    dailyMax: num("EINZ_NOTIFY_DAILY_MAX", 8),
  };
}

export interface NotifyEntry {
  spaceId: string;
  senderMemberId: string;
  /** 发送者显示名；没名字是 null（正文里按语言退成「对方」/「Someone」）。 */
  senderName: string | null;
  count: number;
  lastAt: number;
}

/** 一个收件地址本轮要发的内容（可能横跨多个空间）。 */
export interface NotifyPlan {
  email: string;
  /** 收件人自己的显示名（可能没有 → null，正文里就不称呼）。 */
  displayName: string | null;
  entries: NotifyEntry[];
  total: number;
  /** entries 里最新一条的时刻（=这封信的时点）。 */
  newestAt: number;
  lang: MailLang;
}

/** 邮件正文语言。库里是 NULL（存量行）或别的值时一律按 zh，别让脏数据把正文变成空白。 */
export type MailLang = "zh" | "en";
export function mailLang(raw: string | null | undefined): MailLang {
  return raw === "en" ? "en" : "zh";
}

// ── 邮箱地址的处理 ─────────────────────────────────────────────────────────

/** 保守的地址形状校验：不做 RFC 5322 全量解析（过度），卡住"本地@域名.域名"就行。 */
const EMAIL_RE = /^[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$/;

/** 规范化：去空白 + 小写（Gmail 之外的主流服务商也不区分大小写，统一按小写存主键）。 */
export function normalizeEmail(raw: string): string | null {
  const trimmed = raw.trim().toLowerCase();
  if (trimmed.length === 0) return null;
  if (trimmed.length > 254) throw new ApiError("INVALID_REQUEST", "email too long", 400);
  const at = trimmed.indexOf("@");
  if (at <= 0 || at > 64) throw new ApiError("INVALID_REQUEST", "invalid email", 400);
  if (!EMAIL_RE.test(trimmed)) throw new ApiError("INVALID_REQUEST", "invalid email", 400);
  return trimmed;
}

// ── 计划（纯读数据库，可测）────────────────────────────────────────────────

/**
 * 算出本轮该发给谁。只读不发。
 *
 * 顺序刻意是「先便宜后昂贵」：先按地址行过滤（冷却/退订/退信），每个邮箱才去做
 * 空间 → 未读 → 在线三层查询。绝大多数 tick 在第 0 步就空手而归。
 */
export function planNotifications(now = Date.now()): NotifyPlan[] {
  const db = getDb();
  const { quietMs, cooldownMs, dailyMax } = notifyParams();
  const day = dayKey(now);

  const emails = db
    .prepare(
      `SELECT email, verified_at, unsubscribe_at, hard_bounce_at, pause_until,
              last_sent_at, sent_day, sent_count, lang
         FROM notify_emails`
    )
    .all() as {
    email: string;
    verified_at: number | null;
    unsubscribe_at: number | null;
    hard_bounce_at: number | null;
    pause_until: number | null;
    last_sent_at: number | null;
    sent_day: string | null;
    sent_count: number;
    lang: string | null;
  }[];

  const plans: NotifyPlan[] = [];
  for (const row of emails) {
    // 准入：必须已经点过验证链接（把别人的地址填进来当骚扰通道是这类功能的头号滥用面）
    if (row.verified_at == null) continue;
    if (row.unsubscribe_at != null || row.hard_bounce_at != null) continue;
    if (row.pause_until != null && row.pause_until > now) continue; // 软失败退避中
    // 冷却
    if (row.last_sent_at != null && now - row.last_sent_at < cooldownMs) continue;
    // 日上限（sent_day 跨天自动失效，不需要额外清理任务）
    if (row.sent_day === day && row.sent_count >= dailyMax) continue;

    const memberRows = db
      .prepare(
        `SELECT space_id, member_id, display_name
           FROM space_members
          WHERE email = ? AND member_id IS NOT NULL AND status = 'active'`
      )
      .all(row.email) as { space_id: string; member_id: string; display_name: string | null }[];

    const entries: NotifyEntry[] = [];
    let displayName: string | null = null;

    for (const m of memberRows) {
      if (displayName == null) displayName = cleanName(m.display_name);
      const plan = planForMember(m.space_id, m.member_id, now, quietMs);
      if (plan) entries.push(...plan);
    }
    if (entries.length === 0) continue;

    entries.sort((a, b) => b.lastAt - a.lastAt);
    plans.push({
      email: row.email,
      displayName,
      entries,
      total: entries.reduce((s, e) => s + e.count, 0),
      newestAt: Math.max(...entries.map((e) => e.lastAt)),
      lang: mailLang(row.lang),
    });
  }
  return plans;
}

/** 单个 member 在单个空间里的未读摘要；不满足闸门就返回 null。 */
function planForMember(
  spaceId: string,
  memberId: string,
  now: number,
  quietMs: number
): NotifyEntry[] | null {
  const db = getDb();

  const { read_seq: readSeq } = db
    .prepare(
      `SELECT COALESCE(MAX(read_upto_seq), 0) AS read_seq
         FROM receipts WHERE space_id = ? AND member_id = ?`
    )
    .get(spaceId, memberId) as { read_seq: number };

  // 未读口径 = unreadCount（receipts.ts）：晚于读取水位、且**不是自己这条身份**发的。
  // 必须走 member 维度（同一身份的第二条通道发的不算未读）。
  const grouped = db
    .prepare(
      `SELECT COALESCE(d.member_id, '') AS sender_member_id,
              COUNT(*) AS n,
              MAX(m.created_at) AS last_at
         FROM messages m
         LEFT JOIN entrances d ON d.entrance_id = m.sender_entrance_id
        WHERE m.space_id = ?
          AND m.server_sequence > ?
          AND (d.member_id IS NULL OR d.member_id != ?)
        GROUP BY COALESCE(d.member_id, '')`
    )
    .all(spaceId, readSeq, memberId) as {
    sender_member_id: string;
    n: number;
    last_at: number;
  }[];
  if (grouped.length === 0) return null;

  const newestAt = Math.max(...grouped.map((g) => g.last_at));
  // ③ 静默窗：最新一条之后还在继续发 → 再等等，让这一串并入一封信
  if (now - newestAt < quietMs) return null;

  // ② 真的走开了：任一通道还挂着 WS 连接 → 他在线就能收到 message.new，不必拍他
  const myEntrances = db
    .prepare(
      `SELECT entrance_id, last_seen, offline_since
         FROM entrances WHERE member_id = ? AND status = 'active'`
    )
    .all(memberId) as { entrance_id: string; last_seen: number | null; offline_since: number | null }[];
  if (myEntrances.some((e) => getConnectedAt(e.entrance_id) != null)) return null;
  const activityAt = myEntrances.reduce((max, e) => {
    const t = Math.max(e.last_seen ?? 0, e.offline_since ?? 0);
    return t > max ? t : max;
  }, 0);
  // 消息到了之后他回来过（WS/REST 任一有活动）→ 他已经有机会看到，不再打扰
  if (activityAt >= newestAt) return null;

  return grouped.map((g) => ({
    spaceId,
    senderMemberId: g.sender_member_id,
    senderName: displayNameOf(spaceId, g.sender_member_id),
    count: g.n,
    lastAt: g.last_at,
  }));
}

function cleanName(raw: string | null): string | null {
  const s = (raw ?? "").trim();
  return s.length > 0 ? s : null;
}

/**
 * 发送者显示名；没有名字的行是 null——绝不把 member_id 这种内部锚点写进邮件。
 * 退到「对方」/「Someone」是**正文**的事（见 SUMMARY_COPY，按语言退）。
 */
function displayNameOf(spaceId: string, memberId: string): string | null {
  if (memberId.length === 0) return null;
  const row = getDb()
    .prepare(`SELECT display_name FROM space_members WHERE space_id = ? AND member_id = ?`)
    .get(spaceId, memberId) as { display_name: string | null } | undefined;
  return cleanName(row?.display_name ?? null);
}

// ── 发送 ───────────────────────────────────────────────────────────────────

export interface TickSummary {
  planned: number;
  sent: number;
  failures: number;
}

/**
 * 一轮 tick：算 → 发 → 记。
 * `dryRun` 只返回计划（UI 自查 / 排障用），不投递。
 */
export async function runNotifyTick(opts: {
  now?: number;
  mailer?: Mailer | null;
  dryRun?: boolean;
} = {}): Promise<TickSummary> {
  const now = opts.now ?? Date.now();
  const mailer = opts.mailer === undefined ? currentMailer() : opts.mailer;
  if (mailer == null) return { planned: 0, sent: 0, failures: 0 };

  cleanupTokens(now);
  const plans = planNotifications(now);
  if (opts.dryRun) return { planned: plans.length, sent: 0, failures: 0 };

  let sent = 0;
  let failures = 0;
  for (const plan of plans) {
    try {
      const unsubscribeToken = ensureUnsubscribeToken(plan.email, now);
      await mailer.send(buildSummaryMail(plan, mailer.config, unsubscribeToken));
      markSent(plan.email, now);
      failureStreak.delete(plan.email);
      sent += 1;
      console.log(`[einz] 邮件通知：已发 ${maskEmail(plan.email)}（${plan.total} 条未读，${plan.entries.length} 个来源）`);
    } catch (err) {
      failures += 1;
      const permanent = err instanceof MailError && err.permanent;
      recordFailure(plan.email, now, permanent, err);
    }
  }
  return { planned: plans.length, sent, failures };
}

/** 本进程当前的发送器（未配置 SMTP → null，整个功能降级为空转）。 */
let mailerSingleton: Mailer | null | undefined;
function currentMailer(): Mailer | null {
  if (mailerSingleton === undefined) {
    const cfg = loadMailConfig();
    mailerSingleton = cfg == null ? null : createMailer(cfg);
  }
  return mailerSingleton;
}

/** 启动定时 tick（挂 app.ts，间隔见 notifyParams.tickMs）。 */
export function startNotifier(): void {
  if (loadMailConfig() == null) {
    console.log(
      "[einz] 邮件通知：未启用（缺 EINZ_SMTP_HOST / EINZ_SMTP_USER / EINZ_SMTP_PASS / EINZ_MAIL_FROM 任一，功能整体关闭）"
    );
    return;
  }
  const { tickMs, quietMs, cooldownMs, dailyMax } = notifyParams();
  console.log(
    `[einz] 邮件通知：已启用 tick=${tickMs / 1000}s 静默=${quietMs / 1000}s 冷却=${cooldownMs / 60000}min 日上限=${dailyMax}`
  );
  void runNotifyTick().catch((e) => console.error("[einz] 邮件通知 tick 失败", e));
  const timer = setInterval(() => {
    void runNotifyTick().catch((e) => console.error("[einz] 邮件通知 tick 失败", e));
  }, tickMs);
  timer.unref();
}

function markSent(email: string, now: number): void {
  const day = dayKey(now);
  const db = getDb();
  const row = db
    .prepare(`SELECT sent_day, sent_count FROM notify_emails WHERE email = ?`)
    .get(email) as { sent_day: string | null; sent_count: number } | undefined;
  if (row == null) return;
  const count = row.sent_day === day ? row.sent_count + 1 : 1;
  db.prepare(`UPDATE notify_emails SET last_sent_at = ?, sent_day = ?, sent_count = ? WHERE email = ?`).run(
    now,
    day,
    count,
    email
  );
}

/**
 * 失败记账。永久失败（5xx）直接钉死不再试——反复给一个不存在的地址发信，
 * 掉的是**发件域名**的信誉，那是所有通知一起陪葬的事。临时失败退避一阵再试。
 */
function recordFailure(email: string, now: number, permanent: boolean, err: unknown): void {
  const message = err instanceof Error ? err.message : String(err);
  if (permanent) {
    failureStreak.delete(email);
    getDb()
      .prepare(`UPDATE notify_emails SET hard_bounce_at = ?, pause_until = NULL WHERE email = ?`)
      .run(now, email);
    console.error(`[einz] 邮件通知：${maskEmail(email)} 硬退信，永久停发 — ${message}`);
    return;
  }
  const waitMs = nextBackoffMs(email);
  const until = now + waitMs;
  getDb().prepare(`UPDATE notify_emails SET pause_until = ? WHERE email = ?`).run(until, email);
  console.error(
    `[einz] 邮件通知：${maskEmail(email)} 发送失败，${Math.round(waitMs / 60_000)} 分钟后重试 — ${message}`
  );
}

/**
 * 连续失败的指数退避（5min → 10 → 20 → … → 60min 封顶）。
 * 计数只在进程内存里：重启就从头再来，这没关系——它保护的是 SMTP 额度与域名信誉，
 * 重启后重新试一次本来也是合理的。
 */
const failureStreak = new Map<string, number>();
function nextBackoffMs(email: string): number {
  const n = (failureStreak.get(email) ?? 0) + 1;
  failureStreak.set(email, n);
  return Math.min(60 * 60_000, 5 * 60_000 * 2 ** (n - 1));
}

function dayKey(ms: number): string {
  return new Date(ms).toISOString().slice(0, 10);
}

function cleanupTokens(now: number): void {
  getDb().prepare(`DELETE FROM notify_tokens WHERE expires_at < ?`).run(now);
}

/** 日志里不落完整地址（邮箱是这个服务端唯一能直接指向真人的字段）。 */
export function maskEmail(email: string): string {
  const [local, domain] = email.split("@");
  if (local == null || domain == null) return "(invalid)";
  const head = local.slice(0, 1);
  return `${head}***@${domain}`;
}

// ── 邮件正文 ───────────────────────────────────────────────────────────────

/**
 * 中英两套文案。语言由客户端在设置邮箱时上报（服务端无法知道收件人读哪种语言）。
 *
 * 两条写作约定：
 * - **正文里绝不含消息内容**——服务端只有密文，而且邮件会在对方邮箱里明文躺好几年，
 *   正文泄露等于把整条加密链路短路掉。所以每封信都只能回答"谁、几条、几点"。
 * - 英文一律**句首大写，不做 Title Case**（老板 2026-09 定的全站文案规则，邮件同样适用）；
 *   品牌名 Einz 照原样。
 */
interface SummaryCopy {
  subject(total: number): string;
  greeting(name: string | null): string | null;
  count(total: number): string;
  /** 一行摘要：发送者 + 条数 + 时刻。 */
  entry(name: string, count: number, stamp: string): string;
  openApp(): string;
  noContent(): string;
  stop(url: string): string;
  unnamed(): string;
}

const SUMMARY_COPY: Record<MailLang, SummaryCopy> = {
  zh: {
    subject: (total) => `[Einz] 你有 ${total} 条未读消息`,
    greeting: (name) => (name == null ? null : `${name}：`),
    count: (total) => `你在 Einz 有 ${total} 条未读消息：`,
    entry: (name, count, stamp) => `  ${name}    ${count} 条    ${stamp}`,
    openApp: () => "打开 Einz 就能看到。",
    noContent: () => "消息是端到端加密的，这封邮件里没有正文，以后也不会有。",
    stop: (url) => `不想再收到这类提醒：${url}`,
    unnamed: () => "对方",
  },
  en: {
    subject: (total) => `[Einz] You have ${total} unread ${total === 1 ? "message" : "messages"}`,
    greeting: (name) => (name == null ? null : `${name},`),
    count: (total) =>
      `You have ${total} unread ${total === 1 ? "message" : "messages"} in Einz:`,
    entry: (name, count, stamp) =>
      `  ${name}    ${count} ${count === 1 ? "message" : "messages"}    ${stamp}`,
    openApp: () => "Open Einz to read them.",
    noContent: () =>
      "Messages are end-to-end encrypted — this email has no message text in it, and never will.",
    stop: (url) => `Stop these emails: ${url}`,
    unnamed: () => "Someone",
  },
};

/** 摘要信（"有人在找你"）。 */
export function buildSummaryMail(
  plan: NotifyPlan,
  cfg: MailConfig,
  unsubscribeToken: string
): OutgoingMail {
  const copy = SUMMARY_COPY[plan.lang];
  const unsubscribeUrl = `${cfg.baseUrl}/notify/unsubscribe?token=${encodeURIComponent(unsubscribeToken)}`;
  const lines = plan.entries.map((e) =>
    copy.entry(e.senderName ?? copy.unnamed(), e.count, formatStamp(e.lastAt))
  );

  const text = [
    copy.greeting(plan.displayName),
    null,
    copy.count(plan.total),
    null,
    ...lines,
    null,
    copy.openApp(),
    null,
    copy.noContent(),
    null,
    "——",
    copy.stop(unsubscribeUrl),
  ]
    .filter((l) => l !== null)
    .join("\n");

  return {
    to: plan.email,
    subject: copy.subject(plan.total),
    text,
    unsubscribeUrl,
  };
}

interface VerifyCopy {
  subject(): string;
  greeting(name: string | null): string | null;
  why(): string;
  confirm(url: string): string;
  notYou(): string;
  noContent(): string;
  stop(url: string): string;
}

const VERIFY_COPY: Record<MailLang, VerifyCopy> = {
  zh: {
    subject: () => "[Einz] 确认这个邮箱接收消息提醒",
    greeting: (name) => (name == null ? null : `${name}：`),
    why: () =>
      "这个邮箱被填成了 Einz 的消息提醒地址——你在 Einz 有新消息时，我们会往这里发一封提醒。",
    confirm: (url) => `确认要接收请点这个链接：${url}`,
    notYou: () => "如果不是你填的，忽略这封邮件就好——不点链接就什么都不会发生。",
    noContent: () => "提醒邮件里不会有消息正文：消息是端到端加密的，服务端只保管密文。",
    stop: (url) => `不接收提醒：${url}`,
  },
  en: {
    subject: () => "[Einz] Confirm this email for message alerts",
    greeting: (name) => (name == null ? null : `${name},`),
    why: () =>
      "This address was set to receive Einz message alerts — we'll email here when you have new messages and haven't been online for a while.",
    confirm: (url) => `Confirm it's yours: ${url}`,
    notYou: () =>
      "If it wasn't you, just ignore this email — nothing happens until the link is opened.",
    noContent: () =>
      "Alert emails never contain message text: messages are end-to-end encrypted and the server only stores ciphertext.",
    stop: (url) => `No alerts: ${url}`,
  },
};

/** 验证信：把地址填进来的人不一定是地址的主人，所以必须过这一道（防滥用 + 防手滑）。 */
export function buildVerificationMail(
  email: string,
  verifyUrl: string,
  unsubscribeUrl: string | null,
  displayName: string | null,
  lang: MailLang
): OutgoingMail {
  const copy = VERIFY_COPY[lang];
  const text = [
    copy.greeting(displayName),
    null,
    copy.why(),
    null,
    copy.confirm(verifyUrl),
    null,
    copy.notYou(),
    null,
    "——",
    copy.noContent(),
    unsubscribeUrl == null ? null : copy.stop(unsubscribeUrl),
  ]
    .filter((l) => l !== null)
    .join("\n");

  return {
    to: email,
    subject: copy.subject(),
    text,
    ...(unsubscribeUrl ? { unsubscribeUrl } : {}),
  };
}

/**
 * 时间戳：本地时间在前、紧凑 UTC 在后（`14:32（20261001T063200Z）`）。
 * 老板中美两地同用这一个账号，只给本地时间在两个时区之间会看错，只给 UTC 又没人
 * 心算得动——两个并列，谁都不会误读。跨日/跨年的消息补上日期。
 */
function formatStamp(ms: number): string {
  const d = new Date(ms);
  const now = new Date();
  const pad = (n: number): string => String(n).padStart(2, "0");
  const sameDay = d.toDateString() === now.toDateString();
  const local = sameDay
    ? `${pad(d.getHours())}:${pad(d.getMinutes())}`
    : `${pad(d.getMonth() + 1)}/${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
  const utc =
    `${d.getUTCFullYear()}${pad(d.getUTCMonth() + 1)}${pad(d.getUTCDate())}` +
    `T${pad(d.getUTCHours())}${pad(d.getUTCMinutes())}${pad(d.getUTCSeconds())}Z`;
  return `${local}（${utc}）`;
}

// ── 服务端 API 用的业务函数 ────────────────────────────────────────────────

export interface NotifyEmailStatus {
  email: string | null;
  /** none=没设置 / pending=待点验证链接 / verified=生效中 / inactive=已退订或硬退信后停发。 */
  state: "none" | "pending" | "verified" | "inactive";
  /** 本次调用是否真的往 SMTP 投了一封验证信（老地址已验证则不需要重发）。 */
  verification_sent: boolean;
}

/**
 * PUT /notify/email：设置本空间里"我"的提醒邮箱，并发出一封确认信。
 *
 * 同一地址已经在别的空间验证过 → **直接生效**（不再麻烦人点第二次）；
 * 否则一律走验证：不给"不存在的第三方地址"留直通通道。
 *
 * 刻意**不刷新 last_seen**（对比 messages.syncMessages 会刷新）：last_seen 是
 * "这条通道最后活动"的证据，而通知的第②道闸门正是靠它判断"他回来过没有"。
 * 有人在设置页里添删邮箱，不该因此把他标记为"在线"从而错过本该发的提醒——
 * 反过来也一样：App 只要在前台，WS 心跳本来就在刷它，不需要这几个端点代劳。
 */
export async function setNotifyEmail(
  token: string,
  rawEmail: string,
  opts: { mailer?: Mailer | null; lang?: string | null } = {}
): Promise<NotifyEmailStatus> {
  const { entrance_id, space_id, member_id } = requireSession(token);
  const email = normalizeEmail(rawEmail);
  if (email == null) throw new ApiError("INVALID_REQUEST", "email required", 400);

  const db = getDb();
  const now = Date.now();
  const lang = mailLang(opts.lang);
  const existing = db.prepare(`SELECT * FROM notify_emails WHERE email = ?`).get(email) as
    | { email: string; verified_at: number | null; unsubscribe_at: number | null; hard_bounce_at: number | null }
    | undefined;

  if (existing == null) {
    db.prepare(`INSERT INTO notify_emails (email, lang, created_at) VALUES (?, ?, ?)`).run(
      email,
      lang,
      now
    );
  } else {
    // 重新登记 = 明确的"我还要收"：清掉退订与退信停发、并按本次上报刷新正文语言。
    // 它是本人主动动作（持有会话），不清的话换过邮箱的人永远救不回来。
    db.prepare(
      `UPDATE notify_emails
          SET unsubscribe_at = NULL, hard_bounce_at = NULL, pause_until = NULL, lang = ?
        WHERE email = ?`
    ).run(lang, email);
  }

  const row = db.prepare(`SELECT verified_at FROM notify_emails WHERE email = ?`).get(email) as {
    verified_at: number | null;
  };

  bindMembersEmail(space_id, member_id, email);
  logNotifyActivity(entrance_id, space_id, "notify.email.set");

  // 已验证 → 不打扰；未验证 → 发一封确认信（这是唯一必须立刻投递的场景，失败要告诉调用方）
  if (row.verified_at != null) {
    return { email, state: "verified", verification_sent: false };
  }
  const mailer = opts.mailer === undefined ? currentMailer() : opts.mailer;
  if (mailer == null) {
    throw new ApiError("MAIL_DISABLED", "邮件通知未启用：服务端缺 SMTP 配置", 503);
  }
  const verifyToken = ensureVerifyToken(email, now);
  const unsubscribeToken = ensureUnsubscribeToken(email, now);
  // 收件人自己的名字（写进称呼）；没有名字就不称呼——"对方"是给**发送者**留的回退，
  // 用在自己身上就成了怪话。
  const own = cleanName(
    (getDb()
      .prepare(`SELECT display_name FROM space_members WHERE space_id = ? AND member_id = ?`)
      .get(space_id, member_id) as { display_name: string | null } | undefined)?.display_name ?? null
  );
  await mailer.send(
    buildVerificationMail(
      email,
      `${mailer.config.baseUrl}/notify/verify?token=${encodeURIComponent(verifyToken)}`,
      `${mailer.config.baseUrl}/notify/unsubscribe?token=${encodeURIComponent(unsubscribeToken)}`,
      own,
      lang
    )
  );
  return { email, state: "pending", verification_sent: true };
}

export function getNotifyEmail(token: string): NotifyEmailStatus {
  const { space_id, member_id } = requireSession(token);
  const email = emailOfMember(space_id, member_id);
  return { email, state: stateOf(email), verification_sent: false };
}

/** DELETE /notify/email：撤掉这个空间的提醒邮箱；没有别处再用就把这一行彻底删干净。 */
export function deleteNotifyEmail(token: string): { ok: true } {
  const { entrance_id, space_id, member_id } = requireSession(token);
  const email = emailOfMember(space_id, member_id);
  getDb()
    .prepare(`UPDATE space_members SET email = NULL WHERE space_id = ? AND member_id = ?`)
    .run(space_id, member_id);
  if (email != null) purgeEmailIfUnused(email);
  logNotifyActivity(entrance_id, space_id, "notify.email.delete");
  return { ok: true };
}

/**
 * GET /notify/verify?token= / /notify/unsubscribe?token=：一次性消费 token。
 * 免鉴权（浏览器里点开的链接没有 Bearer 可言）——所以 verify token 24h 有效、
 * 用后即焚；unsubscribe token 长期有效但**只做退订**这一件无害的事。
 */
export function consumeNotifyToken(
  rawToken: string,
  kind: "verify" | "unsubscribe"
): { ok: true; email: string } | { ok: false } {
  const token = String(rawToken ?? "").trim();
  if (token.length === 0 || token.length > 256) return { ok: false };
  const db = getDb();
  const row = db
    .prepare(`SELECT email, expires_at, used_at FROM notify_tokens WHERE token = ? AND kind = ?`)
    .get(token, kind) as { email: string; expires_at: number; used_at: number | null } | undefined;
  if (row == null || row.used_at != null || row.expires_at < Date.now()) return { ok: false };

  if (kind === "verify") {
    db.prepare(`UPDATE notify_tokens SET used_at = ? WHERE token = ?`).run(Date.now(), token);
    db.prepare(`UPDATE notify_emails SET verified_at = COALESCE(verified_at, ?) WHERE email = ?`).run(
      Date.now(),
      row.email
    );
    console.log(`[einz] 邮件通知：${maskEmail(row.email)} 已验证`);
  } else {
    // 退订链接**不销毁**（每封信底部都要印同一个链接），只置位
    db.prepare(
      `UPDATE notify_emails SET unsubscribe_at = COALESCE(unsubscribe_at, ?) WHERE email = ?`
    ).run(Date.now(), row.email);
    console.log(`[einz] 邮件通知：${maskEmail(row.email)} 已退订`);
  }
  return { ok: true, email: row.email };
}

// ── 内部小工具 ─────────────────────────────────────────────────────────────

function emailOfMember(spaceId: string, memberId: string): string | null {
  const row = getDb()
    .prepare(`SELECT email FROM space_members WHERE space_id = ? AND member_id = ?`)
    .get(spaceId, memberId) as { email: string | null } | undefined;
  const email = row?.email ?? null;
  return email != null && email.length > 0 ? email : null;
}

function stateOf(email: string | null): NotifyEmailStatus["state"] {
  if (email == null) return "none";
  const row = getDb()
    .prepare(
      `SELECT verified_at, unsubscribe_at, hard_bounce_at FROM notify_emails WHERE email = ?`
    )
    .get(email) as
    | { verified_at: number | null; unsubscribe_at: number | null; hard_bounce_at: number | null }
    | undefined;
  if (row == null) return "pending";
  if (row.unsubscribe_at != null || row.hard_bounce_at != null) return "inactive";
  return row.verified_at == null ? "pending" : "verified";
}

/** 把地址绑到该 member 这一行；同一地址在别处的绑定不动（换地址只影响本空间）。 */
function bindMembersEmail(spaceId: string, memberId: string, email: string): void {
  getDb()
    .prepare(`UPDATE space_members SET email = ? WHERE space_id = ? AND member_id = ?`)
    .run(email, spaceId, memberId);
}

/** 没有 space_members 再引用这个地址 → 连同 token 一起物理删除（"彻底不留"）。 */
function purgeEmailIfUnused(email: string): void {
  const db = getDb();
  const used = db
    .prepare(`SELECT 1 FROM space_members WHERE email = ? LIMIT 1`)
    .get(email) as unknown;
  if (used != null) return;
  db.prepare(`DELETE FROM notify_tokens WHERE email = ?`).run(email);
  db.prepare(`DELETE FROM notify_emails WHERE email = ?`).run(email);
}

function newToken(): string {
  return randomBytes(24).toString("base64url");
}

/** 验证链接：24 小时有效、一次性（重设邮箱会重新签发一枚旧的即失效）。 */
function ensureVerifyToken(email: string, now: number): string {
  const db = getDb();
  db.prepare(`DELETE FROM notify_tokens WHERE email = ? AND kind = 'verify' AND used_at IS NULL`).run(email);
  const token = newToken();
  db.prepare(
    `INSERT INTO notify_tokens (token, email, kind, expires_at, created_at) VALUES (?, ?, 'verify', ?, ?)`
  ).run(token, email, now + 24 * 60 * 60_000, now);
  return token;
}

/**
 * 退订链接：每个地址一枚、长期有效、可反复点（每封信底部都印同一个）。
 * 刻意**不设 To-BE（用后即焚）**：撕掉的链接会出现在历史邮件里，用户点开只看到失效页。
 */
export function ensureUnsubscribeToken(email: string, now: number): string {
  const db = getDb();
  const row = db
    .prepare(`SELECT token FROM notify_tokens WHERE email = ? AND kind = 'unsubscribe' LIMIT 1`)
    .get(email) as { token: string } | undefined;
  if (row) return row.token;
  const token = newToken();
  db.prepare(
    `INSERT INTO notify_tokens (token, email, kind, expires_at, created_at) VALUES (?, ?, 'unsubscribe', ?, ?)`
  ).run(token, email, now + 10 * 365 * 24 * 60 * 60_000, now);
  return token;
}

/** 审计：**绝不记邮箱地址本身**（那是服务端唯一能直接指向真人的字段）。 */
function logNotifyActivity(entranceId: string, spaceId: string, kind: string): void {
  logActivity({ entranceId, spaceId, kind, detail: {}, meta: NO_META });
}
