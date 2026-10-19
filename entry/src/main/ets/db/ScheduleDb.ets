import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Logger } from '../common/Logger';
import { errText } from '../common/Util';
import {
  DB_NAME,
  DB_VERSION,
  DDL_INDEXES,
  DDL_TABLES,
  DDL_VIEWS,
  PRAGMA_SETUP
} from './TableSchema';
import { DbExecutor, StoreExecutor, TxExecutor } from './DbExecutor';
import { DbLock } from './DbLock';
import { MIGRATIONS, Migration } from './DbMigrations';

const TAG: string = 'ScheduleDb';

/** 「库还没被应用初始化过」的固定文案：卡片进程据此给出可读的空态，而不是"数据读取失败" */
const NOT_READY_MESSAGE: string = '数据库尚未初始化（请先打开一次应用）';

/**
 * RelationalStore 连接与 schema 生命周期的唯一入口（进程内单例）。
 *
 * 职责：
 *  1. 打开 / 复用数据库连接（并发调用只真正打开一次）；
 *  2. 首次安装建表建索引，老用户按 user_version 逐级迁移；
 *  3. 提供事务执行器给上层；
 *  4. 提供数据库级备份与恢复（`store.backup` / `store.restore`）。
 *
 * 不负责：任何业务语义。表怎么读写由 DAO 决定，事务边界由 Repository 决定。
 *
 * ## 「只读用途」的开口（`init(context, false)`）
 *
 * 桌面卡片（`EntryFormAbility`）与应用界面是两个进程、共用这一个库文件。
 * 卡片只需要**看**数据，却和界面一样走 `init()` —— 于是每 30 分钟的卡片刷新都会
 * 顺手改 PRAGMA、开写事务，平白多出一堆跨进程的锁竞争（`14800024`）。
 * `allowWrites = false` 就是给这类调用方的开关：**跳过一切写操作**，只打开连接读数据。
 * 注意它不是 `StoreConfig.isReadOnly` —— WAL 模式下读连接也得能写 `-wal`/`-shm` 文件，
 * 真开成只读反而打不开库。这里禁的是"应用层主动写"。
 */
export class ScheduleDb {
  private static instance: ScheduleDb | null = null;

  private store: relationalStore.RdbStore | null = null;
  private storeExecutor: StoreExecutor | null = null;
  /** 并发 init 的合流点：同一时刻只允许一次真实打开 */
  private opening: Promise<void> | null = null;
  /** 当前连接是不是按"可以写"打开的（用于判断"要不要为写请求换一条连接"） */
  private storeAllowsWrites: boolean = false;

  private constructor() {
  }

  static getInstance(): ScheduleDb {
    if (ScheduleDb.instance === null) {
      ScheduleDb.instance = new ScheduleDb();
    }
    return ScheduleDb.instance;
  }

  /**
   * 幂等初始化。可在 EntryAbility.onCreate 里 await，也可在首个页面 aboutToAppear 里 await。
   *
   * @param allowWrites 这次使用需不需要写权限。`false` = 只读用途（卡片进程）：
   *                    不执行 PRAGMA、不建表不迁移，库没准备好就抛 `NOT_READY_MESSAGE`。
   *                    默认 `true`。
   */
  async init(context: common.Context, allowWrites: boolean = true): Promise<void> {
    if (this.store !== null) {
      if (!allowWrites || this.storeAllowsWrites) {
        // 连接健在，且能力足以满足这次请求（只读请求用一条可写连接也完全没问题）
        return;
      }
      // 连接是"只读用途"打开的，现在有人要写：换一条可写连接
      Logger.info(TAG, '当前连接为只读用途，本次需要写权限，重新打开数据库');
      await this.close();
    }
    if (this.opening !== null) {
      await this.opening;
      if (this.store !== null && (!allowWrites || this.storeAllowsWrites)) {
        return;
      }
      await this.close();
    }
    this.opening = this.doInit(context, allowWrites);
    try {
      await this.opening;
    } finally {
      this.opening = null;
    }
  }

