import { ScheduleDb } from '../db/ScheduleDb';
import { DbExecutor } from '../db/DbExecutor';
import { TodoDao } from '../dao/TodoDao';
import {
  REPEAT_DAILY,
  REPEAT_MONTHLY,
  REPEAT_WEEKLY,
  TodoSubtask,
  TodoTask,
  TRASH_KEEP_DAYS
} from '../model/Todo';
import { nowMs } from '../common/Util';
import { Logger } from '../common/Logger';

const TAG: string = 'TodoRepository';

/**
 * 待办仓库：待办数据的唯一事务入口（与 ScheduleRepository 同级，互不掺和）。
 *
 * 待办数据与课表完全独立（不带学期外键），删学期 / 换教师都不影响待办；
 * 唯一的交集是「学习」清单里展示的当天课程——那只读课表（loadTodayLessons），不写。
 *
 * 约定：
 *  - 读走非事务执行器；任何写都进事务（单任务 + 子任务 = 两张表，必须同生同死）；
 *  - 遇 14800024 由 ScheduleDb.runInTransaction 统一退避重试；
 *  - 「完成重复任务 → 克隆下一条」与「标记完成」在同一个事务里，防止中途崩溃出现
 *    "完成了但下一条没生成"的断档。
 */
export class TodoRepository {
  private static instance: TodoRepository | null = null;
  private db: ScheduleDb;

  private constructor() {
    this.db = ScheduleDb.getInstance();
  }

  static getInstance(): TodoRepository {
    if (TodoRepository.instance === null) {
      TodoRepository.instance = new TodoRepository();
    }
    return TodoRepository.instance;
  }

  /** 全部未删除任务（子任务已装配；UI 拿到后自行筛选排序） */
  async loadTasks(): Promise<TodoTask[]> {
    const exec = this.db.executor();
    const tasks: TodoTask[] = await TodoDao.listActive(exec);
    await this.attachSubtasks(exec, tasks);
    return tasks;
  }

  /** 回收站（子任务已装配；恢复时要用到子任务） */
  async loadTrash(): Promise<TodoTask[]> {
    const exec = this.db.executor();
    const tasks: TodoTask[] = await TodoDao.listTrash(exec);
    await this.attachSubtasks(exec, tasks);
    return tasks;
  }

  private async attachSubtasks(exec: DbExecutor, tasks: TodoTask[]): Promise<void> {
    for (let i = 0; i < tasks.length; i++) {
      tasks[i].subtasks = await TodoDao.listSubtasks(exec, tasks[i].id);
    }
  }

  /** 按 id 取单条任务（详情全屏页用；含子任务；查不到返回 null） */
  async loadTask(taskId: number): Promise<TodoTask | null> {
    const exec = this.db.executor();
    const task: TodoTask | undefined = await TodoDao.getById(exec, taskId);
    if (task === undefined) {
      return null;
    }
    task.subtasks = await TodoDao.listSubtasks(exec, taskId);
    return task;
  }

  /** 新建任务（标题即可；其余字段走详情编辑） */
  async create(task: TodoTask): Promise<number> {
    task.created_at = nowMs();
    task.updated_at = task.created_at;
    task.recomputeRemindAt();
    return this.db.runInTransaction<number>(async (exec) => {
      return TodoDao.insert(exec, task);
    });
  }

  /** 编辑保存（自动保存走这里：整行更新 + 子任务重写） */
  async saveEdit(task: TodoTask): Promise<void> {
    task.updated_at = nowMs();
    task.recomputeRemindAt();
    await this.db.runInTransaction<void>(async (exec) => {
      await TodoDao.update(exec, task);
    });
  }

  /**
   * 标记完成 / 撤销完成。
   *
   * 完成重复任务时在同事务克隆下一条（due_at 顺推一个周期，提醒按新截止重算）；
   * **克隆前查重**：同标题 + 同重复规则 + 同截止且未完成的任务已存在就不再插入——
   * 撤销不回收已克隆的下一条，没有这道闸，「撤销 → 再完成」每转一圈就堆一条同款；
   * 撤销只清 done / done_at。
   */
  async toggleDone(task: TodoTask): Promise<void> {
    await this.db.runInTransaction<void>(async (exec) => {
      const now: number = nowMs();
      task.done = !task.done;
      task.done_at = task.done ? now : undefined;
      task.updated_at = now;
      task.remind_fired = task.done ? task.remind_fired : false;
      await TodoDao.update(exec, task);
      if (task.done && task.repeat_rule !== 'none') {
        const next: TodoTask = this.cloneForRepeat(task, now);
        const all: TodoTask[] = await TodoDao.listActive(exec);
        let exists: boolean = false;
        for (let i = 0; i < all.length; i++) {
          const t: TodoTask = all[i];
          if (!t.done && t.title === next.title && t.repeat_rule === next.repeat_rule
            && t.due_at === next.due_at) {
            exists = true;
            break;
          }
        }
        if (!exists) {
          await TodoDao.insert(exec, next);
        } else {
          Logger.info(TAG, `重复任务下一条已存在（${next.title}），跳过克隆`);
        }
      }
    });
  }

