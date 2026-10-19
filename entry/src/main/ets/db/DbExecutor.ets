import { relationalStore } from '@kit.ArkData';
import { DbLock } from './DbLock';

/**
 * 数据访问的统一执行入口。
 *
 * 存在的理由：`RdbStore` 与 `Transaction` 拥有一组同名同形的方法，但它们是两个
 * 互不兼容的类型。DAO 层只依赖本接口，于是"同一段 SQL 既可以走连接、也可以走事务"
 * 而不需要写两遍。Repository 负责决定用哪个 executor。
 */
export interface DbExecutor {
  insert(table: string, values: relationalStore.ValuesBucket): Promise<number>;

  batchInsert(table: string, values: Array<relationalStore.ValuesBucket>): Promise<number>;

  update(values: relationalStore.ValuesBucket, predicates: relationalStore.RdbPredicates): Promise<number>;

  delete(predicates: relationalStore.RdbPredicates): Promise<number>;

  querySql(sql: string, bindArgs: Array<relationalStore.ValueType>): Promise<relationalStore.ResultSet>;

  executeSql(sql: string, bindArgs: Array<relationalStore.ValueType>): Promise<void>;
}

/**
 * 走数据库连接（非事务，自动提交）。
 *
 * 每条语句都套一层"遇锁重试"：桌面卡片与应用同时用库时，`14800024`（database file is locked）
 * 是瞬时故障而不是数据错误。单条语句是原子的 —— SQLite 报 BUSY 意味着**这条语句根本没执行**，
 * 所以重放安全，不会写两遍。事务里的语句不在这里重试（事务已经废了，得整体重来，
 * 见 `ScheduleDb.runInTransaction`）。
 */
export class StoreExecutor implements DbExecutor {
  private store: relationalStore.RdbStore;

  constructor(store: relationalStore.RdbStore) {
    this.store = store;
  }

  insert(table: string, values: relationalStore.ValuesBucket): Promise<number> {
    return DbLock.run<number>(`insert ${table}`, () => this.store.insert(table, values));
  }

  batchInsert(table: string, values: Array<relationalStore.ValuesBucket>): Promise<number> {
    return DbLock.run<number>(`batchInsert ${table}`, () => this.store.batchInsert(table, values));
  }

  update(values: relationalStore.ValuesBucket, predicates: relationalStore.RdbPredicates): Promise<number> {
    return DbLock.run<number>('update', () => this.store.update(values, predicates));
  }

  delete(predicates: relationalStore.RdbPredicates): Promise<number> {
    return DbLock.run<number>('delete', () => this.store.delete(predicates));
  }

  querySql(sql: string, bindArgs: Array<relationalStore.ValueType>): Promise<relationalStore.ResultSet> {
    return DbLock.run<relationalStore.ResultSet>('querySql', () => this.store.querySql(sql, bindArgs));
  }

  executeSql(sql: string, bindArgs: Array<relationalStore.ValueType>): Promise<void> {
    // RdbStore.executeSql 自 API 12 起废弃，统一改走 execute（返回首行首列，DDL/写语句返回 null）
    return DbLock.run<void>('executeSql', () => this.store.execute(sql, bindArgs).then(() => {}));
  }
}

/**
 * 走显式事务，失败整体回滚。
 *
 * 这里**不做**语句级重试：一条语句在事务里失败，事务就已经废了（后续语句都在一个
 * 可能已被 SQLite 回滚的上下文里），继续用它只会得到更难懂的错误。要重试就整体重来 ——
 * 那是 `ScheduleDb.runInTransaction` 的职责。
 */
export class TxExecutor implements DbExecutor {
  private tx: relationalStore.Transaction;

  constructor(tx: relationalStore.Transaction) {
    this.tx = tx;
  }

  insert(table: string, values: relationalStore.ValuesBucket): Promise<number> {
    return this.tx.insert(table, values);
  }

  batchInsert(table: string, values: Array<relationalStore.ValuesBucket>): Promise<number> {
    return this.tx.batchInsert(table, values);
  }

  update(values: relationalStore.ValuesBucket, predicates: relationalStore.RdbPredicates): Promise<number> {
    return this.tx.update(values, predicates);
  }

  delete(predicates: relationalStore.RdbPredicates): Promise<number> {
    return this.tx.delete(predicates);
  }

  querySql(sql: string, bindArgs: Array<relationalStore.ValueType>): Promise<relationalStore.ResultSet> {
    return this.tx.querySql(sql, bindArgs);
  }

  async executeSql(sql: string, bindArgs: Array<relationalStore.ValueType>): Promise<void> {
    // Transaction 上没有 executeSql（那是 RdbStore 的 API），对齐方法为 execute
    await this.tx.execute(sql, bindArgs);
  }
}

/**
 * ResultSet 的类型安全读取器。
 *
 * 旧实现里"JSON → 领域对象"的类型边界在这里被替换成"列 → 领域对象"：
 * 列名到下标只解析一次，空值与类型错误统一走兜底值，调用方拿到的永远是确定类型。
 */
export class RsReader {
  private rs: relationalStore.ResultSet;
  private indexMap: Map<string, number> = new Map<string, number>();

  constructor(rs: relationalStore.ResultSet) {
    this.rs = rs;
    const names: string[] = rs.columnNames;
    for (let i = 0; i < names.length; i++) {
      this.indexMap.set(names[i], i);
    }
  }

  has(column: string): boolean {
    const idx: number | undefined = this.indexMap.get(column);
    return idx !== undefined && idx >= 0;
  }

  private idxOf(column: string): number {
    const idx: number | undefined = this.indexMap.get(column);
    return idx === undefined ? -1 : idx;
  }

  isNull(column: string): boolean {
    const idx: number = this.idxOf(column);
    return idx < 0 || this.rs.isColumnNull(idx);
  }

  str(column: string, fallback: string = ''): string {
    const idx: number = this.idxOf(column);
    if (idx < 0 || this.rs.isColumnNull(idx)) {
      return fallback;
    }
    return this.rs.getString(idx);
  }

  /** 可空字符串：区分"空串"与"未填" */
  optStr(column: string): string | undefined {
    const idx: number = this.idxOf(column);
    if (idx < 0 || this.rs.isColumnNull(idx)) {
      return undefined;
    }
    return this.rs.getString(idx);
  }

  num(column: string, fallback: number = 0): number {
    const idx: number = this.idxOf(column);
    if (idx < 0 || this.rs.isColumnNull(idx)) {
      return fallback;
    }
    return this.rs.getLong(idx);
  }

  optNum(column: string): number | undefined {
    const idx: number = this.idxOf(column);
    if (idx < 0 || this.rs.isColumnNull(idx)) {
      return undefined;
    }
    return this.rs.getLong(idx);
  }

  real(column: string, fallback: number = 0): number {
    const idx: number = this.idxOf(column);
    if (idx < 0 || this.rs.isColumnNull(idx)) {
      return fallback;
    }
    return this.rs.getDouble(idx);
  }

  optReal(column: string): number | null {
    const idx: number = this.idxOf(column);
    if (idx < 0 || this.rs.isColumnNull(idx)) {
      return null;
    }
    return this.rs.getDouble(idx);
  }

  bool(column: string, fallback: boolean = false): boolean {
    const idx: number = this.idxOf(column);
    if (idx < 0 || this.rs.isColumnNull(idx)) {
      return fallback;
    }
    return this.rs.getLong(idx) === 1;
  }
}
