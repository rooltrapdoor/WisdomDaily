import { Logger } from '../common/Logger';
import { delay, errText, isDbLocked } from '../common/Util';

const TAG: string = 'DbLock';

/**
 * 「数据库被占用」的重试策略。
 *
 * ## 为什么需要它
 *
 * 桌面卡片（`EntryFormAbility`）与应用界面分别跑在两个进程里，却共用同一个库文件。
 * 只要两边在同一时刻都想拿写锁，后来者就会收到 `14800024`（SQLite: The database file is locked）。
 * 这个错误是**瞬时**的：对方的事务提交完，锁就没了，几毫秒后重来一定能成。
 *
 * 但它的表现一点也不"瞬时"：`Index.refresh()` 里任何一步抛出去，整页就变成
 * 「课表加载失败」+ 一片空白 —— 用户以为数据丢了。所以在这一层把锁等掉，
 * 让上层只看到"这次刷新稍微慢了一点点"。
 *
 * ## 什么时候可以重试，什么时候绝对不能
 *
 * 判据是「这段操作重来一次，会不会造成副作用翻倍」：
 *  - 单条语句（`StoreExecutor` 那条自动提交的连接）→ 可以：SQLite 报 BUSY 时这条语句根本没执行；
 *  - 整个事务（`runInTransaction`）→ 可以，但**只在提交之前**：
 *    提交阶段出错说明"可能已经落库了但没收到回复"，重放会写两遍。
 *
 * ## 等待多久
 *
 * 指数退避 80 / 160 / 320 / 640 / 800 ms，最多 5 次（合计约 2 秒）。
 * 上限刻意压在 2 秒级：卡片的定时刷新事务是毫秒级的，等这么久足够；
 * 但也不能无限等 —— 真出了死锁，宁可报错也不能把界面卡住。
 */
export class DbLock {
  /** 含首次在内最多尝试几次 */
  static readonly MAX_ATTEMPTS: number = 5;
  /** 第一次重试前等待的毫秒数，之后逐次翻倍 */
  private static readonly BASE_BACKOFF_MS: number = 80;
  /** 单次等待的上限毫秒数 */
  private static readonly MAX_BACKOFF_MS: number = 800;

  /** 是不是"数据库被占用"（可重试）—— 判据集中在 `Util.isDbLocked`，这里只做转发便于调用方少一个依赖 */
  static isLock(e: Object): boolean {
    return isDbLocked(e);
  }

  /** 第 attempt 次重试前的等待：80 / 160 / 320 / 640 / 800 … 毫秒 */
  static backoff(attempt: number): Promise<void> {
    let ms: number = DbLock.BASE_BACKOFF_MS;
    for (let i = 1; i < attempt; i++) {
      ms = ms * 2;
      if (ms >= DbLock.MAX_BACKOFF_MS) {
        ms = DbLock.MAX_BACKOFF_MS;
        break;
      }
    }
    return delay(ms);
  }

  /**
   * 把一段「要么整体成功、要么什么都没发生」的操作包成「遇锁自动重试」。
   *
   * 传进来的 `op` 必须满足这个前提 —— 语句级的自动提交、或"提交前的事务"都满足；
   * 已经走到 commit 的路径不要用它（见类注释）。
   */
  static async run<T>(label: string, op: () => Promise<T>): Promise<T> {
    for (let attempt = 1; attempt <= DbLock.MAX_ATTEMPTS; attempt++) {
      try {
        return await op();
      } catch (e) {
        if (!DbLock.isLock(e) || attempt >= DbLock.MAX_ATTEMPTS) {
          throw e as Error;
        }
        Logger.warn(TAG, `${label} 遇数据库占用，第 ${attempt} 次重试：${errText(e)}`);
        await DbLock.backoff(attempt);
      }
    }
    // 到不了这里：最后一次失败必然在上面那个 catch 里抛出去了
    throw new Error(`${label} 重试 ${DbLock.MAX_ATTEMPTS} 次仍未成功`);
  }
}
