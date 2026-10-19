import { clamp, WEEKDAY_LABELS } from './Util';

const MS_PER_DAY: number = 24 * 60 * 60 * 1000;

/**
 * 课表日期工具。
 *
 * 与旧实现的区别（都是这次改造要修掉的坑）：
 *  1. `parseDate` 手工解析，绝不用 `new Date('2025-09-01')` —— 该写法按 UTC 解析，
 *     在东八区会整体前移一天，导致"第 1 周周一"错位。
 *  2. `getWeekNumber` 以"起始日所在周的周一"为第 1 周锚点并 `+1`，
 *     解决起始日不是周一时算出"第 0 周"的问题。
 *  3. 过期日期统一夹紧到 [1, totalWeeks]，界面上不再出现负数周或越界周。
 */
export class DateUtil {
  /** 统一存储格式：`YYYY-MM-DD`（补零，可字典序比较，可直接被 SQLite 排序） */
  static toDateString(d: Date): string {
    const y: number = d.getFullYear();
    const m: number = d.getMonth() + 1;
    const day: number = d.getDate();
    return `${y}-${m < 10 ? '0' : ''}${m}-${day < 10 ? '0' : ''}${day}`;
  }

  /** 解析 `YYYY-MM-DD`、`YYYY/M/D`（兼容旧数据）或任意可解析字符串，返回本地时区零点 */
  static parseDate(text: string | null | undefined): Date {
    if (!text) {
      return DateUtil.today();
    }
    const matched: RegExpMatchArray | null = text.trim().match(/^(\d{4})[-/](\d{1,2})[-/](\d{1,2})/);
    if (matched !== null) {
      const y: number = parseInt(matched[1], 10);
      const m: number = parseInt(matched[2], 10);
      const d: number = parseInt(matched[3], 10);
      if (m >= 1 && m <= 12 && d >= 1 && d <= 31) {
        return new Date(y, m - 1, d);
      }
    }
    const fallback: Date = new Date(text);
    return isNaN(fallback.getTime()) ? DateUtil.today() : fallback;
  }

  static today(): Date {
    const now: Date = new Date();
    return new Date(now.getFullYear(), now.getMonth(), now.getDate());
  }

  /** 取某日期所在周的周一（零点） */
  static weekMonday(date: Date): Date {
    const dayOfWeek: number = date.getDay(); // 0 = 周日
    const offset: number = dayOfWeek === 0 ? -6 : 1 - dayOfWeek;
    return new Date(date.getFullYear(), date.getMonth(), date.getDate() + offset);
  }

  /** 取某日期所在周的周一 ~ 周日共 7 天 */
  static getWeekDates(anchor: Date): Date[] {
    const monday: Date = DateUtil.weekMonday(anchor);
    const dates: Date[] = [];
    for (let i = 0; i < 7; i++) {
      dates.push(new Date(monday.getFullYear(), monday.getMonth(), monday.getDate() + i));
    }
    return dates;
  }

  /** 第 1 周 ~ 第 totalWeeks 周的日期矩阵，下标 i 对应第 i+1 周 */
  static getAllWeekDates(startDate: Date, totalWeeks: number): Date[][] {
    const firstMonday: Date = DateUtil.weekMonday(startDate);
    const matrix: Date[][] = [];
    for (let week = 0; week < totalWeeks; week++) {
      const weekAnchor: Date = new Date(firstMonday.getFullYear(), firstMonday.getMonth(),
        firstMonday.getDate() + week * 7);
      matrix.push(DateUtil.getWeekDates(weekAnchor));
    }
    return matrix;
  }

  /**
   * 计算 selectDate 落在学期的第几周（1-based，起始日所在周即第 1 周）。
   * 超出学期范围时夹紧到 [1, totalWeeks]。
   */
  static getWeekNumber(startDate: Date, selectDate: Date, totalWeeks: number): number {
    const startMonday: number = DateUtil.weekMonday(startDate).getTime();
    const selectMonday: number = DateUtil.weekMonday(selectDate).getTime();
    const diffWeeks: number = Math.round((selectMonday - startMonday) / (7 * MS_PER_DAY));
    return clamp(diffWeeks + 1, 1, totalWeeks);
  }

  /** 今天是否落在学期区间内（含首尾） */
  static isDateInSemester(startDate: Date, date: Date, totalWeeks: number): boolean {
    const start: number = startDate.getTime();
    const end: number = start + totalWeeks * 7 * MS_PER_DAY;
    const target: number = date.getTime();
    return target >= start && target <= end;
  }

