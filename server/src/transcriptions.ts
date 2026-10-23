import { spawn } from "node:child_process";
import { ApiError, touchLastSeen } from "./auth.js";
import { requireSession } from "./guard.js";

/**
 * 方案 D'：服务端自建 Whisper 转写（voiceTranscript.zhcn.md §15.2）。
 *
 * 隐私承诺（设计文档定稿，部署文档 aimemo/whisperDeploy.zhcn.md §0）：
 * - 明文音频**全程只在内存**——通过 stdin 管道（whisper-cli `-f -`）喂给子进程，
 *   不写临时文件、不落盘、不进日志；
 * - 审计/事件日志只记「事件发生 + 耗时 + 音频时长」，**绝不记音频内容与转写文本**；
 * - 暴露面 = 运营者本人（server 已能看到密文元数据），不引入第三方。
 *
 * 配置（server/docker/.env，两个都配才启用；缺任一 → 端点报 TRANSCRIBE_DISABLED）：
 *   EINZ_WHISPER_BIN    whisper-cli 可执行文件绝对路径
 *   EINZ_WHISPER_MODEL  ggml 模型文件绝对路径
 *   EINZ_WHISPER_THREADS  推理线程数（默认 1，防止小 VPS 被单次转写打满）
 *   EINZ_TRANSCRIBE_MAX_BYTES  音频上限（默认 10 MiB ≈ 16kHz/16bit/mono 约 5 分钟）
 */

export const MAX_TRANSCRIBE_AUDIO_BYTES = Number(
  process.env.EINZ_TRANSCRIBE_MAX_BYTES ?? 10 * 1024 * 1024
);

/** whisper-cli 可执行与模型路径（都配了才启用转写）。 */
function whisperConfig(): { bin: string; model: string; threads: number } | null {
  const bin = process.env.EINZ_WHISPER_BIN;
  const model = process.env.EINZ_WHISPER_MODEL;
  if (bin == null || bin.length === 0 || model == null || model.length === 0) return null;
  return { bin, model, threads: Number(process.env.EINZ_WHISPER_THREADS ?? 1) };
}

/** 服务端转写是否已启用（/health capabilities 用，客户端据此隐藏/显示入口）。 */
export function transcribeEnabled(): boolean {
  return whisperConfig() != null;
}

export interface TranscribeResult {
  text: string;
  /** 音频时长（毫秒，从 16kHz/16bit/mono wav 头算出；非法 wav 抛 INVALID_REQUEST）。 */
  audio_ms: number;
}

/** 16kHz/16bit/单声道 PCM wav 的时长（毫秒）。仅认 PCM16（客户端录音就是这个规格），
 *  其他格式拒绝而非猜测——转写质量与 whisper 的 ffmpeg 分支无关，喂错格式只会出垃圾。
 *
 *  接受两种 PCM 容器：标准 tag=1，以及 WAVE_FORMAT_EXTENSIBLE（0xFFFE，子格式 GUID
 *  头两位为 1）——macOS 的 AVCaptureAudioFileOutput 把标准 PCM16 录音写成 extensible
 *  （2026-10-23 实测：JUNK + 40 字节 fmt + FLLR + data，数据本身是 16bit 交错 PCM），
 *  App 上传前虽已规范化，服务端也不能因此把合法音频 400 掉。 */
export function wavDurationMs(wav: Buffer): number {
  // RIFF 头：12 字节文件头 + 逐 chunk 找 fmt 与 data（容忍非标准 chunk 顺序）
  if (wav.length < 44 || wav.toString("ascii", 0, 4) !== "RIFF" || wav.toString("ascii", 8, 12) !== "WAVE") {
    throw new ApiError("INVALID_REQUEST", "not a wav file", 400);
  }
  let offset = 12;
  let byteRate = 0;
  let dataStart = -1;
  let dataLen = 0;
  while (offset + 8 <= wav.length) {
    const id = wav.toString("ascii", offset, offset + 4);
    const size = wav.readUInt32LE(offset + 4);
    if (id === "fmt ") {
      const audioFormat = wav.readUInt16LE(offset + 8);
      // 0xFFFE 的 fmt 是 40 字节：标准 16 字节 + cbSize(2)/validBits(2)/
      // channelMask(4) + 子格式 GUID(16)；GUID 起点 = 块头 + 8 + 24 = +32，
      // 其头两位（LE）为 1 = PCM（float 是 3，仍拒）。
      const isExtensiblePcm =
        audioFormat === 0xfffe &&
        offset + 34 <= wav.length &&
        wav.readUInt16LE(offset + 32) === 1;
      if (audioFormat !== 1 && !isExtensiblePcm) {
        throw new ApiError("INVALID_REQUEST", "only PCM wav supported", 400);
      }
      byteRate = wav.readUInt32LE(offset + 16);
    } else if (id === "data") {
      dataStart = offset + 8;
      dataLen = Math.min(size, wav.length - dataStart);
    }
    offset += 8 + size + (size % 2); // chunk 按 2 字节对齐
    if (size === 0 && id !== "data") break; // 防畸形头死循环
  }
  if (byteRate === 0 || dataStart < 0) {
    throw new ApiError("INVALID_REQUEST", "wav missing fmt/data chunk", 400);
  }
  return Math.round((dataLen / byteRate) * 1000);
}

