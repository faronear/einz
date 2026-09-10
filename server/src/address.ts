import { keccak } from "hash-wasm";

// Multiverse：space_address = "0x" + EIP-55(Keccak-256(space_public_key 字节) 后 20 字节)
//（PROTOCOL_MULTIVERSE.md §2：地址只定位不授权，Keccak-256 派生 + EIP-55 checksum；
//  地址确定性：同一 space_public_key 恒得同一地址，用于分享/二维码/精确查找）。

/** EIP-55 checksum 编码：地址 hex 的每个字母字符按 Keccak-256(hex ASCII) 的
 *  对应 nibble ≥ 8 大写化（校验与美化一体，EIP-55 规范）。 */
export async function toEip55(addrBytes20: Uint8Array): Promise<string> {
  const hex = Buffer.from(addrBytes20).toString("hex");
  const hashHex = await keccak(hex); // 64 hex（32 字节）——nibble 决定大小写
  let out = "";
  for (let i = 0; i < hex.length; i++) {
    const c = hex[i];
    if (c >= "a" && c <= "f") {
      const nibble = parseInt(hashHex[i], 16);
      out += nibble >= 8 ? c.toUpperCase() : c;
    } else {
      out += c;
    }
  }
  return "0x" + out;
}

/** 由 space_public_key（创建者公钥 base64）派生地址；公钥缺失时回退随机占位
 * （兼容旧行为——客户端未传公钥的异常情况）。 */
export async function deriveSpaceAddress(
  spacePublicKeyB64: string | undefined,
  fallback: string,
): Promise<string> {
  if (spacePublicKeyB64 == null || spacePublicKeyB64.length === 0) {
    return fallback;
  }
  const pubBytes = Buffer.from(spacePublicKeyB64, "base64");
  const fullHash = await keccak(pubBytes); // 64 hex（32 字节）
  const last20 = Buffer.from(fullHash.slice(fullHash.length - 40), "hex");
  return toEip55(last20);
}
