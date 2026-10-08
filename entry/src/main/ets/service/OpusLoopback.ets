import { audio } from '@kit.AudioKit';
import { BusinessError } from '@kit.BasicServicesKit';
import type { OpusFrame } from 'libopuscodec.so';
import { Logger } from '../common/Logger';
import { BufferFlags, decoderConfig, encoderConfig, frameBytes } from '../model/OpusProfiles';
import type { OpusProfile } from '../model/OpusProfiles';
import { OpusCodec } from './OpusCodec';
import { FrameSplitter, PcmCollector, PcmRingBuffer } from './PcmBuffers';

/** Everything the UI shows while the loopback runs. */
export interface LoopbackMetrics {
  running: boolean;
  encoderName: string;
  decoderName: string;
  configNote: string;
  frameDurationMs: number;
  framesEncoded: number;
  packets: number;
  avgPacketBytes: number;
  measuredKbps: number;
  compressionRatio: number;
  encodeLatencyMs: number;
  decodeLatencyMs: number;
  pipelineLatencyMs: number;
  droppedFrames: number;
  underrunMs: number;
  capturedSeconds: number;
  lastError: string;
}

const MAX_CAPTURE_SECONDS: number = 12;
/** Three frames of jitter buffer: enough to absorb a late codec callback. */
const RING_FRAMES: number = 3;

function toSamplingRate(rate: number): audio.AudioSamplingRate {
  switch (rate) {
    case 8000:
      return audio.AudioSamplingRate.SAMPLE_RATE_8000;
    case 12000:
      return audio.AudioSamplingRate.SAMPLE_RATE_12000;
    case 24000:
      return audio.AudioSamplingRate.SAMPLE_RATE_24000;
    case 48000:
      return audio.AudioSamplingRate.SAMPLE_RATE_48000;
    default:
      return audio.AudioSamplingRate.SAMPLE_RATE_16000;
  }
}

function toChannels(count: number): audio.AudioChannel {
  return count === 2 ? audio.AudioChannel.CHANNEL_2 : audio.AudioChannel.CHANNEL_1;
}

/**
 * Microphone -> Opus encoder -> Opus decoder -> speaker, frame by frame.
 *
 * Nothing in this chain waits for anything: the capturer callback pushes a
 * frame and returns, the codec answers on its own thread and the renderer
 * callback drains a ring buffer. That is what keeps the added delay at roughly
 * one frame plus the codec round trip.
 */
export class OpusLoopback {
  private profile: OpusProfile | undefined = undefined;
  private encoder: OpusCodec | undefined = undefined;
  private decoder: OpusCodec | undefined = undefined;
  private capturer: audio.AudioCapturer | undefined = undefined;
  private renderer: audio.AudioRenderer | undefined = undefined;

  private splitter: FrameSplitter | undefined = undefined;
  private ring: PcmRingBuffer | undefined = undefined;
  private readonly decodedPcm: PcmCollector = new PcmCollector();
  private readonly encodedPackets: Array<Uint8Array> = [];

  private ptsUs: number = 0;
  private frameDurationUs: number = 20000;
  private captureTimeByPts: Map<number, number> = new Map();
  private packetBytes: number = 0;
  private packetCount: number = 0;
  private pipelineLatencyMs: number = 0;
  private startTime: number = 0;
  private lastError: string = '';
  private running: boolean = false;

  isRunning(): boolean {
    return this.running;
  }

  /** Decoded PCM of the last run, ready to be written out as a WAV file. */
  capturedPcm(): Uint8Array {
    return this.decodedPcm.merge();
  }

  capturedProfile(): OpusProfile | undefined {
    return this.profile;
  }

  /** Raw Opus packets of the last run, length prefixed by the caller. */
  capturedPackets(): Array<Uint8Array> {
    return this.encodedPackets;
  }

