import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { ScheduleRepository } from '../repository/ScheduleRepository';
import { ScheduleTemplate, ScheduleSlot } from '../model/ScheduleTemplate';
import { DateUtil } from '../common/DateUtil';
import { clamp, errText, colorOr, THEME_COLOR_DEFAULT, PAGE_BG_COLOR } from '../common/Util';
import { Logger } from '../common/Logger';
import { WidgetLaunch } from '../widget/WidgetLaunch';

const TAG: string = 'TemplateEditPage';

/** 布局常量 */
interface LAYOUT_Interface {
  headerHeight: number;
  inputHeight: number;
  cardRadius: number;
  slotRowHeight: number;
}

const LAYOUT: LAYOUT_Interface = {
  headerHeight: 56,
  inputHeight: 46,
  cardRadius: 12,
  slotRowHeight: 42
};

/** 每天节数上限：一节课都没排完的一天是不存在的，24 节足够覆盖早八到晚自习 */
const MAX_SESSIONS: number = 24;
const MIN_SESSIONS: number = 1;
/** 每节时长（分钟）的合法区间 */
const MIN_DURATION: number = 1;
const MAX_DURATION: number = 300;

/**
 * 时间表全屏编辑页。
 *
 * 与旧版（管理 sheet 里的一个子视图）的区别：
 *  1. **全屏**：sheet 只有半屏高，12~24 个节次要滚很久；这里用独立页面，节次列表一屏放得下。
 *  2. **改名**：名称直接改，不再需要"另存为一张新表"。
 *  3. **手动保存**：编辑过程中只改内存里的草稿，不写库；点右上角「完成」才落库。
 *     系统返回 / 点「‹」时若还有未保存的改动，会弹窗确认是否放弃。
 *
 * 时间模型：用户只维护「开始时间 + 时长」，结束时间一律由 `applyDuration` / `setSlotStart`
 * 推导，因此永远不会出现"开始 08:00、结束 07:30"这种自相矛盾的节次。
 */
@Entry
@ComponentV2
struct TemplateEdit {
  @Local busy: boolean = true;
  @Local ready: boolean = false;
  @Local message: string = '';
  @Local templateId: number = 0;
  /** 正在编辑的时间表（直接就是活的模型对象，改动后连同 slots 一起落库） */
  @Local draft: ScheduleTemplate = new ScheduleTemplate();
  /** 名称输入框镜像：避免 TextInput 与模型互相回写导致光标跳动 */
  @Local nameText: string = '';
  /** 时长输入框镜像（可能是非法中间态，如空串、"4"） */
  @Local durationText: string = '45';
  /** 界面强调色（跟「我的 → 界面设置」里的主题色保持一致） */
  @Local themeColor: string = THEME_COLOR_DEFAULT;
  /** 保存结果提示：空串 = 无需提示 */
  @Local saveHint: string = '';
  /** 有未保存的改动（编辑只改内存草稿，点「完成」才落库） */
  @Local dirty: boolean = false;
  /**
   * 载入完成时的内容快照：脏标记一律用「当前内容 ≠ 基线」判定，
   * **不用"回调被触发过"判定**。
   *
   * 原因：受控输入框 `TextInput({ text: this.nameText })` 在 `loadTemplate()` 把 ''
   * 写成真实值时会触发一次 `onChange` —— 那不是用户输入。若按"回调触发过就算脏"，
   * 页面一打开就是脏的（页头直接写「有未保存的修改」，退出还弹「放弃修改？」）。
   * 快照比较顺带覆盖了"改了又改回原样" = 其实没有改动的情况。
   */
  private baseline: string = '';

  /** 同一时刻只允许一次写库，避免连点造成并发事务（完成按钮会显示"保存中…"） */
  @Local saving: boolean = false;

  // ---- 开始时间选择（自建底部弹层）----
  /**
   * 为什么不用系统的 `TimePickerDialog`：它的顶部标题是固定布局，会显示当天日期
   * （"2026年9月20日 周日"），官方 FAQ 明确说明暂不支持隐藏标题日期。
   * 于是这里用 bindSheet + `TimePicker` 组件自建弹层 —— 组件本身只有"时""分"两列。
   */
  @Local showTimeSheet: boolean = false;
  /** 正在选开始时间的节次号（0 = 未在选） */
  @Local editingSlotNo: number = 0;
  @Local pickHour: number = 0;
  @Local pickMinute: number = 0;