  private async doInit(context: common.Context, allowWrites: boolean): Promise<void> {
    const config: relationalStore.StoreConfig = {
      name: DB_NAME,
      securityLevel: relationalStore.SecurityLevel.S1
    };

    const store: relationalStore.RdbStore =
      await DbLock.run<relationalStore.RdbStore>('打开数据库', () => relationalStore.getRdbStore(context, config));

    // PRAGMA 是**写型**操作（改 journal_mode 要独占访问），只读用途的连接一律不碰：
    // 库里该有的设置由上次可写连接留下并持久化在文件里，读方不需要再设一遍。
    if (allowWrites) {
      await this.applyPragma(store);
    }

    const installedVersion: number = store.version;
    if (installedVersion === 0) {
      if (!allowWrites) {
        await ScheduleDb.discard(store);
        throw new Error(NOT_READY_MESSAGE);
      }
      Logger.info(TAG, `首次安装，创建 schema v${DB_VERSION}`);
      await DbLock.run<void>('建表', () => this.createSchema(store));
      store.version = DB_VERSION;
    } else if (installedVersion < DB_VERSION) {
      if (!allowWrites) {
        await ScheduleDb.discard(store);
        throw new Error(NOT_READY_MESSAGE);
      }
      Logger.info(TAG, `检测到 schema v${installedVersion}，开始迁移到 v${DB_VERSION}`);
      await DbLock.run<void>('迁移', () => this.migrate(store, installedVersion));
      store.version = DB_VERSION;
    } else {
      // 版本号已是最新，但表可能被人为清理过，做一次轻量自检
      const healthy: boolean = await DbLock.run<boolean>('schema 自检', () => this.hasTable(store, 'semester'));
      if (!healthy) {
        if (!allowWrites) {
          await ScheduleDb.discard(store);
          throw new Error(NOT_READY_MESSAGE);
        }
        Logger.warn(TAG, '版本号正常但核心表缺失，重建 schema');
        await DbLock.run<void>('重建 schema', () => this.createSchema(store));
      }
    }

    this.store = store;
    this.storeAllowsWrites = allowWrites;
    this.storeExecutor = new StoreExecutor(store);
    Logger.info(TAG, `数据库就绪：${DB_NAME} v${store.version}（${allowWrites ? '可写' : '只读用途'}）`);
  }

  /** 只读用途发现库还没准备好：把刚打开的连接关掉再抛，避免留下一条悬空连接 */
  private static async discard(store: relationalStore.RdbStore): Promise<void> {
    try {
      await store.close();
    } catch (e) {
      Logger.warn(TAG, `关闭未就绪的连接失败（已忽略）：${errText(e)}`);
    }
  }

  /** 库是否还没被应用初始化过（卡片进程据此给出"请先打开应用"的空态） */
  static isNotReady(e: Object): boolean {
    return e instanceof Error && (e as Error).message.indexOf(NOT_READY_MESSAGE) >= 0;
  }

  private async applyPragma(store: relationalStore.RdbStore): Promise<void> {
    for (let i = 0; i < PRAGMA_SETUP.length; i++) {
      const sql: string = PRAGMA_SETUP[i];
      try {
        // 换 journal_mode 需要独占访问，另一个进程正在用库时会被拒 —— 这是可重试的锁错误
        await DbLock.run<void>('PRAGMA', () => store.execute(sql).then(() => {}));
      } catch (e) {
        // PRAGMA 失败不阻断启动：外键约束在 DAO 层有显式级联兜底
        Logger.warn(TAG, `PRAGMA 执行失败（已忽略）：${sql} -> ${errText(e)}`);
      }
    }
  }

  /** 建表 / 建视图 / 建索引，整体放在一个事务里，要么全成要么全不成 */
  private async createSchema(store: relationalStore.RdbStore): Promise<void> {
    const tx: relationalStore.Transaction = await store.createTransaction();
    try {
      for (let i = 0; i < DDL_TABLES.length; i++) {
        await tx.execute(DDL_TABLES[i]);
      }
      for (let i = 0; i < DDL_VIEWS.length; i++) {
        await tx.execute(DDL_VIEWS[i]);
      }
      for (let i = 0; i < DDL_INDEXES.length; i++) {
        await tx.execute(DDL_INDEXES[i]);
      }
      await tx.commit();
      Logger.info(TAG, `schema 创建完成：${DDL_TABLES.length} 表 / ${DDL_VIEWS.length} 视图 / ${DDL_INDEXES.length} 索引`);
    } catch (e) {
      await tx.rollback();
      Logger.error(TAG, `schema 创建失败：${errText(e)}`);
      throw e as Error;
    }
  }

  private async migrate(store: relationalStore.RdbStore, fromVersion: number): Promise<void> {
    for (let i = 0; i < MIGRATIONS.length; i++) {
      const step: Migration = MIGRATIONS[i];
      if (step.targetVersion <= fromVersion) {
        continue;
      }
      Logger.info(TAG, `执行迁移 v${step.targetVersion}：${step.describe}`);
      await step.run(store);
    }
    // 迁移可能新增了表/索引，补齐一遍（全部 IF NOT EXISTS，幂等）
    for (let i = 0; i < DDL_TABLES.length; i++) {
      await store.execute(DDL_TABLES[i]);
    }
    for (let i = 0; i < DDL_VIEWS.length; i++) {
      await store.execute(DDL_VIEWS[i]);
    }
    for (let i = 0; i < DDL_INDEXES.length; i++) {
      await store.execute(DDL_INDEXES[i]);
    }
  }