  async start(profile: OpusProfile): Promise<void> {
    if (this.running) {
      return;
    }
    this.reset(profile);

    // 1. Codecs first, so the audio callbacks always find them ready.
    this.encoder = new OpusCodec(encoderConfig(profile), (frame: OpusFrame) => this.onEncoded(frame));
    this.encoder.open();
    this.decoder = new OpusCodec(decoderConfig(profile), (frame: OpusFrame) => this.onDecoded(frame));
    this.decoder.open();

    const streamInfo: audio.AudioStreamInfo = {
      samplingRate: toSamplingRate(profile.sampleRate),
      channels: toChannels(profile.channelCount),
      sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
      encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
    };

    // 2. Capture. SOURCE_TYPE_VOICE_COMMUNICATION asks the system for the
    //    low-latency voice path, including echo cancellation, which a
    //    microphone-to-speaker loop needs to stay usable.
    const capturerOptions: audio.AudioCapturerOptions = {
      streamInfo: streamInfo,
      capturerInfo: { source: audio.SourceType.SOURCE_TYPE_VOICE_COMMUNICATION, capturerFlags: 0 }
    };
    const capturer: audio.AudioCapturer = await audio.createAudioCapturer(capturerOptions);
    capturer.on('readData', (buffer: ArrayBuffer) => this.onCaptured(buffer));
    this.capturer = capturer;

    // 3. Playback of the decoded stream.
    const rendererOptions: audio.AudioRendererOptions = {
      streamInfo: streamInfo,
      rendererInfo: { usage: audio.StreamUsage.STREAM_USAGE_VOICE_COMMUNICATION, rendererFlags: 0 }
    };
    const renderer: audio.AudioRenderer = await audio.createAudioRenderer(rendererOptions);
    renderer.on('writeData', (buffer: ArrayBuffer) => this.onRenderRequest(buffer));
    this.renderer = renderer;

    await renderer.start();
    await capturer.start();
    this.running = true;
    this.startTime = Date.now();
    Logger.info(`loopback started with profile ${profile.key}`);
  }

  async stop(): Promise<void> {
    if (!this.running) {
      return;
    }
    this.running = false;
    const capturer: audio.AudioCapturer | undefined = this.capturer;
    const renderer: audio.AudioRenderer | undefined = this.renderer;
    try {
      if (capturer !== undefined) {
        capturer.off('readData');
        await capturer.stop();
        await capturer.release();
      }
      if (renderer !== undefined) {
        renderer.off('writeData');
        await renderer.stop();
        await renderer.release();
      }
    } catch (error) {
      const err = error as BusinessError;
      Logger.error(`failed to release audio streams: ${err.code} ${err.message}`);
    }
    this.capturer = undefined;
    this.renderer = undefined;
    this.encoder?.close();
    this.decoder?.close();
    Logger.info(`loopback stopped, ${this.packetCount} Opus packets, ${this.decodedPcm.byteLength} PCM bytes`);
  }

  metrics(): LoopbackMetrics {
    const encoderStats = this.encoder?.stats();
    const decoderStats = this.decoder?.stats();
    const info = this.encoder?.info();
    const decoderInfo = this.decoder?.info();
    const elapsedSeconds: number = this.startTime === 0 ? 0 : (Date.now() - this.startTime) / 1000;
    const frameMs: number = this.frameDurationUs / 1000;
    const pcmBytesPerSecond: number = this.profile === undefined ? 1
      : this.profile.sampleRate * this.profile.channelCount * 2;
    const measuredKbps: number = elapsedSeconds > 0 ? (this.packetBytes * 8) / elapsedSeconds / 1000 : 0;
    const underrunBytes: number = this.ring === undefined ? 0 : this.ring.underruns;

    return {
      running: this.running,
      encoderName: info === undefined ? '-' : info.codecName,
      decoderName: decoderInfo === undefined ? '-' : decoderInfo.codecName,
      configNote: decoderInfo === undefined ? '-' : decoderInfo.configNote,
      frameDurationMs: frameMs,
      framesEncoded: encoderStats === undefined ? 0 : encoderStats.inFrames,
      packets: this.packetCount,
      avgPacketBytes: this.packetCount === 0 ? 0 : Math.round(this.packetBytes / this.packetCount),
      measuredKbps: measuredKbps,
      compressionRatio: measuredKbps > 0 ? (pcmBytesPerSecond * 8 / 1000) / measuredKbps : 0,
      encodeLatencyMs: encoderStats === undefined ? 0 : encoderStats.avgLatencyMs,
      decodeLatencyMs: decoderStats === undefined ? 0 : decoderStats.avgLatencyMs,
      pipelineLatencyMs: this.pipelineLatencyMs,
      droppedFrames: (encoderStats === undefined ? 0 : encoderStats.dropped) +
        (decoderStats === undefined ? 0 : decoderStats.dropped),
      underrunMs: pcmBytesPerSecond > 0 ? underrunBytes * 1000 / pcmBytesPerSecond : 0,
      capturedSeconds: pcmBytesPerSecond > 0 ? this.decodedPcm.byteLength / pcmBytesPerSecond : 0,
      lastError: this.lastError
    };
  }

