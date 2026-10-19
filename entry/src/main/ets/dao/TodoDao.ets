import { relationalStore } from '@kit.ArkData';
import { DbExecutor, RsReader } from '../db/DbExecutor';
import { DaoSupport } from './DaoSupport';
import { Tables } from '../db/TableSchema';
import { TodoSubtask, TodoTask } from '../model/Todo';

/**
 * 待办 DAO（todo_task / todo_subtask，schema v7）。
 *
 * 与其它 DAO 同一约定：
 *  - 所有方法收 `DbExecutor`（事务边界由仓库决定）；
 *  - ResultSet 用完即关（不关泄漏）；
 *  - 删除分两级：softDelete（进回收站）与 hardDelete（物理删，含子任务）。
 */
export class TodoDao {

  private static mapTask(reader: RsReader): TodoTask {
    return TodoTask.fromRow(reader);
  }

  private static async queryTasks(exec: DbExecutor, sql: string,
    args: Array<number | string>): Promise<TodoTask[]> {
    const rs = await exec.querySql(sql, args);
    const rows: TodoTask[] = [];
    try {
      while (rs.goToNextRow()) {
        rows.push(TodoDao.mapTask(new RsReader(rs)));
      }
    } finally {
      rs.close();
    }
    return rows;
  }

  /** 未删除的任务（含回收站外的全部：未完成 + 已完成 + 已归档） */
  static async listActive(exec: DbExecutor): Promise<TodoTask[]> {
    return TodoDao.queryTasks(exec,
      `SELECT * FROM ${Tables.TODO_TASK} WHERE deleted = 0 ORDER BY created_at DESC`, []);
  }

  /** 回收站（deleted = 1，按删除时间倒序） */
  static async listTrash(exec: DbExecutor): Promise<TodoTask[]> {
    return TodoDao.queryTasks(exec,
      `SELECT * FROM ${Tables.TODO_TASK} WHERE deleted = 1 ORDER BY deleted_at DESC`, []);
  }

  /** 按 id 取单条未删除任务（详情页用；查不到返回 undefined） */
  static async getById(exec: DbExecutor, id: number): Promise<TodoTask | undefined> {
    const args: Array<number | string> = [id];
    const rows: TodoTask[] = await TodoDao.queryTasks(exec,
      `SELECT * FROM ${Tables.TODO_TASK} WHERE id = ? AND deleted = 0`, args);
    return rows.length > 0 ? rows[0] : undefined;
  }

  /** 某任务的全部子任务（按 sort_order） */
  static async listSubtasks(exec: DbExecutor, taskId: number): Promise<TodoSubtask[]> {
    const args: Array<number | string> = [taskId];
    const rs = await exec.querySql(
      `SELECT * FROM ${Tables.TODO_SUBTASK} WHERE task_id = ? ORDER BY sort_order ASC, id ASC`, args);
    const rows: TodoSubtask[] = [];
    try {
      while (rs.goToNextRow()) {
        rows.push(TodoSubtask.fromRow(new RsReader(rs)));
      }
    } finally {
      rs.close();
    }
    return rows;
  }

  /** 新任务：插主行 + 子任务，返回新任务 id */
  static async insert(exec: DbExecutor, task: TodoTask): Promise<number> {
    const args: Array<relationalStore.ValueType> = [
      task.title, task.description,
      task.due_at === undefined ? null : task.due_at,
      task.remind_at === undefined ? null : task.remind_at,
      task.remind_offset_min === undefined ? null : task.remind_offset_min,
      task.priority, task.tag, task.list_name, task.repeat_rule,
      task.done ? 1 : 0,
      task.done_at === undefined ? null : task.done_at,
      task.remind_fired ? 1 : 0,
      task.created_at, task.updated_at
    ];
    await exec.executeSql(
      `INSERT INTO ${Tables.TODO_TASK}
         (title, description, due_at, remind_at, remind_offset_min, priority, tag, list_name,
          repeat_rule, done, done_at, remind_fired, deleted, deleted_at, archived, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, NULL, 0, ?, ?)`, args);
    const id: number = await DaoSupport.lastRowId(exec);
    await TodoDao.replaceSubtasks(exec, id, task.subtasks);
    return id;
  }

