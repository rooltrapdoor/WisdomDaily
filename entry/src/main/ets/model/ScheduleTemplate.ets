import { ScheduleSlotRow, ScheduleTemplateRow } from './Rows';
import { DateUtil } from '../common/DateUtil';
import { clamp } from '../common/Util';

/** 一节课的起止时间（对应 schedule_slot 表） */
@ObservedV2
export class ScheduleSlot {
  @Trace session_no: number = 1;
  @Trace start_time: string = '';
  @Trace end_time: string = '';

  static of(sessionNo: number, start: string, end: string): ScheduleSlot {
    const slot: ScheduleSlot = new ScheduleSlot();
    slot.session_no = sessionNo;
    slot.start_time = start;
    slot.end_time = end;
    return slot;
  }
}

/**
 * 内置 12 节标准作息：1-4 上午、5-8 下午、9-12 晚上
 *
 * 说明：这是"出厂模板"的节次表，只作为新建时间表的初始值；
 * 之后用户可在时间表编辑页自由调整节数与每节时长（结束时间由时长自动推导）。
 */
const STANDARD_SLOT_TABLE: string[][] = [
  ['08:00', '08:45'], ['08:55', '09:40'],
  ['10:00', '10:45'], ['10:55', '11:40'],
  ['14:00', '14:45'], ['14:55', '15:40'],
  ['16:00', '16:45'], ['16:55', '17:40'],
  ['19:00', '19:45'], ['19:55', '20:40'],
  ['20:50', '21:35'], ['21:45', '22:30']
];

/** 构造"12 节标准作息"的模板骨架（内置模板与用户新建时间表共用同一套初始值） */
function STANDARD_TEMPLATE_SEED(name: string): ScheduleTemplate {
  const template: ScheduleTemplate = new ScheduleTemplate();
  template.name = name;
  template.class_sessions = STANDARD_SLOT_TABLE.length;
  template.duration_time = 45;
  template.slots = STANDARD_SLOT_TABLE.map((pair: string[], index: number) =>
    ScheduleSlot.of(index + 1, pair[0], pair[1]));
  return template;
}

/**
 * 课表时间模板（对应 schedule_template + schedule_slot）。
 *
 * `citation_count` 不再是一个需要维护的计数列，而是由 `v_template_stat` 视图
 * 实时 COUNT 得出——旧版那个计数一旦不同步就会出现"被引用的模板被删掉"的问题。
 */
@ObservedV2
export class ScheduleTemplate {
  @Trace id: number = 0;
  @Trace name: string = '默认';
  /** 每天总节数，决定课表网格行数 */
  @Trace class_sessions: number = 12;
  /** 每节时长（分钟），仅展示 */
  @Trace duration_time: number = 45;
  /** 被学期引用次数（只读，来自视图） */
  @Trace citation_count: number = 0;
  /** 受保护的内置模板，不允许删除 */
  @Trace is_builtin: boolean = false;
  @Trace slots: ScheduleSlot[] = [];

  static standard(name: string): ScheduleTemplate {
    const template: ScheduleTemplate = STANDARD_TEMPLATE_SEED(name);
    template.is_builtin = true;
    return template;
  }

  static fromRow(row: ScheduleTemplateRow, slots: ScheduleSlot[]): ScheduleTemplate {
    const template: ScheduleTemplate = new ScheduleTemplate();
    template.id = row.id;
    template.name = row.name;
    template.class_sessions = row.class_sessions;
    template.duration_time = row.duration_time;
    template.is_builtin = row.is_builtin;
    template.citation_count = row.citation_count;
    template.slots = slots;
    return template;
  }

  /** 新建（非内置）时间表：12 节标准作息、每节 45 分钟，供"新建时间表"入口使用 */
  static blank(name: string): ScheduleTemplate {
    const template: ScheduleTemplate = STANDARD_TEMPLATE_SEED(name);
    template.is_builtin = false;
    return template;
  }

