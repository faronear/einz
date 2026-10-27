import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { ApiError, touchLastSeen } from "./auth.js";
import { requireSession } from "./guard.js";
import type { OfflineRecognizer } from "sherpa-onnx-node";

/**
 * 服务端转写（方案 D' 演进，20261009_voiceTranscript.zhcn.md §15.2）：双引擎。
 *
 * 隐私承诺（设计文档定稿，部署文档 aimemo/20261022_whisperDeploy.zhcn.md §0）：
 * - 明文音频**全程只在内存**——whisper 引擎经 stdin 管道（whisper-cli `-f -`）喂
 *   子进程；sensevoice 引擎进程内识别（sherpa-onnx node addon）。都不写临时文件、
 *   不落盘、不进日志；
 * - 审计/事件日志只记「事件发生 + 耗时 + 音频时长」，**绝不记音频内容与转写文本**；
 * - 暴露面 = 运营者本人（server 已能看到密文元数据），不引入第三方。
 *
 * 配置（server/docker/.env；两个引擎任一可用即启用转写）：
 *   EINZ_ASR_ENGINE      引擎选择：whisper / sensevoice（缺省=sensevoice 配了就用，
 *                        否则 whisper）——与 App 本机同模型的 sensevoice 优先
 *   EINZ_WHISPER_BIN     whisper 引擎：whisper-cli 可执行绝对路径
 *   EINZ_WHISPER_MODEL   whisper 引擎：ggml 模型文件绝对路径
 *   EINZ_WHISPER_THREADS whisper 引擎：推理线程数（默认 1）
 *   EINZ_SENSEVOICE_MODEL  sensevoice 引擎：模型目录（含 model.int8.onnx +
 *                        tokens.txt，与 App 本机模型同文件，可整目录拷来）
 *   EINZ_SENSEVOICE_THREADS  sensevoice 引擎：线程数（默认 1）
 *   EINZ_TRANSCRIBE_MAX_BYTES  音频上限（默认 10 MiB ≈ 16kHz/16bit/mono 约 5 分钟）
 */

export const MAX_TRANSCRIBE_AUDIO_BYTES = Number(
  process.env.EINZ_TRANSCRIBE_MAX_BYTES ?? 10 * 1024 * 1024
);

/** ASR 引擎标识。 */
export type AsrEngine = "whisper" | "sensevoice";

/** ASR runner：wav 缓冲 → 转写文本（生产按引擎分发；测试可注入假实现）。 */
export type AsrRunner = (wav: Buffer, lang: string) => Promise<string>;

/** whisper 引擎配置（bin 与 model 都配了才算）。 */
function whisperEngineConfig(): { bin: string; model: string; threads: number } | null {
  const bin = process.env.EINZ_WHISPER_BIN;
  const model = process.env.EINZ_WHISPER_MODEL;
  if (bin == null || bin.length === 0 || model == null || model.length === 0) return null;
  return { bin, model, threads: Number(process.env.EINZ_WHISPER_THREADS ?? 1) };
}

/** sensevoice 引擎配置：目录下 model.int8.onnx + tokens.txt 齐全才算配了。
 *  目录形态与 App 本机模型一致（voiceTranscript_model.dart 的 kModelVersion 目录），
 *  整目录拷给服务端即可复用。 */
function senseVoiceEngineConfig(): { model: string; tokens: string; threads: number } | null {
  const dir = process.env.EINZ_SENSEVOICE_MODEL;
  if (dir == null || dir.length === 0) return null;
  const model = join(dir, "model.int8.onnx");
  const tokens = join(dir, "tokens.txt");
  if (!existsSync(model) || !existsSync(tokens)) return null;
  return { model, tokens, threads: Number(process.env.EINZ_SENSEVOICE_THREADS ?? 1) };
}

/** 选择引擎：EINZ_ASR_ENGINE 显式优先（大小写不敏感）；未设 → sensevoice 配了
 *  就用（与 App 本机同模型：中文质量、简体、ITN 全对齐），否则 whisper；都没有
 *  返回 null（未启用，端点报 TRANSCRIBE_DISABLED）。 */