  private reset(profile: OpusProfile): void {
    const bytesPerFrame: number = frameBytes(profile);
    this.profile = profile;
    this.frameDurationUs = profile.frameSizeMs * 1000;
    this.splitter = new FrameSplitter(bytesPerFrame);
    this.ring = new PcmRingBuffer(bytesPerFrame * RING_FRAMES);
    this.decodedPcm.clear();
    this.encodedPackets.length = 0;
    this.ptsUs = 0;
    this.captureTimeByPts = new Map();
    this.packetBytes = 0;
    this.packetCount = 0;
    this.pipelineLatencyMs = 0;
    this.startTime = 0;
    this.lastError = '';
  }

  /** AudioCapturer callback: copy, split into Opus frames, hand to the encoder. */
  private onCaptured(buffer: ArrayBuffer): void {
    if (!this.running || this.splitter === undefined || this.encoder === undefined) {
      return;
    }
    // The framework reuses this ArrayBuffer, so the data has to be copied here.
    this.splitter.append(new Uint8Array(buffer.slice(0)));
    while (true) {
      const frame: ArrayBuffer | undefined = this.splitter.next();
      if (frame === undefined) {
        break;
      }
      const pts: number = this.ptsUs;
      this.ptsUs += this.frameDurationUs;
      this.captureTimeByPts.set(pts, Date.now());
      if (!this.encoder.push(frame, pts, BufferFlags.NONE)) {
        this.captureTimeByPts.delete(pts);
      }
    }
  }

  private onEncoded(frame: OpusFrame): void {
    if (frame.errorCode !== 0) {
      this.lastError = `encoder error ${frame.errorCode}`;
      Logger.error(this.lastError);
      return;
    }
    if (this.decoder === undefined) {
      return;
    }
    if ((frame.flags & BufferFlags.CODEC_DATA) !== 0) {
      // Opus identification header: the decoder needs it before the first
      // packet, exactly as a demuxer would deliver it.
      this.decoder.push(frame.data, frame.pts, BufferFlags.CODEC_DATA);
      Logger.info(`forwarded ${frame.data.byteLength} bytes of Opus codec data to the decoder`);
      return;
    }
    this.packetCount++;
    this.packetBytes += frame.data.byteLength;
    if (this.decodedPcm.byteLength < this.captureLimitBytes()) {
      this.encodedPackets.push(new Uint8Array(frame.data.slice(0)));
    }
    this.decoder.push(frame.data, frame.pts, BufferFlags.NONE);
  }

  private onDecoded(frame: OpusFrame): void {
    if (frame.errorCode !== 0) {
      this.lastError = `decoder error ${frame.errorCode}`;
      Logger.error(this.lastError);
      return;
    }
    const pcm: Uint8Array = new Uint8Array(frame.data);
    this.ring?.write(pcm);
    if (this.decodedPcm.byteLength < this.captureLimitBytes()) {
      this.decodedPcm.add(new Uint8Array(frame.data.slice(0)));
    }
    const capturedAt: number | undefined = this.captureTimeByPts.get(frame.pts);
    if (capturedAt !== undefined) {
      this.captureTimeByPts.delete(frame.pts);
      const elapsed: number = Date.now() - capturedAt;
      // Exponential moving average keeps the reading readable on screen.
      this.pipelineLatencyMs = this.pipelineLatencyMs === 0 ? elapsed
        : this.pipelineLatencyMs * 0.9 + elapsed * 0.1;
    }
  }

  private onRenderRequest(buffer: ArrayBuffer): audio.AudioDataCallbackResult {
    const target: Uint8Array = new Uint8Array(buffer);
    this.ring?.read(target);
    return audio.AudioDataCallbackResult.VALID;
  }

  private captureLimitBytes(): number {
    if (this.profile === undefined) {
      return 0;
    }
    return this.profile.sampleRate * this.profile.channelCount * 2 * MAX_CAPTURE_SECONDS;
  }
}
