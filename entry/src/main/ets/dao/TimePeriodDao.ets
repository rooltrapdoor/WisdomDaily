import { relationalStore } from '@kit.ArkData';
import { DbExecutor, RsReader } from '../db/DbExecutor';
import { DaoSupport } from './DaoSupport';
import { PeriodWeekRow, TimePeriodRow } from '../model/Rows';
import { TimePeriod } from '../model/Course';
import { Tables } from '../db/TableSchema';
import { normalizeWeeks } from '../common/Util';

/**
 * time_period + period_week 两张表的读写。
 *
 * 周次拆表带来的直接好处（旧版用 `week_nums` 数组时做不到）：
 *  - "第 8 周有哪些课" 变成一次索引查询，而不是全量遍历数组；
 *  - 周次数量天生有 CHECK 约束，不会出现越界周次；
 *  - 改周次只 DELETE + INSERT 子行，不动时间段本身。
 */
export class TimePeriodDao {
  private static readonly COLS: string =
    `tp.id, tp.class_group_id, tp.weekday, tp.start_time, tp.end_time, tp.class_room, tp.remark`;

  private static map(reader: RsReader): TimePeriodRow {
    return {
      id: reader.num('id'),
      class_group_id: reader.num('class_group_id'),
      weekday: reader.num('weekday', 1),
      start_time: reader.num('start_time', 1),
      end_time: reader.num('end_time', 2),
      class_room: reader.str('class_room'),
      remark: reader.str('remark')
    };
  }

  /** 学期下全部时间段（不展开周次，避免行数爆炸：展开会让 1 条记录变成 20 条） */
  static async listBySemester(exec: DbExecutor, semesterId: number): Promise<TimePeriodRow[]> {
    const rs = await exec.querySql(
      `SELECT ${TimePeriodDao.COLS}
         FROM ${Tables.TIME_PERIOD} tp
         JOIN ${Tables.CLASS_GROUP} cg ON cg.id = tp.class_group_id
         JOIN ${Tables.COURSE} c ON c.id = cg.course_id
        WHERE c.semester_id = ?
        ORDER BY tp.class_group_id ASC, tp.weekday ASC, tp.start_time ASC`, [semesterId]);
    const rows: TimePeriodRow[] = [];
    try {
      while (rs.goToNextRow()) {
        rows.push(TimePeriodDao.map(new RsReader(rs)));
      }
    } finally {
      rs.close();
    }
    return rows;
  }

  static async listByClassGroup(exec: DbExecutor, classGroupId: number): Promise<TimePeriodRow[]> {
    const rs = await exec.querySql(
      `SELECT ${TimePeriodDao.COLS} FROM ${Tables.TIME_PERIOD} tp
        WHERE tp.class_group_id = ? ORDER BY tp.weekday ASC, tp.start_time ASC`, [classGroupId]);
    const rows: TimePeriodRow[] = [];
    try {
      while (rs.goToNextRow()) {
        rows.push(TimePeriodDao.map(new RsReader(rs)));
      }
    } finally {
      rs.close();
    }
    return rows;
  }

  /** 学期下全部周次（已按学期总周数过滤，越界周次不会进入内存） */
  static async listWeeksBySemester(exec: DbExecutor, semesterId: number, maxWeek: number): Promise<PeriodWeekRow[]> {
    const rs = await exec.querySql(
      `SELECT pw.time_period_id, pw.week_no
         FROM ${Tables.PERIOD_WEEK} pw
         JOIN ${Tables.TIME_PERIOD} tp ON tp.id = pw.time_period_id
         JOIN ${Tables.CLASS_GROUP} cg ON cg.id = tp.class_group_id
         JOIN ${Tables.COURSE} c ON c.id = cg.course_id
        WHERE c.semester_id = ? AND pw.week_no <= ?
        ORDER BY pw.time_period_id ASC, pw.week_no ASC`, [semesterId, maxWeek]);
    const rows: PeriodWeekRow[] = [];
    try {
      while (rs.goToNextRow()) {
        const reader: RsReader = new RsReader(rs);
        rows.push({
          time_period_id: reader.num('time_period_id'),
          week_no: reader.num('week_no')
        });
      }
    } finally {
      rs.close();
    }
    return rows;
  }

  static async weeksOf(exec: DbExecutor, timePeriodId: number, maxWeek: number): Promise<number[]> {
    const rs = await exec.querySql(
      `SELECT week_no FROM ${Tables.PERIOD_WEEK}
        WHERE time_period_id = ? AND week_no <= ? ORDER BY week_no ASC`, [timePeriodId, maxWeek]);
    const weeks: number[] = [];
    try {
      while (rs.goToNextRow()) {
        weeks.push(new RsReader(rs).num('week_no'));
      }
    } finally {
      rs.close();
    }
    return weeks;
  }

