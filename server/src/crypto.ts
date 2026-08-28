import { createRequire } from "node:module";

// libsodium-wrappers 的 ESM 入口（dist/modules-esm）在 Node ESM 下损坏（缺 libsodium.mjs），
// 统一用 CJS 构建（dist/modules/libsodium-wrappers.js）。
const require = createRequire(import.meta.url);
const sodium = require("libsodium-wrappers") as typeof import("libsodium-wrappers");

let ready = false;

async function ensureReady(): Promise<void> {
  if (!ready) {
    await sodium.ready;
    ready = true;
  }
}

/** 用设备公钥"密封"一段明文（crypto_box_seal，匿名发送方加密，E2EE.md §7）。 */
export async function sealFor(pubKeyB64: string, plaintext: Uint8Array): Promise<string> {
  await ensureReady();
  const pubKey = sodium.from_base64(pubKeyB64);
  const sealed = sodium.crypto_box_seal(plaintext, pubKey);
  return sodium.to_base64(sealed);
}

/** 生成 n 字节 CSPRNG 随机数。 */
export async function randomBytes(n: number): Promise<Uint8Array> {
  await ensureReady();
  return sodium.randombytes_buf(n);
}

/** base64 编码。 */
export function toB64(bytes: Uint8Array): string {
  return sodium.to_base64(bytes);
}

/** base64 解码（含无填充容忍）。 */
export function fromB64(s: string): Uint8Array {
  return sodium.from_base64(s);
}

/** 常量时间比较两个 base64 字符串对应的字节。 */
export function constantTimeEqualB64(a: string, b: string): boolean {
  const ab = fromB64(a);
  const bb = fromB64(b);
  if (ab.length !== bb.length) return false;
  let diff = 0;
  for (let i = 0; i < ab.length; i++) diff |= ab[i] ^ bb[i];
  return diff === 0;
}
