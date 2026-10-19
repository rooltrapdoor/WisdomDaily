import { DbExecutor, RsReader } from '../db/DbExecutor';
import { DaoSupport } from './DaoSupport';
import { SemesterRow } from '../model/Rows';
import { Semester } from '../model/Semester';
import { Tables } from '../db/TableSchema';
import { nowMs } from '../common/Util';

/**
 * semester 表的读写。
 *
 * 所有方法都接收 `DbExecutor`：调用方传连接则自动提交，传事务则随事务一起回滚。
 * DAO 内部不做业务判断，只做 SQL 与行映射。
 */
export class SemesterDao {
  private static readonly COLS: string =
    `s.id, s.name, s.total_weeks, s.start_date, s.schedule_id, st.name AS schedule_name, ` +
    `s.sort_order, s.created_at, s.updated_at`;

  private static readonly FROM: string =
    `${Tables.SEMESTER} s LEFT JOIN ${Tables.SCHEDULE_TEMPLATE} st ON st.id = s.schedule_id`;

  private static map(reader: RsReader): SemesterRow {
    return {
      id: reader.num('id'),
      name: reader.str('name'),
      total_weeks: reader.num('total_weeks', 20),
      start_date: reader.str('start_date'),
      schedule_id: reader.optNum('schedule_id'),
      schedule_name: reader.optStr('schedule_name'),
      sort_order: reader.num('sort_order'),
      created_at: reader.num('created_at'),
      updated_at: reader.num('updated_at')
    };
  }

  static async listAll(exec: DbExecutor): Promise<SemesterRow[]> {
    const rs = await exec.querySql(
      `SELECT ${SemesterDao.COLS} FROM ${SemesterDao.FROM} ORDER BY s.sort_order ASC, s.id ASC`, []);
    const rows: SemesterRow[] = [];
    try {
      while (rs.goToNextRow()) {
        rows.push(SemesterDao.map(new RsReader(rs)));
      }
    } finally {
      rs.close();
    }
    return rows;
  }

  static async findById(exec: DbExecutor, id: number): Promise<SemesterRow | undefined> {
    const rs = await exec.querySql(
      `SELECT ${SemesterDao.COLS} FROM ${SemesterDao.FROM} WHERE s.id = ?`, [id]);
    try {
      if (!rs.goToFirstRow()) {
        return undefined;
      }
      return SemesterDao.map(new RsReader(rs));
    } finally {
      rs.close();
    }
  }

  static async findByName(exec: DbExecutor, name: string): Promise<SemesterRow | undefined> {
    const rs = await exec.querySql(
      `SELECT ${SemesterDao.COLS} FROM ${SemesterDao.FROM} WHERE s.name = ?`, [name]);
    try {
      if (!rs.goToFirstRow()) {
        return undefined;
      }
      return SemesterDao.map(new RsReader(rs));
    } finally {
      rs.close();
    }
  }

  static async lastRowId(exec: DbExecutor): Promise<number> {
    return DaoSupport.lastRowId(exec);
  }

  /** 新增学期；返回自增主键。名称唯一冲突会抛异常，由上层转成友好提示 */
  static async insert(exec: DbExecutor, semester: Semester, sortOrder: number): Promise<number> {
    const ts: number = nowMs();
    await exec.executeSql(
      `INSERT INTO ${Tables.SEMESTER}
         (name, total_weeks, start_date, schedule_id, sort_order, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
      [semester.name, semester.total_weeks, semester.start_date,
        semester.schedule_id > 0 ? semester.schedule_id : null, sortOrder, ts, ts]);
    return DaoSupport.lastRowId(exec);
  }

  static async update(exec: DbExecutor, semester: Semester): Promise<number> {
    await exec.executeSql(
      `UPDATE ${Tables.SEMESTER}
          SET name = ?, total_weeks = ?, start_date = ?, schedule_id = ?, updated_at = ?
        WHERE id = ?`,
      [semester.name, semester.total_weeks, semester.start_date,
        semester.schedule_id > 0 ? semester.schedule_id : null, nowMs(), semester.id]);
    return semester.id;
  }

  /** 只改作息模板引用：切换模板是最常见的单字段改动，走独立语句避免整行重写 */
  static async updateScheduleRef(exec: DbExecutor, semesterId: number, scheduleId: number): Promise<void> {
    await exec.executeSql(
      `UPDATE ${Tables.SEMESTER} SET schedule_id = ?, updated_at = ? WHERE id = ?`,
      [scheduleId > 0 ? scheduleId : null, nowMs(), semesterId]);
  }

  /**
   * 删除学期，并显式级联清理其下所有数据。
   *
   * 为什么不用 `ON DELETE CASCADE` 就完事：SQLite 外键需每连接开启，
   * RelationalStore 的连接池不保证处处生效，所以这里把清理链写全，
   * 保证无论 PRAGMA 是否生效都不留孤儿行。调用方必须放在事务里。
   */
  static async deleteCascade(exec: DbExecutor, semesterId: number): Promise<void> {
    await exec.executeSql(
      `DELETE FROM ${Tables.PERIOD_WEEK}
        WHERE time_period_id IN (
              SELECT tp.id FROM ${Tables.TIME_PERIOD} tp
                JOIN ${Tables.CLASS_GROUP} cg ON cg.id = tp.class_group_id
                JOIN ${Tables.COURSE} c ON c.id = cg.course_id
               WHERE c.semester_id = ?)`, [semesterId]);

    await exec.executeSql(
      `DELETE FROM ${Tables.TIME_PERIOD}
        WHERE class_group_id IN (
              SELECT cg.id FROM ${Tables.CLASS_GROUP} cg
                JOIN ${Tables.COURSE} c ON c.id = cg.course_id
               WHERE c.semester_id = ?)`, [semesterId]);

    await exec.executeSql(
      `DELETE FROM ${Tables.CLASS_GROUP}
        WHERE course_id IN (SELECT id FROM ${Tables.COURSE} WHERE semester_id = ?)`, [semesterId]);

    await exec.executeSql(`DELETE FROM ${Tables.COURSE}  WHERE semester_id = ?`, [semesterId]);
    await exec.executeSql(`DELETE FROM ${Tables.TEACHER} WHERE semester_id = ?`, [semesterId]);

    // 兜底把悬空的"当前指向"清空（正常情况下外键 SET NULL 已经处理）
    await exec.executeSql(
      `UPDATE ${Tables.APP_SETTING} SET semester_id = NULL WHERE semester_id = ?`, [semesterId]);
    await exec.executeSql(
      `UPDATE ${Tables.APP_SETTING} SET teacher_id = NULL
        WHERE teacher_id IS NOT NULL AND teacher_id NOT IN (SELECT id FROM ${Tables.TEACHER})`, []);

    await exec.executeSql(`DELETE FROM ${Tables.SEMESTER} WHERE id = ?`, [semesterId]);
  }

  /** 学期数量：至少要留一个，界面上不允许删到空 */
  static async count(exec: DbExecutor): Promise<number> {
    return DaoSupport.scalarNumber(exec, `SELECT COUNT(*) AS v FROM ${Tables.SEMESTER}`, []);
  }

  /** 重排：批量写入新的 sort_order，保持界面顺序稳定 */
  static async updateSortOrders(exec: DbExecutor, orderedIds: number[]): Promise<void> {
    for (let i = 0; i < orderedIds.length; i++) {
      await exec.executeSql(`UPDATE ${Tables.SEMESTER} SET sort_order = ? WHERE id = ?`, [i, orderedIds[i]]);
    }
  }
}
