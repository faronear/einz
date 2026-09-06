// 临时验证脚本：两阶段附件上传（先 blob 后 message）+ 孤儿清理（2026-09-02）
// 运行：node test/verify_two_phase.mjs（需先 npm run build）
// 不纳入 npm test（冒烟测试本身有存量问题，见 worklog）。
import { createHash } from "node:crypto";
import { createRequire } from "node:module";
import { spawn } from "node:child_process";
import { createServer } from "node:net";
import { mkdtempSync, rmSync, existsSync, writeFileSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import assert from "node:assert/strict";

const require = createRequire(import.meta.url);
const sodium = require("libsodium-wrappers");
const B64 = sodium.base64_variants.ORIGINAL;
const ROOT = resolve(import.meta.dirname, "..");
const PORT = 3917;

let serverProc = null;
const tempDir = mkdtempSync(join(tmpdir(), "einz-2phase-"));

function freePort() {
  return new Promise((done) => {
    const srv = createServer();
    srv.listen(0, () => {
      const port = srv.address().port;
      srv.close(() => done(port));
    });
  });
}

async function waitReady(port, timeoutMs = 10_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      await fetch(`http://127.0.0.1:${port}/devices`);
      return;
    } catch {
      await new Promise((r) => setTimeout(r, 100));
    }
  }
  throw new Error("server not ready");
}

