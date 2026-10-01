/**
 * 邮件管道的连通性探针：`npm run mail:probe`
 *
 * 为什么必须先跑它：**这件事最大的风险不在代码，而在出网**。服务器在中国大陆，
 * Oracle Email Delivery 的 SMTP 在境外；国内云厂商普遍封杀出站 25 端口，587 也不是
 * 每一家都放行。先花十秒确认"这条路通不通"，再决定要不要配 A 记录、SPF/DKIM——
 * 顺序反了就是配完一堆 DNS 才发现 TCP 根本出不去。
 *
 * 用法（两种，任选）：
 *   1) 环境变量已经在 `deployment/.env` 里（服务器上的常规形态）→ 直接跑，脚本会自己
 *      去读 `../../deployment/.env`（可用 `EINZ_ENV_FILE` 指向别处）：
 *        EINZ_PROBE_TO=you@example.com npm run mail:probe
 *   2) 临时用一组值试（例如在本机 iMac 上验凭据）→ 直接写在命令行上，命令行优先：
 *        EINZ_SMTP_HOST=smtp.email.<region>.oci.oraclecloud.com \
 *        EINZ_SMTP_PORT=587 EINZ_SMTP_USER=ocid1.user.… EINZ_SMTP_PASS='…' \
 *        EINZ_MAIL_FROM='Einz <hi@tic.cc>' \
 *        EINZ_PROBE_TO=you@example.com npm run mail:probe
 *
 * 为什么要自己读 .env（而不是让用户先 source）：**服务端进程不读 .env**——它的变量由
 * docker compose 注入（deployment/docker-compose.*.yml）。但探针是**运维手动在宿主机上
 * 跑**的，那一刻 shell 里什么都没有，于是"明明填好了 .env 却报缺配置"。这个脚本是运维
 * 工具，替它把这一步做掉是合理的；服务端那条路径刻意保持"只认环境变量"，避免容器里
 * 悄悄吃到一个陈旧的 .env。
 */
import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { loadMailConfig, createMailer, MailError } from "../src/mailer.js";

/**
 * 从 `KEY=VALUE` 文件里补环境变量（**不覆盖**已有的真实环境变量：命令行优先）。
 * 只认最简单的形态：忽略空行与 `#` 注释、去掉行尾注释不做、去掉 `export ` 前缀、
 * 剥掉成对的引号。够用了——别把它做成通用 dotenv。
 */
function loadEnvFile(path: string): number {
  if (!existsSync(path)) return 0;
  let loaded = 0;
  for (const rawLine of readFileSync(path, "utf8").split("\n")) {
    const line = rawLine.trim();
    if (line.length === 0 || line.startsWith("#")) continue;
    const eq = line.indexOf("=");
    if (eq <= 0) continue;
    const key = line.slice(0, eq).trim().replace(/^export\s+/, "");
    let value = line.slice(eq + 1).trim();
    const quoted =
      (value.startsWith("'") && value.endsWith("'")) ||
      (value.startsWith('"') && value.endsWith('"'));
    if (quoted && value.length >= 2) value = value.slice(1, -1);
    if (key.length === 0 || process.env[key] !== undefined) continue; // 已有的优先
    process.env[key] = value;
    loaded += 1;
  }
  return loaded;
}

/** 探针所在目录 → 仓库根的 deployment/.env（可用 EINZ_ENV_FILE 覆盖）。 */
const ENV_FILE =
  process.env.EINZ_ENV_FILE ??
  resolve(import.meta.dirname ?? process.cwd(), "../../deployment/.env");

async function main(): Promise<void> {
  const loaded = loadEnvFile(ENV_FILE);
  if (loaded > 0) console.log(`· 已加载 ${ENV_FILE}（${loaded} 个变量；命令行上的值优先）`);

  const to = (process.env.EINZ_PROBE_TO ?? "").trim();
  const cfg = loadMailConfig();
  if (cfg == null) {
    console.error("✗ 缺少 SMTP 配置（需要 EINZ_SMTP_HOST / EINZ_SMTP_USER / EINZ_SMTP_PASS / EINZ_MAIL_FROM）");
    console.error(`  已尝试读取：${ENV_FILE}（不存在或里面没这几项；也可用 EINZ_ENV_FILE 指定别的文件）`);
    console.error("  或直接写在命令行上（见本文件顶部注释的用法 2）。");
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