export function resolveAsrEngine(): AsrEngine | null {
  const want = (process.env.EINZ_ASR_ENGINE ?? "").trim().toLowerCase();
  const whisperOk = whisperEngineConfig() != null;
  const senseOk = senseVoiceEngineConfig() != null;
  if (want === "whisper") return whisperOk ? "whisper" : null;
  if (want === "sensevoice") return senseOk ? "sensevoice" : null;
  if (senseOk) return "sensevoice";
  if (whisperOk) return "whisper";
  return null;
}

/** 当前引擎名（/health 透出 asr_engine，便于部署后确认切换是否生效）。 */
export function activeAsrEngine(): AsrEngine | null {
  return resolveAsrEngine();
}

export interface TranscribeResult {
  text: string;
  /** 音频时长（毫秒，从 16kHz/16bit/mono wav 头算出；非法 wav 抛 INVALID_REQUEST）。 */
  audio_ms: number;
}

/** 16kHz/16bit/单声道 PCM wav 的时长（毫秒）。仅认 PCM16（客户端录音就是这个规格），
 *  其他格式拒绝而非猜测——转写质量与引擎的格式兜底无关，喂错格式只会出垃圾。
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

/** 从 wav 缓冲提取 16kHz/mono PCM16 采样（归一化 Float32Array）——sensevoice 引擎
 *  的输入。容器解析与 [wavDurationMs] 同口径；多声道取第 0 声道（防御，客户端上传前
 *  已归一化为 mono）；非 16kHz 直接拒（sensevoice 模型只吃 16k，客户端契约保证，
 *  见 20261009_voiceTranscript.zhcn.md §8）。 */
export function wavPcmSamples(wav: Buffer): { samples: Float32Array; sampleRate: number } {
  if (wav.length < 44 || wav.toString("ascii", 0, 4) !== "RIFF" || wav.toString("ascii", 8, 12) !== "WAVE") {
    throw new ApiError("INVALID_REQUEST", "not a wav file", 400);
  }
  let offset = 12;
  let channels = 0;
  let sampleRate = 0;
  let bits = 0;
  let dataStart = -1;
  let dataLen = 0;
  while (offset + 8 <= wav.length) {
    const id = wav.toString("ascii", offset, offset + 4);
    const size = wav.readUInt32LE(offset + 4);
    if (id === "fmt ") {
      const audioFormat = wav.readUInt16LE(offset + 8);
      const isExtensiblePcm =
        audioFormat === 0xfffe &&
        offset + 34 <= wav.length &&
        wav.readUInt16LE(offset + 32) === 1;
      if (audioFormat !== 1 && !isExtensiblePcm) {
        throw new ApiError("INVALID_REQUEST", "only PCM wav supported", 400);
      }
      channels = wav.readUInt16LE(offset + 10);
      sampleRate = wav.readUInt32LE(offset + 12);
      bits = wav.readUInt16LE(offset + 22);
    } else if (id === "data") {
      dataStart = offset + 8;
      dataLen = Math.min(size, wav.length - dataStart);
    }
    offset += 8 + size + (size % 2);
    if (size === 0 && id !== "data") break;
  }
  if (dataStart < 0 || channels === 0 || sampleRate === 0) {
    throw new ApiError("INVALID_REQUEST", "wav missing fmt/data chunk", 400);
  }
  if (bits !== 16) {
    throw new ApiError("INVALID_REQUEST", "only 16-bit PCM wav supported", 400);
  }
  if (sampleRate !== 16000) {
    throw new ApiError("INVALID_REQUEST", "sensevoice engine expects 16kHz wav", 400);
  }
  const frameBytes = channels * 2;
  const frames = Math.floor(dataLen / frameBytes);
  const samples = new Float32Array(frames);
  for (let i = 0; i < frames; i++) {
    samples[i] = wav.readInt16LE(dataStart + i * frameBytes) / 32768;
  }
  return { samples, sampleRate };
}

