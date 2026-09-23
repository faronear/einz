import { ApiError } from "./auth.js";

/** 通道名规则（老板 2026-09-16 定）：只允许 **中文字、英文字母、数字 0-9、
 *  下划线 `_`、中划线 `-`**，最长 32 字符。
 *
 *  与客户端 `shared/lib/src/policy/entrance_name_policy.dart` 是同一约定的两份实现
 *  （Dart/TS 无法共用一份代码），改动务必两边同步。
 *
 *  服务端为什么要自己再查一遍：通道名是**别处传来的数据**（create/join 的
 *  entrance_name、POST /entrances/name），前端校验只是体验，服务端这道才是约束——
 *  老版本客户端、直接打接口的脚本都得被收口。
 *
 *  两条不同的处理，别混用：
 *  - [normalizeEntranceName]：create/join 带的名字（多数是客户端自动取的宿主机名/
 *    设备型号，用户没表达过意愿）→ 不合规字符换成 `_`；
 *  - [assertEntranceName]：显式改名（用户主动输入的）→ 不合规直接 400，让客户端
 *    提示重输，而不是悄悄把人的输入改掉。 */
export const ENTRANCE_NAME_MAX_LENGTH = 32;

/** 中文用 Unicode 属性 \p{Script=Han}（与 Dart 版一致）：覆盖全部汉字区（含
 *  `𠮷` 这类罕见姓名用字），且不含日文假名 / 韩文 / 全角字母。 */
const ENTRANCE_NAME_ALLOWED_CHAR = /[0-9A-Za-z_\-\p{Script=Han}]/u;
export const ENTRANCE_NAME_RE = /^[0-9A-Za-z_\-\p{Script=Han}]+$/u;

/** 显式改名：不合规 → 400（文案给调用方/用户看，客户端另有本地提示）。 */
export function assertEntranceName(name: string): void {
  if (typeof name !== "string") {
    throw new ApiError("INVALID_REQUEST", "entrance_name 必须是字符串", 400);
  }
  const value = name.trim();
  if (value.length === 0) {
    throw new ApiError("INVALID_REQUEST", "entrance_name 不能为空", 400);
  }
  if ([...value].length > ENTRANCE_NAME_MAX_LENGTH) {
    throw new ApiError(
      "INVALID_REQUEST",
      `entrance_name 最长 ${ENTRANCE_NAME_MAX_LENGTH} 个字符`,
      400
    );
  }
  if (!ENTRANCE_NAME_RE.test(value)) {
    throw new ApiError(
      "INVALID_REQUEST",
      "entrance_name 只能包含中文字、英文字母、数字、下划线(_)、中划线(-)",
      400
    );
  }
}

/** create/join 携带的名字：不合规字符换成 `_`、截断到上限；空则返回 null
 *  （entrance_name 允许为空，展示层用 entrance_id 兜底）。 */
export function normalizeEntranceName(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const source = raw.trim();
  if (source.length === 0) return null;
  let out = "";
  for (const ch of source) {
    out += ENTRANCE_NAME_ALLOWED_CHAR.test(ch) ? ch : "_";
  }
  out = [...out].slice(0, ENTRANCE_NAME_MAX_LENGTH).join("");
  return out.length === 0 ? null : out;
}