/** 解析 whisper-cli stdout：取每行时间戳之后的部分并拼接。
 *  不依赖 -nt 等新版 flag（旧版 whisper.cpp 也能跑），只按输出形态解析。 */
export function parseWhisperStdout(out: string): string {
  const lines: string[] = [];
  for (const line of out.split("\n")) {
    const m = line.match(/\]\s*(.*)$/); // [00:00:00.000 --> 00:00:03.200]  文本
    const text = (m?.[1] ?? (line.includes("-->") ? "" : line)).trim();
    if (text.length > 0) lines.push(text);
  }
  return lines.join(" ").trim();
}

type WhisperRunner = (wav: Buffer, lang: string) => Promise<string>;

/** 默认 runner：spawn whisper-cli，音频经 stdin 管道进子进程（不落盘）。
 *  ⚠ 必须传 `-f -`（短横）而不是 `-f /dev/stdin`：whisper.cpp 的 read_audio_data
 *  对 `-` 是把 stdin 全量读进内存再解析（管道安全）；对 `/dev/stdin` 会当普通
 *  文件走 ma_decoder_init_file——stdin 是管道、不可 seek，miniaudio 打开即失败，
 *  再回落 ffmpeg（多数机器没装）→ exit 11「read_audio_data from /dev/stdin」。
 *  2026-10-23 macOS 实测踩到（此前各次测试都在到达 whisper 前就失败，从未真正
 *  跑通过这条管道）。 */
const realWhisperRunner: WhisperRunner = (wav, lang) => {
  const cfg = whisperConfig();
  if (cfg == null) throw new ApiError("TRANSCRIBE_DISABLED", "server transcription not configured", 503);
  return new Promise((resolvePromise, reject) => {
    const child = spawn(
      cfg.bin,
      ["-m", cfg.model, "-f", "-", "-l", lang, "-np", "-t", String(cfg.threads)],
      { stdio: ["pipe", "pipe", "pipe"] }
    );
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new ApiError("TRANSCRIBE_TIMEOUT", "whisper took too long", 504));
    }, 120_000);
    child.stdout.on("data", (d: Buffer) => (stdout += d.toString()));
    child.stderr.on("data", (d: Buffer) => (stderr += d.toString()));
    child.on("error", (err) => {
      clearTimeout(timer);
      reject(new ApiError("TRANSCRIBE_FAILED", `whisper spawn failed: ${err.message}`, 503));
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      if (code !== 0) {
        // stderr 只取首行进错误消息——whisper 的报错行不含音频内容，但仍然截断防意外
        const first = stderr.split("\n").find((l) => l.trim().length > 0) ?? "";
        reject(new ApiError("TRANSCRIBE_FAILED", `whisper exit ${code}: ${first.slice(0, 200)}`, 503));
        return;
      }
      resolvePromise(stdout);
    });
    // 音频走 stdin：wav 缓冲写完即关，子进程经 `-f -` 从 stdin 读取
    child.stdin.on("error", () => {/* whisper 读完即退出，EPIPE 竞态属正常 */});
    child.stdin.end(wav);
  });
};

/** 转写一条语音（POST /transcriptions 主体逻辑）。
 *  `runner` 供测试注入假引擎；生产恒用 realWhisperRunner。 */
export async function transcribeWav(
  token: string,
  wav: Buffer,
  lang: string,
  runner: WhisperRunner = realWhisperRunner
): Promise<TranscribeResult> {
  const startedAt = Date.now();
  const { entrance_id } = requireSession(token);
  touchLastSeen(entrance_id);

  const audioMs = wavDurationMs(wav);
  // 频率上限约束在 ratelimit（transcribe 桶）；这里只按音频时长兜底——
  // 10MiB 上限已是约 5 分钟，短于此的都放行
  const stdout = await runner(wav, lang);
  const text = parseWhisperStdout(stdout);
  // 事件日志：只有事件与耗时。不记音频字节、不记文本、不记来源 IP 之外的内容
  // （隐私承诺见文件头）；IP 由路由层的全站审计另行覆盖，这里不重复。
  console.log(`[transcribe] entrance=${entrance_id} audio_ms=${audioMs} cost_ms=${Date.now() - startedAt} chars=${text.length}`);
  return { text, audio_ms: audioMs };
}
