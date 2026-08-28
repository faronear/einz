/**
 * OnlySpace Server 冒烟测试（Phase 0，可验证）
 *
 * 模拟两台设备（Node 侧用 libsodium-wrappers 扮演客户端）：
 *   A 认证 → A 加密发送 → B 认证 → B 增量同步 → B 解密
 * 同时验证：Server 只见密文（明文不出现在任何响应与数据库）、幂等、白名单拒绝。
 *
 * 运行：npm test（需先 npm run build 生成 dist/）
 */
import { createRequire } from "node:module";
// libsodium-wrappers 的 ESM 入口在 Node ESM 下损坏，统一用 CJS 构建（同 server/src/crypto.ts）。
const require = createRequire(import.meta.url);
const sodium = require("libsodium-wrappers") as typeof import("libsodium-wrappers");

// 与 Server 协议一致：标准 base64 + 填充（同 server/src/crypto.ts 的 B64）
const B64 = sodium.base64_variants.ORIGINAL;
import { spawn, type ChildProcess } from "node:child_process";
import { createServer, type AddressInfo } from "node:net";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { WebSocket } from "ws";
import assert from "node:assert/strict";
import Database from "better-sqlite3";

const ROOT = resolve(import.meta.dirname, "..");
const HELLO = "hello b, this is a secret message ❤️";

let serverProc: ChildProcess | null = null;
let tempDir = "";

// ---------- 工具 ----------

function freePort(): Promise<number> {
  return new Promise((done) => {
    const srv = createServer();
    srv.listen(0, () => {
      const port = (srv.address() as AddressInfo).port;
      srv.close(() => done(port));
    });
  });
}

async function waitReady(port: number, timeoutMs = 10_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`http://127.0.0.1:${port}/devices`);
      void res; // 任何 HTTP 响应都说明 Server 已就绪
      return;
    } catch {
      await new Promise((r) => setTimeout(r, 100));
    }
  }
  throw new Error("server did not become ready in time");
}

interface KeyPair {
  privateKey: Uint8Array;
  publicKey: Uint8Array;
}

/** 消息密文信封（E2EE.md §5.1，字段类型须与 Server 校验一致）。 */
interface MessageEnvelope {
  v: number;
  type: string;
  key_version: number;
  message_id: string;
  sender_device_id: string;
  nonce: string;
  ciphertext: string;
}

// ---------- 模拟设备（扮演未来 Dart 客户端） ----------

class TestDevice {
  deviceId: string;
  personId: string;
  keypair: KeyPair;
  sessionToken = "";
  spaceKey: Uint8Array;

  constructor(deviceId: string, personId: string, spaceKey: Uint8Array) {
    this.deviceId = deviceId;
    this.personId = personId;
    this.keypair = sodium.crypto_box_keypair();
    this.spaceKey = spaceKey;
  }

  async auth(port: number): Promise<void> {
    const challengeRes = await fetch(`http://127.0.0.1:${port}/auth/challenge`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ device_id: this.deviceId }),
    });
    assert.equal(challengeRes.status, 200, "challenge should succeed");
    const { challenge_id, sealed_challenge } = (await challengeRes.json()) as {
      challenge_id: string;
      sealed_challenge: string;
    };

    const sealed = sodium.from_base64(sealed_challenge, B64);
    const plaintext = sodium.crypto_box_seal_open(sealed, this.keypair.publicKey, this.keypair.privateKey);

    const verifyRes = await fetch(`http://127.0.0.1:${port}/auth/verify`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ challenge_id, challenge_plaintext: sodium.to_base64(plaintext, B64) }),
    });
    assert.equal(verifyRes.status, 200, "verify should succeed");
    const { session_token } = (await verifyRes.json()) as { session_token: string };
    this.sessionToken = session_token;
  }

  /** 客户端 E2EE 加密（E2EE.md §5）：SpaceKey → MessageKey → XChaCha20-Poly1305。 */
  encryptMessage(messageId: string, plaintext: string, spaceId: string): MessageEnvelope {
    const msgKey = sodium.crypto_generichash(32, sodium.from_string(`m:${messageId}`), this.spaceKey);
    const nonce = sodium.randombytes_buf(24);
    const aad = sodium.from_string(`onlyspace-v1${spaceId}${messageId}${this.deviceId}text1`);
    const ciphertext = sodium.crypto_aead_xchacha20poly1305_ietf_encrypt(
      sodium.from_string(plaintext),
      aad,
      null,
      nonce,
      msgKey
    );
    return {
      v: 1,
      type: "text",
      key_version: 1,
      message_id: messageId,
      sender_device_id: this.deviceId,
      nonce: sodium.to_base64(nonce, B64),
      ciphertext: sodium.to_base64(ciphertext, B64),
    };
  }

  /** 客户端 E2EE 解密（验证同步回来的密文可解）。 */
  decryptMessage(env: MessageEnvelope, spaceId: string): string {
    const msgKey = sodium.crypto_generichash(32, sodium.from_string(`m:${env.message_id}`), this.spaceKey);
    const nonce = sodium.from_base64(env.nonce, B64);
    const aad = sodium.from_string(`onlyspace-v1${spaceId}${env.message_id}${env.sender_device_id}text1`);
    const plain = sodium.crypto_aead_xchacha20poly1305_ietf_decrypt(
      null,
      sodium.from_base64(env.ciphertext, B64),
      aad,
      nonce,
      msgKey
    );
    return sodium.to_string(plain);
  }

  async postMessage(port: number, env: Record<string, string>): Promise<{ server_sequence: number }> {
    const res = await fetch(`http://127.0.0.1:${port}/messages`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${this.sessionToken}` },
      body: JSON.stringify(env),
    });
    assert.equal(res.status, 200, "post message should succeed");
    return (await res.json()) as { server_sequence: number };
  }

  async sync(port: number, after: number): Promise<{ messages: Record<string, string>[]; last_sequence: number }> {
    const res = await fetch(`http://127.0.0.1:${port}/sync?after=${after}`, {
      headers: { Authorization: `Bearer ${this.sessionToken}` },
    });
    assert.equal(res.status, 200, "sync should succeed");
    return (await res.json()) as { messages: Record<string, string>[]; last_sequence: number };
  }
}

