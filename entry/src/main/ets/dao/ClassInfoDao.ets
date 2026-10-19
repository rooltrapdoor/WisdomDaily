import { DbExecutor, RsReader } from '../db/DbExecutor';
import { DaoSupport } from './DaoSupport';
import { ClassInfoRow, OrphanClassRow } from '../model/Rows';
import { ClassInfo } from '../model/Student';
import { Tables } from '../db/TableSchema';
import { newUuid, nowMs } from '../common/Util';

/**
 * class_info 表的读写：班级档案。
 *
 * 这是本次改造新增的一张表，专门解决旧版"班级名既是显示名又是关联键"的问题：
 *  - `class_id`（UUID）不可变，课程引用它；
 *  - `class_name` 可以随便改，改名只动一行，所有关联自动跟随；
 *  - 旧版靠 `Class/Class_<班级名>.json` 文件名做关联，改名后名单变孤儿。
 */
export class ClassInfoDao {
  private static map(reader: RsReader): ClassInfoRow {
    return {
      class_id: reader.str('class_id'),
      class_name: reader.str('class_name')
    };
  }

  static async listAll(exec: DbExecutor): Promise<ClassInfoRow[]> {
    const rs = await exec.querySql(
      `SELECT class_id, class_name FROM ${Tables.CLASS_INFO} ORDER BY class_name ASC`, []);
    const rows: ClassInfoRow[] = [];
    try {
      while (rs.goToNextRow()) {
        rows.push(ClassInfoDao.map(new RsReader(rs)));
      }
    } finally {
      rs.close();
    }
    return rows;
  }

  static async findById(exec: DbExecutor, classId: string): Promise<ClassInfoRow | undefined> {
    const rs = await exec.querySql(
      `SELECT class_id, class_name FROM ${Tables.CLASS_INFO} WHERE class_id = ?`, [classId]);
    try {
      if (!rs.goToFirstRow()) {
        return undefined;
      }
      return ClassInfoDao.map(new RsReader(rs));
    } finally {
      rs.close();
    }
  }

  static async findByName(exec: DbExecutor, className: string): Promise<ClassInfoRow | undefined> {
    const rs = await exec.querySql(
      `SELECT class_id, class_name FROM ${Tables.CLASS_INFO} WHERE class_name = ?`, [className]);
    try {
      if (!rs.goToFirstRow()) {
        return undefined;
      }
      return ClassInfoDao.map(new RsReader(rs));
    } finally {
      rs.close();
    }
  }

  /** 按班名取 class_id，不存在则创建。导入课程时用它把班名落到稳定主键上 */
  static async ensureByName(exec: DbExecutor, className: string): Promise<string> {
    const found: ClassInfoRow | undefined = await ClassInfoDao.findByName(exec, className);
    if (found !== undefined) {
      return found.class_id;
    }
    const classId: string = newUuid();
    const ts: number = nowMs();
    await exec.executeSql(
      `INSERT INTO ${Tables.CLASS_INFO} (class_id, class_name, created_at, updated_at) VALUES (?, ?, ?, ?)`,
      [classId, className, ts, ts]);
    return classId;
  }

  static async insert(exec: DbExecutor, info: ClassInfo): Promise<string> {
    const classId: string = info.class_id.length > 0 ? info.class_id : newUuid();
    const ts: number = nowMs();
    await exec.executeSql(
      `INSERT INTO ${Tables.CLASS_INFO} (class_id, class_name, created_at, updated_at) VALUES (?, ?, ?, ?)`,
      [classId, info.class_name, ts, ts]);
    return classId;
  }

  /** 班级改名：只改一行，所有引用这个 class_id 的课程自动跟到新名字 */
  static async rename(exec: DbExecutor, classId: string, newName: string): Promise<void> {
    await exec.executeSql(
      `UPDATE ${Tables.CLASS_INFO} SET class_name = ?, updated_at = ? WHERE class_id = ?`,
      [newName, nowMs(), classId]);
  }

  /** 被多少个课程引用（决定能否删除） */
  static async referenceCount(exec: DbExecutor, classId: string): Promise<number> {
    return DaoSupport.scalarNumber(exec,
      `SELECT COUNT(*) AS v FROM ${Tables.CLASS_GROUP} WHERE class_id = ?`, [classId]);
  }

  /** 删除班级档案；仍被课程引用时返回 false，不强行删（RESTRICT 语义） */
  static async deleteIfUnused(exec: DbExecutor, classId: string): Promise<boolean> {
    const refs: number = await ClassInfoDao.referenceCount(exec, classId);
    if (refs > 0) {
      return false;
    }
    await exec.executeSql(`DELETE FROM ${Tables.STUDENT} WHERE class_id = ?`, [classId]);
    await exec.executeSql(`DELETE FROM ${Tables.CLASS_INFO} WHERE class_id = ?`, [classId]);
    return true;
  }

  static async count(exec: DbExecutor): Promise<number> {
    return DaoSupport.scalarNumber(exec, `SELECT COUNT(*) AS v FROM ${Tables.CLASS_INFO}`, []);
  }

  /**
   * 启动自愈用：列出"孤儿"班级档案 —— 没有被任何班级分组引用。
   *
   * 之所以会存在孤儿：新增课程时新建的班级分组如果没把 `class_id` 落库
   * （见 `CourseDao.upsertGroup`），档案就成了没人引用的孤儿，而分组那边
   * 是个空 `class_id`。两者本是同一次保存写入的，靠 `created_at` 就能配回。
   */
  static async listUnreferenced(exec: DbExecutor): Promise<OrphanClassRow[]> {
    const rs = await exec.querySql(
      `SELECT ci.class_id AS class_id, ci.class_name AS class_name, ci.created_at AS created_at
         FROM ${Tables.CLASS_INFO} ci
        WHERE NOT EXISTS (SELECT 1 FROM ${Tables.CLASS_GROUP} cg WHERE cg.class_id = ci.class_id)
        ORDER BY ci.created_at ASC, ci.class_id ASC`, []);
    const rows: OrphanClassRow[] = [];
    try {
      while (rs.goToNextRow()) {
        const reader: RsReader = new RsReader(rs);
        rows.push({
          class_id: reader.str('class_id'),
          class_name: reader.str('class_name'),
          created_at: reader.num('created_at')
        });
      }
    } finally {
      rs.close();
    }
    return rows;
  }
}