  /** 复制任务（含子任务；清单不变，标题加「副本」） */
  async duplicate(taskId: number): Promise<TodoTask | undefined> {
    return this.db.runInTransaction<TodoTask | undefined>(async (exec) => {
      const all: TodoTask[] = await TodoDao.listActive(exec);
      let source: TodoTask | undefined = undefined;
      for (let i = 0; i < all.length; i++) {
        if (all[i].id === taskId) {
          source = all[i];
          break;
        }
      }
      if (source === undefined) {
        return undefined;
      }
      const now: number = nowMs();
      const copy: TodoTask = new TodoTask();
      copy.title = `${source.title}（副本）`;
      copy.description = source.description;
      copy.due_at = source.due_at;
      copy.remind_offset_min = source.remind_offset_min;
      copy.priority = source.priority;
      copy.tag = source.tag;
      copy.list_name = source.list_name;
      copy.repeat_rule = source.repeat_rule;
      copy.created_at = now;
      copy.updated_at = now;
      copy.recomputeRemindAt();
      for (let i = 0; i < source.subtasks.length; i++) {
        const sub: TodoSubtask = new TodoSubtask();
        sub.title = source.subtasks[i].title;
        sub.done = false;
        sub.sort_order = source.subtasks[i].sort_order;
        copy.subtasks.push(sub);
      }
      const newId: number = await TodoDao.insert(exec, copy);
      copy.id = newId;
      return copy;
    });
  }

  /** 重复任务的"下一条"：顺推一个周期，提醒重算，子任务照搬（全部未完成） */
  private cloneForRepeat(task: TodoTask, now: number): TodoTask {
    const next: TodoTask = new TodoTask();
    next.title = task.title;
    next.description = task.description;
    if (task.due_at !== undefined) {
      const due: Date = new Date(task.due_at);
      if (task.repeat_rule === REPEAT_DAILY) {
        due.setDate(due.getDate() + 1);
      } else if (task.repeat_rule === REPEAT_WEEKLY) {
        due.setDate(due.getDate() + 7);
      } else if (task.repeat_rule === REPEAT_MONTHLY) {
        due.setMonth(due.getMonth() + 1);
      }
      next.due_at = due.getTime();
    }
    next.remind_offset_min = task.remind_offset_min;
    next.priority = task.priority;
    next.tag = task.tag;
    next.list_name = task.list_name;
    next.repeat_rule = task.repeat_rule;
    next.created_at = now;
    next.updated_at = now;
    next.recomputeRemindAt();
    for (let i = 0; i < task.subtasks.length; i++) {
      const sub: TodoSubtask = new TodoSubtask();
      sub.title = task.subtasks[i].title;
      sub.done = false;
      sub.sort_order = task.subtasks[i].sort_order;
      next.subtasks.push(sub);
    }
    return next;
  }

  /** 软删进回收站 */
  async softDelete(ids: number[]): Promise<void> {
    const now: number = nowMs();
    await this.db.runInTransaction<void>(async (exec) => {
      await TodoDao.softDelete(exec, ids, now);
    });
  }

  /** 从回收站恢复：未完成任务的重提醒按（截止 - 提前量）重建 */
  async restore(ids: number[]): Promise<void> {
    const now: number = nowMs();
    await this.db.runInTransaction<void>(async (exec) => {
      await TodoDao.restore(exec, ids, now);
      const all: TodoTask[] = await TodoDao.listActive(exec);
      for (let i = 0; i < all.length; i++) {
        const task: TodoTask = all[i];
        if (ids.indexOf(task.id) < 0) {
          continue;
        }
        if (!task.done && task.due_at !== undefined && task.remind_offset_min !== undefined) {
          task.remind_fired = false;
          task.recomputeRemindAt();
          // update 会整行重写（含子任务重写）——先把子任务装回来，别把用户的子任务清了
          task.subtasks = await TodoDao.listSubtasks(exec, task.id);
          await TodoDao.update(exec, task);
        }
      }
    });
  }

  /** 彻底删除（回收站里手动清空单条） */
  async hardDelete(ids: number[]): Promise<void> {
    await this.db.runInTransaction<void>(async (exec) => {
      await TodoDao.hardDelete(exec, ids);
    });
  }

  /** 清理回收站超过保留期的任务，返回清理条数 */
  async purgeExpiredTrash(): Promise<number> {
    const horizon: number = nowMs() - TRASH_KEEP_DAYS * 24 * 60 * 60 * 1000;
    return this.db.runInTransaction<number>(async (exec) => {
      return TodoDao.purgeExpired(exec, horizon);
    });
  }

  /** 到点提醒：把所有到期未提醒的任务标记为已提醒，返回它们（UI 负责弹窗与稍后提醒） */
  async collectDueReminders(): Promise<TodoTask[]> {
    const now: number = nowMs();
    const exec = this.db.executor();
    const all: TodoTask[] = await TodoDao.listActive(exec);
    const due: TodoTask[] = [];
    for (let i = 0; i < all.length; i++) {
      const task: TodoTask = all[i];
      if (!task.done && !task.remind_fired && task.remind_at !== undefined && task.remind_at <= now) {
        due.push(task);
      }
    }
    if (due.length === 0) {
      return [];
    }
    const ids: number[] = [];
    for (let i = 0; i < due.length; i++) {
      ids.push(due[i].id);
    }
    await this.db.runInTransaction<void>(async (tx) => {
      for (let i = 0; i < ids.length; i++) {
        await TodoDao.setRemindFired(tx, ids[i], true, due[i].remind_at, now);
      }
    });
    return due;
  }

  /** 稍后提醒：顺延 remind_at 并清掉已提醒标记 */
  async snooze(taskId: number, remindAtMs: number): Promise<void> {
    await this.db.runInTransaction<void>(async (exec) => {
      await TodoDao.setRemindFired(exec, taskId, false, remindAtMs, nowMs());
    });
  }
}
