// sherpa-onnx-node（npm，CJS + JSDoc typedefs）的最小类型声明——本服务端只用
// 离线 ASR 三件套（OfflineRecognizer/createStream/acceptWaveform/decodeAsync）。
// 声明而非依赖包内类型：包体是 JS，NodeNext 下无 .d.ts 可供直接引用。
declare module "sherpa-onnx-node" {
  export interface OfflineRecognizerConfig {
    modelConfig?: {
      senseVoice?: {
        model?: string;
        language?: string;
        useInverseTextNormalization?: number;
      };
      tokens?: string;
      numThreads?: number;
      debug?: number | boolean;
      [key: string]: unknown;
    };
    [key: string]: unknown;
  }

  export interface OfflineRecognizerResult {
    text?: string;
    lang?: string;
    [key: string]: unknown;
  }

  export interface OfflineStream {
    acceptWaveform(wave: { samples: Float32Array; sampleRate: number }): void;
  }

  export class OfflineRecognizer {
    constructor(config: OfflineRecognizerConfig);
    createStream(): OfflineStream;
    decode(stream: OfflineStream): void;
    decodeAsync(stream: OfflineStream): Promise<OfflineRecognizerResult>;
    getResult(stream: OfflineStream): OfflineRecognizerResult;
  }
}