  /**
   * 今天是否已晚于学期的最后一天（最后一个周日）。
   *
   * 与 `isDateInSemester` 的边界口径一致取"最后一周周日"为学期末日，
   * 因此学期结束后的第一个周一起就判定为已结束。
   */
  static isSemesterEnded(startDate: Date, totalWeeks: number): boolean {
    const lastDay: number = DateUtil.weekMonday(startDate).getTime()
      + totalWeeks * 7 * MS_PER_DAY - MS_PER_DAY;
    return DateUtil.today().getTime() > lastDay;
  }

  /** 今天是否还没到学期的第一天（第一周周一） */
  static isSemesterNotStarted(startDate: Date): boolean {
    return DateUtil.today().getTime() < DateUtil.weekMonday(startDate).getTime();
  }

  /**
   * 取"今天所在的周"：
   *  - 学期进行中 → 今天真正的周次（如第 7 周）
   *  - 学期尚未开始 or 已经结束 → 1（两种情况都没有"今天所在周"，
   *    统一落到第 1 周，避免出现"停在最后一周"这种反直觉的落点）
   *
   * 课表页启动/切换学期时都用它决定默认周次，因此"每次默认第一周"的观感不会再出现。
   */
  static getCurrentWeek(startDate: Date, totalWeeks: number): number {
    if (DateUtil.isSemesterNotStarted(startDate) || DateUtil.isSemesterEnded(startDate, totalWeeks)) {
      return 1;
    }
    return DateUtil.getWeekNumber(startDate, DateUtil.today(), totalWeeks);
  }

  /** 把 week_nums 渲染成紧凑文本，如 "1-8周" / "1,3,5周" / "1-4,9-12周" */
  static formatWeeks(weekNums: number[]): string {
    if (weekNums.length === 0) {
      return '未设置周次';
    }
    const sorted: number[] = weekNums.slice().sort((a: number, b: number) => a - b);
    const segments: string[] = [];
    let start: number = sorted[0];
    let prev: number = sorted[0];
    for (let i = 1; i <= sorted.length; i++) {
      const current: number = i < sorted.length ? sorted[i] : -1;
      if (current !== prev + 1) {
        segments.push(start === prev ? `${start}` : `${start}-${prev}`);
        start = current;
      }
      prev = current;
    }
    return `${segments.join(',')}周`;
  }

  /** 数据库 weekday（1=周一）→ 中文 label */
  static weekdayLabel(weekday: number): string {
    return WEEKDAY_LABELS[clamp(weekday, 1, 7) - 1];
  }

  /** JS `Date.getDay()`（0=周日）→ 数据库 weekday（1=周一..7=周日） */
  static toDbWeekday(jsDay: number): number {
    return jsDay === 0 ? 7 : jsDay;
  }

  /** 创建"某个时间点"的本地零点，用于 SQLite 存储时间戳 */
  static startOfDay(date: Date): number {
    return new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
  }

  // ------------------------------------------------------------ 作息时间（HH:mm）

  /** `HH:mm` → 从零点起的分钟数；解析失败返回 0（调用方按"未设置"处理） */
  static hmToMinutes(text: string | null | undefined): number {
    if (!text) {
      return 0;
    }
    const matched: RegExpMatchArray | null = text.trim().match(/^(\d{1,2}):(\d{1,2})$/);
    if (matched === null) {
      return 0;
    }
    const hour: number = clamp(parseInt(matched[1], 10), 0, 23);
    const minute: number = clamp(parseInt(matched[2], 10), 0, 59);
    return hour * 60 + minute;
  }

  /** 分钟数 → `HH:mm`；跨天时夹紧到 23:59，避免出现 24:15 这种非法时间 */
  static hmFromMinutes(minutes: number): string {
    const safe: number = clamp(Math.round(minutes), 0, 24 * 60 - 1);
    const hour: number = Math.floor(safe / 60);
    const minute: number = safe % 60;
    return `${hour < 10 ? '0' : ''}${hour}:${minute < 10 ? '0' : ''}${minute}`;
  }

  /** 由"时分"构造一个时间点（供 TimePickerDialog 的 selected 初值使用） */
  static hmToDate(hour: number, minute: number): Date {
    return new Date(2000, 0, 1, clamp(hour, 0, 23), clamp(minute, 0, 59));
  }
}
