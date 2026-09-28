#!/usr/bin/env node
/**
 * Einz macOS 自动更新脚本（2026-09-28 老板定：放弃 Sparkle，用轻量脚本）。
 *
 * 从 GitHub Releases 检查最新 macOS dist 产物版本，**远程比本地新才下载覆盖**
 * /Applications/einz.app（老板 2026-09-28 要求）。
 *
 * 版本检查用旁车小文件 *.version.txt（CI 随 zip 一起上传，内容就是版本号一行）：
 * 先拉几十字节的 txt 比版本，新了才下载几百 MB 的 zip——Release 资产名固定
 * 不带版本号（固定名才能自动覆盖老文件、不堆积多版本），所以版本号单独记录。
 * 流程：拉 version.txt → 与本地比较 →（更新时）下载 zip → ditto 解压
 * → 备份现有 app → 原子替换（mv）→ 清理。
 *
 * 用法：
 *   node scripts/updateMacosApp.js            # 比版本，更新才覆盖
 *   node scripts/updateMacosApp.js --force    # 跳过版本比较，强制覆盖
 *
 * 前置：
 *   - 本机已装好一次 einz.app（首次安装仍需手动，见 buildMacos.sh 产物）
 *   - Releases 里有 einz-app-macos-dist.zip + einz-app-macos-dist.version.txt
 *     （buildMultiPlatform.yml 的 macos job 上传，或本机打包后手动补传）
 *
 * 说明：
 *   - 下载用 curl（带重试）：node fetch 在老板网络环境下直连 GitHub 失败率高
 *     （2026-09-28 实测 fetch failed / curl 也要多试几次），curl 的 --retry 更扛得住。
 *   - 版本格式 yymm.ddhh.mm（见 appVersion.js），去点成整数直接比大小，
 *     单调递增无歧义。
 *   - 用 ditto 解压：产物 zip 里的 Frameworks 有符号链接，unzip 会破坏签名结构
 *     （与 buildMacos.sh 打包口径一致，ditto 能完整保留符号链接与权限）。
 *   - 替换用同卷 mv（临时目录建在 /tmp，macOS 上 /tmp 与 /Applications 同卷）：
 *     原子操作，解压中途失败不会留下半个 app。
 *   - 旧版备份到 /tmp，安装失败自动放回；成功则清理。
 *   - app 正在运行时替换文件不影响运行中的进程，重启 app 即新版。
 */
'use strict';

const { execFileSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const RELEASE_URL =
  'https://github.com/faronear/einz/releases/download/latest/einz-app-macos-dist.zip';
// 版本旁车文件（CI 每次构建随 zip 一起上传，内容就是版本号一行，如 2609.2805.59）：
// 固定文件名 + 固定 tag，新构建直接覆盖老文件，不会堆积多版本（老板 2026-09-28）
const VERSION_URL =
  'https://github.com/faronear/einz/releases/download/latest/einz-app-macos-dist.version.txt';
const APP_NAME = 'einz.app';
const TARGET = `/Applications/${APP_NAME}`;
const BACKUP_DIR = path.join(os.tmpdir(), 'einz-update-backup');

const FORCE = process.argv.includes('--force');

/** 打印命令再执行，返回 stdout（输出不透传，给脚本加工用）。 */
function run(cmd, args) {
  console.log(`==> ${cmd} ${args.join(' ')}`);
  return execFileSync(cmd, args, { stdio: ['ignore', 'pipe', 'inherit'] }).toString();
}

/** 下载（curl 带重试）到指定路径；失败抛错（stdio inherit 已把错误打出来）。 */
function download(url, dest) {
  console.log(`==> 下载 ${url}`);
  execFileSync('/usr/bin/curl', [
    '-fSL',             // 失败即错 + 跟随重定向
    '--retry', '3',     // 网络抖动重试（老板网络访问 GitHub 不稳，2026-09-28 实测）
    '--retry-delay', '2',
    '--connect-timeout', '20',
    '--max-time', '600',
    '-o', dest,
    url,
  ], { stdio: 'inherit' });
  return fs.statSync(dest).size;
}

/** 拉远程版本号：version.txt 里就一行版本号（容忍首尾空白）。失败返回 null。 */
function fetchRemoteVersion() {
  const tmp = path.join(os.tmpdir(), 'einz-update-version.txt');
  try {
    execFileSync('/usr/bin/curl', [
      '-fsSL', '--retry', '3', '--retry-delay', '2',
      '--connect-timeout', '20', '--max-time', '60', '-o', tmp, VERSION_URL,
    ], { stdio: 'inherit' });
    const v = fs.readFileSync(tmp, 'utf8').trim();
    return /^\d{4}\.\d{4}\.\d{2}$/.test(v) ? v : null;
  } catch {
    return null;
  } finally {
    fs.rmSync(tmp, { force: true });
  }
}

/** 从已下载的 zip 里读 app 版本（旁车 txt 缺失时的兜底）。 */
function readZipVersion(zipPath) {
  const plist = execFileSync('/usr/bin/unzip', [
    '-p', zipPath, `${APP_NAME}/Contents/Info.plist`,
  ]);
  const raw = plist.toString('latin1');
  // Info.plist 可能是二进制格式：直接抓版本号模式（yymm.ddhh.mm）
  const match = raw.match(/(\d{4}\.\d{4}\.\d{2})/);
  if (!match) throw new Error('zip 包内 Info.plist 读不到 CFBundleShortVersionString');
  return match[1];
}

/** 版本比较：'2609.2805.59' → 2609280559，纯数字比大小（格式见 appVersion.js）。 */
function versionRank(v) {
  return Number(v.replace(/\./g, ''));
}

function main() {
  if (!fs.existsSync(TARGET) && !FORCE) {
    console.error(`❌ 本机没有 ${TARGET}：首次安装请手动装一次（buildMacos.sh 产物），之后才能用本脚本更新`);
    process.exit(1);
  }
  const localVersion = fs.existsSync(TARGET)
    ? run('/usr/bin/defaults', ['read', `${TARGET}/Contents/Info`, 'CFBundleShortVersionString']).trim()
    : '';

  // 1) 先拉小文件比版本，新了才下 zip
  let remoteVersion = fetchRemoteVersion();
  if (remoteVersion) {
    console.log(`==> 本地版本 ${localVersion || '（未安装）'} · 远程版本 ${remoteVersion}`);
    if (!FORCE && versionRank(remoteVersion) <= versionRank(localVersion)) {
      console.log('✅ 本地已是最新，无需更新');
      return;
    }
  } else if (!FORCE) {
    console.log('⚠️ 拿不到远程版本号（version.txt 未上传？）——继续下载 zip 后从包内读版本再比');
  }
  if (FORCE) console.log('（--force：跳过版本比较，强制覆盖）');

  // 2) 下载 zip；旁车 txt 缺失时从包内读版本兜底
  const zipPath = path.join(os.tmpdir(), 'einz-update-download.zip');
  const size = download(RELEASE_URL, zipPath);
  if (size < 1024 * 1024) {
    // 产物至少几十 MB：太小说明拿到的不是真 zip（如 GitHub 错误页）
    console.error(`❌ 下载内容仅 ${(size / 1024).toFixed(0)} KB，不像 app 产物，中止`);
    process.exit(1);
  }
  console.log(`   ${(size / 1024 / 1024).toFixed(1)} MB`);
  if (!remoteVersion) {
    remoteVersion = readZipVersion(zipPath);
    console.log(`==> 包内版本 ${remoteVersion} · 本地版本 ${localVersion || '（未安装）'}`);
    if (!FORCE && versionRank(remoteVersion) <= versionRank(localVersion)) {
      console.log('✅ 本地已是最新，无需更新');
      fs.rmSync(zipPath, { force: true });
      return;
    }
  }

  // 3) 解压到临时目录：/tmp 与 /Applications 同卷（macOS 根卷），mv 替换是原子的
  const extractDir = fs.mkdtempSync(path.join(os.tmpdir(), 'einz-update-'));
  console.log('==> ditto 解压（保留符号链接与签名结构）');
  execFileSync('/usr/bin/ditto', ['-x', '-k', zipPath, extractDir], { stdio: 'inherit' });

  const extractedApp = path.join(extractDir, APP_NAME);
  if (!fs.existsSync(extractedApp)) {
    console.error(`❌ zip 里没有 ${APP_NAME}，产物格式不对，中止`);
    process.exit(1);
  }

  // 4) 备份现有 app（存在才备）：失败可从 BACKUP_DIR 手动放回
  fs.rmSync(BACKUP_DIR, { recursive: true, force: true });
  if (fs.existsSync(TARGET)) {
    console.log(`==> 备份现有 app 到 ${BACKUP_DIR}`);
    fs.mkdirSync(BACKUP_DIR, { recursive: true });
    fs.renameSync(TARGET, path.join(BACKUP_DIR, APP_NAME));
  }

  // 5) 原子替换 + 清理
  try {
    console.log(`==> 安装到 ${TARGET}`);
    fs.renameSync(extractedApp, TARGET);
  } catch (err) {
    // mv 失败（如权限）：把备份放回去，别让老板没 app 用
    if (fs.existsSync(path.join(BACKUP_DIR, APP_NAME))) {
      fs.renameSync(path.join(BACKUP_DIR, APP_NAME), TARGET);
      console.log('   已从备份还原旧版');
    }
    throw err;
  } finally {
    fs.rmSync(extractDir, { recursive: true, force: true });
    fs.rmSync(zipPath, { force: true });
  }

  // 6) 去掉"从网络下载"的隔离标记：dist 渠道 Developer ID 签名已过本机 Gatekeeper
  // 校验，quarantine 会让每次启动都弹确认框
  run('/usr/bin/xattr', ['-dr', 'com.apple.quarantine', TARGET]);
  console.log(`✅ 已更新到 ${remoteVersion}（${TARGET}；若 app 正在运行，重启后生效）`);
}

try {
  main();
} catch (err) {
  console.error('❌ 更新失败：', err.message);
  process.exit(1);
}
