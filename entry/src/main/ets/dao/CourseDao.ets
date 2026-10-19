import { DbExecutor, RsReader } from '../db/DbExecutor';
import { DaoSupport } from './DaoSupport';
import { ClassGroupRow, CourseRow, DanglingGroupRow } from '../model/Rows';
import { ClassGroup, Course } from '../model/Course';
import { Tables } from '../db/TableSchema';
import { newUuid, nowMs, normalizeColor } from '../common/Util';

/**
 * course + class_group 两张表的读写。
 *
 * 之所以放在同一个 DAO：class_group 的生命周期完全依附于 course
 * （课程删了，它的班级分组必然一起走），拆开反而让级联逻辑无处安放。
 */
export class CourseDao {
  private static readonly COLS: string =
    `id, course_id, semester_id, teacher_id, course_name, course_type, course_score, course_remark, sort_order`;

  private static map(reader: RsReader): CourseRow {
    return {
      id: reader.num('id'),
      course_id: reader.str('course_id'),
      semester_id: reader.num('semester_id'),
      teacher_id: reader.num('teacher_id'),
      course_name: reader.str('course_name'),
      course_type: reader.str('course_type', '理论'),
      course_score: reader.optReal('course_score'),
      course_remark: reader.str('course_remark'),
      sort_order: reader.num('sort_order')
    };
  }

  private static mapGroup(reader: RsReader): ClassGroupRow {
    return {
      id: reader.num('id'),
      course_id: reader.num('course_id'),
      class_id: reader.str('class_id'),
      class_name: reader.str('class_name'),
      population: reader.num('population'),
      color: normalizeColor(reader.str('color', '#F0F0F0')),
      sort_order: reader.num('sort_order')
    };
  }

  // ---------------------------------------------------------------- course

  static async listBySemester(exec: DbExecutor, semesterId: number): Promise<CourseRow[]> {
    const rs = await exec.querySql(
      `SELECT ${CourseDao.COLS} FROM ${Tables.COURSE}
        WHERE semester_id = ? ORDER BY teacher_id ASC, sort_order ASC, id ASC`, [semesterId]);
    const rows: CourseRow[] = [];
    try {
      while (rs.goToNextRow()) {
        rows.push(CourseDao.map(new RsReader(rs)));
      }
    } finally {
      rs.close();
    }
    return rows;
  }

  static async listByTeacher(exec: DbExecutor, semesterId: number, teacherId: number): Promise<CourseRow[]> {
    const rs = await exec.querySql(
      `SELECT ${CourseDao.COLS} FROM ${Tables.COURSE}
        WHERE semester_id = ? AND teacher_id = ? ORDER BY sort_order ASC, id ASC`,
      [semesterId, teacherId]);
    const rows: CourseRow[] = [];
    try {
      while (rs.goToNextRow()) {
        rows.push(CourseDao.map(new RsReader(rs)));
      }
    } finally {
      rs.close();
    }
    return rows;
  }

  static async findById(exec: DbExecutor, courseRowId: number): Promise<CourseRow | undefined> {
    const rs = await exec.querySql(
      `SELECT ${CourseDao.COLS} FROM ${Tables.COURSE} WHERE id = ?`, [courseRowId]);
    try {
      if (!rs.goToFirstRow()) {
        return undefined;
      }
      return CourseDao.map(new RsReader(rs));
    } finally {
      rs.close();
    }
  }

  static async findByBusinessKey(exec: DbExecutor, teacherId: number, semesterId: number,
    courseName: string, courseType: string): Promise<CourseRow | undefined> {
    const rs = await exec.querySql(
      `SELECT ${CourseDao.COLS} FROM ${Tables.COURSE}
        WHERE teacher_id = ? AND semester_id = ? AND course_name = ? AND course_type = ?`, 
      [teacherId, semesterId, courseName, courseType]);
    try {
      if (!rs.goToFirstRow()) {
        return undefined;
      }
      return CourseDao.map(new RsReader(rs));
    } finally {
      rs.close();
    }
  }

