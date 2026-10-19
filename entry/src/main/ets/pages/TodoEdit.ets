import { router } from '@kit.ArkUI';
import { TodoRepository } from '../repository/TodoRepository';
import {
  PRESET_LISTS,
  PRIORITY_HIGH,
  PRIORITY_LOW,
  PRIORITY_MID,
  PRIORITY_NONE,
  REPEAT_DAILY,
  REPEAT_MONTHLY,
  REPEAT_NONE,
  REPEAT_WEEKLY,
  TodoSubtask,
  TodoTask
} from '../model/Todo';
import { DateUtil } from '../common/DateUtil';
import { errText } from '../common/Util';
import { Logger } from '../common/Logger';

const TAG: string = 'TodoEdit';

const MIN_MS: number = 60000;
const DAY_MS: number = 24 * 60 * MIN_MS;

/** 提醒提前量芯片（offset 仅在 set=true 时有意义：undefined = 不提醒） */
class RemindChip {
  label: string = '';
  set: boolean = false;
  offset: number = 0;
  constructor(label: string, set: boolean, offset: number) {
    this.label = label;
    this.set = set;
    this.offset = offset;
  }
}

const REMIND_CHIPS: RemindChip[] = [
  new RemindChip('不提醒', false, 0),
  new RemindChip('准时', true, 0),
  new RemindChip('提前 5 分钟', true, 5),
  new RemindChip('提前 1 小时', true, 60),
  new RemindChip('提前 1 天', true, 1440)
];

/** 优先级芯片 */
class PriorityChip {
  label: string = '';
  value: number = 0;
  constructor(label: string, value: number) {
    this.label = label;
    this.value = value;
  }
}

const PRIORITY_CHIPS: PriorityChip[] = [
  new PriorityChip('无', PRIORITY_NONE),
  new PriorityChip('低', PRIORITY_LOW),
  new PriorityChip('中', PRIORITY_MID),
  new PriorityChip('高', PRIORITY_HIGH)
];

/** 重复规则芯片 */
class RepeatChip {
  label: string = '';
  value: string = '';
  constructor(label: string, value: string) {
    this.label = label;
    this.value = value;
  }
}

const REPEAT_CHIPS: RepeatChip[] = [
  new RepeatChip('不重复', REPEAT_NONE),
  new RepeatChip('每天', REPEAT_DAILY),
  new RepeatChip('每周', REPEAT_WEEKLY),
  new RepeatChip('每月', REPEAT_MONTHLY)
];

/** 子任务草稿（详情模式下要保留 done 勾选态） */
class SubDraft {
  title: string = '';
  done: boolean = false;
  constructor(title: string, done: boolean) {
    this.title = title;
    this.done = done;
  }
}

/**
 * 待办全屏页（新建 / 详情两用；待办面板右下角 + 与点击任务行进入）。
 *
 *  - 新建：路由参数只带 themeColor，标题「新建任务」，保存走 `TodoRepository.create`；
 *  - 详情：路由参数带 taskId，标题「任务详情」，先 loadTask 回填表单（含子任务勾选态），
 *    保存走 `saveEdit` 整行更新（done / done_at / created_at 等由回填的原任务带回去，
 *    子任务先删后插整体重写）；另有复制任务 / 移入回收站；
 *  - 成功后 `router.back()`，由首页 `onPageShow` 自增 refreshTick 让待办面板重载；
 *  - 主题色由调用方带过来（与待办面板一致）。
 */
@Entry
@ComponentV2
struct TodoEditPage {
  /** 主题色（待办面板传入） */
  @Local themeColor: string = '#1890FF';
  /** 详情模式：任务 id（0 = 新建） */
  @Local editId: number = 0;
  /** 详情模式回填的原任务（保存时以它为底，保留 done / created_at 等表单外字段） */
  private baseTask: TodoTask | null = null;
  @Local title: string = '';
  @Local description: string = '';
  /** 截止时间（毫秒；undefined = 未设置） */
  @Local dueAt: number | undefined = undefined;
  /** 提醒提前量（分钟；undefined = 不提醒） */
  @Local remindOffset: number | undefined = undefined;
  @Local priority: number = PRIORITY_NONE;
  @Local listName: string = '个人';
  @Local repeatRule: string = REPEAT_NONE;
  /** 子任务草稿（创建 / 详情一并入库） */
  @Local subs: SubDraft[] = [];
  @Local subInput: string = '';
  @Local saving: boolean = false;

