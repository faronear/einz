/**
 * 邮件通知（notifier）回归：**节流四道闸门**是这个功能唯一真正难的地方，
 * 也是全部测试目标——发信本身换个 SMTP 凭据就能试，闸门错了却是天天扰民。
 *
 * 四道闸门（notifier.planNotifications）：
 *   ① 真有未读 ② 真的走开了（未读到了之后没回来过）③ 静默窗已过 ④ 冷却 + 日上限
 * 另外测两件副产品：跨空间按地址聚合成一封、tick 的发送记账。
 *
 * 运行：npm test（tsx test/notify.test.ts）
 */
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

import { hashSessionToken } from "../src/auth.js";
import { getDb, openDb } from "../src/db.js";
import {
  buildSummaryMail,
  notifyParams,
  planNotifications,
  runNotifyTick,
  type NotifyPlan,
} from "../src/notifier.js";
import type { MailConfig, Mailer, OutgoingMail } from "../src/mailer.js";

// 闸门参数：静默 2 分钟 / 冷却 30 分钟 / 日上限 8（老板 2026-10-01 选定档）。
// notifyParams() 每次现读环境变量，所以这里直接改 env 就能把时间拉到可控范围。
process.env.EINZ_NOTIFY_QUIET_MS = "120000";
process.env.EINZ_NOTIFY_COOLDOWN_MS = "1800000";
process.env.EINZ_NOTIFY_DAILY_MAX = "8";

const SPACE = "space-a";
const OTHER_SPACE = "space-b";
const ME = "member-me";
const PEER = "member-peer";
const PEER_2 = "member-peer-2";
const MY_DEVICE = "dev-me";
const PEER_DEVICE = "dev-peer";
const PEER_2_DEVICE = "dev-peer-2";
const EMAIL = "luk@example.com";

interface SeedOpts {
  /** 我的最后活动时刻（默认：一小时前，早早离线）。 */
  myActivityAt?: number;
  /** 对方消息的创建时刻（默认：10 分钟前）。 */
  messagesAt?: number;
  /** 我读到第几条（默认：没读过 → 全未读）。 */
  readUpto?: number;
  /** 对方是不是也发给我在别的空间的身份（跨空间聚合测试用）。 */
  alsoOtherSpace?: boolean;
  unverified?: boolean;
}

function seed(opts: SeedOpts = {}): number {
  const db = getDb();
  const now = Date.now();
  const messagesAt = opts.messagesAt ?? now - 10 * 60_000;
  const myActivityAt = opts.myActivityAt ?? now - 60 * 60_000;

  db.prepare(
    `INSERT INTO spaces (space_id, space_address, space_public_key, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?)`,
  ).run(SPACE, "addr-a", "pk-a", now, now);
  db.prepare(
    `INSERT INTO spaces (space_id, space_address, space_public_key, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?)`,
  ).run(OTHER_SPACE, "addr-b", "pk-b", now, now);

  // 我只有一条通道，且早就没活动了（离线）
  db.prepare(
    `INSERT INTO entrances (entrance_id, member_id, public_key, status, last_seen, created_at)
     VALUES (?, ?, 'pk', 'active', ?, ?)`,
  ).run(MY_DEVICE, ME, myActivityAt, now);
  // 注意 ws.ts 里 last_seen 是"最后活动证据"，干净断开时置 0、把时刻落到 offline_since；
  // 这里用一个偏早的 last_seen 模拟"离线很久了"
  db.prepare(
    `INSERT INTO entrances (entrance_id, member_id, public_key, status, last_seen, offline_since, created_at)
     VALUES (?, ?, 'pk', 'active', 0, ?, ?)`,
  ).run(PEER_DEVICE, PEER, myActivityAt, now);
  db.prepare(
    `INSERT INTO entrances (entrance_id, member_id, public_key, status, last_seen, offline_since, created_at)
     VALUES (?, ?, 'pk', 'active', 0, ?, ?)`,
  ).run(PEER_2_DEVICE, PEER_2, myActivityAt, now);

  db.prepare(
    `INSERT INTO space_members (space_id, member_id, slot, display_name, email, status, joined_at)
     VALUES (?, ?, ?, ?, ?, 'active', ?)`,
  ).run(SPACE, ME, 0, "我", EMAIL, now);
  db.prepare(
    `INSERT INTO space_members (space_id, member_id, slot, display_name, status, joined_at)
     VALUES (?, ?, 1, '小张', 'active', ?)`,
  ).run(SPACE, PEER, now);
  db.prepare(
    `INSERT INTO space_members (space_id, member_id, slot, display_name, status, joined_at)
     VALUES (?, ?, 2, NULL, 'active', ?)`,
  ).run(SPACE, PEER_2, now);

  db.prepare(
    `INSERT INTO space_members (space_id, member_id, slot, display_name, status, joined_at)
     VALUES (?, ?, 1, '小李', 'active', ?)`,
  ).run(OTHER_SPACE, PEER, now);

  db.prepare(
    `INSERT INTO notify_emails (email, verified_at, created_at)
     VALUES (?, ?, ?)`,
  ).run(EMAIL, opts.unverified ? null : now, now);

  const msg = db.prepare(
    `INSERT INTO messages (message_id, space_id, sender_entrance_id, sender_member_id, type, key_version, nonce, ciphertext, server_sequence, created_at)
     VALUES (?, ?, ?, ?, 'text', 1, 'n', 'c', ?, ?)`,
  );
  msg.run("m1", SPACE, PEER_DEVICE, PEER, 1, messagesAt);
  msg.run("m2", SPACE, PEER_DEVICE, PEER, 2, messagesAt);
  msg.run("m3", SPACE, PEER_2_DEVICE, PEER_2, 3, messagesAt);
  msg.run("m4", SPACE, MY_DEVICE, ME, 4, messagesAt); // 我自己发的 ≠ 未读
  if (opts.alsoOtherSpace) {
    // 同一位（另一个空间里的同一个地址）也给我发了：member_id 不同、邮箱地址相同
    db.prepare(
      `INSERT INTO space_members (space_id, member_id, slot, display_name, email, status, joined_at)
       VALUES (?, ?, ?, ?, ?, 'active', ?)`,
    ).run(OTHER_SPACE, ME, 0, "我", EMAIL, now);
    msg.run("m5", OTHER_SPACE, PEER_DEVICE, PEER, 1, messagesAt);
  }

  if (opts.readUpto != null) {
    db.prepare(
      `INSERT INTO receipts (space_id, member_id, delivered_upto_seq, read_upto_seq, updated_at)
       VALUES (?, ?, ?, ?, ?)`,
    ).run(SPACE, ME, opts.readUpto, opts.readUpto, Date.now());
  }
  return now;
}