/** 解析 ASR runner 的原始输出为文本：兼容两种形态——whisper 旧版时间戳行
 *  （`[00:00:00.000 --> ...] 文本`，取 `]` 后部分）与 `-otxt -of -` 的纯文本行
 *  （无 `]` 也无 `-->` → 原行收取）；空行跳过。 */
export function parseAsrText(out: string): string {
  const lines: string[] = [];
  for (const line of out.split("\n")) {
    const m = line.match(/\]\s*(.*)$/);
    const text = (m?.[1] ?? (line.includes("-->") ? "" : line)).trim();
    if (text.length > 0) lines.push(text);
  }
  return lines.join(" ").trim();
}

/** whisper 引擎：spawn whisper-cli，音频经 stdin 管道进子进程（不落盘）。
 *  ⚠ 两个必须传的旗标（2026-10-23 macOS 实测踩到）：
 *  ① `-f -`（短横）而不是 `-f /dev/stdin`：whisper.cpp 的 read_audio_data 对 `-`
 *     是把 stdin 全量读进内存再解析（管道安全）；对 `/dev/stdin` 会当普通文件走
 *     ma_decoder_init_file——stdin 是管道、不可 seek，miniaudio 打开即失败，再回落
 *     ffmpeg（多数机器没装）→ exit 11「read_audio_data from /dev/stdin」。
 *  ② `-otxt -of -`：新版 whisper.cpp 的文本只经由输出格式函数（-otxt/-ovtt/-osrt…）
 *     落盘，**不再默认往 stdout 打时间戳行**——不传就是解码成功但 stdout 全空
 *     （exit 0，只余一条 warning），转写结果恒为空串。`-of -` 把 txt 输出写到
 *     stdout（仍不落盘，守隐私承诺）；[parseAsrText] 对纯文本行有兜底。 */
