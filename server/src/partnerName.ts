import { ApiError } from "./auth.js";

/** 用户名称（partner 显示名）规则（老板 2026-09-16 定）：最多 32 字符，只允许
 *  **中文字、英文字母、数字、`_` `-`、表情符 emoji**。
 *
 *  与设备名的差别是**允许 emoji**——名字是给人看的亲昵称呼（"小猪🐷"），设备名
 *  是给机器看的短标识，所以两条规则不合并（见 entranceName.ts）。
 *
 *  客户端同款规则在 `shared/lib/src/policy/partner_name_policy.dart`（Dart/TS 无法
 *  共用一份代码，改动务必两边同步）。
 *
 *  名字一律是用户自己输入的（没有"自动取名"这条路），因此这里只做**拒绝**：不合规
 *  直接 400，让客户端提示重输，而不是悄悄把人的名字改掉。 */
export const PARTNER_NAME_MAX_LENGTH = 32;

/** 中文用 \p{Script=Han}（全部汉字区，含 `𠮷`；不含假名/谚文/全角）；emoji 走
 *  Unicode 属性（比手写区间全），再补国旗/变体选择符/ZWJ/键帽四类拼装件。 */
const PARTNER_NAME_ALLOWED_CHAR =
  /[0-9A-Za-z_\-\p{Script=Han}\p{Extended_Pictographic}\u{1F1E6}-\u{1F1FF}️︎‍⃣]/u;
export const PARTNER_NAME_RE =
  /^[0-9A-Za-z_\-\p{Script=Han}\p{Extended_Pictographic}\u{1F1E6}-\u{1F1FF}️︎‍⃣]+$/u;

/** 不合规 → 400（文案给调用方/用户看，客户端另有本地提示）。 */
export function assertPartnerName(name: string): void {
  if (typeof name !== "string") {
    throw new ApiError("INVALID_REQUEST", "name 必须是字符串", 400);
  }
  const value = name.trim();
  if (value.length === 0) {
    throw new ApiError("INVALID_REQUEST", "name 不能为空", 400);
  }
  if ([...value].length > PARTNER_NAME_MAX_LENGTH) {
    throw new ApiError(
      "INVALID_REQUEST",
      `name 最长 ${PARTNER_NAME_MAX_LENGTH} 个字符`,
      400
    );
  }
  if (!PARTNER_NAME_RE.test(value)) {
    throw new ApiError(
      "INVALID_REQUEST",
      "name 只能包含中文字、英文字母、数字、下划线(_)、中划线(-)与表情符",
      400
    );
  }
}
