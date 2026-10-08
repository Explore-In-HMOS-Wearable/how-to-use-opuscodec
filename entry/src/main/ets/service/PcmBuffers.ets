/**
 * Small byte helpers that sit between the audio callbacks and the codec.
 *
 * AudioCapturer hands over whatever the audio HAL produced, which is not the
 * Opus frame size, and AudioRenderer asks for whatever it needs right now.
 * Both sides therefore need a re-chunking step.
 */

/** Collects captured PCM and hands it out in fixed size frames. */
export class FrameSplitter {
  private readonly frameSize: number;
  private buffer: Uint8Array;
  private length: number = 0;

  constructor(frameSize: number) {
    this.frameSize = frameSize;
    this.buffer = new Uint8Array(frameSize * 8);
  }

  append(data: Uint8Array): void {
    if (this.length + data.length > this.buffer.length) {
      const grown: Uint8Array = new Uint8Array((this.length + data.length) * 2);
      grown.set(this.buffer.subarray(0, this.length), 0);
      this.buffer = grown;
    }
    this.buffer.set(data, this.length);
    this.length += data.length;
  }

  /** Detaches the next complete frame, or undefined when more input is needed. */
  next(): ArrayBuffer | undefined {
    if (this.length < this.frameSize) {
      return undefined;
    }
    const frame: Uint8Array = this.buffer.slice(0, this.frameSize);
    this.buffer.copyWithin(0, this.frameSize, this.length);
    this.length -= this.frameSize;
    return frame.buffer as ArrayBuffer;
  }

  reset(): void {
    this.length = 0;
  }
}

/**
 * Lock free enough for one producer (decoder callback) and one consumer
 * (renderer writeData callback): both run on the ArkTS thread, so plain
 * indices are sufficient.
 */
export class PcmRingBuffer {
  private readonly data: Uint8Array;
  private readIndex: number = 0;
  private writeIndex: number = 0;
  private filled: number = 0;
  private overflowBytes: number = 0;
  private underrunBytes: number = 0;

  constructor(capacityBytes: number) {
    this.data = new Uint8Array(capacityBytes);
  }

  write(source: Uint8Array): void {
    for (let i = 0; i < source.length; i++) {
      if (this.filled === this.data.length) {
        // Keep the newest audio: an overrun means playback fell behind.
        this.readIndex = (this.readIndex + 1) % this.data.length;
        this.filled--;
        this.overflowBytes++;
      }
      this.data[this.writeIndex] = source[i];
      this.writeIndex = (this.writeIndex + 1) % this.data.length;
      this.filled++;
    }
  }

  /** Fills target completely, padding with silence on underrun. */
  read(target: Uint8Array): number {
    let copied: number = 0;
    while (copied < target.length && this.filled > 0) {
      target[copied] = this.data[this.readIndex];
      this.readIndex = (this.readIndex + 1) % this.data.length;
      this.filled--;
      copied++;
    }
    for (let i = copied; i < target.length; i++) {
      target[i] = 0;
    }
    this.underrunBytes += target.length - copied;
    return copied;
  }

  get available(): number {
    return this.filled;
  }

  get overflows(): number {
    return this.overflowBytes;
  }

  get underruns(): number {
    return this.underrunBytes;
  }

  reset(): void {
    this.readIndex = 0;
    this.writeIndex = 0;
    this.filled = 0;
    this.overflowBytes = 0;
    this.underrunBytes = 0;
  }
}

/** Concatenates PCM chunks into one buffer, used when exporting a WAV file. */
export class PcmCollector {
  private readonly chunks: Array<Uint8Array> = [];
  private total: number = 0;

  add(chunk: Uint8Array): void {
    this.chunks.push(chunk);
    this.total += chunk.length;
  }

  get byteLength(): number {
    return this.total;
  }

  merge(): Uint8Array {
    const merged: Uint8Array = new Uint8Array(this.total);
    let offset: number = 0;
    for (const chunk of this.chunks) {
      merged.set(chunk, offset);
      offset += chunk.length;
    }
    return merged;
  }

  clear(): void {
    this.chunks.length = 0;
    this.total = 0;
  }
}
