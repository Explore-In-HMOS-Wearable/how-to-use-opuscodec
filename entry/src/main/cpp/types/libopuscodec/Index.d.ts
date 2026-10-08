/**
 * ArkTS view of the native Opus module (entry/src/main/cpp).
 *
 * Everything here is backed by the AVCodec NDK
 * (OH_AudioCodec_* with OH_AVCODEC_MIMETYPE_AUDIO_OPUS).
 */

/** What the device reports for the Opus encoder or decoder. */
export interface OpusCapability {
  supported: boolean;
  isEncoder: boolean;
  isHardware: boolean;
  /** Codec instance name, e.g. "OH.Media.Codec.Encoder.Audio.Opus". */
  name: string;
  sampleRates: Array<number>;
  channelMin: number;
  channelMax: number;
  bitrateMin: number;
  bitrateMax: number;
  complexityMin: number;
  complexityMax: number;
}

/** Configuration handed to OH_AudioCodec_Configure. */
export interface OpusSessionConfig {
  isEncoder: boolean;
  /** 8000 / 12000 / 16000 / 24000 / 48000. */
  sampleRate: number;
  channelCount: number;
  /** Target bitrate in bit/s, encoder only. */
  bitrate: number;
  /** OH_MD_KEY_AUDIO_COMPRESSION_LEVEL, 0..10, encoder only. */
  complexity: number;
  /** Frame length the pipeline pushes, in milliseconds. */
  frameSizeMs: number;
}

/** One frame produced by the codec, delivered on the ArkTS thread. */
export interface OpusFrame {
  data: ArrayBuffer;
  /** Presentation timestamp in microseconds, mirrored from the input frame. */
  pts: number;
  /** OH_AVCodecBufferFlags bit field. */
  flags: number;
  /** push -> output round trip measured inside the codec. */
  latencyMs: number;
  /** Non zero when this record reports an OH_AVCodecOnError instead of data. */
  errorCode: number;
}

export interface OpusStats {
  inFrames: number;
  outFrames: number;
  inBytes: number;
  outBytes: number;
  /** Frames refused because every codec input buffer was still in flight. */
  dropped: number;
  lastLatencyMs: number;
  avgLatencyMs: number;
  maxLatencyMs: number;
}

export interface OpusSessionInfo {
  codecName: string;
  /** Whether the decoder accepted the synthesised OpusHead header. */
  configNote: string;
  isEncoder: boolean;
  sampleRate: number;
  channelCount: number;
  bitrate: number;
  complexity: number;
  frameSizeMs: number;
  /** PCM bytes of one frame; the natural push size for the encoder. */
  frameBytes: number;
}

export const getCapability: (isEncoder: boolean) => OpusCapability;

/** Creates, configures and prepares a codec. Throws when the device refuses. */
export const createSession: (config: OpusSessionConfig) => number;

export const setOutputCallback: (handle: number, callback: (frame: OpusFrame) => void) => void;

export const start: (handle: number) => void;

/**
 * Hands one frame to the codec without blocking.
 * Returns false when no input buffer was free, i.e. the frame was dropped.
 */
export const push: (handle: number, data: ArrayBuffer, ptsUs: number, flags: number) => boolean;

export const flush: (handle: number) => void;

export const stop: (handle: number) => void;

export const destroy: (handle: number) => void;

export const getStats: (handle: number) => OpusStats;

export const getSessionInfo: (handle: number) => OpusSessionInfo;