  aboutToAppear(): void {
    this.loadTemplate();
  }

  /**
   * 卡片点课要求"回课表看这节课"，而本页是全屏页、会挡住首页的定位逻辑。
   *
   * 没有未保存改动时直接退回，让首页 `onPageShow` 接手；
   * 有改动则留在本页（用户的编辑优先，请求会在 2 分钟后自动过期）。
   */
  onPageShow(): void {
    if (WidgetLaunch.hasPending() && !this.dirty) {
      router.back();
    }
  }

  onBackPress(): boolean {
    // 系统返回手势：有未保存改动先弹确认；返回 true 表示已消费本次返回
    if (this.dirty) {
      this.confirmDiscard();
      return true;
    }
    return false;
  }

  private context(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }

  // ---------------------------------------------------------------- 加载

  private async loadTemplate(): Promise<void> {
    const params: Record<string, Object> | undefined = router.getParams() as Record<string, Object>;
    if (params === undefined || params['templateId'] === undefined) {
      this.message = '参数异常：未指定时间表';
      this.busy = false;
      return;
    }
    this.templateId = parseInt('' + params['templateId']);
    if (this.templateId <= 0) {
      this.message = '参数异常：未指定时间表';
      this.busy = false;
      return;
    }
    // 强调色由调用方带过来（Index 已经读好了设置），省一次 workspace 查询
    const themeParam: string = params['themeColor'] === undefined ? '' : `${params['themeColor']}`;
    this.themeColor = colorOr(themeParam, THEME_COLOR_DEFAULT);

    try {
      const repo: ScheduleRepository = ScheduleRepository.getInstance();
      await repo.init(this.context());
      const template: ScheduleTemplate | undefined = await repo.loadTemplate(this.templateId);
      if (template === undefined) {
        this.message = '时间表不存在，可能已被删除';
        this.busy = false;
        return;
      }
      this.draft = template;
      this.nameText = template.name;
      this.durationText = `${template.duration_time}`;
      this.ready = true;
      // 基线必须在 ready 置位后、且在所有回填之后取：受控输入框因回填触发的那次
      // onChange 会在这之后到达，届时 snapshot() 已等于基线 → 不会误标脏。
      this.baseline = this.snapshot();
      this.dirty = false;
    } catch (e) {
      this.message = `加载失败：${errText(e)}`;
      Logger.error(TAG, this.message);
    }
    this.busy = false;
  }

  // ---------------------------------------------------------------- 编辑动作

  /** 名称变化：只更新镜像 + 重算脏标记（空名交给保存时兜底成"未命名时间表"） */
  private onNameChange(value: string): void {
    this.nameText = value;
    this.recomputeDirty();
  }

  /**
   * 每节时长变化。
   *
   * 解析失败（空串 / 只敲了个"-"）时只更新输入框，不动模型、也不改动脏标记——
   * 否则中途会把 45 分钟改成 1 分钟，把整张表的时间轴搅乱。
   */
  private onDurationChange(value: string): void {
    this.durationText = value;
    const minutes: number = parseInt(value.trim());
    if (isNaN(minutes) || minutes < MIN_DURATION || minutes > MAX_DURATION) {
      return;
    }
    this.draft.applyDuration(minutes);
    this.recomputeDirty();
  }

  /** 每天节数：增节按"上一节结束 +10 分钟课间"顺延，减节直接截断 */
  private onSessionCountChange(count: number): void {
    const target: number = clamp(Math.round(count), MIN_SESSIONS, MAX_SESSIONS);
    if (target === this.draft.slots.length) {
      return;
    }
    this.draft.ensureSessionCount(target);
    this.recomputeDirty();
  }

  /** 点某节的开始时间 → 弹出只有时、分的自建时间选择层；确定后结束时间 = 开始 + 时长 */
  private pickSlotStart(index: number): void {
    const slots: ScheduleSlot[] = this.draft.slots;
    if (index < 0 || index >= slots.length) {
      return;
    }
    const slot: ScheduleSlot = slots[index];
    const startMinutes: number = clamp(DateUtil.hmToMinutes(slot.start_time), 0, 23 * 60 + 59);
    this.editingSlotNo = slot.session_no;
    this.pickHour = Math.floor(startMinutes / 60);
    this.pickMinute = startMinutes % 60;
    this.showTimeSheet = true;
  }

