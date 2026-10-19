import { relationalStore } from '@kit.ArkData';
import { DbExecutor, RsReader } from '../db/DbExecutor';
import { DaoSupport } from './DaoSupport';
import { AttendanceExportRow, AttendanceRow } from '../model/Rows';
import { Tables } from '../db/TableSchema';
import { nowMs } from '../common/Util';

/**
 * `attendance`（签到记录）表的读写。
 *
 * 唯一键 `(time_period_id, week_no, student_id)`；一次课的点名结果**整批替换**，
 * 不做逐行 upsert —— 老师点完一轮就是一整份快照，"半新半旧"的中间态没有任何意义。
 */
export class AttendanceDao {
  /** `grade` / `score` 在库里可为 NULL（旷课与请假就没有这两项），读出来统一成 0 */
  private static readonly COLS: string =
    `a.id, a.time_period_id, a.week_no, a.student_id, a.status,
     IFNULL(a.grade, 0) AS grade, IFNULL(a.score, 0) AS score`;

  private static map(reader: RsReader): AttendanceRow {
    return {
      id: reader.num('id'),
      time_period_id: reader.num('time_period_id'),
      week_no: reader.num('week_no'),
      student_id: reader.num('student_id'),
      status: reader.str('status'),
      grade: reader.num('grade'),
      score: reader.num('score')
    };
  }

  /** 某一次课（时间段 × 周次）的全部签到行 —— 点名页进来时按它回填手势状态 */
  static async listBySession(exec: DbExecutor, periodId: number, weekNo: number): Promise<AttendanceRow[]> {
    const rs = await exec.querySql(
      `SELECT ${AttendanceDao.COLS} FROM ${Tables.ATTENDANCE} a
        WHERE a.time_period_id = ? AND a.week_no = ?
        ORDER BY a.student_id ASC`, [periodId, weekNo]);
    const rows: AttendanceRow[] = [];
    try {
      while (rs.goToNextRow()) {
        rows.push(AttendanceDao.map(new RsReader(rs)));
      }
    } finally {
      rs.close();
    }
    return rows;
  }

  /**
   * 导出一整个班的签到行，**带上"这次课排在第几"的排序键**。
   *
   * 为什么按 `class_id` 而不是按"课程"取：导出入口在**班级名册**（列表里是班级，不是课程），
   * 而一个班可能被多门课教 —— 那些课的点名记录都属于这个班的考勤列。
   * 列号由调用方按 `(week_no, weekday, start_time)` 排序后定，这里只保证顺序稳定：
   * 同一周里上午的课必须排在下周的课之前，只按 `week_no` 排会把同周多节定成随机顺序。
   */
  static async listByClass(exec: DbExecutor, classId: string): Promise<AttendanceExportRow[]> {
    const rs = await exec.querySql(
      `SELECT a.time_period_id, a.week_no, a.student_id, a.status,
              IFNULL(a.grade, 0) AS grade, IFNULL(a.score, 0) AS score,
              tp.weekday, tp.start_time
         FROM ${Tables.ATTENDANCE} a
         JOIN ${Tables.TIME_PERIOD} tp ON tp.id = a.time_period_id
         JOIN ${Tables.CLASS_GROUP} cg ON cg.id = tp.class_group_id
        WHERE cg.class_id = ?
        ORDER BY a.week_no ASC, tp.weekday ASC, tp.start_time ASC, a.student_id ASC`, [classId]);
    const rows: AttendanceExportRow[] = [];
    try {
      while (rs.goToNextRow()) {
        const reader: RsReader = new RsReader(rs);
        rows.push({
          time_period_id: reader.num('time_period_id'),
          week_no: reader.num('week_no'),
          weekday: reader.num('weekday'),
          start_time: reader.num('start_time'),
          student_id: reader.num('student_id'),
          status: reader.str('status'),
          grade: reader.num('grade'),
          score: reader.num('score')
        });
      }
    } finally {
      rs.close();
    }
    return rows;
  }

  static async deleteBySession(exec: DbExecutor, periodId: number, weekNo: number): Promise<void> {
    await exec.executeSql(
      `DELETE FROM ${Tables.ATTENDANCE} WHERE time_period_id = ? AND week_no = ?`, [periodId, weekNo]);
  }

  /**
   * 整批替换某一次课的点名结果（先清本次课、再写入）。
   * 调用方需放在事务里 —— 中途失败会留下"这次课一个人都没点到"的空壳。
   */
  static async replaceSession(exec: DbExecutor, periodId: number, weekNo: number,
    rows: AttendanceRow[]): Promise<number> {
    await AttendanceDao.deleteBySession(exec, periodId, weekNo);
    if (rows.length === 0) {
      return 0;
    }
    const ts: number = nowMs();
    const buckets: Array<relationalStore.ValuesBucket> = [];
    for (let i = 0; i < rows.length; i++) {
      const row: AttendanceRow = rows[i];
      const bucket: relationalStore.ValuesBucket = {};
      bucket['time_period_id'] = periodId;
      bucket['week_no'] = weekNo;
      bucket['student_id'] = row.student_id;
      bucket['status'] = row.status;
      // 旷课/请假没有等级与分数：写 NULL 而不是 0，让"未评"与"0 分"在库里就是两回事
      bucket['grade'] = row.grade > 0 ? row.grade : null;
      bucket['score'] = row.score > 0 ? row.score : null;
      bucket['created_at'] = ts;
      bucket['updated_at'] = ts;
      buckets.push(bucket);
    }
    return exec.batchInsert(Tables.ATTENDANCE, buckets);
  }

  static async countAll(exec: DbExecutor): Promise<number> {
    return DaoSupport.scalarNumber(exec, `SELECT COUNT(*) AS v FROM ${Tables.ATTENDANCE}`, []);
  }

  /**
   * 清理"父母已不在"的签到行。
   *
   * 为什么要有这个函数：`attendance` 有两个父表（`time_period` 与 `student`），
   * 而本工程的级联删除是**显式写在各 DAO 里**的（PRAGMA foreign_keys 在连接池里
   * 不保证每条连接都生效，见 `TableSchema.PRAGMA_SETUP` 的注释）。与其在
   * "删课程 / 删班级 / 删时段 / 删周次 / 删教师 / 删学期 / 删学生" 七个入口
   * 各写一条形态不同的 DELETE，不如**统一收口成一条与来源无关的幂等语句**：
   * 只要父母不在了就清掉。少七处特判，就少七次"新加一条删除路径忘了级联"的机会。
   *
   * （"删掉某一次课"不属于孤儿清理 —— 时间段还在，只是那一周没了，
   *   走 `deleteBySession` 精确删。）
   */
  static async pruneOrphans(exec: DbExecutor): Promise<void> {
    await exec.executeSql(
      `DELETE FROM ${Tables.ATTENDANCE}
        WHERE time_period_id NOT IN (SELECT id FROM ${Tables.TIME_PERIOD})
           OR student_id     NOT IN (SELECT id FROM ${Tables.STUDENT})`, []);
  }
}