  private async hasTable(store: relationalStore.RdbStore, table: string): Promise<boolean> {
    const args: Array<relationalStore.ValueType> = [table];
    const rs: relationalStore.ResultSet =
      await store.querySql(`SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?`, args);
    const exists: boolean = rs.rowCount > 0;
    rs.close();
    return exists;
  }

  /** 未初始化就调用属于编程错误，直接抛，避免后续出现难以定位的空指针 */
  getStore(): relationalStore.RdbStore {
    if (this.store === null) {
      throw new Error('ScheduleDb 尚未初始化，请先 await ScheduleDb.getInstance().init(context)');
    }
    return this.store;
  }

  get isReady(): boolean {
    return this.store !== null;
  }

  /** 非事务执行器：单条独立语句走它 */
  executor(): DbExecutor {
    if (this.storeExecutor === null) {
      throw new Error('ScheduleDb 尚未初始化');
    }
    return this.storeExecutor;
  }

  /**
   * 事务执行器。回调里抛任何异常都会整体回滚。
   *
   * 课表的一次"保存"涉及 6 张表（course/class_group/time_period/period_week/...），
   * 必须整体成功——这正是旧版 JSON 全量覆盖最容易出事的地方。
   *
   * 遇锁（`14800024`）整体重来，但**只在提交之前**：
   * `committing` 一旦置位就说明已经进了提交阶段，此时失败的结果是"不确定"
   * （可能已落库），重放会写两遍 —— 宁可报错也不能把用户的课表写成双份。
   */
  async runInTransaction<T>(work: (exec: DbExecutor) => Promise<T>): Promise<T> {
    const store: relationalStore.RdbStore = this.getStore();
    for (let attempt = 1; attempt <= DbLock.MAX_ATTEMPTS; attempt++) {
      let tx: relationalStore.Transaction | null = null;
      let committing: boolean = false;
      try {
        tx = await store.createTransaction();
        const result: T = await work(new TxExecutor(tx));
        committing = true;
        await tx.commit();
        return result;
      } catch (e) {
        if (tx !== null && !committing) {
          try {
            await tx.rollback();
          } catch (e2) {
            Logger.error(TAG, `事务回滚失败：${errText(e2)}`);
          }
        }
        if (committing || !DbLock.isLock(e) || attempt >= DbLock.MAX_ATTEMPTS) {
          throw e as Error;
        }
        Logger.warn(TAG, `事务遇数据库占用，第 ${attempt} 次重试：${errText(e)}`);
        await DbLock.backoff(attempt);
      }
    }
    // 到不了这里：最后一次失败必然在上面那个 catch 里抛出去了
    throw new Error(`事务重试 ${DbLock.MAX_ATTEMPTS} 次仍未成功`);
  }

  /** 数据库级备份：RelationalStore 原生能力，比手工序列化更可靠 */
  async backup(destFileName: string): Promise<void> {
    try {
      await this.getStore().backup(destFileName);
      Logger.info(TAG, `备份完成：${destFileName}`);
    } catch (e) {
      Logger.error(TAG, `备份失败：${errText(e)}`);
      throw e as Error;
    }
  }

  /** 用备份文件覆盖当前库；覆盖前建议先 backup 一份现场 */
  async restore(srcFileName: string): Promise<void> {
    try {
      await this.getStore().restore(srcFileName);
      Logger.info(TAG, `恢复完成：${srcFileName}`);
    } catch (e) {
      Logger.error(TAG, `恢复失败：${errText(e)}`);
      throw e as Error;
    }
  }

  /**
   * 关闭连接并把单例状态清干净，之后 `init()` 可以再次真正打开。
   *
   * `opening` 一并清空：它是"初始化在路上"的合流点，连接已经关了还留着它，
   * 会让下一次 init 误判为"正在初始化"而直接返回（表现为数据库再也打不开）。
   */
  async close(): Promise<void> {
    if (this.store === null) {
      return;
    }
    try {
      await this.store.close();
    } catch (e) {
      Logger.error(TAG, `关闭数据库失败：${errText(e)}`);
    }
    this.store = null;
    this.storeExecutor = null;
    this.opening = null;
    this.storeAllowsWrites = false;
    Logger.info(TAG, '数据库已关闭');
  }
}
