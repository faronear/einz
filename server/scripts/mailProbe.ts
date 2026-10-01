/**
 * 邮件管道的连通性探针：`npm run mail:probe`
 *
 * 为什么必须先跑它：**这件事最大的风险不在代码，而在出网**。服务器在中国大陆，
 * Oracle Email Delivery 的 SMTP 在境外；国内云厂商普遍封杀出站 25 端口，587 也不是
 * 每一家都放行。先花十秒确认"这条路通不通"，再决定要不要配 A 记录、SPF/DKIM——
 * 顺序反了就是配完一堆 DNS 才发现 TCP 根本出不去。
 *
 * 用法：
 *   EINZ_SMTP_HOST=smtp.email.<region>.oci.oraclecloud.com \
 *   EINZ_SMTP_PORT=587 EINZ_SMTP_USER=ocid1.user.… EINZ_SMTP_PASS='…' \
 *   EINZ_MAIL_FROM='Einz <notify@einz.yuanjinx.com>' \
 *   EINZ_PROBE_TO=you@example.com npm run mail:probe
 */
import { loadMailConfig, createMailer, MailError } from "../src/mailer.js";

async function main(): Promise<void> {
  const to = (process.env.EINZ_PROBE_TO ?? "").trim();
  const cfg = loadMailConfig();
  if (cfg == null) {
    console.error("✗ 缺少 SMTP 配置（需要 EINZ_SMTP_HOST / EINZ_SMTP_USER / EINZ_SMTP_PASS / EINZ_MAIL_FROM）");
    process.exitCode = 1;
    return;
  }
  if (to.length === 0) {
    console.error("✗ 缺少 EINZ_PROBE_TO（收信地址：探针会真的发出一封测试信）");
    process.exitCode = 1;
    return;
  }

  console.log(`→ ${cfg.host}:${cfg.port} secure=${cfg.secure} from=${cfg.from} to=${to}`);
  const started = Date.now();
  try {
    await createMailer(cfg).send({
      to,
      subject: "[Einz] 邮件管道探针",
      text: [
        "这是一封探针邮件：SMTP 通路正常，且这封邮件成功抵达了收件箱。",
        "",
        `发件：${cfg.from}`,
        `站点：${cfg.baseUrl}`,
        `耗时：${Date.now() - started} ms`,
      ].join("\n"),
    });
    console.log(`✓ 已投递（${Date.now() - started} ms）——没收到的话先看垃圾箱：那说明 SPF/DKIM 还没配好。`);
  } catch (err) {
    const permanent = err instanceof MailError && err.permanent;
    console.error(`✗ 投递失败（${Date.now() - started} ms，${permanent ? "服务器明确拒收" : "临时故障/连不通"}）`);
    console.error(String(err instanceof Error ? err.message : err));
    if (!permanent) {
      console.error(
        [
          "",
          "排查顺序：",
          "  1) nc -vz <host> <port> 看 TCP 通不通（连不上 = 出口被封，换 587 或换服务商）",
          "  2) 云厂商安全组/出入站规则是否放行出站",
          "  3) 用户名是 ocid1.user.…，密码是控制台生成的 SMTP 凭据（不是登录密码）",
          "  4) 发件地址必须是 Email Delivery 里登记过的 approved sender",
        ].join("\n")
      );
    }
    process.exitCode = 1;
  }
}

void main();
