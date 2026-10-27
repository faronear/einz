#!/usr/bin/env node
// ASC 年龄分级问卷查看/补答（scripts/ascAgeRating.mjs）
//
// 背景（2026-10-27）：ASC 提审报 "You must respond to the required age ratings
// questions"。原因：Apple 会增量往 ageRatingDeclaration 追加新必答题（如
// socialMedia、ageAssurance），追加后所有 app 分级回到「待回应」状态，拦住
// 新提交——即使几天前刚填过且已算出 4+/12+。解法：把 null 的必答字段补上。
//   本次补的：socialMedia=false（einz 邀请制封闭私聊/群聊，无公开发现/关注/
//   信息流，不是社交媒体）；ageAssurance=false（无成人内容，目标全年龄）。
//
// 凭据（不入 git，见 .gitignore 的 *.nogit.nosf 规则）：
//   - API key 配置：_simsim.nogit.nosf/apikey-apple.simsim.js
//     （appStoreConnectApi.{keyid, issuerId}）
//   - 私钥：~/private_keys/AuthKey_<keyid>.p8
//   - ⚠ JWT 必须 aud='appstoreconnect-v1'，不带 aud 一律 401
//
// 依赖 jose（脚本目录自带 node_modules，或 npm i -g jose 后改 import）。
//
// 用法：
//   node scripts/ascAgeRating.mjs                 # 查看问卷现状（标出 null 字段）
//   node scripts/ascAgeRating.mjs patch '<json>'  # 补答，如 '{"socialMedia":false}'
//     或交互外传字段：node scripts/ascAgeRating.mjs patch socialMedia=false

import { SignJWT, importPKCS8 } from 'jose';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, '..');
const CRED_MODULE = path.join(repoRoot, '_simsim.nogit.nosf/apikey-apple.simsim.js');

// 固定 app：einz（bundle cc.tic.einz，ASC id 见下）。换 app 时改这里。
const APP_ID = '6814318911';

// ---- ASC API 封装 ----

async function loadCredentials() {
  const mod = await import('file://' + CRED_MODULE);
  const cfg = mod.default?.appStoreConnectApi ?? mod.appStoreConnectApi;
  if (!cfg?.keyid || !cfg?.issuerId) {
    console.error(`❌ 凭据不完整：${CRED_MODULE} 需含 appStoreConnectApi.{keyid, issuerId}`);
    process.exit(1);
  }
  const keyPath = path.join(os.homedir(), 'private_keys', `AuthKey_${cfg.keyid}.p8`);
  if (!fs.existsSync(keyPath)) {
    console.error(`❌ 私钥不存在：${keyPath}`);
    process.exit(1);
  }
  return { cfg, p8: fs.readFileSync(keyPath, 'utf8') };
}

async function makeAsc(cfg, p8) {
  const key = await importPKCS8(p8, 'ES256');
  async function token() {
    return new SignJWT({ aud: 'appstoreconnect-v1' })
      .setProtectedHeader({ alg: 'ES256', kid: cfg.keyid, typ: 'JWT' })
      .setIssuer(cfg.issuerId)
      .setIssuedAt()
      .setExpirationTime('20m')
      .sign(key);
  }
  return async function asc(apiPath, opts = {}) {
    const res = await fetch('https://api.appstoreconnect.apple.com' + apiPath, {
      ...opts,
      headers: { Authorization: 'Bearer ' + (await token()), 'Content-Type': 'application/json', ...(opts.headers ?? {}) },
    });
    const body = await res.json();
    if (!res.ok) {
      console.error(`❌ ASC API ${res.status}:`, JSON.stringify(body).slice(0, 500));
      process.exit(1);
    }
    return body;
  };
}

// ---- 业务 ----

async function getAgeRatingDeclaration(asc) {
  const infos = await asc(`/v1/apps/${APP_ID}/appInfos`);
  const info = infos.data?.[0];
  if (!info) {
    console.error(`❌ app ${APP_ID} 无 appInfo 记录`);
    process.exit(1);
  }
  console.log(`appInfo ${info.id} · 状态 ${info.attributes.appStoreState} · 当前分级 ${info.attributes.appStoreAgeRating ?? '?'}`);
  const ard = await asc(`/v1/appInfos/${info.id}/ageRatingDeclaration`);
  return { infoId: info.id, ardId: ard.data.id, attributes: ard.data.attributes };
}

async function show(asc) {
  const { infoId, ardId, attributes } = await getAgeRatingDeclaration(asc);
  console.log(`ageRatingDeclaration ${ardId}\n`);
  const entries = Object.entries(attributes).sort(([a], [b]) => a.localeCompare(b));
  for (const [field, value] of entries) {
    const marker = value === null ? '  ← 必答未答（null）' : '';
    console.log(`  ${field} = ${JSON.stringify(value)}${marker}`);
  }
  const nulls = entries.filter(([, v]) => v === null).map(([k]) => k);
  console.log(`\n共 ${entries.length} 字段，null ${nulls.length} 个${nulls.length ? '：' + nulls.join(', ') : ''}`);
  if (nulls.length === 0) console.log('✅ 问卷完整，无必答未答项。');
  console.log(`\n补答示例：node ${path.relative(repoRoot, fileURLToPath(import.meta.url))} patch socialMedia=false`);
}

async function patch(asc, attrs) {
  const { infoId, ardId, attributes: before } = await getAgeRatingDeclaration(asc);
  console.log('补答字段：', JSON.stringify(attrs));
  const out = await asc(`/v1/ageRatingDeclarations/${ardId}`, {
    method: 'PATCH',
    body: JSON.stringify({ data: { type: 'ageRatingDeclarations', id: ardId, attributes: attrs } }),
  });
  const after = out.data.attributes;
  for (const [field, value] of Object.entries(attrs)) {
    console.log(`  ${field}: ${JSON.stringify(before[field])} → ${JSON.stringify(after[field])}`);
  }
  console.log('✅ 已写入。ASC 页面刷新后分级应自动重算（einz 预期 12+，因 UGC + chat）。');
}

// ---- 入口 ----

const { cfg, p8 } = await loadCredentials();
const asc = await makeAsc(cfg, p8);
const [cmd, ...args] = process.argv.slice(2);

if (cmd === undefined || cmd === 'show') {
  await show(asc);
} else if (cmd === 'patch') {
  const attrs = {};
  for (const arg of args) {
    if (arg.includes('=')) {
      const [field, raw] = arg.split('=', 2);
      attrs[field] = raw === 'true' ? true : raw === 'false' ? false : raw === 'null' ? null : raw;
    } else {
      Object.assign(attrs, JSON.parse(arg));
    }
  }
  if (Object.keys(attrs).length === 0) {
    console.error('用法：node scripts/ascAgeRating.mjs patch <field>=<value> ... 或 patch \'<json>\'');
    process.exit(1);
  }
  await patch(asc, attrs);
} else {
  console.error('用法：node scripts/ascAgeRating.mjs [show | patch <field>=<value> ...]');
  process.exit(1);
}
