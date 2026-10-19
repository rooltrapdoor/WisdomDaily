import { relationalStore } from '@kit.ArkData';
import { DbExecutor, RsReader } from '../db/DbExecutor';

/**
 * DAO 共用小工具：处理"取单值"这类到处都要写一遍的样板 SQL。
 * 所有方法都保证 ResultSet 被关闭（RelationalStore 的游标不关会泄漏）。
 */
export class DaoSupport {
  /** 上一次 INSERT 生成的自增主键（同一执行器/同一事务内有效） */
  static async lastRowId(exec: DbExecutor): Promise<number> {
    return DaoSupport.scalarNumber(exec, `SELECT last_insert_rowid() AS v`, []);
  }

  static async scalarNumber(exec: DbExecutor, sql: string, args: Array<relationalStore.ValueType>): Promise<number> {
    const rs: relationalStore.ResultSet = await exec.querySql(sql, args);
    try {
      if (!rs.goToFirstRow()) {
        return 0;
      }
      return new RsReader(rs).num('v');
    } finally {
      rs.close();
    }
  }

  static async scalarString(exec: DbExecutor, sql: string, args: Array<relationalStore.ValueType>): Promise<string> {
    const rs: relationalStore.ResultSet = await exec.querySql(sql, args);
    try {
      if (!rs.goToFirstRow()) {
        return '';
      }
      return new RsReader(rs).str('v');
    } finally {
      rs.close();
    }
  }
}