  /** 取消选择：丢弃本次滚动结果，不改模型 */
  private cancelSlotStart(): void {
    this.showTimeSheet = false;
  }

  /** 确认选择：写回该节开始时间（结束时间由模型推导），只标脏不落库 */
  private confirmSlotStart(): void {
    if (this.editingSlotNo <= 0) {
      this.showTimeSheet = false;
      return;
    }
    const minutes: number = clamp(this.pickHour * 60 + this.pickMinute, 0, 23 * 60 + 59);
    this.draft.setSlotStart(this.editingSlotNo, DateUtil.hmFromMinutes(minutes));
    this.recomputeDirty();
    this.showTimeSheet = false;
  }

  /**
   * 当前内容快照：按"保存后真正会写进库的值"拼。
   *
   * 用 `this.draft.duration_time`（只在解析成功时才更新）而不是 `durationText`
   * （可能是空串 / "4" 这类非法中间态）—— 非法中间态本来就不会被保存，
   * 不该让页头变成"有未保存的修改"。
   */
  private snapshot(): string {
    const name: string = this.nameText.trim();
    const parts: string[] = [
      name.length > 0 ? name : '未命名时间表',
      `${this.draft.duration_time}`,
      `${this.draft.slots.length}`
    ];
    for (let i = 0; i < this.draft.slots.length; i++) {
      const slot: ScheduleSlot = this.draft.slots[i];
      parts.push(`${slot.session_no}@${slot.start_time}-${slot.end_time}`);
    }
    return parts.join('|');
  }

  /**
   * 重算"有未保存的改动"。
   *
   * 每个编辑动作末尾调用；判据是**内容与基线不一致**，不是"回调被触发过"。
   * 这样：① 打开页面（异步回填触发的那次 onChange）不会误标脏；
   * ② 改了又改回原样 → 自动回到干净状态，退出不再弹确认框。
   */
  private recomputeDirty(): void {
    if (!this.ready) {
      return;
    }
    const changed: boolean = this.snapshot() !== this.baseline;
    if (changed === this.dirty) {
      return;
    }
    this.dirty = changed;
    if (changed) {
      this.saveHint = '';
    }
  }

  /** 返回但未保存 → 弹窗确认是否放弃改动 */
  private confirmDiscard(): void {
    AlertDialog.show({
      title: '放弃修改？',
      message: '当前改动尚未保存，退出后将丢失。',
      primaryButton: {
        value: '继续编辑',
        action: () => {
        }
      },
      secondaryButton: {
        value: '放弃修改',
        fontColor: '#DC2626',
        action: () => {
          this.dirty = false;
          router.back();
        }
      },
      cancel: () => {
      }
    });
  }

  // ---------------------------------------------------------------- 保存

  /** 点「完成」：有改动才落库，成功后出栈 */
  private async saveAndBack(): Promise<void> {
    if (this.saving) {
      return;
    }
    if (!this.dirty) {
      router.back();
      return;
    }
    this.saving = true;
    this.saveHint = '保存中…';
    try {
      const name: string = this.nameText.trim();
      this.draft.name = name.length > 0 ? name : '未命名时间表';
      this.draft.class_sessions = this.draft.slots.length;
      await ScheduleRepository.getInstance().saveTemplate(this.draft);
      this.dirty = false;
      this.saveHint = `已保存 ${this.clockText()}`;
      router.back();
    } catch (e) {
      this.saveHint = `保存失败：${errText(e)}`;
      Logger.error(TAG, this.saveHint);
    }
    this.saving = false;
  }

  private clockText(): string {
    const now: Date = new Date();
    const hh: string = now.getHours() < 10 ? `0${now.getHours()}` : `${now.getHours()}`;
    const mm: string = now.getMinutes() < 10 ? `0${now.getMinutes()}` : `${now.getMinutes()}`;
    const ss: string = now.getSeconds() < 10 ? `0${now.getSeconds()}` : `${now.getSeconds()}`;
    return `${hh}:${mm}:${ss}`;
  }

  /** 节次总数快照：渲染时直接读，避免表达式里重复取 length */
  private slotCount(): number {
    return this.draft.slots.length;
  }

