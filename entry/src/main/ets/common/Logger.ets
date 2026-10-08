import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x3200;
const TAG: string = 'OpusSample';

export class Logger {
  static info(message: string): void {
    hilog.info(DOMAIN, TAG, '%{public}s', message);
  }

  static warn(message: string): void {
    hilog.warn(DOMAIN, TAG, '%{public}s', message);
  }

  static error(message: string): void {
    hilog.error(DOMAIN, TAG, '%{public}s', message);
  }
}
