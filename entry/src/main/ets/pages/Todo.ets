import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { ScheduleRepository } from '../repository/ScheduleRepository';
import { TodoRepository } from '../repository/TodoRepository';
import { LessonRow } from '../model/Rows';
import { ScheduleSlot } from '../model/ScheduleTemplate';
import {
  PRESET_LISTS,
  PRIORITY_NONE,
  PriorityStyle,
  TodoTask,
  repeatLabel
} from '../model/Todo';
import { DateUtil } from '../common/DateUtil';
import { PAGE_BG_COLOR, errText, nowMs } from '../common/Util';
import { Logger } from '../common/Logger';
import { LessonDoneStore } from '../common/LessonDoneStore';

const TAG: string = 'TodoPanel';

/** 视图状态：主列表（按 逾期/今日/即将/无截止/已完成 分组）与回收站 */
const VIEW_ALL: string = 'all';
const VIEW_TRASH: string = 'trash';

/** 排序方式 */
const SORT_DUE: string = 'due';
const SORT_PRIORITY: string = 'priority';
const SORT_CREATED: string = 'created';

const MIN_MS: number = 60000;
const DAY_MS: number = 24 * 60 * MIN_MS;

/**
 * 待办面板（TabBar 第二页）。
 *
 * 界面（09-25 截图定稿）：
 *  - 问候语 + 日期 + 搜索 + 今日进度环卡片；
 *  - 主列表按 逾期 / 今日 / 即将 / 无截止 / 已完成 分组（组头带数量，行右缘优先级色条）；
 *  - 新建走右下角 + 全屏页（pages/TodoEdit）；回收站入口在右上角（保留 30 天）；
 *  - **清单筛选**（行首「全部」+ 各清单，点全部显示当天所有待办）+ 标题/描述搜索 +
 *    排序（截止 / 优先级 / 创建时间）；
 *  - 点击任务行进**全屏任务详情页**（pages/TodoEdit 带 taskId）；
 *  - 完成 / 撤销（显示完成时间）；重复任务完成后自动克隆下一条；
 *  - 批量：长按进多选 → 批量完成 / 批量删除（名册同款两排式底栏，等高）；
 *  - 回收站：恢复 / 彻底删除 / 过期自动清理；
 *  - 提醒：应用内到点提醒 + 稍后提醒（5 分钟 / 1 小时 / 明天）。
 *    系统级推送受代理提醒额度管控（1700002，见 docs/04 §12.3.2 上课提醒一节），
 *    待 Calendar Kit 路线确定后再接系统通知。
 *  - 「全部 / 工作」清单顶部展示当天课程（只读课表，按当前指针学期 + 教师）；
 *    课程可左滑标记完成（preferences 按天登记），完成后横线划掉，再滑可撤销。
 */
@ComponentV2
export struct TodoPanel {
  /** 主题色（随「我的」拾色器变化） */
  @Param uiThemeColor: string = '#1890FF';
  /** 全屏新增页返回后的刷新信号（Index.onPageShow 自增，@Monitor 响应） */
  @Param refreshTick: number = 0;
  @Local tasks: TodoTask[] = [];
  @Local trashTasks: TodoTask[] = [];
  @Local viewTab: string = VIEW_ALL;
  /** 清单筛选：空串 = 全部（显示当天所有待办） */
  @Local listFilter: string = '';
  /** 筛选行的清单芯片：预设 + 任务里出现过的 */
  @Local listNames: string[] = PRESET_LISTS.slice();
  @Local searchKey: string = '';
  @Local sortBy: string = SORT_DUE;
  @Local selectMode: boolean = false;
  @Local selectedIds: number[] = [];
  @Local todayLessons: LessonRow[] = [];
  /** 当前指针学期时间表的节次钟点（课程行显示起止时间用） */
  @Local todaySlots: ScheduleSlot[] = [];
  /** 当天已划掉的课程 key（${course_row_id}-${time_period_id}，preferences 按天登记） */
  @Local doneLessonKeys: string[] = [];
  /** 当前指针教师姓名（问候语用；无指针为空串） */
  @Local teacherName: string = '';
  @Local reminderTask: TodoTask | null = null;

  aboutToAppear(): void {
    this.reloadAll();
    this.checkReminders();
  }

  /** 从全屏新增页返回（Index.onPageShow 自增 refreshTick）后重载 */
  @Monitor('refreshTick')
  onRefreshTick(): void {
    this.reloadAll();
    this.checkReminders();
  }

  // ------------------------------------------------------------ 数据加载

  private async reloadAll(): Promise<void> {
    try {
      const purged: number = await TodoRepository.getInstance().purgeExpiredTrash();
      if (purged > 0) {
        Logger.info(TAG, `回收站自动清理 ${purged} 条过期任务`);
      }
      await this.reloadTasks();
    } catch (e) {
      Logger.error(TAG, `待办数据加载失败：${errText(e)}`);
    }
  }

