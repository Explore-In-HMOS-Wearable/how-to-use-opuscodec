import { fileIo as fs } from '@kit.CoreFileKit';
import { Logger } from '../common/Logger';
import type { OpusProfile } from '../model/OpusProfiles';

const WAV_HEADER_BYTES: number = 44;
const PCM_FORMAT_TAG: number = 1;
const BITS_PER_SAMPLE: number = 16;

function writeAscii(view: DataView, offset: number, text: string): void {
  for (let i = 0; i < text.length; i++) {
    view.setUint8(offset + i, text.charCodeAt(i));
  }
}

/**
 * Wraps raw PCM in a RIFF/WAVE header.
 *
 * AVPlayer has no Opus demuxer to hand raw packets to, and the muxer NDK only
 * writes mp4/m4a/mp3/amr/wav/aac. So the decoded PCM is what gets handed to
 * AVPlayer, which is also the honest picture of the pipeline: AVCodec decodes,
 * AVPlayer renders.
 */
export function buildWav(pcm: Uint8Array, sampleRate: number, channels: number): ArrayBuffer {
  const byteRate: number = sampleRate * channels * BITS_PER_SAMPLE / 8;
  const blockAlign: number = channels * BITS_PER_SAMPLE / 8;
  const buffer: ArrayBuffer = new ArrayBuffer(WAV_HEADER_BYTES + pcm.length);
  const view: DataView = new DataView(buffer);

  writeAscii(view, 0, 'RIFF');
  view.setUint32(4, 36 + pcm.length, true);
  writeAscii(view, 8, 'WAVE');
  writeAscii(view, 12, 'fmt ');
  view.setUint32(16, 16, true);                  // PCM chunk size
  view.setUint16(20, PCM_FORMAT_TAG, true);
  view.setUint16(22, channels, true);
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, byteRate, true);
  view.setUint16(32, blockAlign, true);
  view.setUint16(34, BITS_PER_SAMPLE, true);
  writeAscii(view, 36, 'data');
  view.setUint32(40, pcm.length, true);
  new Uint8Array(buffer).set(pcm, WAV_HEADER_BYTES);
  return buffer;
}

/**
 * Length prefixed container for the encoded packets.
 *
 * Opus packets are self delimiting only inside a container such as Ogg, so a
 * raw dump needs its own framing before it can be replayed. Header layout:
 * "OPUSRAW1" | sampleRate u32 | channels u8 | frameMs u8 | reserved u16,
 * then per packet: length u16 followed by the payload.
 */
export function buildOpusStream(packets: Array<Uint8Array>, profile: OpusProfile): ArrayBuffer {
  let payloadBytes: number = 0;
  for (const packet of packets) {
    payloadBytes += packet.length + 2;
  }
  const buffer: ArrayBuffer = new ArrayBuffer(16 + payloadBytes);
  const view: DataView = new DataView(buffer);
  writeAscii(view, 0, 'OPUSRAW1');
  view.setUint32(8, profile.sampleRate, true);
  view.setUint8(12, profile.channelCount);
  view.setUint8(13, profile.frameSizeMs);
  view.setUint16(14, 0, true);

  const bytes: Uint8Array = new Uint8Array(buffer);
  let offset: number = 16;
  for (const packet of packets) {
    view.setUint16(offset, packet.length, true);
    offset += 2;
    bytes.set(packet, offset);
    offset += packet.length;
  }
  return buffer;
}

/** Writes a buffer into the sandbox files directory and returns its path. */
export function writeToFilesDir(filesDir: string, fileName: string, data: ArrayBuffer): string {
  const path: string = `${filesDir}/${fileName}`;
  const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
  try {
    fs.writeSync(file.fd, data);
  } finally {
    fs.closeSync(file);
  }
  Logger.info(`wrote ${data.byteLength} bytes to ${path}`);
  return path;
}
