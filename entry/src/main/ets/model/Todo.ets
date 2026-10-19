import { RsReader } from '../db/DbExecutor';

/**
 * 待办任务（对应 todo_task / todo_subtask 表，schema v7）。
 *
 * 设计要点：
 *  - 时间戳一律毫秒 epoch（与全库约定一致）；"未设置"用 undefined（落库为 NULL）；
 *  - priority：0 无 / 1 低 / 2 中 / 3 高；repeat_rule：none / daily / weekly / monthly；
 *  - 提醒不单独存"提醒时间"列，由 due_at - remind_offset_min 现算；
 *    remind_offset_min：undefined = 不提醒，0 = 准时，5 / 60 / 1440 = 提前量（分钟）；
 *  - 删除是**软删**（deleted=1 + deleted_at），回收站保留 30 天后物理清理；
 *  - 重复任务完成后**克隆下一条**（原条留痕在已完成，下一条进入未完成）。
 */

export const PRIORITY_NONE: number = 0;
export const PRIORITY_LOW: number = 1;
export const PRIORITY_MID: number = 2;
export const PRIORITY_HIGH: number = 3;

export const REPEAT_NONE: string = 'none';
export const REPEAT_DAILY: string = 'daily';
export const REPEAT_WEEKLY: string = 'weekly';
export const REPEAT_MONTHLY: string = 'monthly';

/** 回收站保留天数：超过后进页自动物理清理 */
export const TRASH_KEEP_DAYS: number = 30;

/** 预设清单（可自由输入，不限于此） */
export const PRESET_LISTS: string[] = ['个人', '工作', '购物', '学习'];

/** 提醒提前量选项（分钟；0 = 准时提醒）。undefined = 不提醒 */
export const REMIND_OFFSETS: number[] = [0, 5, 60, 1440];

/** 优先级显示名与配色（UI 唯一取色处） */
export class PriorityStyle {
  static label(priority: number): string {
    if (priority === PRIORITY_HIGH) {
      return '高';
    }
    if (priority === PRIORITY_MID) {
      return '中';
    }
    if (priority === PRIORITY_LOW) {
      return '低';
    }
    return '无';
  }

  static color(priority: number): string {
    if (priority === PRIORITY_HIGH) {
      return '#EF4444';
    }
    if (priority === PRIORITY_MID) {
      return '#F59E0B';
    }
    if (priority === PRIORITY_LOW) {
      return '#3B82F6';
    }
    return '#9CA3AF';
  }
}

export function repeatLabel(rule: string): string {
  if (rule === REPEAT_DAILY) {
    return '每天';
  }
  if (rule === REPEAT_WEEKLY) {
    return '每周';
  }
  if (rule === REPEAT_MONTHLY) {
    return '每月';
  }
  return '不重复';
}

/** 子任务（对应 todo_subtask 表） */
@ObservedV2
export class TodoSubtask {
  @Trace id: number = 0;
  @Trace task_id: number = 0;
  @Trace title: string = '';
  @Trace done: boolean = false;
  @Trace sort_order: number = 0;

  static fromRow(reader: RsReader): TodoSubtask {
    const item: TodoSubtask = new TodoSubtask();
    item.id = reader.num('id');
    item.task_id = reader.num('task_id');
    item.title = reader.str('title');
    item.done = reader.num('done', 0) === 1;
    item.sort_order = reader.num('sort_order', 0);
    return item;
  }
}

/** 待办任务（对应 todo_task 表；subtasks 由仓库装配，非表列） */
@ObservedV2
export class TodoTask {
  @Trace id: number = 0;
  @Trace title: string = '';
  @Trace description: string = '';
  /** 截止时间（毫秒；undefined = 未设置） */
  @Trace due_at: number | undefined = undefined;
  /** 下次提醒时间（毫秒；由 due_at - remind_offset_min 现算，undefined = 不提醒） */
  @Trace remind_at: number | undefined = undefined;
  /** 提前量（分钟）：undefined = 不提醒，0 = 准时，5 / 60 / 1440 */
  @Trace remind_offset_min: number | undefined = undefined;
  @Trace priority: number = PRIORITY_NONE;
  /** 标签（单值文本，空串 = 无） */
  @Trace tag: string = '';
  /** 清单 / 项目 */
  @Trace list_name: string = '个人';
  @Trace repeat_rule: string = REPEAT_NONE;
  @Trace done: boolean = false;
  @Trace done_at: number | undefined = undefined;
  /** 本次提醒是否已弹过（防重复提醒；稍后提醒会清零并顺延 remind_at） */
  @Trace remind_fired: boolean = false;
  @Trace deleted: boolean = false;
  @Trace deleted_at: number | undefined = undefined;
  @Trace archived: boolean = false;
  @Trace created_at: number = 0;
  @Trace updated_at: number = 0;
  /** 子任务（仓库装配） */
  @Trace subtasks: TodoSubtask[] = [];

  static fromRow(reader: RsReader): TodoTask {
    const task: TodoTask = new TodoTask();
    task.id = reader.num('id');
    task.title = reader.str('title');
    task.description = reader.str('description');
    task.due_at = reader.optNum('due_at');
    task.remind_at = reader.optNum('remind_at');
    task.remind_offset_min = reader.optNum('remind_offset_min');
    task.priority = reader.num('priority', PRIORITY_NONE);
    task.tag = reader.optStr('tag') === undefined ? '' : (reader.optStr('tag') as string);
    task.list_name = reader.str('list_name', '个人');
    task.repeat_rule = reader.str('repeat_rule', REPEAT_NONE);
    task.done = reader.num('done', 0) === 1;
    task.done_at = reader.optNum('done_at');
    task.remind_fired = reader.num('remind_fired', 0) === 1;
    task.deleted = reader.num('deleted', 0) === 1;
    task.deleted_at = reader.optNum('deleted_at');
    task.archived = reader.num('archived', 0) === 1;
    task.created_at = reader.num('created_at');
    task.updated_at = reader.num('updated_at');
    return task;
  }

  /** 由截止时间与提前量重算下次提醒时间（保存 / 改期时调用） */
  recomputeRemindAt(): void {
    if (this.due_at === undefined || this.remind_offset_min === undefined) {
      this.remind_at = undefined;
      return;
    }
    this.remind_at = this.due_at - this.remind_offset_min * 60000;
  }

  /** 子任务进度：已完成数 / 总数 */
  subtaskProgress(): string {
    if (this.subtasks.length === 0) {
      return '';
    }
    let doneCount: number = 0;
    for (let i = 0; i < this.subtasks.length; i++) {
      if (this.subtasks[i].done) {
        doneCount++;
      }
    }
    return `${doneCount}/${this.subtasks.length}`;
  }
}
