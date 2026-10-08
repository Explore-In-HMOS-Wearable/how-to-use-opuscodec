import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../common/Logger';
import { OPUS_PROFILES, profileByKey } from '../model/OpusProfiles';
import type { OpusProfile } from '../model/OpusProfiles';
import { describeCapability, readCapabilities } from '../service/OpusCodec';
import { buildOpusStream, buildWav, writeToFilesDir } from '../service/MediaExport';
import { OpusLoopback } from '../service/OpusLoopback';
import type { LoopbackMetrics } from '../service/OpusLoopback';
import { SessionPlayer } from '../service/SessionPlayer';
import type { PlayerStatus } from '../service/SessionPlayer';

const MIC_PERMISSION: Permissions = 'ohos.permission.MICROPHONE';
const METRICS_INTERVAL_MS: number = 500;

function round(value: number, digits: number): string {
  return value.toFixed(digits);
}

@Entry
@Component
struct Index {
  private readonly loopback: OpusLoopback = new OpusLoopback();
  private readonly player: SessionPlayer = new SessionPlayer();
  private metricsTimer: number = -1;

  @State capabilityText: string = 'Reading codec capabilities...';
  @State selectedKey: string = OPUS_PROFILES[0].key;
  @State status: string = 'Idle';
  @State busy: boolean = false;
  @State running: boolean = false;
  @State metrics: LoopbackMetrics | undefined = undefined;
  @State playerStatus: PlayerStatus | undefined = undefined;
  @State exportedPath: string = '';

  aboutToAppear(): void {
    this.loadCapabilities();
    this.player.setListener(() => {
      this.playerStatus = this.player.status();
    });
  }

  aboutToDisappear(): void {
    this.stopMetricsTimer();
    this.loopback.stop();
    this.player.release();
  }

  /**
   * OH_AVCodec_GetCapability tells us what the device really offers before any
   * codec is created, which is the right place to fail fast.
   */
  private loadCapabilities(): void {
    try {
      const caps = readCapabilities();
      this.capabilityText = `${describeCapability(caps[0])}\n\n${describeCapability(caps[1])}`;
      if (!caps[0].supported || !caps[1].supported) {
        this.status = 'audio/opus is not fully supported here';
      }
    } catch (error) {
      const err = error as BusinessError;
      this.capabilityText = `Capability query failed: ${err.message}`;
      Logger.error(this.capabilityText);
    }
  }