  static async insert(exec: DbExecutor, course: Course, semesterId: number, teacherId: number,
    sortOrder: number): Promise<number> {
    const ts: number = nowMs();
    const courseId: string = course.course_id.length > 0 ? course.course_id : newUuid();
    await exec.executeSql(
      `INSERT INTO ${Tables.COURSE}
         (course_id, semester_id, teacher_id, course_name, course_type, course_score, course_remark,
          sort_order, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [courseId, semesterId, teacherId, course.course_name, course.course_type,
        course.course_score === null ? null : course.course_score,
        course.course_remark, sortOrder, ts, ts]);
    return DaoSupport.lastRowId(exec);
  }

  /** 只更新课程自身字段；所属教师/学期以 course.teacher_id 为准，不在此处改动 */
  static async update(exec: DbExecutor, course: Course): Promise<void> {
    await exec.executeSql(
      `UPDATE ${Tables.COURSE}
          SET course_name = ?, course_type = ?, course_score = ?, course_remark = ?, updated_at = ?
        WHERE id = ?`,
      [course.course_name, course.course_type,
        course.course_score === null ? null : course.course_score,
        course.course_remark, nowMs(), course.id]);
  }

  /** 课程换教师（教师列表里"移动课程"这类操作） */
  static async updateTeacher(exec: DbExecutor, courseRowId: number, teacherId: number): Promise<void> {
    await exec.executeSql(
      `UPDATE ${Tables.COURSE} SET teacher_id = ?, updated_at = ? WHERE id = ?`,
      [teacherId, nowMs(), courseRowId]);
  }

  /** 删除课程：显式清除其下 班级分组 → 时间段 → 周次 */
  static async deleteCascade(exec: DbExecutor, courseRowId: number): Promise<void> {
    await exec.executeSql(
      `DELETE FROM ${Tables.PERIOD_WEEK}
        WHERE time_period_id IN (
              SELECT tp.id FROM ${Tables.TIME_PERIOD} tp
                JOIN ${Tables.CLASS_GROUP} cg ON cg.id = tp.class_group_id
               WHERE cg.course_id = ?)`, [courseRowId]);
    await exec.executeSql(
      `DELETE FROM ${Tables.TIME_PERIOD}
        WHERE class_group_id IN (SELECT id FROM ${Tables.CLASS_GROUP} WHERE course_id = ?)`, [courseRowId]);
    await exec.executeSql(`DELETE FROM ${Tables.CLASS_GROUP} WHERE course_id = ?`, [courseRowId]);
    await exec.executeSql(`DELETE FROM ${Tables.COURSE} WHERE id = ?`, [courseRowId]);
  }

  static async countBySemester(exec: DbExecutor, semesterId: number): Promise<number> {
    return DaoSupport.scalarNumber(exec,
      `SELECT COUNT(*) AS v FROM ${Tables.COURSE} WHERE semester_id = ?`, [semesterId]);
  }

  // ------------------------------------------------------------ class_group

  /** 学期下全部班级分组（带班名，供对象图组装时一次性取回） */
  static async listGroupsBySemester(exec: DbExecutor, semesterId: number): Promise<ClassGroupRow[]> {
    const rs = await exec.querySql(
      `SELECT cg.id, cg.course_id, cg.class_id, ci.class_name, cg.population, cg.color, cg.sort_order
         FROM ${Tables.CLASS_GROUP} cg
         JOIN ${Tables.COURSE} c ON c.id = cg.course_id
         JOIN ${Tables.CLASS_INFO} ci ON ci.class_id = cg.class_id
        WHERE c.semester_id = ?
        ORDER BY cg.course_id ASC, cg.sort_order ASC, cg.id ASC`, [semesterId]);
    const rows: ClassGroupRow[] = [];
    try {
      while (rs.goToNextRow()) {
        rows.push(CourseDao.mapGroup(new RsReader(rs)));
      }
    } finally {
      rs.close();
    }
    return rows;
  }

  static async listGroupsByCourse(exec: DbExecutor, courseRowId: number): Promise<ClassGroupRow[]> {
    const rs = await exec.querySql(
      `SELECT cg.id, cg.course_id, cg.class_id, ci.class_name, cg.population, cg.color, cg.sort_order
         FROM ${Tables.CLASS_GROUP} cg
         JOIN ${Tables.CLASS_INFO} ci ON ci.class_id = cg.class_id
        WHERE cg.course_id = ? ORDER BY cg.sort_order ASC, cg.id ASC`, [courseRowId]);
    const rows: ClassGroupRow[] = [];
    try {
      while (rs.goToNextRow()) {
        rows.push(CourseDao.mapGroup(new RsReader(rs)));
      }
    } finally {
      rs.close();
    }
    return rows;
  }

  /**
   * 写入"课程 × 班级"。
   *
   * **`classId` 必须由调用方显式传入，不能从 `group.class_id` 里读。**
   * 这一条是"新增课程后课表里看不到"的根因所在：调用方（`saveCourseGraph`）在
   * 事务里用 `ClassInfoDao.ensureByName` 把班名换成新的 `class_id` 时，只来得及
   * 写进自己的局部变量，此刻 `group.class_id` 还是空串；本方法若从 `group` 取值，
   * 落库的就是 `class_id = ''`。而 `v_lesson` 是六表 JOIN（含 `class_info`），
   * 空串关联不上任何班级档案 —— 整组时间段被 JOIN 吃掉，课表永远不显示，
   * 学生管理（`class_group JOIN class_info`）也数不到这个班。
   * 显式传参还有第二个好处：事务回滚时内存里的 `group` 不会被塞进一个
   * 未提交的 UUID，重试不会写出悬空引用。
   */
  static async upsertGroup(exec: DbExecutor, courseRowId: number, group: ClassGroup,
    sortOrder: number, classId: string): Promise<number> {
    const existing: number = await DaoSupport.scalarNumber(exec,
      `SELECT COALESCE(MAX(id), 0) AS v FROM ${Tables.CLASS_GROUP} WHERE course_id = ? AND class_id = ?`,
      [courseRowId, classId]);
    const color: string = normalizeColor(group.color);
    if (existing > 0) {
      await exec.executeSql(
        `UPDATE ${Tables.CLASS_GROUP} SET class_id = ?, population = ?, color = ?, sort_order = ? WHERE id = ?`,
        [classId, group.population, color, sortOrder, existing]);
      return existing;
    }
    await exec.executeSql(
      `INSERT INTO ${Tables.CLASS_GROUP} (course_id, class_id, population, color, sort_order)
       VALUES (?, ?, ?, ?, ?)`,
      [courseRowId, classId, group.population, color, sortOrder]);
    return DaoSupport.lastRowId(exec);
  }

  /** 按主键更新"课程 × 班级"（编辑模式：允许改绑 class_id、人数与颜色） */
  static async updateGroup(exec: DbExecutor, group: ClassGroup): Promise<void> {
    await exec.executeSql(
      `UPDATE ${Tables.CLASS_GROUP} SET class_id = ?, population = ?, color = ? WHERE id = ?`,
      [group.class_id, group.population, normalizeColor(group.color), group.id]);
  }

  static async deleteGroup(exec: DbExecutor, groupId: number): Promise<void> {
    await exec.executeSql(
      `DELETE FROM ${Tables.PERIOD_WEEK}
        WHERE time_period_id IN (SELECT id FROM ${Tables.TIME_PERIOD} WHERE class_group_id = ?)`, [groupId]);
    await exec.executeSql(`DELETE FROM ${Tables.TIME_PERIOD} WHERE class_group_id = ?`, [groupId]);
    await exec.executeSql(`DELETE FROM ${Tables.CLASS_GROUP} WHERE id = ?`, [groupId]);
  }

  /** 课程已登记的班级 id 列表，用于判断哪些班级分组已经不存在、需要清理 */
  static async groupIdsOfCourse(exec: DbExecutor, courseRowId: number): Promise<number[]> {
    const rs = await exec.querySql(
      `SELECT id FROM ${Tables.CLASS_GROUP} WHERE course_id = ? ORDER BY id ASC`, [courseRowId]);
    const ids: number[] = [];
    try {
      while (rs.goToNextRow()) {
        ids.push(new RsReader(rs).num('id'));
      }
    } finally {
      rs.close();
    }
    return ids;
  }

  /**
   * 启动自愈用：列出"班级关联断了"的分组行 —— `class_id` 在 `class_info` 里找不到
   * 对应档案（空串也算）。带上所属课程的 `created_at`，供上层按时间戳给它找回档案。
   *
   * 注意 `listGroupsByCourse` 是 `JOIN class_info`，这类行在那边**读不出来** ——
   * 所以坏行不仅课表不显示，连编辑页里那个班级分组都会凭空消失。
   */
  static async listDanglingGroups(exec: DbExecutor): Promise<DanglingGroupRow[]> {
    const rs = await exec.querySql(
      `SELECT cg.id AS id, cg.course_id AS course_id, cg.class_id AS class_id,
              c.created_at AS course_created_at
         FROM ${Tables.CLASS_GROUP} cg
         JOIN ${Tables.COURSE} c ON c.id = cg.course_id
        WHERE NOT EXISTS (SELECT 1 FROM ${Tables.CLASS_INFO} ci WHERE ci.class_id = cg.class_id)
        ORDER BY c.created_at ASC, cg.id ASC`, []);
    const rows: DanglingGroupRow[] = [];
    try {
      while (rs.goToNextRow()) {
        const reader: RsReader = new RsReader(rs);
        rows.push({
          id: reader.num('id'),
          course_id: reader.num('course_id'),
          class_id: reader.str('class_id'),
          course_created_at: reader.num('course_created_at')
        });
      }
    } finally {
      rs.close();
    }
    return rows;
  }

  /** 启动自愈专用：把一个班级分组重新绑到指定的班级档案上 */
  static async bindGroupClass(exec: DbExecutor, groupId: number, classId: string): Promise<void> {
    await exec.executeSql(
      `UPDATE ${Tables.CLASS_GROUP} SET class_id = ? WHERE id = ?`, [classId, groupId]);
  }
}