  aboutToAppear(): void {
    const params: Record<string, Object> | undefined = router.getParams() as Record<string, Object>;
    if (params !== undefined && params['themeColor'] !== undefined) {
      this.themeColor = '' + params['themeColor'];
    }
    if (params !== undefined && params['taskId'] !== undefined) {
      const taskId: number = Number(params['taskId']);
      if (Number.isFinite(taskId) && taskId > 0) {
        this.editId = taskId;
        this.loadTask(taskId);
      }
    }
  }

  /** 详情模式：回填表单（查不到任务视为已不存在，退出） */
  private async loadTask(taskId: number): Promise<void> {
    try {
      const task: TodoTask | null = await TodoRepository.getInstance().loadTask(taskId);
      if (task === null) {
        this.toast('这条任务已不存在');
        router.back();
        return;
      }
      this.baseTask = task;
      this.title = task.title;
      this.description = task.description;
      this.dueAt = task.due_at;
      this.remindOffset = task.remind_offset_min;
      this.priority = task.priority;
      this.listName = task.list_name;
      this.repeatRule = task.repeat_rule;
      const drafts: SubDraft[] = [];
      for (let i = 0; i < task.subtasks.length; i++) {
        drafts.push(new SubDraft(task.subtasks[i].title, task.subtasks[i].done));
      }
      this.subs = drafts;
    } catch (e) {
      Logger.error(TAG, `待办详情加载失败：${errText(e)}`);
      this.toast(`加载任务失败：${errText(e)}`);
      router.back();
    }
  }

  // ------------------------------------------------------------ 表单操作

  private remindChipActive(chip: RemindChip): boolean {
    if (!chip.set) {
      return this.remindOffset === undefined;
    }
    return this.remindOffset === chip.offset;
  }

  private setRemindOffset(chip: RemindChip): void {
    if (!chip.set) {
      this.remindOffset = undefined;
      return;
    }
    this.remindOffset = chip.offset;
  }

  private pickDueDate(): void {
    const base: Date = this.dueAt === undefined ? new Date() : new Date(this.dueAt);
    DatePickerDialog.show({
      start: new Date(DateUtil.startOfDay(new Date())),
      selected: base,
      end: new Date(DateUtil.startOfDay(new Date()) + 366 * DAY_MS),
      onDateAccept: (value: Date) => {
        this.pickDueTime(value);
      }
    });
  }

  private pickDueTime(datePart: Date): void {
    const base: Date = this.dueAt === undefined ? new Date() : new Date(this.dueAt);
    TimePickerDialog.show({
      selected: base,
      onAccept: (value: TimePickerResult) => {
        const due: Date = new Date(datePart.getFullYear(), datePart.getMonth(), datePart.getDate(),
          value.hour, value.minute, 0, 0);
        this.dueAt = due.getTime();
        if (this.remindOffset === undefined) {
          this.remindOffset = 0;
        }
      }
    });
  }

  private clearDue(): void {
    this.dueAt = undefined;
    this.remindOffset = undefined;
  }

  private addSubtask(): void {
    const name: string = this.subInput.trim();
    if (name.length === 0) {
      return;
    }
    this.subs = this.subs.concat([new SubDraft(name, false)]);
    this.subInput = '';
  }

  private removeSubtask(index: number): void {
    if (index < 0 || index >= this.subs.length) {
      return;
    }
    const kept: SubDraft[] = [];
    for (let i = 0; i < this.subs.length; i++) {
      if (i !== index) {
        kept.push(this.subs[i]);
      }
    }
    this.subs = kept;
  }

  private toggleSubDone(index: number): void {
    if (index < 0 || index >= this.subs.length) {
      return;
    }
    const sub: SubDraft = this.subs[index];
    this.subs[index] = new SubDraft(sub.title, !sub.done);
  }

