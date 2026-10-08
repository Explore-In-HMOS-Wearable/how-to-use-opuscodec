import type { OpusSessionConfig } from 'libopuscodec.so';

/**
 * Mirror of OH_AVCodecBufferFlags (native_avbuffer_info.h). The native layer
 * passes the raw bit field through, so the ArkTS side needs the same values.
 */
export class BufferFlags {
  static readonly NONE: number = 0;
  static readonly EOS: number = 1;
  static readonly SYNC_FRAME: number = 1 << 1;
  static readonly INCOMPLETE_FRAME: number = 1 << 2;
  /** Codec specific data, for Opus the identification header. */
  static readonly CODEC_DATA: number = 1 << 3;
}

/**
 * A ready-made encoder/decoder setup. Opus is one of the few codecs where the
 * frame length is a free parameter: 20 ms is the default trade-off, 10 ms and
 * 5 ms cut the algorithmic delay at the cost of packet overhead.
 */
export interface OpusProfile {
  key: string;
  label: string;
  hint: string;
  sampleRate: number;
  channelCount: number;
  bitrate: number;
  /** OH_MD_KEY_AUDIO_COMPRESSION_LEVEL, 0..10. Lower is cheaper and faster. */
  complexity: number;
  frameSizeMs: number;
}

export const OPUS_PROFILES: Array<OpusProfile> = [
  {
    key: 'lowlatency',
    label: 'Low latency',
    hint: '16 kHz mono, 10 ms frames, complexity 3. Voice pipeline tuned for delay.',
    sampleRate: 16000,
    channelCount: 1,
    bitrate: 24000,
    complexity: 3,
    frameSizeMs: 10
  },
  {
    key: 'voice',
    label: 'Voice',
    hint: '16 kHz mono, 20 ms frames, complexity 5. The usual VoIP default.',
    sampleRate: 16000,
    channelCount: 1,
    bitrate: 24000,
    complexity: 5,
    frameSizeMs: 20
  },
  {
    key: 'wideband',
    label: 'Wideband',
    hint: '48 kHz mono, 20 ms frames, complexity 8. Quality over CPU cost.',
    sampleRate: 48000,
    channelCount: 1,
    bitrate: 64000,
    complexity: 8,
    frameSizeMs: 20
  }
];

export function profileByKey(key: string): OpusProfile {
  for (const profile of OPUS_PROFILES) {
    if (profile.key === key) {
      return profile;
    }
  }
  return OPUS_PROFILES[0];
}

export function encoderConfig(profile: OpusProfile): OpusSessionConfig {
  return {
    isEncoder: true,
    sampleRate: profile.sampleRate,
    channelCount: profile.channelCount,
    bitrate: profile.bitrate,
    complexity: profile.complexity,
    frameSizeMs: profile.frameSizeMs
  };
}

export function decoderConfig(profile: OpusProfile): OpusSessionConfig {
  return {
    isEncoder: false,
    sampleRate: profile.sampleRate,
    channelCount: profile.channelCount,
    bitrate: profile.bitrate,
    complexity: profile.complexity,
    frameSizeMs: profile.frameSizeMs
  };
}

/** PCM bytes of one frame for the given profile (16 bit samples). */
export function frameBytes(profile: OpusProfile): number {
  return profile.sampleRate * profile.channelCount * 2 * profile.frameSizeMs / 1000;
}
