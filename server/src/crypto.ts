import { createRequire } from "node:module";
import { argon2id, argon2Verify } from "hash-wasm";

// libsodium-wrappers 的 ESM 入口（dist/modules-esm）在 Node ESM 下损坏（缺 libsodium.mjs），
// 统一用 CJS 构建（dist/modules/libsodium-wrappers.js）。
const require = createRequire(import.meta.url);
const sodium = require("libsodium-wrappers") as typeof import("libsodium-wrappers");

// 统一 base64 变体：标准 base64 + 填充（与客户端 Dart base64Encode/Decode 一致）。
// libsodium-wrappers 默认变体是 URL-safe 无填充，直接使用会与客户端不兼容。
const B64 = sodium.base64_variants.ORIGINAL;

let ready = false;

async function ensureReady(): Promise<void> {
  if (!ready) {
    await sodium.ready;
    ready = true;
  }
}

/** 用通道公钥"密封"一段明文（crypto_box_seal，匿名发送方加密，E2EE.md §7）。 */
export async function sealFor(pubKeyB64: string, plaintext: Uint8Array): Promise<string> {
  await ensureReady();
  const pubKey = sodium.from_base64(pubKeyB64, B64);
  const sealed = sodium.crypto_box_seal(plaintext, pubKey);
  return sodium.to_base64(sealed, B64);
}

/** 生成 n 字节 CSPRNG 随机数。 */
export async function randomBytes(n: number): Promise<Uint8Array> {
  await ensureReady();
  return sodium.randombytes_buf(n);
}

/** base64 编码（标准 + 填充）。 */
export function toB64(bytes: Uint8Array): string {
  return sodium.to_base64(bytes, B64);
}

/** base64 解码（标准 + 填充，含无填充容忍）。 */
export function fromB64(s: string): Uint8Array {
  return sodium.from_base64(s, B64);
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

/**
 * 口令 argon2id 哈希（PHC 编码 `$argon2id$…`，与客户端 sodium pwhashStr 同格式）。
 * 仅用于"口令是否匹配"的服务端验证（加入方取口令密保箱时校验），
 * 不用于任何密钥派生。
 * libsodium-wrappers 不暴露 pwhash API，这里用纯 wasm 的 hash-wasm（参数≈MODERATE）。
 */
export async function pwhashStr(passphrase: string): Promise<string> {
  const salt = await randomBytes(16);
  return argon2id({
    password: passphrase,
    salt,
    parallelism: 1,
    iterations: 3,
    memorySize: 65536, // 64 MiB（≈ libsodium OPSLIMIT_MODERATE / MEMLIMIT_MODERATE）
    hashLength: 32,
    outputType: "encoded",
  });
}

/** 验证口令是否匹配哈希（PHC 格式，兼容客户端 sodium 生成的 $argon2id$ 哈希）。 */
export async function pwhashStrVerify(hashed: string, passphrase: string): Promise<boolean> {
  try {
    return await argon2Verify({ password: passphrase, hash: hashed });
  } catch {
    return false;
  }
}
