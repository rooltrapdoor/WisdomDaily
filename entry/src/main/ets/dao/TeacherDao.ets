import { DbExecutor, RsReader } from '../db/DbExecutor';
import { DaoSupport } from './DaoSupport';
import { TeacherRow } from '../model/Rows';
import { Teacher } from '../model/Teacher';
import { Tables } from '../db/TableSchema';
import { nowMs } from '../common/Util';

/** teacher 表的读写。(semester_id, staff_no, name) 唯一 */
export class TeacherDao {
  private static readonly COLS: string =
    `id, semester_id, staff_no, name, department, age, sex, telephone, sort_order`;

  private static map(reader: RsReader): TeacherRow {
    return {
      id: reader.num('id'),
      semester_id: reader.num('semester_id'),
      staff_no: reader.num('staff_no'),
      name: reader.str('name'),
      department: reader.optStr('department'),
      age: reader.optNum('age'),
      sex: reader.optStr('sex'),
      telephone: reader.optStr('telephone'),
      sort_order: reader.num('sort_order')
    };
  }

  static async listBySemester(exec: DbExecutor, semesterId: number): Promise<TeacherRow[]> {
    const rs = await exec.querySql(
      `SELECT ${TeacherDao.COLS} FROM ${Tables.TEACHER}
        WHERE semester_id = ? ORDER BY sort_order ASC, id ASC`, [semesterId]);
    const rows: TeacherRow[] = [];
    try {
      while (rs.goToNextRow()) {
        rows.push(TeacherDao.map(new RsReader(rs)));
      }
    } finally {
      rs.close();
    }
    return rows;
  }

  static async findById(exec: DbExecutor, id: number): Promise<TeacherRow | undefined> {
    const rs = await exec.querySql(
      `SELECT ${TeacherDao.COLS} FROM ${Tables.TEACHER} WHERE id = ?`, [id]);
    try {
      if (!rs.goToFirstRow()) {
        return undefined;
      }
      return TeacherDao.map(new RsReader(rs));
    } finally {
      rs.close();
    }
  }

  static async findByStaffNo(exec: DbExecutor, semesterId: number, staffNo: number): Promise<TeacherRow[]> {
    const rs = await exec.querySql(
      `SELECT ${TeacherDao.COLS} FROM ${Tables.TEACHER}
        WHERE semester_id = ? AND staff_no = ? ORDER BY id ASC`, [semesterId, staffNo]);
    const rows: TeacherRow[] = [];
    try {
      while (rs.goToNextRow()) {
        rows.push(TeacherDao.map(new RsReader(rs)));
      }
    } finally {
      rs.close();
    }
    return rows;
  }

  static async insert(exec: DbExecutor, teacher: Teacher, semesterId: number, sortOrder: number): Promise<number> {
    const ts: number = nowMs();
    await exec.executeSql(
      `INSERT INTO ${Tables.TEACHER}
         (semester_id, staff_no, name, department, age, sex, telephone, sort_order, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [semesterId, teacher.staff_no, teacher.name,
        teacher.department === undefined ? null : teacher.department,
        teacher.age === undefined ? null : teacher.age,
        teacher.sex === undefined ? null : teacher.sex,
        teacher.telephone === undefined ? null : teacher.telephone,
        sortOrder, ts, ts]);
    return DaoSupport.lastRowId(exec);
  }

  static async update(exec: DbExecutor, teacher: Teacher): Promise<void> {
    await exec.executeSql(
      `UPDATE ${Tables.TEACHER}
          SET staff_no = ?, name = ?, department = ?, age = ?, sex = ?, telephone = ?, updated_at = ?
        WHERE id = ?`,
      [teacher.staff_no, teacher.name,
        teacher.department === undefined ? null : teacher.department,
        teacher.age === undefined ? null : teacher.age,
        teacher.sex === undefined ? null : teacher.sex,
        teacher.telephone === undefined ? null : teacher.telephone,
        nowMs(), teacher.id]);
  }

  /**
   * 按 (semester, staff_no, name) upsert。
   *
   * 这与旧版 `Teachers.pushTeacher` 的"命中则合并字段"语义一致：
   * 同一教师多次导入只保留一条，且不覆盖已有课程。
   */
  static async upsert(exec: DbExecutor, teacher: Teacher, semesterId: number, sortOrder: number): Promise<number> {
    const found: TeacherRow | undefined = await TeacherDao.findExact(exec, semesterId, teacher.staff_no, teacher.name);
    if (found === undefined) {
      return TeacherDao.insert(exec, teacher, semesterId, sortOrder);
    }
    await exec.executeSql(
      `UPDATE ${Tables.TEACHER}
          SET department = COALESCE(?, department),
              age        = COALESCE(?, age),
              sex        = COALESCE(?, sex),
              telephone  = COALESCE(?, telephone),
              updated_at = ?
        WHERE id = ?`,
      [teacher.department === undefined ? null : teacher.department,
        teacher.age === undefined ? null : teacher.age,
        teacher.sex === undefined ? null : teacher.sex,
        teacher.telephone === undefined ? null : teacher.telephone,
        nowMs(), found.id]);
    return found.id;
  }

  static async findExact(exec: DbExecutor, semesterId: number, staffNo: number,
    name: string): Promise<TeacherRow | undefined> {
    const rs = await exec.querySql(
      `SELECT ${TeacherDao.COLS} FROM ${Tables.TEACHER}
        WHERE semester_id = ? AND staff_no = ? AND name = ? LIMIT 1`, [semesterId, staffNo, name]);
    try {
      if (!rs.goToFirstRow()) {
        return undefined;
      }
      return TeacherDao.map(new RsReader(rs));
    } finally {
      rs.close();
    }
  }

  /** 删除教师并显式级联清理其课程链（课程 → 班级分组 → 时间段 → 周次） */
  static async deleteCascade(exec: DbExecutor, teacherId: number): Promise<void> {
    await exec.executeSql(
      `DELETE FROM ${Tables.PERIOD_WEEK}
        WHERE time_period_id IN (
              SELECT tp.id FROM ${Tables.TIME_PERIOD} tp
                JOIN ${Tables.CLASS_GROUP} cg ON cg.id = tp.class_group_id
                JOIN ${Tables.COURSE} c ON c.id = cg.course_id
               WHERE c.teacher_id = ?)`, [teacherId]);

    await exec.executeSql(
      `DELETE FROM ${Tables.TIME_PERIOD}
        WHERE class_group_id IN (
              SELECT cg.id FROM ${Tables.CLASS_GROUP} cg
                JOIN ${Tables.COURSE} c ON c.id = cg.course_id
               WHERE c.teacher_id = ?)`, [teacherId]);

    await exec.executeSql(
      `DELETE FROM ${Tables.CLASS_GROUP}
        WHERE course_id IN (SELECT id FROM ${Tables.COURSE} WHERE teacher_id = ?)`, [teacherId]);

    await exec.executeSql(`DELETE FROM ${Tables.COURSE} WHERE teacher_id = ?`, [teacherId]);
    await exec.executeSql(`DELETE FROM ${Tables.TEACHER} WHERE id = ?`, [teacherId]);
    await exec.executeSql(
      `UPDATE ${Tables.APP_SETTING} SET teacher_id = NULL WHERE teacher_id = ?`, [teacherId]);
  }

  static async countBySemester(exec: DbExecutor, semesterId: number): Promise<number> {
    return DaoSupport.scalarNumber(exec,
      `SELECT COUNT(*) AS v FROM ${Tables.TEACHER} WHERE semester_id = ?`, [semesterId]);
  }
}