// ---------- 主流程 ----------

async function main(): Promise<void> {
  await sodium.ready;

  tempDir = mkdtempSync(join(tmpdir(), "onlyspace-smoke-"));
  const spaceKey = sodium.randombytes_buf(32);
  const devA = new TestDevice("dev-a1", "person-a", spaceKey);
  const devB = new TestDevice("dev-b1", "person-b", spaceKey);

  // 生成一次性配置（config.json 白名单）
  const config = {
    space_id: "space-smoke-test",
    devices: [
      { device_id: devA.deviceId, person_id: devA.personId, public_key: sodium.to_base64(devA.keypair.publicKey, B64), status: "active" },
      { device_id: devB.deviceId, person_id: devB.personId, public_key: sodium.to_base64(devB.keypair.publicKey, B64), status: "active" },
    ],
  };
  const configPath = join(tempDir, "config.json");
  writeFileSync(configPath, JSON.stringify(config, null, 2));

  const port = await freePort();
  serverProc = spawn(process.execPath, [join(ROOT, "dist/app.js")], {
    env: {
      ...process.env,
      PORT: String(port),
      ONLYSPACE_CONFIG: configPath,
      ONLYSPACE_DB: join(tempDir, "app.db"),
      ONLYSPACE_FILES: join(tempDir, "files"),
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  serverProc.stderr?.on("data", (d) => process.stderr.write(`[server] ${d}`));

  try {
    await waitReady(port);

    // 1) 白名单外设备挑战 → 403
    const evil = await fetch(`http://127.0.0.1:${port}/auth/challenge`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ device_id: "dev-evil" }),
    });
    assert.equal(evil.status, 403, "non-whitelisted device must be rejected");

    // 2) A 认证
    await devA.auth(port);

    // 3) A 加密发送
    const envA = devA.encryptMessage("msg-0001", HELLO, config.space_id);
    const posted = await devA.postMessage(port, envA);
    assert.equal(posted.server_sequence, 1, "first message gets sequence 1");

    // 4) 幂等：同 message_id 重复上传 → 不新增
    const repost = await devA.postMessage(port, envA);
    assert.equal(repost.server_sequence, 1, "duplicate message_id is idempotent");

    // 5) B 认证 + 增量同步
    await devB.auth(port);
    const sync1 = await devB.sync(port, 0);
    assert.equal(sync1.messages.length, 1, "B should receive exactly 1 message");
    assert.equal(sync1.messages[0].message_id, "msg-0001");

    // 6) 关键断言：Server 同步返回的是密文，明文绝不出现
    const raw = JSON.stringify(sync1);
    assert.ok(!raw.includes(HELLO), "plaintext must NOT appear in sync response");

    // 7) B 解密成功（端到端闭环）
    const decrypted = devB.decryptMessage(sync1.messages[0], config.space_id);
    assert.equal(decrypted, HELLO, "B must decrypt the message correctly");

    // 8) 数据库核查：messages 表只有密文，无明文
    const db = new Database(join(tempDir, "app.db"), { readonly: true });
    const row = db.prepare(`SELECT ciphertext FROM messages WHERE message_id = 'msg-0001'`).get() as { ciphertext: string };
    assert.ok(row.ciphertext.length > 0, "ciphertext stored");
    assert.ok(!row.ciphertext.includes(HELLO), "DB must not contain plaintext");
    db.close();

    // 9) 无 token 访问 → 401
    const noAuth = await fetch(`http://127.0.0.1:${port}/sync?after=0`);
    assert.equal(noAuth.status, 401, "missing token must be rejected");

    // 10) WS：A 连接后，B 发消息 → A 实时收到 message.new
    await new Promise<void>((done, fail) => {
      // token 含 base64 的 +/= 字符，作为查询参数必须 URL 编码（PROTOCOL.md §8.1）
      const ws = new WebSocket(`ws://127.0.0.1:${port}/ws?pv=1&token=${encodeURIComponent(devA.sessionToken)}`);
      const timer = setTimeout(() => fail(new Error("WS message.new timeout")), 5000);
      ws.on("message", (data) => {
        const frame = JSON.parse(data.toString());
        if (frame.type === "hello") {
          void devB.postMessage(port, devB.encryptMessage("msg-0002", "reply from b", config.space_id));
        } else if (frame.type === "message.new") {
          assert.equal(frame.payload.message.message_id, "msg-0002", "A should receive B's message in realtime");
          clearTimeout(timer);
          ws.close();
          done();
        }
      });
      ws.on("error", (e) => fail(e));
    });

    console.log("✅ 冒烟测试全部通过：认证 / E2EE 密文 / 幂等 / 同步 / 白名单 / 明文隔离 / WS 实时");
  } finally {
    serverProc?.kill("SIGTERM");
    rmSync(tempDir, { recursive: true, force: true });
  }
}

main().catch((err) => {
  console.error("❌ 冒烟测试失败:", err);
  process.exit(1);
});
