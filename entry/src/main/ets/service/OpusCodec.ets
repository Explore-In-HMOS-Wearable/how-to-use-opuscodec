import { createSession, destroy, flush, getCapability, getSessionInfo, getStats, push, setOutputCallback,
  start, stop } from 'libopuscodec.so';
import type { OpusCapability, OpusFrame, OpusSessionConfig, OpusSessionInfo, OpusStats } from 'libopuscodec.so';
import { Logger } from '../common/Logger';

export type OpusFrameHandler = (frame: OpusFrame) => void;

/**
 * One configured Opus codec instance.
 *
 * Lifecycle mirrors the AVCodec NDK exactly:
 *   createSession -> OH_AudioCodec_CreateByMime + Configure + Prepare
 *   open()        -> OH_AudioCodec_Start
 *   push()        -> OH_AudioCodec_PushInputBuffer (never blocks)
 *   close()       -> OH_AudioCodec_Stop + Destroy
 */
export class OpusCodec {
  private handle: number = -1;
  private readonly config: OpusSessionConfig;
  private readonly handler: OpusFrameHandler;

  constructor(config: OpusSessionConfig, handler: OpusFrameHandler) {
    this.config = config;
    this.handler = handler;
  }

  /** Creates the codec and starts it. Throws a BusinessError-like Error on failure. */
  open(): void {
    this.handle = createSession(this.config);
    setOutputCallback(this.handle, this.handler);
    start(this.handle);
    const info: OpusSessionInfo = getSessionInfo(this.handle);
    Logger.info(`opus ${info.isEncoder ? 'encoder' : 'decoder'} started: ${info.codecName}, ` +
      `${info.sampleRate} Hz / ${info.channelCount} ch / ${info.bitrate} bps, ` +
      `frame ${info.frameSizeMs} ms (${info.frameBytes} PCM bytes), ${info.configNote}`);
  }

  get isOpen(): boolean {
    return this.handle >= 0;
  }

  /** Returns false when the codec had no free input buffer and dropped the frame. */
  push(data: ArrayBuffer, ptsUs: number, flags: number): boolean {
    if (this.handle < 0) {
      return false;
    }
    return push(this.handle, data, ptsUs, flags);
  }

  flush(): void {
    if (this.handle >= 0) {
      flush(this.handle);
    }
  }

  stats(): OpusStats {
    if (this.handle < 0) {
      return {
        inFrames: 0, outFrames: 0, inBytes: 0, outBytes: 0, dropped: 0,
        lastLatencyMs: 0, avgLatencyMs: 0, maxLatencyMs: 0
      };
    }
    return getStats(this.handle);
  }

  info(): OpusSessionInfo | undefined {
    return this.handle < 0 ? undefined : getSessionInfo(this.handle);
  }

  close(): void {
    if (this.handle < 0) {
      return;
    }
    stop(this.handle);
    destroy(this.handle);
    this.handle = -1;
  }
}

/** Reads what this device actually offers for audio/opus. */
export function readCapabilities(): OpusCapability[] {
  return [getCapability(true), getCapability(false)];
}

export function describeCapability(cap: OpusCapability): string {
  if (!cap.supported) {
    return `${cap.isEncoder ? 'Encoder' : 'Decoder'}: not available`;
  }
  const role: string = cap.isEncoder ? 'Encoder' : 'Decoder';
  const rates: string = cap.sampleRates.length > 0 ? cap.sampleRates.join('/') : 'unreported';
  let text: string = `${role}: ${cap.name || 'audio/opus'}\n` +
    `${cap.isHardware ? 'hardware' : 'software'}, ${rates} Hz, ${cap.channelMin}-${cap.channelMax} ch`;
  if (cap.isEncoder && cap.bitrateMax > 0) {
    text += `\nbitrate ${cap.bitrateMin}-${cap.bitrateMax} bps, complexity ${cap.complexityMin}-${cap.complexityMax}`;
  }
  return text;
}