  /** 截止显示：今天只报时分，跨天带日期 */
  private formatDue(ms: number): string {
    const d: Date = new Date(ms);
    const hm: string = `${d.getHours()}:${d.getMinutes() < 10 ? '0' : ''}${d.getMinutes()}`;
    const today: number = DateUtil.startOfDay(new Date());
    if (ms >= today && ms < today + DAY_MS) {
      return hm;
    }
    return `${d.getMonth() + 1}月${d.getDate()}日 ${hm}`;
  }

  private dueLabel(): string {
    return this.dueAt === undefined ? '未设置' : this.formatDue(this.dueAt);
  }

  // ------------------------------------------------------------ 保存 / 详情操作

  private toast(msg: string): void {
    if (msg.length === 0) {
      return;
    }
    AlertDialog.show({
      message: msg,
      autoCancel: true,
      confirm: { value: '知道了', action: () => { } }
    });
  }

  private async save(): Promise<void> {
    const name: string = this.title.trim();
    if (name.length === 0) {
      this.toast('请先填写任务标题');
      return;
    }
    if (this.saving) {
      return;
    }
    if (this.editId > 0 && this.baseTask === null) {
      // 详情模式但原任务还没回填完成——不保存，避免误建成新任务
      this.toast('任务还在加载中，请稍候');
      return;
    }
    this.saving = true;
    try {
      if (this.editId > 0 && this.baseTask !== null) {
        // 详情：以回填的原任务为底（保留 done / done_at / created_at 等表单外字段）
        const task: TodoTask = this.baseTask;
        task.title = name;
        task.description = this.description.trim();
        task.due_at = this.dueAt;
        task.remind_offset_min = this.dueAt === undefined ? undefined : this.remindOffset;
        task.priority = this.priority;
        task.list_name = this.listName;
        task.repeat_rule = this.repeatRule;
        task.subtasks = [];
        for (let i = 0; i < this.subs.length; i++) {
          const subName: string = this.subs[i].title.trim();
          if (subName.length === 0) {
            continue;
          }
          const sub: TodoSubtask = new TodoSubtask();
          sub.title = subName;
          sub.done = this.subs[i].done;
          sub.sort_order = task.subtasks.length;
          task.subtasks.push(sub);
        }
        await TodoRepository.getInstance().saveEdit(task);
        Logger.info(TAG, `待办更新成功 id=${task.id} 子任务 ${task.subtasks.length} 条`);
      } else {
        const task: TodoTask = new TodoTask();
        task.title = name;
        task.description = this.description.trim();
        task.due_at = this.dueAt;
        task.remind_offset_min = this.dueAt === undefined ? undefined : this.remindOffset;
        task.priority = this.priority;
        task.list_name = this.listName;
        task.repeat_rule = this.repeatRule;
        for (let i = 0; i < this.subs.length; i++) {
          const subName: string = this.subs[i].title.trim();
          if (subName.length === 0) {
            continue;
          }
          const sub: TodoSubtask = new TodoSubtask();
          sub.title = subName;
          sub.sort_order = task.subtasks.length;
          task.subtasks.push(sub);
        }
        const id: number = await TodoRepository.getInstance().create(task);
        Logger.info(TAG, `待办创建成功 id=${id} 子任务 ${task.subtasks.length} 条`);
      }
      router.back();
    } catch (e) {
      Logger.error(TAG, `待办保存失败：${errText(e)}`);
      this.toast(`保存失败：${errText(e)}`);
    }
    this.saving = false;
  }

  /** 详情模式：复制任务（复制成功直接退出，面板刷新后可见副本） */
  private async duplicateCurrent(): Promise<void> {
    if (this.saving) {
      return;
    }
    this.saving = true;
    try {
      const copy: TodoTask | undefined =
        await TodoRepository.getInstance().duplicate(this.editId);
      this.toast(copy === undefined ? '任务不存在' : `已复制为「${copy.title}」`);
      if (copy !== undefined) {
        router.back();
      }
    } catch (e) {
      this.toast(`复制任务失败：${errText(e)}`);
    }
    this.saving = false;
  }

  /** 详情模式：移入回收站（软删，可在回收站恢复） */
  private async trashCurrent(): Promise<void> {
    if (this.saving) {
      return;
    }
    this.saving = true;
    try {
      await TodoRepository.getInstance().softDelete([this.editId]);
      router.back();
    } catch (e) {
      this.toast(`移入回收站失败：${errText(e)}`);
    }
    this.saving = false;
  }

