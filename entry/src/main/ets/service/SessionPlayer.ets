import { avSession } from '@kit.AVSessionKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { media } from '@kit.MediaKit';
import { Logger } from '../common/Logger';

export interface PlayerStatus {
  state: string;
  positionMs: number;
  durationMs: number;
  sessionActive: boolean;
  detail: string;
}

/**
 * Plays the decoded Opus material through AVPlayer and publishes it to the
 * system through AVSessionKit, so the watch media controls drive the same
 * player instance.
 *
 * The chain is: Opus packets -> AVCodec decoder (native module) -> PCM -> WAV
 * in the app sandbox -> AVPlayer. AVPlayer has no Opus elementary stream input,
 * so the decode step stays with AVCodec and AVPlayer takes over from there.
 */
export class SessionPlayer {
  private player: media.AVPlayer | undefined = undefined;
  private session: avSession.AVSession | undefined = undefined;
  private file: fs.File | undefined = undefined;
  private state: string = 'idle';
  private positionMs: number = 0;
  private durationMs: number = 0;
  private detail: string = '';
  private preparedResolve: (() => void) | undefined = undefined;
  private preparedReject: ((error: Error) => void) | undefined = undefined;
  private onChange: (() => void) | undefined = undefined;

  setListener(listener: () => void): void {
    this.onChange = listener;
  }

  status(): PlayerStatus {
    return {
      state: this.state,
      positionMs: this.positionMs,
      durationMs: this.durationMs,
      sessionActive: this.session !== undefined,
      detail: this.detail
    };
  }

  /** Loads the WAV file and, when supported, publishes an AVSession for it. */
  async prepare(context: common.UIAbilityContext, filePath: string, title: string): Promise<void> {
    await this.release();

    this.player = await media.createAVPlayer();
    this.bindPlayerEvents(this.player);

    const prepared: Promise<void> = new Promise<void>((resolve: () => void,
                                                       reject: (error: Error) => void) => {
      this.preparedResolve = resolve;
      this.preparedReject = reject;
    });

    // The file stays open while the player reads from it. Once preparation succeeds,
    // ownership moves to this.file and release() closes it. If preparation fails,
    // the player is released first and the finally block closes the file.
    let file: fs.File | undefined = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
    try {
      // Setting the source moves the player from the idle state to the initialized
      // state. The rest of the state machine is driven from the stateChange handler.
      this.player.fdSrc = { fd: file.fd };
      await prepared;
      this.file = file;
      file = undefined;
    } catch (error) {
      await this.release();
      throw error as Error;
    } finally {
      if (file !== undefined) {
        fs.closeSync(file);
      }
    }

    await this.setUpSession(context, title);
  }

  async play(): Promise<void> {
    await this.player?.play();
  }

  async pause(): Promise<void> {
    await this.player?.pause();
  }

  async stop(): Promise<void> {
    if (this.player !== undefined && (this.state === 'playing' || this.state === 'paused')) {
      await this.player.stop();
    }
  }

  async release(): Promise<void> {
    try {
      if (this.session !== undefined) {
        await this.session.deactivate();
        await this.session.destroy();
      }
    } catch (error) {
      const err = error as BusinessError;
      Logger.error(`failed to destroy AVSession: ${err.code} ${err.message}`);
    }
    this.session = undefined;

    try {
      if (this.player !== undefined) {
        await this.player.release();
      }
    } catch (error) {
      const err = error as BusinessError;
      Logger.error(`failed to release AVPlayer: ${err.code} ${err.message}`);
    } finally {
      this.player = undefined;
      if (this.file !== undefined) {
        fs.closeSync(this.file);
        this.file = undefined;
      }
    }
    this.state = 'idle';
    this.positionMs = 0;
    this.notify();
  }

  private bindPlayerEvents(player: media.AVPlayer): void {
    player.on('stateChange', (state: media.AVPlayerState, reason: media.StateChangeReason) => {
      this.state = state;
      Logger.info(`AVPlayer state: ${state} (reason ${reason})`);
      if (state === 'initialized') {
        player.prepare().catch((error: BusinessError) => {
          this.detail = `AVPlayer prepare failed: ${error.code} ${error.message}`;
          Logger.error(this.detail);
          this.preparedReject?.(new Error(this.detail));
          this.preparedResolve = undefined;
          this.preparedReject = undefined;
        });
      } else if (state === 'prepared') {
        this.durationMs = player.duration;
        this.preparedResolve?.();
        this.preparedResolve = undefined;
        this.preparedReject = undefined;
      }
      this.publishPlaybackState();
      this.notify();
    });

    player.on('timeUpdate', (time: number) => {
      this.positionMs = time;
      this.notify();
    });

    player.on('error', (error: BusinessError) => {
      this.detail = `AVPlayer error ${error.code}: ${error.message}`;
      Logger.error(this.detail);
      this.preparedReject?.(new Error(this.detail));
      this.preparedResolve = undefined;
      this.preparedReject = undefined;
      this.notify();
    });
  }

  /**
   * AVSessionKit is optional on some device types, so the player stays usable
   * when the capability is missing.
   */
  private async setUpSession(context: common.UIAbilityContext, title: string): Promise<void> {
    if (!canIUse('SystemCapability.Multimedia.AVSession.Core')) {
      this.detail = 'AVSession is not available on this device, playing locally';
      Logger.warn(this.detail);
      return;
    }
    try {
      this.session = await avSession.createAVSession(context, 'opus_codec_sample', 'audio');
      const metadata: avSession.AVMetadata = {
        assetId: 'opus-loopback-capture',
        title: title,
        artist: 'Opus codec sample',
        duration: this.durationMs
      };
      await this.session.setAVMetadata(metadata);

      this.session.on('play', () => {
        this.play();
      });
      this.session.on('pause', () => {
        this.pause();
      });
      this.session.on('stop', () => {
        this.stop();
      });
      this.session.on('seek', (time: number) => {
        this.player?.seek(time);
      });

      await this.session.activate();
      this.detail = 'AVSession active, system media controls are wired to AVPlayer';
      this.publishPlaybackState();
    } catch (error) {
      const err = error as BusinessError;
      this.detail = `AVSession setup failed: ${err.code} ${err.message}`;
      Logger.error(this.detail);
      this.session = undefined;
    }
  }

  private publishPlaybackState(): void {
    if (this.session === undefined) {
      return;
    }
    let sessionState: avSession.PlaybackState = avSession.PlaybackState.PLAYBACK_STATE_INITIAL;
    if (this.state === 'playing') {
      sessionState = avSession.PlaybackState.PLAYBACK_STATE_PLAY;
    } else if (this.state === 'paused') {
      sessionState = avSession.PlaybackState.PLAYBACK_STATE_PAUSE;
    } else if (this.state === 'stopped' || this.state === 'completed') {
      sessionState = avSession.PlaybackState.PLAYBACK_STATE_STOP;
    } else if (this.state === 'prepared') {
      sessionState = avSession.PlaybackState.PLAYBACK_STATE_PREPARE;
    }
    const playbackState: avSession.AVPlaybackState = {
      state: sessionState,
      speed: 1,
      position: { elapsedTime: this.positionMs, updateTime: Date.now() }
    };
    this.session.setAVPlaybackState(playbackState).catch((error: BusinessError) => {
      Logger.error(`setAVPlaybackState failed: ${error.code} ${error.message}`);
    });
  }

  private notify(): void {
    this.onChange?.();
  }
}