function withDb(fn: () => void): void {
  const dir = mkdtempSync(join(tmpdir(), "einz-notify-"));
  try {
    openDb(join(dir, "notify.db"));
    fn();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function fakeMailer(sent: OutgoingMail[]): Mailer {
  const config: MailConfig = {
    host: "smtp.invalid",
    port: 587,
    secure: false,
    user: "u",
    pass: "p",
    from: "Einz <notify@example.com>",
    baseUrl: "https://einz.yuanjinx.com",
  };
  return {
    config,
    async send(mail: OutgoingMail): Promise<void> {
      sent.push(mail);
    },
  };
}

test("邮件通知：① 必须点过验证链接才发得住——未验证地址一个计划都没有", () => {
  withDb(() => {
    const now = seed({ unverified: true });
    assert.equal(planNotifications(now).length, 0, "没验证 = 不许发出去（别把别人地址当出口）");
  });
});

test("邮件通知：② 未读才算数：自己发的、已读过的都不进计划", () => {
  withDb(() => {
    const now = seed();
    const plans = planNotifications(now);
    assert.equal(plans.length, 1);
    assert.equal(plans[0]!.total, 3, "m1/m2/m3 是对方的，m4 是我自己发的不算未读");
  });
});

test("邮件通知：② 全读过 → 没有计划", () => {
  withDb(() => {
    const now = seed({ readUpto: 4 });
    assert.equal(planNotifications(now).length, 0);
  });
});

test("邮件通知：③ 静默窗内不发（连珠炮合成一封）", () => {
  withDb(() => {
    const now = Date.now();
    seed({ messagesAt: now - 30_000 }); // 30 秒前还在发 → 静默窗（2 分钟）没到
    assert.equal(planNotifications(now).length, 0, "还在聊 → 再等等，让这一串并入一封信");
  });
});

test("邮件通知：③ 静默窗一到，20 条 ≠ 20 封：聚成一封摘要", () => {
  withDb(() => {
    const now = Date.now();
    seed({ messagesAt: now - 10 * 60_000 });
    const plans = planNotifications(now);
    assert.equal(plans.length, 1);
    const plan: NotifyPlan = plans[0]!;
    assert.equal(plan.total, 3);
    assert.equal(plan.entries.length, 2, "两个发送者 → 两行摘要（不按消息条数铺开）");
    const names = plan.entries.map((e) => e.senderName).sort();
    assert.deepEqual(names, ["对方", "小张"], "没名字的那位退到「对方」");
  });
});

test("邮件通知：④ 冷却期内不发；日上限到了也不发", () => {
  withDb(() => {
    const now = seed();
    const db = getDb();
    const { cooldownMs } = notifyParams();

    // 冷却：25 分钟前发过（< 30 分钟）
    db.prepare(`UPDATE notify_emails SET last_sent_at = ? WHERE email = ?`).run(now - 25 * 60_000, EMAIL);
    assert.equal(planNotifications(now).length, 0, "cooldown 内");
    db.prepare(`UPDATE notify_emails SET last_sent_at = ? WHERE email = ?`).run(now - cooldownMs - 1, EMAIL);
    assert.equal(planNotifications(now).length, 1, "冷却结束 → 恢复");

    // 日上限：今天已发 8 封
    db.prepare(`UPDATE notify_emails SET sent_day = ?, sent_count = 8 WHERE email = ?`).run(
      new Date(now).toISOString().slice(0, 10),
      EMAIL,
    );
    assert.equal(planNotifications(now).length, 0, "日上限到 → 本日不再打扰");
    // 换一天（sent_day 过期）→ 恢复
    db.prepare(`UPDATE notify_emails SET sent_day = ? WHERE email = ?`).run("2020-01-01", EMAIL);
    assert.equal(planNotifications(now).length, 1);
  });
});

test("邮件通知：⑤ 他回来过就没必要打扰（消息到了之后有活动 → 不发）", () => {
  withDb(() => {
    const now = Date.now();
    const messagesAt = now - 10 * 60_000;
    seed({ messagesAt, myActivityAt: now - 5 * 60_000 }); // 消息之后他又上线过
    assert.equal(
      planNotifications(now).length,
      0,
      "他回来过就有机会看到了——这一刀比其他三刀加起来省得还多",
    );
  });
});

test("邮件通知：⑥ 同一个邮箱在两个空间有未读 → 合并成一封", () => {
  withDb(() => {
    const now = seed({ alsoOtherSpace: true });
    const plans = planNotifications(now);
    assert.equal(plans.length, 1, "一个地址一封信");
    assert.equal(plans[0]!.total, 4, "两个空间的未读加总");
    assert.equal(
      new Set(plans[0]!.entries.map((e) => e.spaceId)).size,
      2,
      "摘要里同时含两个空间的来源",
    );
  });
});

test("邮件通知：⑦ 正文里绝不能有消息内容——只有谁/几条/几点 + 退订链接", () => {
  withDb(() => {
    const now = seed();
    const plan = planNotifications(now)[0]!;
    const mail = buildSummaryMail(
      plan,
      { baseUrl: "https://einz.yuanjinx.com" } as MailConfig,
      "tok-abc",
    );
    assert.match(mail.subject, /3 条未读消息/);
    assert.match(mail.text!, /小张/);
    assert.match(mail.text!, /打开 Einz 就能看到/);
    assert.match(mail.text!, /https:\/\/einz\.yuanjinx\.com\/notify\/unsubscribe\?token=tok-abc/);
    // 红线：密文/明文内容一个字都不许出现（服务端本来也只有密文可拿到）
    assert.doesNotMatch(mail.text!, /\bc\b|今晚|secret/);
  });
});

test("邮件通知：⑧ tick 真的投递并记账（冷却与日计数生效）", async () => {
  await new Promise<void>((resolve, reject) => {
    const dir = mkdtempSync(join(tmpdir(), "einz-notify-tick-"));
    const done = (err?: unknown): void => {
      rmSync(dir, { recursive: true, force: true });
      if (err) reject(err);
      else resolve();
    };
    try {
      openDb(join(dir, "notify.db"));
      const now = seed();
      const sent: OutgoingMail[] = [];
      void runNotifyTick({ now, mailer: fakeMailer(sent) }).then((summary) => {
        try {
          assert.deepEqual(summary, { planned: 1, sent: 1, failures: 0 });
          assert.equal(sent.length, 1);
          assert.equal(sent[0]!.to, EMAIL);

          const row = getDb()
            .prepare(`SELECT last_sent_at, sent_day, sent_count FROM notify_emails WHERE email = ?`)
            .get(EMAIL) as { last_sent_at: number; sent_day: string; sent_count: number };
          assert.equal(row.last_sent_at, now);
          assert.equal(row.sent_count, 1);

          // 立刻再跑一轮：还在冷却里 → 一封不发
          void runNotifyTick({ now, mailer: fakeMailer(sent) }).then((second) => {
            try {
              assert.deepEqual(second, { planned: 0, sent: 0, failures: 0 });
              assert.equal(sent.length, 1, "第二轮一封都没多发出去");
              done();
            } catch (e) {
              done(e);
            }
          });
        } catch (e) {
          done(e);
        }
      });
    } catch (e) {
      done(e);
    }
  });
});