  /** 重载任务清单 + 统计 + 清单芯片 + 课程完成登记（所有写操作之后都走这里） */
  private async reloadTasks(): Promise<void> {
    const repo: TodoRepository = TodoRepository.getInstance();
    this.tasks = await repo.loadTasks();
    if (this.viewTab === VIEW_TRASH) {
      this.trashTasks = await repo.loadTrash();
    }
    // 清单芯片：预设 + 任务里出现过的清单名
    const names: string[] = PRESET_LISTS.slice();
    for (let i = 0; i < this.tasks.length; i++) {
      const name: string = this.tasks[i].list_name;
      if (name.length > 0 && names.indexOf(name) < 0) {
        names.push(name);
      }
    }
    this.listNames = names;
    this.teacherName = await ScheduleRepository.getInstance().loadCurrentTeacherName();
    this.todayLessons = await ScheduleRepository.getInstance().loadTodayLessons();
    this.todaySlots = await ScheduleRepository.getInstance().loadCurrentSlots();
    this.doneLessonKeys = await LessonDoneStore.load(
      getContext(this) as common.Context, DateUtil.startOfDay(new Date()));
  }

  /** 今日口径：截止在今天的任务（含已完成），进度环用 */
  private todayDueTasks(): TodoTask[] {
    const dayStart: number = DateUtil.startOfDay(new Date());
    const dayEnd: number = dayStart + DAY_MS;
    const out: TodoTask[] = [];
    for (let i = 0; i < this.tasks.length; i++) {
      const t: TodoTask = this.tasks[i];
      if (t.due_at !== undefined && t.due_at >= dayStart && t.due_at < dayEnd) {
        out.push(t);
      }
    }
    return out;
  }

  private todayDoneCount(): number {
    const rows: TodoTask[] = this.todayDueTasks();
    let done: number = 0;
    for (let i = 0; i < rows.length; i++) {
      if (rows[i].done) {
        done++;
      }
    }
    return done;
  }

  private todayPercent(): number {
    const total: number = this.todayDueTasks().length;
    if (total === 0) {
      return 0;
    }
    return Math.round(this.todayDoneCount() * 100 / total);
  }

  private greetWord(): string {
    const h: number = new Date().getHours();
    if (h < 11) {
      return '早上好';
    }
    if (h < 18) {
      return '下午好';
    }
    return '晚上好';
  }

  private todayLabel(): string {
    const d: Date = new Date();
    const names: string[] = ['日', '一', '二', '三', '四', '五', '六'];
    return `今天 ${d.getMonth() + 1}月${d.getDate()}日 周${names[d.getDay()]}`;
  }

  // ------------------------------------------------------------ 到点提醒（应用内）

  private async checkReminders(): Promise<void> {
    try {
      const due: TodoTask[] = await TodoRepository.getInstance().collectDueReminders();
      if (due.length > 0) {
        this.reminderTask = due[0];
      }
    } catch (e) {
      Logger.warn(TAG, `待办提醒检查失败：${errText(e)}`);
    }
  }

  private async snoozeReminder(minutes: number): Promise<void> {
    const task: TodoTask | null = this.reminderTask;
    if (task === null) {
      return;
    }
    this.reminderTask = null;
    await TodoRepository.getInstance().snooze(task.id, nowMs() + minutes * MIN_MS);
  }

  // ------------------------------------------------------------ 筛选 / 排序 / 搜索

  private dueSortKey(t: TodoTask): number {
    return t.due_at === undefined ? 9000000000000000 : t.due_at;
  }

  /**
   * 分组取未完成任务：overdue=截止早于今天零点 / today=今天 /
   * upcoming=今天以后 / nodue=未设截止；统一应用 清单/搜索 过滤（清单空 = 全部，
   * 即显示当天所有待办），组内按 sortBy 排序。
   */
  private sectionTasks(kind: string): TodoTask[] {
    const dayStart: number = DateUtil.startOfDay(new Date());
    const dayEnd: number = dayStart + DAY_MS;
    const key: string = this.searchKey.trim();
    const out: TodoTask[] = [];
    for (let i = 0; i < this.tasks.length; i++) {
      const t: TodoTask = this.tasks[i];
      if (t.done) {
        continue;
      }
      if (kind === 'overdue') {
        if (t.due_at === undefined || t.due_at >= dayStart) {
          continue;
        }
      } else if (kind === 'today') {
        if (t.due_at === undefined || t.due_at < dayStart || t.due_at >= dayEnd) {
          continue;
        }
      } else if (kind === 'upcoming') {
        if (t.due_at === undefined || t.due_at < dayEnd) {
          continue;
        }
      } else {
        if (t.due_at !== undefined) {
          continue;
        }
      }
      if (this.listFilter.length > 0 && t.list_name !== this.listFilter) {
        continue;
      }
      if (key.length > 0) {
        const hay: string = `${t.title} ${t.description}`;
        if (hay.indexOf(key) < 0) {
          continue;
        }
      }
      out.push(t);
    }
    if (this.sortBy === SORT_PRIORITY) {
      out.sort((a: TodoTask, b: TodoTask): number =>
        b.priority - a.priority || this.dueSortKey(a) - this.dueSortKey(b));
    } else if (this.sortBy === SORT_CREATED) {
      out.sort((a: TodoTask, b: TodoTask): number => b.created_at - a.created_at);
    } else {
      out.sort((a: TodoTask, b: TodoTask): number => this.dueSortKey(a) - this.dueSortKey(b));
    }
    return out;
  }