  /** 插入时间段（不含周次），返回新主键 */
  static async insert(exec: DbExecutor, classGroupId: number, period: TimePeriod, maxWeek: number): Promise<number> {
    await exec.executeSql(
      `INSERT INTO ${Tables.TIME_PERIOD}
         (class_group_id, weekday, start_time, end_time, class_room, remark)
       VALUES (?, ?, ?, ?, ?, ?)`,
      [classGroupId, period.weekday, period.start_time, period.end_time, period.class_room, period.remark]);
    const newId: number = await DaoSupport.lastRowId(exec);
    await TimePeriodDao.replaceWeeks(exec, newId, period.week_nums, maxWeek);
    return newId;
  }

  static async update(exec: DbExecutor, period: TimePeriod, maxWeek: number): Promise<void> {
    await exec.executeSql(
      `UPDATE ${Tables.TIME_PERIOD}
          SET weekday = ?, start_time = ?, end_time = ?, class_room = ?, remark = ?
        WHERE id = ?`,
      [period.weekday, period.start_time, period.end_time, period.class_room, period.remark, period.id]);
    await TimePeriodDao.replaceWeeks(exec, period.id, period.week_nums, maxWeek);
  }

  /** 周次整体替换：先删后批量插，保证不残留旧周次 */
  static async replaceWeeks(exec: DbExecutor, timePeriodId: number, weeks: number[], maxWeek: number): Promise<void> {
    await exec.executeSql(`DELETE FROM ${Tables.PERIOD_WEEK} WHERE time_period_id = ?`, [timePeriodId]);
    const normalized: number[] = normalizeWeeks(weeks, maxWeek);
    if (normalized.length === 0) {
      return;
    }
    const buckets: Array<relationalStore.ValuesBucket> = [];
    for (let i = 0; i < normalized.length; i++) {
      const bucket: relationalStore.ValuesBucket = {};
      bucket['time_period_id'] = timePeriodId;
      bucket['week_no'] = normalized[i];
      buckets.push(bucket);
    }
    await exec.batchInsert(Tables.PERIOD_WEEK, buckets);
  }

  static async deleteById(exec: DbExecutor, timePeriodId: number): Promise<void> {
    await exec.executeSql(`DELETE FROM ${Tables.PERIOD_WEEK} WHERE time_period_id = ?`, [timePeriodId]);
    await exec.executeSql(`DELETE FROM ${Tables.TIME_PERIOD} WHERE id = ?`, [timePeriodId]);
  }

  /**
   * 删除某时间段在某一周的一次课（period_week 一行）。
   * 若该时间段的周次因此清零，时间段本身也一并删除——不留"无周次空壳"。
   */
  static async deleteWeek(exec: DbExecutor, timePeriodId: number, weekNo: number): Promise<void> {
    await exec.executeSql(
      `DELETE FROM ${Tables.PERIOD_WEEK} WHERE time_period_id = ? AND week_no = ?`,
      [timePeriodId, weekNo]);
    const remaining: number = await DaoSupport.scalarNumber(exec,
      `SELECT COUNT(*) AS v FROM ${Tables.PERIOD_WEEK} WHERE time_period_id = ?`, [timePeriodId]);
    if (remaining === 0) {
      await TimePeriodDao.deleteById(exec, timePeriodId);
    }
  }

  static async deleteByClassGroup(exec: DbExecutor, classGroupId: number): Promise<void> {
    await exec.executeSql(
      `DELETE FROM ${Tables.PERIOD_WEEK}
        WHERE time_period_id IN (SELECT id FROM ${Tables.TIME_PERIOD} WHERE class_group_id = ?)`, [classGroupId]);
    await exec.executeSql(`DELETE FROM ${Tables.TIME_PERIOD} WHERE class_group_id = ?`, [classGroupId]);
  }

  static async countBySemester(exec: DbExecutor, semesterId: number): Promise<number> {
    return DaoSupport.scalarNumber(exec,
      `SELECT COUNT(*) AS v
         FROM ${Tables.TIME_PERIOD} tp
         JOIN ${Tables.CLASS_GROUP} cg ON cg.id = tp.class_group_id
         JOIN ${Tables.COURSE} c ON c.id = cg.course_id
        WHERE c.semester_id = ?`, [semesterId]);
  }

  static async countWeeksBySemester(exec: DbExecutor, semesterId: number): Promise<number> {
    return DaoSupport.scalarNumber(exec,
      `SELECT COUNT(*) AS v
         FROM ${Tables.PERIOD_WEEK} pw
         JOIN ${Tables.TIME_PERIOD} tp ON tp.id = pw.time_period_id
         JOIN ${Tables.CLASS_GROUP} cg ON cg.id = tp.class_group_id
         JOIN ${Tables.COURSE} c ON c.id = cg.course_id
        WHERE c.semester_id = ?`, [semesterId]);
  }
}