  /** 整行更新（编辑保存 / 状态翻转共用；updated_at 由调用方给） */
  static async update(exec: DbExecutor, task: TodoTask): Promise<void> {
    const args: Array<relationalStore.ValueType> = [
      task.title, task.description,
      task.due_at === undefined ? null : task.due_at,
      task.remind_at === undefined ? null : task.remind_at,
      task.remind_offset_min === undefined ? null : task.remind_offset_min,
      task.priority, task.tag, task.list_name, task.repeat_rule,
      task.done ? 1 : 0,
      task.done_at === undefined ? null : task.done_at,
      task.remind_fired ? 1 : 0,
      task.deleted ? 1 : 0,
      task.deleted_at === undefined ? null : task.deleted_at,
      task.archived ? 1 : 0,
      task.updated_at,
      task.id
    ];
    await exec.executeSql(
      `UPDATE ${Tables.TODO_TASK}
          SET title = ?, description = ?, due_at = ?, remind_at = ?, remind_offset_min = ?,
              priority = ?, tag = ?, list_name = ?, repeat_rule = ?, done = ?, done_at = ?,
              remind_fired = ?, deleted = ?, deleted_at = ?, archived = ?, updated_at = ?
        WHERE id = ?`, args);
    await TodoDao.replaceSubtasks(exec, task.id, task.subtasks);
  }

  /** 只翻转提醒标记（到点提醒触发后置位 / 稍后提醒清零），不碰子任务，省一次重写 */
  static async setRemindFired(exec: DbExecutor, taskId: number, fired: boolean,
    remindAt: number | undefined, nowMs: number): Promise<void> {
    const args: Array<relationalStore.ValueType> = [fired ? 1 : 0,
      remindAt === undefined ? null : remindAt, nowMs, taskId];
    await exec.executeSql(
      `UPDATE ${Tables.TODO_TASK} SET remind_fired = ?, remind_at = ?, updated_at = ? WHERE id = ?`,
      args);
  }

  /** 子任务整体重写（先删后插；数量小，无性能顾虑） */
  static async replaceSubtasks(exec: DbExecutor, taskId: number,
    items: TodoSubtask[]): Promise<void> {
    await exec.executeSql(`DELETE FROM ${Tables.TODO_SUBTASK} WHERE task_id = ?`, [taskId]);
    for (let i = 0; i < items.length; i++) {
      const item: TodoSubtask = items[i];
      const args: Array<relationalStore.ValueType> =
        [taskId, item.title, item.done ? 1 : 0, item.sort_order];
      await exec.executeSql(
        `INSERT INTO ${Tables.TODO_SUBTASK} (task_id, title, done, sort_order) VALUES (?, ?, ?, ?)`,
        args);
    }
  }

  /** 软删：进回收站（deleted=1 + deleted_at；remind 一并停掉避免回收站里还弹提醒） */
  static async softDelete(exec: DbExecutor, ids: number[], deletedAtMs: number): Promise<void> {
    for (let i = 0; i < ids.length; i++) {
      // 占位符只有 3 个（deleted_at / updated_at / id）；deleted = 1 是字面量，args 里不能多塞
      const args: Array<relationalStore.ValueType> = [deletedAtMs, deletedAtMs, ids[i]];
      await exec.executeSql(
        `UPDATE ${Tables.TODO_TASK} SET deleted = 1, deleted_at = ?, remind_at = NULL, updated_at = ?
          WHERE id = ?`, args);
    }
  }

  /** 从回收站恢复 */
  static async restore(exec: DbExecutor, ids: number[], nowMs: number): Promise<void> {
    for (let i = 0; i < ids.length; i++) {
      // 占位符只有 2 个（updated_at / id）；deleted = 0 与 deleted_at = NULL 都是字面量
      const args: Array<relationalStore.ValueType> = [nowMs, ids[i]];
      await exec.executeSql(
        `UPDATE ${Tables.TODO_TASK} SET deleted = 0, deleted_at = NULL, updated_at = ? WHERE id = ?`,
        args);
    }
  }

  /** 彻底删除（物理；子任务靠显式清理——todo 表不挂外键级联，保持独立于课表数据） */
  static async hardDelete(exec: DbExecutor, ids: number[]): Promise<void> {
    for (let i = 0; i < ids.length; i++) {
      await exec.executeSql(`DELETE FROM ${Tables.TODO_SUBTASK} WHERE task_id = ?`, [ids[i]]);
      await exec.executeSql(`DELETE FROM ${Tables.TODO_TASK} WHERE id = ?`, [ids[i]]);
    }
  }

  /** 清理回收站里超过保留期的任务，返回清理条数（进待办页时调用） */
  static async purgeExpired(exec: DbExecutor, expireBeforeMs: number): Promise<number> {
    const args: Array<number | string> = [expireBeforeMs];
    const expired: TodoTask[] = await TodoDao.queryTasks(exec,
      `SELECT * FROM ${Tables.TODO_TASK} WHERE deleted = 1 AND deleted_at IS NOT NULL AND deleted_at < ?`,
      args);
    if (expired.length === 0) {
      return 0;
    }
    const ids: number[] = [];
    for (let i = 0; i < expired.length; i++) {
      ids.push(expired[i].id);
    }
    await TodoDao.hardDelete(exec, ids);
    return ids.length;
  }
}