  // ---------------------------------------------------------------- Builder

  @Builder
  header() {
    Row() {
      Row() {
        Text('‹')
          .fontSize(28)
          .fontColor('#111827')
          .onClick(() => {
            this.backOrDiscard();
          })
      }
      .width(44)
      .height(LAYOUT.headerHeight)
      .justifyContent(FlexAlign.Center)

      Column({ space: 1 }) {
        Text('编辑时间表')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor('#111827')
        Text(this.saveHint.length > 0 ? this.saveHint
          : (this.dirty ? '有未保存的修改' : '点「完成」保存修改'))
          .fontSize(10)
          .fontColor(this.saveHint.startsWith('保存失败') ? '#DC2626' : (this.dirty ? '#D97706' : '#9CA3AF'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Row() {
        Text(this.saving ? '保存中…' : '完成')
          .fontSize(15)
          .fontColor(this.themeColor)
          .onClick(() => {
            this.saveAndBack();
          })
      }
      .height(LAYOUT.headerHeight)
      .padding({ left: 8, right: 12 })
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .height(LAYOUT.headerHeight)
    .padding({ left: 4, right: 4 })
    .backgroundColor('#F3F4F6')
    .alignItems(VerticalAlign.Center)
  }

  /** 点「‹」：有未保存改动先确认放弃，没有就直接出栈 */
  private backOrDiscard(): void {
    if (this.dirty) {
      this.confirmDiscard();
      return;
    }
    router.back();
  }

  @Builder
  nameCard() {
    Column({ space: 6 }) {
      Text('时间表名称')
        .fontSize(12)
        .fontColor('#6B7280')
        .width('100%')
      TextInput({ placeholder: '时间表名称', text: this.nameText })
        .fontSize(15)
        .height(LAYOUT.inputHeight)
        .backgroundColor('#F3F4F6')
        .width('100%')
        .textAlign(TextAlign.Start)
        .padding({ left: 12, right: 12 })
        .onChange((value: string) => this.onNameChange(value))
    }
    .width('100%')
    .padding(14)
    .backgroundColor('#FFFFFF')
    .borderRadius(LAYOUT.cardRadius)
  }

  @Builder
  sessionCountCard() {
    Column({ space: 4 }) {
      Row() {
        Text('每天节数')
          .fontSize(13)
          .fontColor('#374151')
        Blank()
        Text(`${this.slotCount()} 节`)
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor('#111827')
      }
      .width('100%')

      Slider({ value: this.slotCount(), min: MIN_SESSIONS, max: MAX_SESSIONS, step: 1 })
        .width('100%')
        .selectedColor(this.themeColor)
        .trackColor('#E5E7EB')
        .onChange((value: number, mode: SliderChangeMode) => {
          if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
            this.onSessionCountChange(value);
          }
        })

      Row() {
        Text('增节按上一节结束后 10 分钟顺延，减节直接截断')
          .fontSize(10)
          .fontColor('#9CA3AF')
        Blank()
        Text('默认 12 节')
          .fontSize(10)
          .fontColor('#9CA3AF')
      }
      .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor('#FFFFFF')
    .borderRadius(LAYOUT.cardRadius)
  }

  @Builder
  durationCard() {
    Row({ space: 8 }) {
      Text('每节时长')
        .fontSize(13)
        .fontColor('#374151')
      TextInput({ text: this.durationText })
        .type(InputType.Number)
        .fontSize(15)
        .height(40)
        .backgroundColor('#F3F4F6')
        .width(76)
        .textAlign(TextAlign.Center)
        .onChange((value: string) => this.onDurationChange(value))
      Text('分钟')
        .fontSize(13)
        .fontColor('#6B7280')
      Blank()
    }
    .width('100%')
    .padding(14)
    .backgroundColor('#FFFFFF')
    .borderRadius(LAYOUT.cardRadius)
  }

  @Builder
  slotList() {
    Column({ space: 6 }) {
      ForEach(this.draft.slots, (slot: ScheduleSlot, index: number) => {
        Row({ space: 10 }) {
          Text(`第${slot.session_no}节`)
            .fontSize(13)
            .fontColor('#374151')
            // 固定宽度 + 居中：节次位数不同（第1节 / 第12节）时右边界仍对齐，
            // 后面的开始时间胶囊才能在每一行里落在同一竖线上
            .width(56)
            .maxLines(1)
            .textAlign(TextAlign.Center)
          Row() {
            Text(slot.start_time)
              .fontSize(15)
              .fontColor(this.themeColor)
          }
          .height(LAYOUT.slotRowHeight - 8)
          .padding({ left: 14, right: 14 })
          .backgroundColor('#EFF6FF')
          .borderRadius(8)
          .justifyContent(FlexAlign.Center)
          .onClick(() => this.pickSlotStart(index))
          Text('→')
            .fontSize(12)
            .fontColor('#9CA3AF')
          Text(slot.end_time)
            .fontSize(14)
            .fontColor('#6B7280')
        }
        .width('100%')
        .height(LAYOUT.slotRowHeight)
        // 行内均分：首项靠左、末项靠右，相邻元素间隔相等（原先末尾的 Blank() 会把内容全挤在左侧）
        .justifyContent(FlexAlign.SpaceBetween)
      }, (slot: ScheduleSlot) => `${slot.session_no}-${slot.start_time}-${slot.end_time}`)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .backgroundColor('#FFFFFF')
    .borderRadius(LAYOUT.cardRadius)
  }

  /**
   * 开始时间选择层：只有「时」「分」两列的滚轮 + 取消 / 确定。
   *
   * 不用 `TimePickerDialog` 的原因见状态声明处的注释（其顶部日期标题无法隐藏）。
   */
  @Builder
  timeSheetBuilder() {
    Column({ space: 8 }) {
      Row() {
        Text('取消')
          .fontSize(15)
          .fontColor('#6B7280')
          .onClick(() => this.cancelSlotStart())
        Blank()
        Text(`第 ${this.editingSlotNo} 节 · 开始时间`)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor('#111827')
        Blank()
        Text('确定')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.themeColor)
          .onClick(() => this.confirmSlotStart())
      }
      .width('100%')
      .height(48)
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)

      // TimePicker 只渲染时 / 分两列（format 默认即 HOUR_MINUTE），没有任何日期信息
      TimePicker({ selected: DateUtil.hmToDate(this.pickHour, this.pickMinute),
        format: TimePickerFormat.HOUR_MINUTE })
        .height(200)
        .useMilitaryTime(true)
        .selectedTextStyle({ color: this.themeColor, font: { size: 20, weight: FontWeight.Medium } })
        .onChange((value: TimePickerResult) => {
          if (value.hour >= 0 && value.minute >= 0) {
            this.pickHour = value.hour;
            this.pickMinute = value.minute;
          }
        })

      // 底部占位：避开系统导航条
      Column().height(12)
    }
    .width('100%')
    .padding({ top: 4 })
  }

  build() {
    Column({ space: 0 }) {
      this.header()

      if (this.message.length > 0) {
        Text(this.message)
          .fontSize(12)
          .fontColor('#D97706')
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .textAlign(TextAlign.Center)
          .backgroundColor('#FFFBEB')
      }

      if (this.ready) {
        Scroll() {
          Column({ space: 12 }) {
            this.nameCard()
            this.sessionCountCard()
            this.durationCard()

            Text('点击开始时间可修改，结束时间 = 开始时间 + 时长（自动推导）')
              .fontSize(11)
              .fontColor('#9CA3AF')
              .width('100%')
              .padding({ left: 4 })

            this.slotList()

            Text(this.saveHint.length > 0 ? this.saveHint : '修改需点右上角「完成」后才会保存')
              .fontSize(11)
              .fontColor(this.saveHint.startsWith('保存失败') ? '#DC2626' : '#9CA3AF')
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 4, bottom: 4 })

            // 底部占位：避开系统导航条
            Column().height(28)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.TopStart)
      } else {
        Column() {
          Text(this.busy ? '正在加载时间表…' : '无法加载该时间表')
            .fontSize(14)
            .fontColor('#6B7280')
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(PAGE_BG_COLOR)
    // 开始时间选择层（整个页面只有这一个 bindSheet；同一节点挂多个只有最后一个生效）
    .bindSheet($$this.showTimeSheet, this.timeSheetBuilder(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: false,
      onDisappear: () => {
        this.showTimeSheet = false;
      }
    })
  }
}
