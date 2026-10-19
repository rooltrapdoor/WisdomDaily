import { relationalStore } from '@kit.ArkData';
import { DbExecutor, RsReader } from '../db/DbExecutor';
import { DaoSupport } from './DaoSupport';
import { ClassPopulationRow, StudentRow } from '../model/Rows';
import { Student } from '../model/Student';
import { Tables } from '../db/TableSchema';
import { nowMs } from '../common/Util';

/** student 表的读写。(class_id, student_no) 唯一 */
export class StudentDao {
  private static readonly COLS: string =
    `s.id, s.student_no, s.class_id, ci.class_name, s.name, s.age, s.sex, s.telephone, s.remark,
     s.is_builtin, s.sort_order`;

  private static readonly FROM: string =
    `${Tables.STUDENT} s JOIN ${Tables.CLASS_INFO} ci ON ci.class_id = s.class_id`;

  private static map(reader: RsReader): StudentRow {
    return {
      id: reader.num('id'),
      student_no: reader.str('student_no'),
      class_id: reader.str('class_id'),
      class_name: reader.str('class_name'),
      name: reader.str('name'),
      age: reader.optNum('age'),
      sex: reader.optStr('sex'),
      telephone: reader.optStr('telephone'),
      remark: reader.optStr('remark'),
      is_builtin: reader.bool('is_builtin'),
      sort_order: reader.num('sort_order')
    };
  }

  static async listByClass(exec: DbExecutor, classId: string): Promise<StudentRow[]> {
    const rs = await exec.querySql(
      `SELECT ${StudentDao.COLS} FROM ${StudentDao.FROM}
        WHERE s.class_id = ? ORDER BY s.student_no ASC`, [classId]);
    const rows: StudentRow[] = [];
    try {
      while (rs.goToNextRow()) {
        rows.push(StudentDao.map(new RsReader(rs)));
      }
    } finally {
      rs.close();
    }
    return rows;
  }

  static async findById(exec: DbExecutor, id: number): Promise<StudentRow | undefined> {
    const rs = await exec.querySql(
      `SELECT ${StudentDao.COLS} FROM ${StudentDao.FROM} WHERE s.id = ?`, [id]);
    try {
      if (!rs.goToFirstRow()) {
        return undefined;
      }
      return StudentDao.map(new RsReader(rs));
    } finally {
      rs.close();
    }
  }

  static async countByClass(exec: DbExecutor, classId: string): Promise<number> {
    return DaoSupport.scalarNumber(exec,
      `SELECT COUNT(*) AS v FROM ${Tables.STUDENT} WHERE class_id = ?`, [classId]);
  }

  static async insert(exec: DbExecutor, student: Student, classId: string, sortOrder: number): Promise<number> {
    const ts: number = nowMs();
    await exec.executeSql(
      `INSERT INTO ${Tables.STUDENT}
         (student_no, class_id, name, age, sex, telephone, remark, is_builtin, sort_order, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [student.student_no, classId, student.name,
        student.age === undefined ? null : student.age,
        student.sex === undefined ? null : student.sex,
        student.telephone === undefined ? null : student.telephone,
        student.remark === undefined ? null : student.remark,
        student.is_builtin ? 1 : 0, sortOrder, ts, ts]);
    return DaoSupport.lastRowId(exec);
  }

  static async update(exec: DbExecutor, student: Student): Promise<void> {
    await exec.executeSql(
      `UPDATE ${Tables.STUDENT}
          SET student_no = ?, name = ?, age = ?, sex = ?, telephone = ?, remark = ?,
              is_builtin = ?, updated_at = ?
        WHERE id = ?`,
      [student.student_no, student.name,
        student.age === undefined ? null : student.age,
        student.sex === undefined ? null : student.sex,
        student.telephone === undefined ? null : student.telephone,
        student.remark === undefined ? null : student.remark,
        student.is_builtin ? 1 : 0, nowMs(), student.id]);
  }

  static async deleteById(exec: DbExecutor, id: number): Promise<void> {
    await exec.executeSql(`DELETE FROM ${Tables.STUDENT} WHERE id = ?`, [id]);
  }

  static async deleteByClass(exec: DbExecutor, classId: string): Promise<void> {
    await exec.executeSql(`DELETE FROM ${Tables.STUDENT} WHERE class_id = ?`, [classId]);
  }

  /**
   * 整班名单整体替换（导入/粘贴一份新名单时用）。
   * 调用方需放在事务里：先清空再写入，中途失败会留下空名单。
   */
  static async replaceRoster(exec: DbExecutor, classId: string, students: Student[]): Promise<number> {
    await StudentDao.deleteByClass(exec, classId);
    if (students.length === 0) {
      return 0;
    }
    const buckets: Array<relationalStore.ValuesBucket> = [];
    for (let i = 0; i < students.length; i++) {
      const student: Student = students[i];
      const bucket: relationalStore.ValuesBucket = {};
      bucket['student_no'] = student.student_no;
      bucket['class_id'] = classId;
      bucket['name'] = student.name;
      bucket['age'] = student.age === undefined ? null : student.age;
      bucket['sex'] = student.sex === undefined ? null : student.sex;
      bucket['telephone'] = student.telephone === undefined ? null : student.telephone;
      bucket['remark'] = student.remark === undefined ? null : student.remark;
      bucket['is_builtin'] = student.is_builtin ? 1 : 0;
      bucket['sort_order'] = i;
      buckets.push(bucket);
    }
    return exec.batchInsert(Tables.STUDENT, buckets);
  }

  /**
   * 对账视图：每个班在课表里登记的 `population` 与实际名单人数。
   * 旧版这两者分别存在两个 JSON 文件里，没人能保证它们一致；现在一条 SQL 就能查出差异。
   */
  static async populationReport(exec: DbExecutor, semesterId: number): Promise<ClassPopulationRow[]> {
    const rs = await exec.querySql(
      `SELECT cg.class_id,
              ci.class_name,
              MAX(cg.population) AS population,
              (SELECT COUNT(*) FROM ${Tables.STUDENT} st WHERE st.class_id = cg.class_id) AS roster_count
         FROM ${Tables.CLASS_GROUP} cg
         JOIN ${Tables.COURSE} c ON c.id = cg.course_id
         JOIN ${Tables.CLASS_INFO} ci ON ci.class_id = cg.class_id
        WHERE c.semester_id = ?
        GROUP BY cg.class_id, ci.class_name
        ORDER BY ci.class_name ASC`, [semesterId]);
    const rows: ClassPopulationRow[] = [];
    try {
      while (rs.goToNextRow()) {
        const reader: RsReader = new RsReader(rs);
        rows.push({
          class_id: reader.str('class_id'),
          class_name: reader.str('class_name'),
          population: reader.num('population'),
          roster_count: reader.num('roster_count')
        });
      }
    } finally {
      rs.close();
    }
    return rows;
  }
}