/** whisper 引擎 runner（导出供测试与工具复用；生产经 [defaultAsrRunner] 分发）。 */
export const whisperAsrRunner: AsrRunner = (wav, lang) => {
  const cfg = whisperEngineConfig();
  if (cfg == null) throw new ApiError("TRANSCRIBE_DISABLED", "server transcription not configured", 503);
  return new Promise((resolvePromise, reject) => {
    const child = spawn(
      cfg.bin,
      ["-m", cfg.model, "-f", "-", "-l", lang, "-np", "-otxt", "-of", "-", "-t", String(cfg.threads)],
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

// ---- sensevoice 引擎（sherpa-onnx node addon，进程内识别） ----

type SenseVoiceAddon = typeof import("sherpa-onnx-node");

let senseVoiceAddon: SenseVoiceAddon | null | undefined;
let senseVoiceAddonError = "";

/** 懒加载 sherpa-onnx-node（原生 addon，npm 的 optionalDependencies 按平台装）。
 *  没装/平台不支持时记一次错误、每次请求报清晰失败——而不是让整个 server 起不来
 *  （whisper 单引擎部署不受影响）。 */
async function loadSenseVoiceAddon(): Promise<SenseVoiceAddon | null> {
  if (senseVoiceAddon === undefined) {
    try {
      const mod = await import("sherpa-onnx-node");
      // CJS 互操作：ESM import() 下包的导出整体落在 default 上（cjs-module-lexer
      // 只识别到部分命名导出），真正的东西在 mod.default。
      const candidate = mod as unknown as {
        OfflineRecognizer?: unknown;
        default?: SenseVoiceAddon;
      };
      senseVoiceAddon =
        candidate.OfflineRecognizer != null
          ? (candidate as SenseVoiceAddon)
          : candidate.default ?? null;
      if (senseVoiceAddon == null) {
        senseVoiceAddonError = "OfflineRecognizer export not found";
      }
    } catch (e) {
      senseVoiceAddon = null;
      senseVoiceAddonError = e instanceof Error ? e.message : String(e);
    }
  }
  return senseVoiceAddon;
}

let senseVoiceRecognizer: OfflineRecognizer | null = null;
/** 解码串行队列：sherpa 的 recognizer 非并发安全；本端点已有 per-IP 频率限制，
 *  量小，排队可接受。decodeAsync 不卡事件循环（其余请求照常服务）。 */
let senseVoiceTail: Promise<unknown> = Promise.resolve();

/** sensevoice 引擎：与 App 本机同模型（sense-voice-small int8，中/粤/英/日/韩
 *  自动识别 + ITN）。recognizer 懒初始化 + 复用（加载 239MB 模型是大头）；
 *  音频全程内存（acceptWaveform 吃 Float32Array），不落盘。 */
/** sensevoice 引擎 runner（导出供测试与工具复用；生产经 [defaultAsrRunner] 分发）。 */
export const senseVoiceAsrRunner: AsrRunner = async (wav, _lang) => {
  const cfg = senseVoiceEngineConfig();
  if (cfg == null) {
    throw new ApiError("TRANSCRIBE_DISABLED", "sensevoice engine not configured", 503);
  }
  const addon = await loadSenseVoiceAddon();
  if (addon == null) {
    throw new ApiError(
      "TRANSCRIBE_FAILED",
      `sherpa-onnx-node unavailable: ${senseVoiceAddonError} (did npm ci install the platform package?)`,
      503
    );
  }
  const { samples, sampleRate } = wavPcmSamples(wav);
  if (senseVoiceRecognizer == null) {
    senseVoiceRecognizer = new addon.OfflineRecognizer({
      modelConfig: {
        senseVoice: {
          model: cfg.model,
          language: "", // 自动识别（中/粤/英/日/韩），与 App 本机口径一致
          useInverseTextNormalization: 1, // 数字规整（"三个"→"3 个"），同 App
        },
        tokens: cfg.tokens,
        numThreads: cfg.threads,
        debug: 0,
      },
    });
  }
  const recognizer = senseVoiceRecognizer;
  const run = senseVoiceTail.then(async () => {
    const stream = recognizer.createStream();
    stream.acceptWaveform({ samples, sampleRate });
    const result = await recognizer.decodeAsync(stream);
    return String(result.text ?? "").trim();
  });
  senseVoiceTail = run.catch(() => {});
  return run;
};

/** 默认 runner：按 [resolveAsrEngine] 分发到对应引擎（测试可注入假 runner）。 */
const defaultAsrRunner: AsrRunner = (wav, lang) => {
  const engine = resolveAsrEngine();
  if (engine === "sensevoice") return senseVoiceAsrRunner(wav, lang);
  if (engine === "whisper") return whisperAsrRunner(wav, lang);
  throw new ApiError("TRANSCRIBE_DISABLED", "server transcription not configured", 503);
};

/** 转写一条语音（POST /transcriptions 主体逻辑）。
 *  `runner` 供测试注入假引擎；生产恒用 [defaultAsrRunner]（按配置选引擎）。 */
export async function transcribeWav(
  token: string,
  wav: Buffer,
  lang: string,
  runner: AsrRunner = defaultAsrRunner
): Promise<TranscribeResult> {
  const startedAt = Date.now();
  const { entrance_id } = requireSession(token);
  touchLastSeen(entrance_id);

  const audioMs = wavDurationMs(wav);
  // 频率上限约束在 ratelimit（transcribe 桶）；这里只按音频时长兜底——
  // 10MiB 上限已是约 5 分钟，短于此的都放行
  const output = await runner(wav, lang);
  const text = parseAsrText(output);
  // 事件日志：只有事件与耗时。不记音频字节、不记文本、不记来源 IP 之外的内容
  // （隐私承诺见文件头）；IP 由路由层的全站审计另行覆盖，这里不重复。
  console.log(`[transcribe] entrance=${entrance_id} audio_ms=${audioMs} cost_ms=${Date.now() - startedAt} chars=${text.length}`);
  return { text, audio_ms: audioMs };
}