function main() {
  return new Promise(async (done, fail) => {
    try {
      await sodium.ready;
      const port = await freePort();
      const keypair = sodium.crypto_box_keypair();
      const filesDir = join(tempDir, "files");
      serverProc = spawn(process.execPath, [join(ROOT, "dist/app.js")], {
        env: {
          ...process.env,
          PORT: String(port),
          EINZ_DB: join(tempDir, "einz.sqlite.db"),
          EINZ_FILES: filesDir,
        },
        stdio: ["ignore", "ignore", "pipe"],
      });
      await waitReady(port);

      const base = `http://127.0.0.1:${port}`;
      // 1) 首设备自举登记（自主模式：白名单在 devices 表）
      const enrollRes = await fetch(`${base}/devices/enroll`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ public_key: sodium.to_base64(keypair.publicKey, B64), device_name: "verify-a" }),
      });
      assert.equal(enrollRes.status, 200, "enroll should succeed");
      const enroll = await enrollRes.json();
      const deviceId = enroll.device_id;
      assert.equal(enroll.ok, true, "enroll ok");

      // 2) 认证
      const ch = await fetch(`${base}/auth/challenge`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ device_id: deviceId }),
      });
      assert.equal(ch.status, 200, "challenge should succeed");
      const { challenge_id, sealed_challenge } = await ch.json();
      const plaintext = sodium.crypto_box_seal_open(
        sodium.from_base64(sealed_challenge, B64),
        keypair.publicKey,
        keypair.privateKey
      );
      const vf = await fetch(`${base}/auth/verify`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ challenge_id, challenge_plaintext: sodium.to_base64(plaintext, B64) }),
      });
      assert.equal(vf.status, 200, "verify should succeed");
      const { session_token } = await vf.json();

      // 3) 【关键】先传 blob：message_id 尚不存在 → 应 200（旧行为 400 "message not found"）
      // 注意：ID 须满足服务端 assertSafeId 白名单（hex + 连字符）
      const messageId = "aabbccddeeff00112233445566778899";
      const attachmentId = "99887766554433221100ffeeddccbbaa";
      const blob = sodium.randombytes_buf(2048);
      // Server 校验的是 SHA-256（node:crypto），不是 libsodium 的 BLAKE2b
      const sha256 = createHash("sha256").update(blob).digest("base64");
      const attRes = await fetch(`${base}/attachments`, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${session_token}`,
          "Content-Type": "application/octet-stream",
          "x-attachment-meta": JSON.stringify({
            message_id: messageId,
            attachment_id: attachmentId,
            key_version: 1,
            size: blob.length,
            sha256,
            nonce: sodium.to_base64(sodium.randombytes_buf(24), B64),
          }),
        },
        body: Buffer.from(blob),
      });
      assert.equal(attRes.status, 200, `blob-before-message upload should succeed, got ${attRes.status}`);
      console.log("✅ 先传 blob（message 不存在）→ 200");

      // 4) 再发消息 → 关联成功
      const env = {
        v: 1, type: "image", key_version: 1,
        message_id: messageId, sender_device_id: deviceId,
        nonce: sodium.to_base64(sodium.randombytes_buf(24), B64),
        ciphertext: sodium.to_base64(sodium.randombytes_buf(64), B64),
      };
      const msgRes = await fetch(`${base}/messages`, {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${session_token}` },
        body: JSON.stringify(env),
      });
      assert.equal(msgRes.status, 200, "post message should succeed");
      console.log("✅ 再发消息 → 200");

      // 5) sync 携带 attachments_meta
      const sync = await fetch(`${base}/sync?after=0`, { headers: { Authorization: `Bearer ${session_token}` } });
      const body = await sync.json();
      assert.equal(body.messages.length, 1, "1 message");
      assert.equal(body.attachments_meta.length, 1, "attachments_meta present");
      assert.equal(body.attachments_meta[0].attachment_id, attachmentId, "attachment linked to message");
      console.log("✅ sync 返回 attachments_meta，附件与消息已关联");

      // 6) 【关键】孤儿清理：再造一个永不发消息的孤儿 blob，回拨时间后触发清理
      const orphanId = "0123456789abcdef0123456789abcde1";
      const orphanMsg = "fedcba9876543210fedcba9876543210";
      const blob2 = sodium.randombytes_buf(1024);
      const sha256b = createHash("sha256").update(blob2).digest("base64");
      const orphanRes = await fetch(`${base}/attachments`, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${session_token}`,
          "Content-Type": "application/octet-stream",
          "x-attachment-meta": JSON.stringify({
            message_id: orphanMsg,
            attachment_id: orphanId,
            key_version: 1,
            size: blob2.length,
            sha256: sha256b,
            nonce: sodium.to_base64(sodium.randombytes_buf(24), B64),
          }),
        },
        body: Buffer.from(blob2),
      });
      assert.equal(orphanRes.status, 200, "orphan blob upload should succeed");

      // 回拨 created_at 到孤儿窗口之外（>10 分钟），再触发清理
      const Database = require("better-sqlite3");
      const db = new Database(join(tempDir, "einz.sqlite.db"));
      db.prepare("UPDATE attachments SET created_at = ? WHERE attachment_id = ?").run(Date.now() - 20 * 60 * 1000, orphanId);
      db.close();

      const orphanFile = join(filesDir, orphanId.slice(0, 2), orphanId);
      assert.ok(existsSync(orphanFile), "orphan blob file exists before cleanup");

      // 直接在进程内调用 dist 里的清理函数（EINZ_FILES 指向同一目录）
      process.env.EINZ_FILES = filesDir;
      const { openDb, getDb } = await import(`${pathToFileURL(join(ROOT, "dist/db.js")).href}`);
      openDb(join(tempDir, "einz.sqlite.db"));
      const { cleanupOrphanAttachments } = await import(`${pathToFileURL(join(ROOT, "dist/attachments.js")).href}`);
      const removed = cleanupOrphanAttachments();
      assert.equal(removed, 1, "exactly 1 orphan cleaned");
      assert.ok(!existsSync(orphanFile), "orphan blob file removed");
      const db2 = new Database(join(tempDir, "einz.sqlite.db"), { readonly: true });
      const row = db2.prepare("SELECT COUNT(*) AS c FROM attachments WHERE attachment_id = ?").get(orphanId);
      assert.equal(row.c, 0, "orphan row removed");
      // 正常关联的附件必须保留
      const kept = db2.prepare("SELECT COUNT(*) AS c FROM attachments WHERE attachment_id = ?").get(attachmentId);
      assert.equal(kept.c, 1, "linked attachment kept");
      db2.close();
      console.log("✅ 孤儿附件清理（>10 分钟无 message）→ 删除文件+记录，正常附件保留");

      console.log("🎉 两阶段上传 + 孤儿清理验证全部通过");
      done();
    } catch (e) {
      fail(e);
    } finally {
      if (serverProc) {
        serverProc.kill("SIGKILL");
        await new Promise((r) => setTimeout(r, 300));
        try { rmSync(tempDir, { recursive: true, force: true }); } catch { /* ignore */ }
      }
    }
  });
}

main().then(
  () => process.exit(0),
  (e) => {
    console.error("❌ 验证失败:", e);
    process.exit(1);
  }
);