  /** 已完成组：同样应用过滤，按完成时间倒序 */
  private doneTasks(): TodoTask[] {
    const key: string = this.searchKey.trim();
    const out: TodoTask[] = [];
    for (let i = 0; i < this.tasks.length; i++) {
      const t: TodoTask = this.tasks[i];
      if (!t.done) {
        continue;
      }
      if (this.listFilter.length > 0 && t.list_name !== this.listFilter) {
        continue;
      }
      if (key.length > 0) {
        const hay: string = `${t.title} ${t.description}`;
        if (hay.indexOf(key) < 0) {
          continue;
        }
      }
      out.push(t);
    }
    out.sort((a: TodoTask, b: TodoTask): number =>
      (b.done_at === undefined ? 0 : b.done_at) - (a.done_at === undefined ? 0 : a.done_at));
    return out;
  }

  /** 当前分组视图下全部行（全选 / 空态判断用） */
  private allListed(): TodoTask[] {
    return this.sectionTasks('overdue').concat(this.sectionTasks('today'))
      .concat(this.sectionTasks('upcoming')).concat(this.sectionTasks('nodue'))
      .concat(this.doneTasks());
  }

  private sortLabel(): string {
    if (this.sortBy === SORT_PRIORITY) {
      return '按优先级';
    }
    if (this.sortBy === SORT_CREATED) {
      return '按创建';
    }
    return '按截止';
  }

  private cycleSort(): void {
    if (this.sortBy === SORT_DUE) {
      this.sortBy = SORT_PRIORITY;
    } else if (this.sortBy === SORT_PRIORITY) {
      this.sortBy = SORT_CREATED;
    } else {
      this.sortBy = SORT_DUE;
    }
  }

  // ------------------------------------------------------------ 操作

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

  /** 新建：进全屏新增页（保存后 router.back，由 refreshTick 驱动重载） */
  private navToCreate(): void {
    router.pushUrl({
      url: 'pages/TodoEdit',
      params: {
        themeColor: this.uiThemeColor
      }
    });
  }

  private async toggleDone(task: TodoTask): Promise<void> {
    try {
      await TodoRepository.getInstance().toggleDone(task);
      await this.reloadTasks();
    } catch (e) {
      this.toast(`更新任务失败：${errText(e)}`);
    }
  }

  private async deleteTasks(ids: number[]): Promise<void> {
    try {
      await TodoRepository.getInstance().softDelete(ids);
      this.exitSelect();
      await this.reloadTasks();
    } catch (e) {
      this.toast(`删除任务失败：${errText(e)}`);
    }
  }

  private async batchDone(): Promise<void> {
    const ids: number[] = this.selectedIds.slice();
    for (let i = 0; i < ids.length; i++) {
      const task: TodoTask | null = this.taskById(ids[i]);
      if (task !== null && !task.done) {
        await this.toggleDone(task);
      }
    }
    this.exitSelect();
  }

