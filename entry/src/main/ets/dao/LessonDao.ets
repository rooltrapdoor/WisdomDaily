import { DbExecutor, RsReader } from '../db/DbExecutor';
import { DaoSupport } from './DaoSupport';
import { LessonRow } from '../model/Rows';
import { Views } from '../db/TableSchema';

/**
 * 读模型（Read Model）：只读 v_lesson 视图，不写任何表。
 *
 * 视图把 course / teacher / class_group / class_info / time_period / period_week
 * 六张表拍平成"一次上课一行"，于是页面要的各种视角都变成一条 SQL：
 *  - 某教师第 N 周的课（课表主视图）
 *  - 某班第 N 周的课（班级视角，可能跨教师）
 *  - 某周全校所有课（排课总览 / 教室占用统计）
 *
 * 注意：视图展开后行数会按周次翻倍（一条 20 周的时间段 = 20 行），
 * 所以只用于"按周取数"，冷启动组装整学期对象图走的是各表直查。
 */
export class LessonDao {
  private static map(reader: RsReader): LessonRow {
    return {
      course_row_id: reader.num('course_row_id'),
      course_id: reader.str('course_id'),
      course_name: reader.str('course_name'),
      course_type: reader.str('course_type', '理论'),
      course_score: reader.optReal('course_score'),
      course_remark: reader.str('course_remark'),
      semester_id: reader.num('semester_id'),
      teacher_id: reader.num('teacher_id'),
      staff_no: reader.num('staff_no'),
      teacher_name: reader.str('teacher_name'),
      class_group_id: reader.num('class_group_id'),
      class_id: reader.str('class_id'),
      class_name: reader.str('class_name'),
      population: reader.num('population'),
      color: reader.str('color', '#F0F0F0'),
      time_period_id: reader.num('time_period_id'),
      weekday: reader.num('weekday', 1),
      start_time: reader.num('start_time', 1),
      end_time: reader.num('end_time', 2),
      class_room: reader.str('class_room'),
      remark: reader.str('remark'),
      week_no: reader.num('week_no', 1)
    };
  }

  private static async query(exec: DbExecutor, sql: string,
    args: Array<number | string>): Promise<LessonRow[]> {
    const rs = await exec.querySql(sql, args);
    const rows: LessonRow[] = [];
    try {
      while (rs.goToNextRow()) {
        rows.push(LessonDao.map(new RsReader(rs)));
      }
    } finally {
      rs.close();
    }
    return rows;
  }

  /** 某教师某学期的整周课表（课表主视图的数据源） */
  static async weekOfTeacher(exec: DbExecutor, semesterId: number, teacherId: number,
    week: number): Promise<LessonRow[]> {
    return LessonDao.query(exec,
      `SELECT * FROM ${Views.V_LESSON}
        WHERE semester_id = ? AND teacher_id = ? AND week_no = ?
        ORDER BY weekday ASC, start_time ASC, class_name ASC`,
      [semesterId, teacherId, week]);
  }

  /** 某学期某周全部课程（教师总览 / 周课时统计） */
  static async weekOfSemester(exec: DbExecutor, semesterId: number, week: number): Promise<LessonRow[]> {
    return LessonDao.query(exec,
      `SELECT * FROM ${Views.V_LESSON}
        WHERE semester_id = ? AND week_no = ?
        ORDER BY teacher_id ASC, weekday ASC, start_time ASC`,
      [semesterId, week]);
  }

  /** 某个班某周的课（可能来自不同教师，班级视角 / 导出班级课表） */
  static async weekOfClass(exec: DbExecutor, semesterId: number, classId: string,
    week: number): Promise<LessonRow[]> {
    return LessonDao.query(exec,
      `SELECT * FROM ${Views.V_LESSON}
        WHERE semester_id = ? AND class_id = ? AND week_no = ?
        ORDER BY weekday ASC, start_time ASC`,
      [semesterId, classId, week]);
  }

  /** 某教师全部周次的课（导出 / 冲突体检时一次拿全，避免按周循环查询） */
  static async allWeeksOfTeacher(exec: DbExecutor, semesterId: number, teacherId: number): Promise<LessonRow[]> {
    return LessonDao.query(exec,
      `SELECT * FROM ${Views.V_LESSON}
        WHERE semester_id = ? AND teacher_id = ?
        ORDER BY week_no ASC, weekday ASC, start_time ASC`,
      [semesterId, teacherId]);
  }

  // ------------------------------------------------------------------ 诊断（空课表自证）
  //
  // 下面三个只读方法专供"课表一片空白"时定位用：屏幕上"没排课"和"查不到 / 画不出"
  // 长得完全一样，只有把库里的原始计数摊出来才能区分。
  // 它们只做 COUNT / DISTINCT，不参与任何业务判断，写路径也永不调用。

  /** 诊断：某教师在该学期的全部周课次行数（不限周次） */
  static async countOfTeacher(exec: DbExecutor, semesterId: number, teacherId: number): Promise<number> {
    return DaoSupport.scalarNumber(exec,
      `SELECT COUNT(*) AS v FROM ${Views.V_LESSON}
        WHERE semester_id = ? AND teacher_id = ?`,
      [semesterId, teacherId]);
  }

  /** 诊断：该教师实际上有课的周次（升序去重），用来和"当前显示第几周"对照 */
  static async weeksOfTeacher(exec: DbExecutor, semesterId: number, teacherId: number): Promise<number[]> {
    const rs = await exec.querySql(
      `SELECT DISTINCT week_no FROM ${Views.V_LESSON}
        WHERE semester_id = ? AND teacher_id = ?
        ORDER BY week_no ASC`,
      [semesterId, teacherId]);
    const weeks: number[] = [];
    try {
      const reader: RsReader = new RsReader(rs);
      while (rs.goToNextRow()) {
        weeks.push(reader.num('week_no'));
      }
    } finally {
      rs.close();
    }
    return weeks;
  }

  /** 诊断：该学期全部教师的课次行数（不限周次） */
  static async countOfSemester(exec: DbExecutor, semesterId: number): Promise<number> {
    return DaoSupport.scalarNumber(exec,
      `SELECT COUNT(*) AS v FROM ${Views.V_LESSON} WHERE semester_id = ?`,
      [semesterId]);
  }

  /** 某周内使用了哪些教室（排课复盘 / 教室占用） */
  static async roomsInWeek(exec: DbExecutor, semesterId: number, week: number): Promise<string[]> {
    const rs = await exec.querySql(
      `SELECT DISTINCT class_room FROM ${Views.V_LESSON}
        WHERE semester_id = ? AND week_no = ? AND class_room <> ''
        ORDER BY class_room ASC`, [semesterId, week]);
    const rooms: string[] = [];
    try {
      while (rs.goToNextRow()) {
        rooms.push(new RsReader(rs).str('class_room'));
      }
    } finally {
      rs.close();
    }
    return rooms;
  }
}