  // ------------------------------------------------------------ UI

  build() {
    Column() {
      this.topBar()
      Scroll() {
        this.formArea()
      }
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F3F4F6')
  }

  @Builder
  topBar() {
    Row({ space: 8 }) {
      Text('✕')
        .fontSize(18)
        .fontColor('#6B7280')
        .width(36)
        .height(36)
        .textAlign(TextAlign.Center)
        .borderRadius(18)
        .backgroundColor('#FFFFFF')
        .onClick(() => router.back())
      Text(this.editId > 0 ? '任务详情' : '新建任务')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor('#111827')
        .layoutWeight(1)
      Text(this.saving ? '保存中…' : '保存')
        .fontSize(14)
        .fontColor('#FFFFFF')
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .borderRadius(18)
        .backgroundColor(this.title.trim().length > 0 ? this.themeColor : '#9CA3AF')
        .onClick(() => this.save())
    }
    .width('100%')
    .height(56)
    .padding({ left: 16, right: 16 })
    .backgroundColor('#F3F4F6')
  }

  @Builder
  formArea() {
    Column({ space: 12 }) {
      TextInput({ placeholder: '任务标题（必填）', text: this.title })
        .fontSize(16)
        .height(48)
        .backgroundColor('#FFFFFF')
        .borderRadius(12)
        .defaultFocus(this.editId === 0)
        .onChange((value: string) => {
          this.title = value;
        })

      TextArea({ placeholder: '描述 / 备注（可选，支持多行）', text: this.description })
        .fontSize(13)
        .height(84)
        .backgroundColor('#FFFFFF')
        .borderRadius(12)
        .onChange((value: string) => {
          this.description = value;
        })

      this.fieldDueCard()
      this.fieldRemindCard()
      this.fieldPriorityCard()
      this.fieldListCard()
      this.fieldRepeatCard()
      this.fieldSubtaskCard()

      if (this.editId > 0) {
        this.detailActions()
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 4, bottom: 24 })
    .alignItems(HorizontalAlign.Start)
  }

  /** 字段卡片外框：左侧标签 + 右侧内容 */
  @Builder
  fieldFrame(label: string) {
    Text(label)
      .fontSize(13)
      .fontColor('#6B7280')
      .width(60)
  }

  @Builder
  fieldDueCard() {
    Row({ space: 12 }) {
      this.fieldFrame('截止时间')
      Row({ space: 8 }) {
        Text(this.dueLabel())
          .fontSize(13)
          .fontColor(this.dueAt === undefined ? '#9CA3AF' : '#111827')
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .borderRadius(10)
          .backgroundColor('#F3F4F6')
          .onClick(() => this.pickDueDate())
        if (this.dueAt !== undefined) {
          Text('清除')
            .fontSize(12)
            .fontColor('#EF4444')
            .padding(6)
            .onClick(() => this.clearDue())
        }
      }
      .layoutWeight(1)
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#FFFFFF')
    .borderRadius(12)
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  fieldRemindCard() {
    Row({ space: 12 }) {
      this.fieldFrame('提醒')
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
        ForEach(REMIND_CHIPS, (chip: RemindChip) => {
          Text(chip.label)
            .fontSize(12)
            .fontColor(this.remindChipActive(chip) ? '#FFFFFF' : '#374151')
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .borderRadius(14)
            .margin({ right: 6, bottom: 6 })
            .backgroundColor(this.remindChipActive(chip) ? this.themeColor : '#F3F4F6')
            .onClick(() => this.setRemindOffset(chip))
        }, (chip: RemindChip) => `remind-${chip.label}-${this.remindChipActive(chip)}`)
      }
      .layoutWeight(1)
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#FFFFFF')
    .borderRadius(12)
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  fieldPriorityCard() {
    Row({ space: 12 }) {
      this.fieldFrame('优先级')
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
        ForEach(PRIORITY_CHIPS, (chip: PriorityChip) => {
          Text(chip.label)
            .fontSize(12)
            .fontColor(this.priority === chip.value ? '#FFFFFF' : '#374151')
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .borderRadius(14)
            .margin({ right: 6, bottom: 6 })
            .backgroundColor(this.priority === chip.value ? this.themeColor : '#F3F4F6')
            .onClick(() => {
              this.priority = chip.value;
            })
        }, (chip: PriorityChip) => `prio-${chip.label}-${this.priority === chip.value}`)
      }
      .layoutWeight(1)
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#FFFFFF')
    .borderRadius(12)
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  fieldListCard() {
    Row({ space: 12 }) {
      this.fieldFrame('清单')
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
        ForEach(PRESET_LISTS, (name: string) => {
          Text(name)
            .fontSize(12)
            .fontColor(this.listName === name ? '#FFFFFF' : '#374151')
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .borderRadius(14)
            .margin({ right: 6, bottom: 6 })
            .backgroundColor(this.listName === name ? this.themeColor : '#F3F4F6')
            .onClick(() => {
              this.listName = name;
            })
        }, (name: string) => `list-${name}-${this.listName === name}`)
      }
      .layoutWeight(1)
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#FFFFFF')
    .borderRadius(12)
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  fieldRepeatCard() {
    Row({ space: 12 }) {
      this.fieldFrame('重复')
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
        ForEach(REPEAT_CHIPS, (chip: RepeatChip) => {
          Text(chip.label)
            .fontSize(12)
            .fontColor(this.repeatRule === chip.value ? '#FFFFFF' : '#374151')
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .borderRadius(14)
            .margin({ right: 6, bottom: 6 })
            .backgroundColor(this.repeatRule === chip.value ? this.themeColor : '#F3F4F6')
            .onClick(() => {
              this.repeatRule = chip.value;
            })
        }, (chip: RepeatChip) => `repeat-${chip.label}-${this.repeatRule === chip.value}`)
      }
      .layoutWeight(1)
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#FFFFFF')
    .borderRadius(12)
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  fieldSubtaskCard() {
    Row({ space: 12 }) {
      this.fieldFrame('子任务')
      Column({ space: 6 }) {
        ForEach(this.subs, (sub: SubDraft, idx: number) => {
          Row({ space: 8 }) {
            Text(sub.done ? '✓' : '')
              .fontSize(12)
              .fontColor('#FFFFFF')
              .textAlign(TextAlign.Center)
              .width(20)
              .height(20)
              .borderRadius(10)
              .backgroundColor(sub.done ? this.themeColor : '#FFFFFF')
              .border({ width: 1, color: sub.done ? this.themeColor : '#D1D5DB' })
              .onClick(() => this.toggleSubDone(idx))
            Text(sub.title)
              .fontSize(13)
              .fontColor(sub.done ? '#9CA3AF' : '#111827')
              .decoration({ type: sub.done ? TextDecorationType.LineThrough : TextDecorationType.None })
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text('移除')
              .fontSize(11)
              .fontColor('#EF4444')
              .onClick(() => this.removeSubtask(idx))
          }
          .width('100%')
        }, (sub: SubDraft, idx: number) => `sub-${idx}-${sub.title}-${sub.done}`)

        Row({ space: 8 }) {
          TextInput({ placeholder: '子任务标题…', text: this.subInput })
            .fontSize(13)
            .height(36)
            .layoutWeight(1)
            .backgroundColor('#F3F4F6')
            .borderRadius(8)
            .padding({ left: 10, right: 10 })
            .onChange((value: string) => {
              this.subInput = value;
            })
            .onSubmit(() => this.addSubtask())
          Text('添加')
            .fontSize(13)
            .fontColor(this.themeColor)
            .padding(6)
            .onClick(() => this.addSubtask())
        }
        .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#FFFFFF')
    .borderRadius(12)
    .alignItems(VerticalAlign.Top)
  }

  /** 详情模式底部操作：复制 / 移入回收站 */
  @Builder
  detailActions() {
    Row({ space: 8 }) {
      Button('复制任务')
        .fontSize(14)
        .height(44)
        .layoutWeight(1)
        .backgroundColor('#6B7280')
        .onClick(() => this.duplicateCurrent())
      Button('移入回收站')
        .fontSize(14)
        .height(44)
        .layoutWeight(1)
        .backgroundColor('#EF4444')
        .fontColor('#FFFFFF')
        .onClick(() => this.trashCurrent())
    }
    .width('100%')
  }
}