  isDefaultTemplate(): boolean {
    return this.is_builtin || this.name === '默认';
  }

  /** 是否还能删：内置不可删，被学期引用不可删 */
  canDelete(): boolean {
    return !this.isDefaultTemplate() && this.citation_count === 0;
  }

  slotOf(sessionNo: number): ScheduleSlot | undefined {
    for (let i = 0; i < this.slots.length; i++) {
      if (this.slots[i].session_no === sessionNo) {
        return this.slots[i];
      }
    }
    return undefined;
  }

  /** 渲染 "08:00-09:40" 这样的起止时间；越界时返回空串而不是抛异常 */
  timeRange(startSession: number, endSession: number): string {
    const from: ScheduleSlot | undefined = this.slotOf(startSession);
    const to: ScheduleSlot | undefined = this.slotOf(endSession);
    if (from === undefined || to === undefined) {
      return '';
    }
    return `${from.start_time}-${to.end_time}`;
  }

  // -------------------------------------------------- 编辑期的时间推导（时间表编辑页）

  /**
   * 按"每节时长"重算全部结束时间：开始时间保持不变，结束 = 开始 + 时长。
   *
   * 这是"设置每节课的时长"这条需求的实现核心——用户只维护开始时间和时长，
   * 结束时间永远是推导值，不会出现开始/结束互相矛盾的数据。
   */
  applyDuration(duration: number): void {
    const minutes: number = clamp(Math.round(duration), 1, 300);
    this.duration_time = minutes;
    for (let i = 0; i < this.slots.length; i++) {
      const slot: ScheduleSlot = this.slots[i];
      slot.end_time = DateUtil.hmFromMinutes(DateUtil.hmToMinutes(slot.start_time) + minutes);
    }
  }

  /** 设置某一节的开始时间，并立即推导出该节结束时间 */
  setSlotStart(sessionNo: number, startTime: string): void {
    const slot: ScheduleSlot | undefined = this.slotOf(sessionNo);
    if (slot === undefined) {
      return;
    }
    slot.start_time = startTime;
    slot.end_time = DateUtil.hmFromMinutes(
      DateUtil.hmToMinutes(startTime) + clamp(this.duration_time, 1, 300));
  }

  /**
   * 调整"每天节数"。
   *
   * 增加时按"上一节结束 + 10 分钟课间"顺延（首节从 08:00 起），减少时直接截断；
   * `class_sessions` 始终与 `slots.length` 保持一致——两者不一致在库里会被 CHECK 拦住。
   */
  ensureSessionCount(count: number): void {
    const target: number = clamp(Math.round(count), 1, 24);
    const duration: number = clamp(this.duration_time, 1, 300);
    while (this.slots.length < target) {
      const previous: ScheduleSlot | undefined =
        this.slots.length > 0 ? this.slots[this.slots.length - 1] : undefined;
      const startMinutes: number = previous === undefined
        ? 8 * 60
        : DateUtil.hmToMinutes(previous.end_time) + 10;
      const start: string = DateUtil.hmFromMinutes(startMinutes);
      this.slots.push(ScheduleSlot.of(this.slots.length + 1, start,
        DateUtil.hmFromMinutes(DateUtil.hmToMinutes(start) + duration)));
    }
    while (this.slots.length > target) {
      this.slots.pop();
    }
    this.class_sessions = this.slots.length;
  }

  clone(): ScheduleTemplate {
    const copy: ScheduleTemplate = new ScheduleTemplate();
    copy.id = this.id;
    copy.name = this.name;
    copy.class_sessions = this.class_sessions;
    copy.duration_time = this.duration_time;
    copy.citation_count = this.citation_count;
    copy.is_builtin = this.is_builtin;
    copy.slots = this.slots.map((slot: ScheduleSlot) => ScheduleSlot.of(slot.session_no, slot.start_time, slot.end_time));
    return copy;
  }
}