  private confirmBatchDelete(): void {
    const count: number = this.selectedIds.length;
    if (count === 0) {
      return;
    }
    AlertDialog.show({
      message: `把选中的 ${count} 条任务移入回收站？回收站保留 30 天，可随时恢复。`,
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => { }
      },
      secondaryButton: {
        value: '移入回收站',
        action: () => {
          this.deleteTasks(this.selectedIds.slice());
        }
      }
    });
  }

  private async restoreTasks(ids: number[]): Promise<void> {
    try {
      await TodoRepository.getInstance().restore(ids);
      await this.reloadTasks();
    } catch (e) {
      this.toast(`恢复任务失败：${errText(e)}`);
    }
  }

  private async hardDeleteTasks(ids: number[]): Promise<void> {
    try {
      await TodoRepository.getInstance().hardDelete(ids);
      await this.reloadTasks();
    } catch (e) {
      this.toast(`彻底删除失败：${errText(e)}`);
    }
  }

  // ------------------------------------------------------------ 多选

  private enterSelect(id: number): void {
    if (this.viewTab === VIEW_TRASH || this.selectMode) {
      return;
    }
    this.selectMode = true;
    this.selectedIds = [id];
  }

  private exitSelect(): void {
    this.selectMode = false;
    this.selectedIds = [];
  }

  private toggleSelect(id: number): void {
    const idx: number = this.selectedIds.indexOf(id);
    if (idx >= 0) {
      const kept: number[] = [];
      for (let i = 0; i < this.selectedIds.length; i++) {
        if (this.selectedIds[i] !== id) {
          kept.push(this.selectedIds[i]);
        }
      }
      this.selectedIds = kept;
      if (kept.length === 0) {
        this.exitSelect();
        return;
      }
    } else {
      this.selectedIds = this.selectedIds.concat([id]);
    }
  }

  private toggleSelectAll(): void {
    const rows: TodoTask[] = this.allListed();
    if (this.selectedIds.length >= rows.length) {
      this.selectedIds = [];
      return;
    }
    const ids: number[] = [];
    for (let i = 0; i < rows.length; i++) {
      ids.push(rows[i].id);
    }
    this.selectedIds = ids;
  }

  private taskById(id: number): TodoTask | null {
    for (let i = 0; i < this.tasks.length; i++) {
      if (this.tasks[i].id === id) {
        return this.tasks[i];
      }
    }
    return null;
  }

  // ------------------------------------------------------------ 详情导航 / 课程完成

  /** 课程展示条件（唯一真源）：「全部」或「工作」清单下都展示当天课程 */
  private lessonsVisible(): boolean {
    return this.listFilter.length === 0 || this.listFilter === '工作';
  }

  /** 点击任务行：进全屏任务详情页（pages/TodoEdit 带 taskId，保存后 refreshTick 驱动重载） */
  private navToDetail(taskId: number): void {
    if (this.selectMode) {
      return;
    }
    router.pushUrl({
      url: 'pages/TodoEdit',
      params: {
        themeColor: this.uiThemeColor,
        taskId: taskId
      }
    });
  }

  /** 课程 key（与列表 ForEach key 同源；同一天内唯一） */
  private lessonDoneKey(lesson: LessonRow): string {
    return `${lesson.course_row_id}-${lesson.time_period_id}`;
  }

  private isLessonDone(lesson: LessonRow): boolean {
    return this.doneLessonKeys.indexOf(this.lessonDoneKey(lesson)) >= 0;
  }

  /** 课程标记完成 / 撤销：更新内存集合并 preferences 按天登记 */
  private async toggleLessonDone(lesson: LessonRow): Promise<void> {
    const key: string = this.lessonDoneKey(lesson);
    const idx: number = this.doneLessonKeys.indexOf(key);
    const next: string[] = this.doneLessonKeys.slice();
    if (idx >= 0) {
      next.splice(idx, 1);
    } else {
      next.push(key);
    }
    this.doneLessonKeys = next;
    await LessonDoneStore.save(getContext(this) as common.Context,
      DateUtil.startOfDay(new Date()), next);
  }

  // ------------------------------------------------------------ 文本工具

  private pad2(n: number): string {
    return n < 10 ? `0${n}` : `${n}`;
  }

  private formatDue(ms: number): string {
    const d: Date = new Date(ms);
    return `${d.getMonth() + 1}月${d.getDate()}日 ${this.pad2(d.getHours())}:${this.pad2(d.getMinutes())}`;
  }

  private formatDay(ms: number): string {
    const d: Date = new Date(ms);
    return `${d.getMonth() + 1}月${d.getDate()}日`;
  }

  // ------------------------------------------------------------ UI

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column() {
        this.headerGreeting()
        if (this.reminderTask !== null) {
          this.reminderBanner()
        }
        if (this.viewTab === VIEW_TRASH) {
          this.trashHeader()
        } else {
          this.searchRow()
          this.progressCard()
          this.filterChips()
        }
        this.taskList()
        if (this.viewTab === VIEW_TRASH || this.selectMode) {
          this.bottomBar()
        }
        // 给浮层底部导航让位（barOverlap：内容铺到导航栏之下）
        Column().height(56)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(PAGE_BG_COLOR)

      if (this.viewTab !== VIEW_TRASH && !this.selectMode) {
        this.fabButton()
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 顶部：问候语 + 日期；右侧排序与回收站入口 */
  @Builder
  headerGreeting() {
    Row({ space: 8 }) {
      Column({ space: 4 }) {
        Text(this.greetWord() + (this.teacherName.length > 0 ? `，${this.teacherName}` : ''))
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor('#111827')
          .maxLines(1)
        Text(this.todayLabel())
          .fontSize(13)
          .fontColor('#6B7280')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text(this.sortLabel())
        .fontSize(12)
        .fontColor(this.uiThemeColor)
        .padding({ left: 8, right: 8, top: 6, bottom: 6 })
        .borderRadius(14)
        .backgroundColor('#FFFFFF')
        .onClick(() => this.cycleSort())
      Text('回收站')
        .fontSize(12)
        .fontColor('#6B7280')
        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .borderRadius(14)
        .backgroundColor('#FFFFFF')
        .onClick(() => {
          this.viewTab = VIEW_TRASH;
          this.exitSelect();
          this.loadTrash();
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
  }

  /** 搜索条：标题 / 描述 */
  @Builder
  searchRow() {
    TextInput({ placeholder: '搜索任务…', text: this.searchKey })
      .fontSize(13)
      .height(40)
      .width('100%')
      .backgroundColor('#E9EDF2')
      .borderRadius(12)
      .padding({ left: 12, right: 12 })
      .margin({ left: 16, right: 16, bottom: 10 })
      .onChange((value: string) => {
        this.searchKey = value;
      })
  }

  /** 今日进度卡片：圆环 + X/Y + 说明 */
  @Builder
  progressCard() {
    Row({ space: 12 }) {
      Stack() {
        Progress({ value: this.todayPercent(), total: 100, type: ProgressType.Ring })
          .width(52)
          .height(52)
          .color(this.uiThemeColor)
          .backgroundColor('#E5E7EB')
          .style({ strokeWidth: 6 })
        Text(`${this.todayPercent()}%`)
          .fontSize(10)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.uiThemeColor)
      }
      Column({ space: 3 }) {
        Text(this.todayDueTasks().length > 0
          ? `今日进度 ${this.todayDoneCount()}/${this.todayDueTasks().length}`
          : '今天没有安排任务')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#111827')
        Text(this.todayDueTasks().length > 0
          ? `已完成 ${this.todayDoneCount()} 项，还有 ${this.todayDueTasks().length - this.todayDoneCount()} 项待处理`
          : '点右下角 + 新建一个任务吧')
          .fontSize(12)
          .fontColor('#6B7280')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding(14)
    .margin({ left: 16, right: 16, bottom: 10 })
    .backgroundColor('#FFFFFF')
    .borderRadius(14)
  }

  /** 右下角悬浮新建按钮：进全屏新增页 */
  @Builder
  fabButton() {
    Button('+')
      .fontSize(26)
      .width(56)
      .height(56)
      .type(ButtonType.Circle)
      .backgroundColor(this.uiThemeColor)
      .fontColor('#FFFFFF')
      .shadow({ radius: 8, color: '#1F293733', offsetY: 2 })
      .margin({ right: 20, bottom: 110 })
      .onClick(() => this.navToCreate())
  }

  /** 到点提醒横幅（应用内提醒；系统推送受代理提醒额度管控，暂不接） */
  @Builder
  reminderBanner() {
    Row({ space: 8 }) {
      Text('⏰')
        .fontSize(16)
      Column({ space: 2 }) {
        Text(this.reminderTask === null ? '' : this.reminderTask.title)
          .fontSize(13)
          .fontColor('#FFFFFF')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.reminderTask !== null && this.reminderTask.remind_at !== undefined
          ? `到点提醒 · ${this.formatDue(this.reminderTask.remind_at as number)}`
          : '到点提醒')
          .fontSize(11)
          .fontColor('#FDE2E2')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Text('稍后 5 分钟')
        .fontSize(12)
        .fontColor('#FFFFFF')
        .padding(6)
        .borderRadius(8)
        .backgroundColor('#334155')
        .onClick(() => this.snoozeReminder(5))
      Text('知道了')
        .fontSize(12)
        .fontColor('#1F2937')
        .padding(6)
        .borderRadius(8)
        .backgroundColor('#FFFFFF')
        .onClick(() => {
          this.reminderTask = null;
        })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .backgroundColor('#EF4444')
    .borderRadius(10)
    .margin({ left: 16, right: 16, bottom: 8 })
  }

  /** 回收站视图头部：返回 + 说明 */
  @Builder
  trashHeader() {
    Row({ space: 8 }) {
      Text('← 返回')
        .fontSize(14)
        .fontColor(this.uiThemeColor)
        .padding({ left: 4, right: 4, top: 6, bottom: 6 })
        .onClick(() => {
          this.viewTab = VIEW_ALL;
        })
      Text('回收站：删除的任务保留 30 天')
        .fontSize(12)
        .fontColor('#9CA3AF')
      Blank()
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 6 })
  }

  /** 清单筛选行（回收站视图不显示）：行首「全部」+ 各清单；全部 = 显示当天所有待办 */
  @Builder
  filterChips() {
    if (this.viewTab !== VIEW_TRASH) {
      Row({ space: 6 }) {
        Text('全部')
          .fontSize(11)
          .fontColor(this.listFilter.length === 0 ? '#FFFFFF' : '#6B7280')
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .borderRadius(12)
          .border({ width: 1, color: this.listFilter.length === 0 ? this.uiThemeColor : '#E5E7EB' })
          .backgroundColor(this.listFilter.length === 0 ? this.uiThemeColor : '#FFFFFF')
          .onClick(() => {
            this.listFilter = '';
          })
        ForEach(this.listNames, (name: string) => {
          Text(name)
            .fontSize(11)
            .fontColor(this.listFilter === name ? '#FFFFFF' : '#6B7280')
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .borderRadius(12)
            .border({ width: 1, color: this.listFilter === name ? this.uiThemeColor : '#E5E7EB' })
            .backgroundColor(this.listFilter === name ? this.uiThemeColor : '#FFFFFF')
            .onClick(() => {
              this.listFilter = this.listFilter === name ? '' : name;
            })
        }, (name: string) => `list-${name}-${this.listFilter === name}`)
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 6 })
    }
  }

  @Builder
  taskList() {
    List({ space: 8 }) {
      if (this.viewTab === VIEW_TRASH) {
        if (this.trashTasks.length === 0) {
          ListItem() {
            Text('回收站是空的：删除的任务会在这里保留 30 天')
              .fontSize(12)
              .fontColor('#9CA3AF')
              .width('100%')
              .padding(20)
              .textAlign(TextAlign.Center)
          }
        }
        ForEach(this.trashTasks, (task: TodoTask) => {
          ListItem() {
            this.trashRow(task.id)
          }
          .swipeAction({ end: this.trashSwipeActions(task.id) })
        }, (task: TodoTask) => `trash-${task.id}-${task.deleted_at === undefined ? 0 : task.deleted_at}`)
      } else {
        // 「全部 / 工作」清单：顶部展示当天课程（只读课表，可左滑标记完成）
        if (this.lessonsVisible()) {
          ForEach(this.todayLessons, (lesson: LessonRow) => {
            ListItem() {
              this.lessonCard(lesson)
            }
            .swipeAction({ end: this.lessonSwipeActions(lesson) })
          }, (lesson: LessonRow) => `lesson-${lesson.course_row_id}-${lesson.time_period_id}`)
          if (this.todayLessons.length === 0) {
            ListItem() {
              Text('今天没有课程安排')
                .fontSize(11)
                .fontColor('#9CA3AF')
                .width('100%')
                .padding({ top: 6, bottom: 6 })
                .textAlign(TextAlign.Center)
            }
          }
        }
        this.sectionBlock('逾期', 'overdue')
        this.sectionBlock('今日', 'today')
        this.sectionBlock('即将', 'upcoming')
        this.sectionBlock('无截止', 'nodue')
        if (this.doneTasks().length > 0) {
          ListItem() {
            this.sectionHeader('已完成', this.doneTasks().length)
          }
          ForEach(this.doneTasks(), (task: TodoTask) => {
            ListItem() {
              if (this.selectMode) {
                this.selectRow(task.id)
              } else {
                this.taskRow(task.id)
              }
            }
            .swipeAction({ end: this.taskSwipeDelete(task.id) })
          }, (task: TodoTask) =>
            `task-${task.id}-${task.title}-${task.done}-${task.priority}`
            + `-${task.due_at === undefined ? 0 : task.due_at}-${task.subtasks.length}`
            + `-${this.selectMode}-${this.selectedIds.indexOf(task.id) >= 0}`)
        }
      }
      if (this.viewTab !== VIEW_TRASH && this.allListed().length === 0
        && !(this.lessonsVisible() && this.todayLessons.length > 0)) {
        ListItem() {
          Text('这里还没有任务：点右下角 + 新建一个')
            .fontSize(12)
            .fontColor('#9CA3AF')
            .width('100%')
            .padding(20)
            .textAlign(TextAlign.Center)
        }
      }
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .padding({ left: 16, right: 16 })
  }

  /** 当天课程卡（「工作」清单顶部，只读；左侧竖色条 = 课表卡片同款课程颜色；左滑可标记完成） */
  @Builder
  lessonCard(lesson: LessonRow) {
    Row({ space: 10 }) {
      Column()
        .width(4)
        .borderRadius(2)
        .backgroundColor(lesson.color)
        .alignSelf(ItemAlign.Stretch)
      Column({ space: 2 }) {
        Text(lesson.course_name)
          .fontSize(14)
          .fontColor(this.isLessonDone(lesson) ? '#9CA3AF' : '#111827')
          .fontWeight(FontWeight.Medium)
          .decoration({
            type: this.isLessonDone(lesson) ? TextDecorationType.LineThrough : TextDecorationType.None
          })
        Text(`${lesson.class_name}${lesson.class_room.length > 0 ? ` · ${lesson.class_room}` : ''}`)
          .fontSize(11)
          .fontColor(this.isLessonDone(lesson) ? '#C4C9D0' : '#9CA3AF')
          .decoration({
            type: this.isLessonDone(lesson) ? TextDecorationType.LineThrough : TextDecorationType.None
          })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Column({ space: 1 }) {
        Text(this.lessonPeriodText(lesson))
          .fontSize(12)
          .fontColor(this.uiThemeColor)
        if (this.lessonClockText(lesson).length > 0) {
          Text(this.lessonClockText(lesson))
            .fontSize(10)
            .fontColor('#9CA3AF')
        }
      }
      .alignItems(HorizontalAlign.End)
      Text(this.isLessonDone(lesson) ? '已完成' : '课程')
        .fontSize(10)
        .fontColor('#FFFFFF')
        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
        .borderRadius(4)
        .backgroundColor(this.isLessonDone(lesson) ? '#9CA3AF' : this.uiThemeColor)
    }
    .width('100%')
    .padding({ left: 8, right: 10, top: 10, bottom: 10 })
    .backgroundColor('#FFFFFF')
    .borderRadius(10)
    .border({ width: 1, color: '#E5E7EB' })
    .opacity(this.isLessonDone(lesson) ? 0.75 : 1)
  }

  /** 课程左滑：标记完成 / 撤销（完成态横线划掉，preferences 按天登记） */
  @Builder
  lessonSwipeActions(lesson: LessonRow) {
    Row() {
      Text(this.isLessonDone(lesson) ? '撤销' : '完成')
        .fontSize(14)
        .fontColor('#FFFFFF')
        .width(60)
        .height('100%')
        .textAlign(TextAlign.Center)
        .backgroundColor(this.isLessonDone(lesson) ? '#9CA3AF' : '#16A34A')
        .borderRadius(8)
        .onClick(() => this.toggleLessonDone(lesson))
    }
    .height('100%')
  }

  /** 完整节次：第1节 / 第1-2节（跨节连堂显示区间） */
  private lessonPeriodText(lesson: LessonRow): string {
    if (lesson.end_time > lesson.start_time) {
      return `第${lesson.start_time}-${lesson.end_time}节`;
    }
    return `第${lesson.start_time}节`;
  }

  /** 起止钟点（查当前指针学期时间表）；查不到节次返回空串 */
  private lessonClockText(lesson: LessonRow): string {
    const from: ScheduleSlot | null = this.slotOfNo(lesson.start_time);
    const to: ScheduleSlot | null = this.slotOfNo(lesson.end_time);
    if (from === null || to === null || from.start_time.length === 0 || to.end_time.length === 0) {
      return '';
    }
    return `${from.start_time}-${to.end_time}`;
  }

  private slotOfNo(sessionNo: number): ScheduleSlot | null {
    for (let i = 0; i < this.todaySlots.length; i++) {
      if (this.todaySlots[i].session_no === sessionNo) {
        return this.todaySlots[i];
      }
    }
    return null;
  }

  /** 分组区块：组头（名称 + 数量）+ 组内任务行 */
  @Builder
  sectionBlock(label: string, kind: string) {
    if (this.sectionTasks(kind).length > 0) {
      ListItem() {
        this.sectionHeader(label, this.sectionTasks(kind).length)
      }
      ForEach(this.sectionTasks(kind), (task: TodoTask) => {
        ListItem() {
          if (this.selectMode) {
            this.selectRow(task.id)
          } else {
            this.taskRow(task.id)
          }
        }
        .swipeAction({ end: this.taskSwipeDelete(task.id) })
      }, (task: TodoTask) =>
        `task-${task.id}-${task.title}-${task.done}-${task.priority}`
        + `-${task.due_at === undefined ? 0 : task.due_at}-${task.subtasks.length}`
        + `-${this.selectMode}-${this.selectedIds.indexOf(task.id) >= 0}`)
    }
  }

  /** 组头：左侧组名，右侧数量 */
  @Builder
  sectionHeader(label: string, count: number) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor('#6B7280')
      Blank()
      Text(`${count}`)
        .fontSize(13)
        .fontColor('#6B7280')
    }
    .width('100%')
    .padding({ top: 4, bottom: 2, left: 4, right: 4 })
  }

  /** 任务行：勾选框 + 信息 + 徽标；点击进全屏任务详情页，长按进多选 */
  @Builder
  taskRow(taskId: number) {
    Row({ space: 10 }) {
      Text(this.doneMark(taskId))
        .fontSize(13)
        .fontColor('#FFFFFF')
        .textAlign(TextAlign.Center)
        .width(22)
        .height(22)
        .borderRadius(11)
        .backgroundColor(this.isDone(taskId) ? this.uiThemeColor : '#FFFFFF')
        .border({ width: 1, color: this.isDone(taskId) ? this.uiThemeColor : '#D1D5DB' })
        .onClick(() => {
          const task: TodoTask | null = this.taskById(taskId);
          if (task !== null) {
            this.toggleDone(task);
          }
        })
      Column({ space: 3 }) {
        Text(this.titleOf(taskId))
          .fontSize(15)
          .fontColor(this.isDone(taskId) ? '#9CA3AF' : '#111827')
          .decoration({ type: this.isDone(taskId) ? TextDecorationType.LineThrough : TextDecorationType.None })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.descOf(taskId).length > 0) {
          Text(this.descOf(taskId))
            .fontSize(11)
            .fontColor('#9CA3AF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        Row({ space: 6 }) {
          if (this.dueText(taskId).length > 0) {
            Text(this.dueText(taskId))
              .fontSize(10)
              .fontColor(this.isOverdue(taskId) ? '#EF4444' : '#6B7280')
          }
          Text(PriorityStyle.label(this.priorityOf(taskId)))
            .fontSize(10)
            .fontColor('#FFFFFF')
            .padding({ left: 5, right: 5, top: 1, bottom: 1 })
            .borderRadius(4)
            .backgroundColor(PriorityStyle.color(this.priorityOf(taskId)))
          Text(this.listOf(taskId))
            .fontSize(10)
            .fontColor('#6B7280')
            .padding({ left: 5, right: 5, top: 1, bottom: 1 })
            .borderRadius(4)
            .backgroundColor('#F3F4F6')
          if (this.repeatOf(taskId) !== 'none') {
            Text(repeatLabel(this.repeatOf(taskId)))
              .fontSize(10)
              .fontColor('#6B7280')
          }
          if (this.subProgress(taskId).length > 0) {
            Text(`子任务 ${this.subProgress(taskId)}`)
              .fontSize(10)
              .fontColor('#6B7280')
          }
          if (this.isDone(taskId) && this.doneAtOf(taskId) !== undefined) {
            Text(`完成于 ${this.formatDue(this.doneAtOf(taskId) as number)}`)
              .fontSize(10)
              .fontColor('#9CA3AF')
          }
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .onClick(() => {
        if (!this.selectMode) {
          this.navToDetail(taskId);
        }
      })
      // 右缘优先级色条（高=红 中=橙 低=蓝 无=灰）
      Text('')
        .width(4)
        .height(34)
        .borderRadius(2)
        .backgroundColor(PriorityStyle.color(this.priorityOf(taskId)))
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#FFFFFF')
    .borderRadius(10)
    .gesture(LongPressGesture({ repeat: false, duration: 350 })
      .onAction(() => this.enterSelect(taskId)))
  }

  /** 多选态行：整行点按 = 切换选中 */
  @Builder
  selectRow(taskId: number) {
    Row({ space: 10 }) {
      Text(this.selectedIds.indexOf(taskId) >= 0 ? '✓' : '')
        .fontSize(13)
        .fontColor('#FFFFFF')
        .textAlign(TextAlign.Center)
        .width(22)
        .height(22)
        .borderRadius(11)
        .backgroundColor(this.selectedIds.indexOf(taskId) >= 0 ? this.uiThemeColor : '#FFFFFF')
        .border({ width: 1, color: this.selectedIds.indexOf(taskId) >= 0 ? this.uiThemeColor : '#D1D5DB' })
      Column({ space: 2 }) {
        Text(this.titleOf(taskId))
          .fontSize(15)
          .fontColor('#111827')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.listOf(taskId))
          .fontSize(11)
          .fontColor('#9CA3AF')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding(12)
    .backgroundColor(this.selectedIds.indexOf(taskId) >= 0 ? '#EFF6FF' : '#FFFFFF')
    .borderRadius(10)
    .onClick(() => this.toggleSelect(taskId))
    .gesture(LongPressGesture({ repeat: false, duration: 350 })
      .onAction(() => this.toggleSelect(taskId)))
  }

  /** 回收站行：显示删除日期；左滑恢复 / 彻底删除 */
  @Builder
  trashRow(taskId: number) {
    Row({ space: 10 }) {
      Column({ space: 2 }) {
        Text(this.titleOf(taskId))
          .fontSize(15)
          .fontColor('#111827')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`删除于 ${this.trashDeletedText(taskId)} · 30 天后自动清理`)
          .fontSize(11)
          .fontColor('#9CA3AF')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#FFFFFF')
    .borderRadius(10)
  }

  @Builder
  trashSwipeActions(taskId: number) {
    Row({ space: 6 }) {
      Text('恢复')
        .fontSize(14)
        .fontColor('#FFFFFF')
        .width(60)
        .height('100%')
        .textAlign(TextAlign.Center)
        .backgroundColor('#16A34A')
        .borderRadius(8)
        .onClick(() => this.restoreTasks([taskId]))
      Text('彻底删除')
        .fontSize(13)
        .fontColor('#FFFFFF')
        .width(76)
        .height('100%')
        .textAlign(TextAlign.Center)
        .backgroundColor('#EF4444')
        .borderRadius(8)
        .onClick(() => this.hardDeleteTasks([taskId]))
    }
    .height('100%')
  }

  /** 任务行左滑：移入回收站（软删） */
  @Builder
  taskSwipeDelete(taskId: number) {
    Row() {
      Text('删除')
        .fontSize(14)
        .fontColor('#FFFFFF')
        .width(60)
        .height('100%')
        .textAlign(TextAlign.Center)
        .backgroundColor('#EF4444')
        .borderRadius(8)
        .onClick(() => {
          if (this.selectMode) {
            return;
          }
          this.deleteTasks([taskId]);
        })
    }
    .height('100%')
  }

  /** 底部操作条：普通 = 统计 + 新建；多选 = 名册同款两排式（等高） */
  @Builder
  bottomBar() {
    if (this.viewTab === VIEW_TRASH) {
      Row() {
        Text('回收站保留 30 天，左滑可恢复或彻底删除')
          .fontSize(11)
          .fontColor('#9CA3AF')
        Blank()
      }
      .width('100%')
      .height(44)
      .padding({ left: 16, right: 16 })
    } else if (this.selectMode) {
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          Text('取消')
            .fontSize(14)
            .fontColor('#6B7280')
            .padding({ left: 4, right: 4, top: 6, bottom: 6 })
            .onClick(() => this.exitSelect())
          Text(`已选 ${this.selectedIds.length} 条`)
            .fontSize(14)
            .fontColor('#111827')
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
          Text(this.selectedIds.length >= this.allListed().length ? '取消全选' : '全选')
            .fontSize(14)
            .fontColor(this.uiThemeColor)
            .padding({ left: 4, right: 4, top: 6, bottom: 6 })
            .onClick(() => this.toggleSelectAll())
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 11, bottom: 11 })
        .backgroundColor('#F9FAFB')
        .borderRadius(10)

        Row({ space: 8 }) {
          Button('批量完成')
            .fontSize(14)
            .height(44)
            .layoutWeight(1)
            .backgroundColor('#16A34A')
            .enabled(this.selectedIds.length > 0)
            .onClick(() => this.batchDone())
          Button('移入回收站')
            .fontSize(14)
            .height(44)
            .layoutWeight(1)
            .backgroundColor('#EF4444')
            .fontColor('#FFFFFF')
            .enabled(this.selectedIds.length > 0)
            .onClick(() => this.confirmBatchDelete())
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 6 })
    }
  }

  // ------------------------------------------------------------ 行内取值（避免 @Builder 按值传参不观察）

  private isDone(taskId: number): boolean {
    const t: TodoTask | null = this.taskById(taskId);
    return t !== null && t.done;
  }

  private doneMark(taskId: number): string {
    return this.isDone(taskId) ? '✓' : '';
  }

  private titleOf(taskId: number): string {
    const t: TodoTask | null = this.taskById(taskId);
    return t === null ? '' : t.title;
  }

  private descOf(taskId: number): string {
    const t: TodoTask | null = this.taskById(taskId);
    return t === null ? '' : t.description;
  }

  private priorityOf(taskId: number): number {
    const t: TodoTask | null = this.taskById(taskId);
    return t === null ? PRIORITY_NONE : t.priority;
  }

  private listOf(taskId: number): string {
    const t: TodoTask | null = this.taskById(taskId);
    return t === null ? '' : t.list_name;
  }

  private repeatOf(taskId: number): string {
    const t: TodoTask | null = this.taskById(taskId);
    return t === null ? 'none' : t.repeat_rule;
  }

  private doneAtOf(taskId: number): number | undefined {
    const t: TodoTask | null = this.taskById(taskId);
    return t === null ? undefined : t.done_at;
  }

  private subProgress(taskId: number): string {
    const t: TodoTask | null = this.taskById(taskId);
    return t === null ? '' : t.subtaskProgress();
  }

  private isOverdue(taskId: number): boolean {
    const t: TodoTask | null = this.taskById(taskId);
    return t !== null && !t.done && t.due_at !== undefined && t.due_at < nowMs();
  }

  private dueText(taskId: number): string {
    const t: TodoTask | null = this.taskById(taskId);
    if (t === null || t.due_at === undefined) {
      return '';
    }
    return `截止 ${this.formatDue(t.due_at)}`;
  }

  private trashDeletedText(taskId: number): string {
    const t: TodoTask | null = this.taskById(taskId);
    if (t === null || t.deleted_at === undefined) {
      return '—';
    }
    return this.formatDay(t.deleted_at);
  }

  private async loadTrash(): Promise<void> {
    try {
      this.trashTasks = await TodoRepository.getInstance().loadTrash();
    } catch (e) {
      Logger.warn(TAG, `回收站加载失败：${errText(e)}`);
    }
  }
}
