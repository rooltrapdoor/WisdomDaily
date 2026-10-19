import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * 统一日志出口。
 *
 * 所有数据层日志都经过这里，便于：
 *  - 集中控制 domain/tag，方便 `hdc shell hilog` 过滤；
 *  - 保证日志格式一致，便于排查数据库问题。
 */
const DOMAIN: number = 0x0A01;
const PREFIX: string = 'WSD'; // WisdomDaily，旧名 KCB 已随应用改名统一

export class Logger {
  private static wrap(tag: string): string {
    return `${PREFIX}_${tag}`;
  }

  static debug(tag: string, message: string): void {
    hilog.debug(DOMAIN, Logger.wrap(tag), '%{public}s', message);
  }

  static info(tag: string, message: string): void {
    hilog.info(DOMAIN, Logger.wrap(tag), '%{public}s', message);
  }

  static warn(tag: string, message: string): void {
    hilog.warn(DOMAIN, Logger.wrap(tag), '%{public}s', message);
  }

  static error(tag: string, message: string): void {
    hilog.error(DOMAIN, Logger.wrap(tag), '%{public}s', message);
  }
}