  private async ensureMicPermission(): Promise<boolean> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const atManager = abilityAccessCtrl.createAtManager();
    try {
      const wanted: Array<Permissions> = [MIC_PERMISSION];
      const result = await atManager.requestPermissionsFromUser(context, wanted);
      const granted: boolean = result.authResults.length > 0 && result.authResults[0] === 0;
      if (!granted) {
        this.status = 'Microphone permission denied';
      }
      return granted;
    } catch (error) {
      const err = error as BusinessError;
      this.status = `Permission request failed: ${err.message}`;
      return false;
    }
  }

  private startMetricsTimer(): void {
    this.stopMetricsTimer();
    this.metricsTimer = setInterval(() => {
      this.metrics = this.loopback.metrics();
    }, METRICS_INTERVAL_MS);
  }

  private stopMetricsTimer(): void {
    if (this.metricsTimer !== -1) {
      clearInterval(this.metricsTimer);
      this.metricsTimer = -1;
    }
  }

  private async toggleLoopback(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      if (this.running) {
        await this.loopback.stop();
        this.stopMetricsTimer();
        this.metrics = this.loopback.metrics();
        this.running = false;
        this.status = 'Loopback stopped';
      } else {
        if (!await this.ensureMicPermission()) {
          return;
        }
        const profile: OpusProfile = profileByKey(this.selectedKey);
        await this.loopback.start(profile);
        this.running = true;
        this.status = `Running ${profile.label}`;
        this.startMetricsTimer();
      }
    } catch (error) {
      const err = error as BusinessError;
      this.status = `Loopback failed: ${err.message}`;
      Logger.error(`${this.status} (code ${err.code})`);
      this.running = false;
      this.stopMetricsTimer();
    } finally {
      this.busy = false;
    }
  }

  /** Writes the captured material out and hands the WAV to AVPlayer + AVSession. */
  private async exportAndPlay(): Promise<void> {
    if (this.busy) {
      return;
    }
    const profile: OpusProfile | undefined = this.loopback.capturedProfile();
    const pcm: Uint8Array = this.loopback.capturedPcm();
    if (profile === undefined || pcm.length === 0) {
      this.status = 'Nothing captured yet, run the loopback first';
      return;
    }
    this.busy = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const filesDir: string = context.filesDir;

      // The encoded stream is kept as well, so the size difference is visible
      // on disk and the packets can be replayed later.
      const packets = this.loopback.capturedPackets();
      writeToFilesDir(filesDir, 'loopback.opusraw', buildOpusStream(packets, profile));
      const wavPath: string = writeToFilesDir(filesDir, 'loopback.wav',
        buildWav(pcm, profile.sampleRate, profile.channelCount));
      this.exportedPath = wavPath;

      await this.player.prepare(context, wavPath, `Opus ${profile.label} capture`);
      await this.player.play();
      this.playerStatus = this.player.status();
      this.status = 'Playing decoded capture through AVPlayer';
    } catch (error) {
      const err = error as BusinessError;
      this.status = `Playback failed: ${err.message}`;
      Logger.error(this.status);
    } finally {
      this.busy = false;
    }
  }

  @Builder
  sectionTitle(text: string) {
    Text(text)
      .fontSize(13)
      .fontWeight(FontWeight.Bold)
      .fontColor('#7FD1FF')
      .width('100%')
      .margin({ top: 10, bottom: 4 });
  }

  @Builder
  metricRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(11)
        .fontColor('#9E9E9E')
        .layoutWeight(1);
      Text(value)
        .fontSize(11)
        .fontColor('#FFFFFF');
    }
    .width('100%')
    .padding({ top: 1, bottom: 1 });
  }

  @Builder
  profileChips() {
    Column({ space: 4 }) {
      ForEach(OPUS_PROFILES, (profile: OpusProfile) => {
        Button(`${profile.label}  ·  ${profile.sampleRate / 1000}k / ${profile.frameSizeMs}ms`)
          .fontSize(11)
          .width('100%')
          .height(30)
          .backgroundColor(this.selectedKey === profile.key ? '#1F6FEB' : '#2A2A2A')
          .enabled(!this.running)
          .onClick(() => {
            this.selectedKey = profile.key;
          });
      }, (profile: OpusProfile) => profile.key);

      Text(profileByKey(this.selectedKey).hint)
        .fontSize(10)
        .fontColor('#9E9E9E')
        .width('100%')
        .margin({ top: 2 });
    }
    .width('100%');
  }

  @Builder
  metricsPanel() {
    if (this.metrics !== undefined) {
      Column() {
        this.metricRow('Encoder', this.metrics!.encoderName);
        this.metricRow('Decoder cfg', this.metrics!.configNote);
        this.metricRow('Frame', `${this.metrics!.frameDurationMs} ms`);
        this.metricRow('Packets', `${this.metrics!.packets}`);
        this.metricRow('Avg packet', `${this.metrics!.avgPacketBytes} B`);
        this.metricRow('Measured rate', `${round(this.metrics!.measuredKbps, 1)} kbps`);
        this.metricRow('Compression', `${round(this.metrics!.compressionRatio, 1)} x`);
        this.metricRow('Encode', `${round(this.metrics!.encodeLatencyMs, 2)} ms`);
        this.metricRow('Decode', `${round(this.metrics!.decodeLatencyMs, 2)} ms`);
        this.metricRow('Mic to speaker', `${round(this.metrics!.pipelineLatencyMs, 1)} ms`);
        this.metricRow('Dropped', `${this.metrics!.droppedFrames}`);
        this.metricRow('Underrun', `${round(this.metrics!.underrunMs, 0)} ms`);
        this.metricRow('Captured', `${round(this.metrics!.capturedSeconds, 1)} s`);
        if (this.metrics!.lastError.length > 0) {
          Text(this.metrics!.lastError)
            .fontSize(10)
            .fontColor('#FF6B6B')
            .width('100%');
        }
      }
      .width('100%');
    }
  }

  @Builder
  playbackPanel() {
    Column({ space: 4 }) {
      Button(this.playerStatus === undefined ? 'Export + play (AVPlayer)' : 'Re-export + play')
        .fontSize(11)
        .width('100%')
        .height(32)
        .backgroundColor('#2A2A2A')
        .enabled(!this.busy && !this.running)
        .onClick(() => {
          this.exportAndPlay();
        });

      if (this.playerStatus !== undefined) {
        Row({ space: 6 }) {
          Button('Play')
            .fontSize(11)
            .layoutWeight(1)
            .height(28)
            .backgroundColor('#2A2A2A')
            .onClick(() => {
              this.player.play();
            });
          Button('Pause')
            .fontSize(11)
            .layoutWeight(1)
            .height(28)
            .backgroundColor('#2A2A2A')
            .onClick(() => {
              this.player.pause();
            });
          Button('Stop')
            .fontSize(11)
            .layoutWeight(1)
            .height(28)
            .backgroundColor('#2A2A2A')
            .onClick(() => {
              this.player.stop();
            });
        }
        .width('100%');

        this.metricRow('Player', this.playerStatus!.state);
        this.metricRow('Position',
          `${round(this.playerStatus!.positionMs / 1000, 1)} / ${round(this.playerStatus!.durationMs / 1000, 1)} s`);
        this.metricRow('AVSession', this.playerStatus!.sessionActive ? 'active' : 'off');
        if (this.playerStatus!.detail.length > 0) {
          Text(this.playerStatus!.detail)
            .fontSize(10)
            .fontColor('#9E9E9E')
            .width('100%');
        }
      }
      if (this.exportedPath.length > 0) {
        Text(this.exportedPath)
          .fontSize(9)
          .fontColor('#6E6E6E')
          .width('100%');
      }
    }
    .width('100%');
  }

  build() {
    Scroll() {
      Column({ space: 2 }) {
        Text('Opus Codec')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .margin({ top: 6 });
        Text(this.status)
          .fontSize(10)
          .fontColor(this.running ? '#7FD1FF' : '#9E9E9E')
          .width('100%')
          .textAlign(TextAlign.Center);

        this.sectionTitle('1 · Device capability');
        Text(this.capabilityText)
          .fontSize(10)
          .fontColor('#CFCFCF')
          .width('100%');

        this.sectionTitle('2 · Configuration');
        this.profileChips();

        this.sectionTitle('3 · Real-time loopback');
        Button(this.running ? 'Stop' : 'Start mic loopback')
          .fontSize(12)
          .width('100%')
          .height(34)
          .backgroundColor(this.running ? '#8B1F1F' : '#1F6FEB')
          .enabled(!this.busy)
          .onClick(() => {
            this.toggleLoopback();
          });
        this.metricsPanel();

        this.sectionTitle('4 · AVPlayer + AVSession');
        this.playbackPanel();

        Blank().height(16);
      }
      .width('100%')
      .padding({ left: 12, right: 12 });
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
    .scrollBar(BarState.Off);
  }
}
