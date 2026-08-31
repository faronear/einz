/**
 * 邀请码 CLI：npm run invite [-- --person b --hours 24]
 * 生成一次性、短时效的邀请码（新设备凭它 POST /devices/enroll 动态登记，无需重启 Server）。
 * person 默认 b（第二使用者）；hours 默认 24。
 * 依赖环境变量：ONLYSPACE_DB（可选，有默认值）。
 */
import { randomInt } from "node:crypto";
import { loadConfig } from "../src/config.js";
import { getDb, openDb } from "../src/db.js";

// 生产 VPS 上 config/db 位于 deployment/ 下，必须显式传 env（docker 容器内路径不可用于宿主机）。
// 缺失时给出清晰提示，避免落入默认路径（server/ 下不存在）产生误导性错误。
if (!process.env.ONLYSPACE_DB || !process.env.ONLYSPACE_CONFIG) {
  console.error(`⚠️ 缺少环境变量：ONLYSPACE_DB 与 ONLYSPACE_CONFIG 必须显式设置`);
  console.error(`   生产 VPS 示例：`);
  console.error(`     ONLYSPACE_CONFIG=<部署目录>/deployment/config/config.json \\`);
  console.error(`     ONLYSPACE_DB=<部署目录>/deployment/data/app.db \\`);
  console.error(`     npm run invite -- --person person-b`);
  process.exit(1);
}

// 生成可读邀请码：大写字母+数字（去混淆 I/O/0/1），5 字符一组，共 20 字符
const ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
function genCode(len = 20): string {
  let s = "";
  for (let i = 0; i < len; i++) s += ALPHABET[randomInt(ALPHABET.length)];
  return s.match(/.{1,5}/g)!.join("-");
}

const personArg = process.argv.indexOf("--person");
const hoursArg = process.argv.indexOf("--hours");
const hours = hoursArg >= 0 ? Number(process.argv[hoursArg + 1]) : 24;

openDb();
const cfg = loadConfig();
const db = getDb();

// 校验 person 是白名单中的已知 person（防打错）；默认取第二个 person（= 对方，给新设备加入用）
const knownPersons = [...new Set(cfg.devices.map((d) => d.person_id))];
const person = personArg >= 0 ? process.argv[personArg + 1] : (knownPersons[1] ?? knownPersons[0]);
if (!knownPersons.includes(person)) {
  console.error(`⚠️ person 不在白名单: ${person}（已知: ${knownPersons.join(", ")}）`);
  process.exit(1);
}

const now = Date.now();
const expiresAt = now + hours * 3600_000;
const code = genCode();

db.prepare(`INSERT INTO invites (invite_code, person_id, status, created_at, expires_at) VALUES (?, ?, 'pending', ?, ?)`)
  .run(code, person, now, expiresAt);

console.log(`✅ 邀请码已生成（一次性，${hours}h 内有效）:`);
console.log(`   邀请码: ${code}`);
console.log(`   person: ${person}`);
console.log(`   过期时间: ${new Date(expiresAt).toISOString()}`);
console.log(`   给新设备使用: POST /devices/enroll { device_id, public_key, invite_code }`);
