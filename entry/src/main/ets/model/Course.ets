import { ClassGroupRow, CourseRow, TimePeriodRow } from './Rows';
import { DEFAULT_COLOR, newUuid, normalizeColor, normalizeWeeks, weekContains } from '../common/Util';
import { DateUtil } from '../common/DateUtil';

/**
 * 一个上课时间段（对应 time_period + period_week 两张表）。
 *
 * 与旧结构的关键差异：
 *  - `week_nums` 不再是"数组塞在对象里"，而是 period_week 的子行；内存里仍是数组，
 *    但写入/读取都由 DAO 保证与子表一致，不存在"父对象写了、周次没写"的半截状态。
 *  - 冲突判定（`overlaps`）同时比较"星期 + 节次区间 + 周次集合"，修掉了旧版
 *    只看包含关系、忽略周次的漏判。
 */
@ObservedV2
export class TimePeriod {
  /** time_period.id，未落库时为 0 */
  @Trace id: number = 0;
  /** 1 = 周一 … 7 = 周日 */
  @Trace weekday: number = 1;
  /** 生效周次，已排序去重 */
  @Trace week_nums: number[] = [];
  @Trace class_room: string = '';
  /** 起始节次，1-based */
  @Trace start_time: number = 1;
  /** 结束节次，1-based，含 */
  @Trace end_time: number = 2;
  @Trace remark: string = '';

  static empty(maxWeek: number): TimePeriod {
    const period: TimePeriod = new TimePeriod();
    const weeks: number[] = [];
    for (let i = 1; i <= maxWeek; i++) {
      weeks.push(i);
    }
    period.week_nums = weeks;
    return period;
  }

  static fromRow(row: TimePeriodRow, weeks: number[], maxWeek: number): TimePeriod {
    const period: TimePeriod = new TimePeriod();
    period.id = row.id;
    period.weekday = row.weekday;
    period.start_time = row.start_time;
    period.end_time = row.end_time;
    period.class_room = row.class_room;
    period.remark = row.remark;
    period.week_nums = normalizeWeeks(weeks, maxWeek);
    return period;
  }

  /** 落库载荷；`id` 由数据库生成，不在此处携带 */
  toRow(classGroupId: number): TimePeriodRow {
    return {
      id: this.id,
      class_group_id: classGroupId,
      weekday: this.weekday,
      start_time: this.start_time,
      end_time: this.end_time,
      class_room: this.class_room,
      remark: this.remark
    };
  }

  coversWeek(week: number): boolean {
    return weekContains(this.week_nums, week);
  }

  /** 与另一个时间段是否真的冲突：同一天 + 节次区间相交 + 至少一周重叠 */
  overlaps(other: TimePeriod): boolean {
    if (this.weekday !== other.weekday) {
      return false;
    }
    // 区间相交（闭区间）：! (a.end < b.start || b.end < a.start)
    if (this.end_time < other.start_time || other.end_time < this.start_time) {
      return false;
    }
    for (let i = 0; i < this.week_nums.length; i++) {
      if (weekContains(other.week_nums, this.week_nums[i])) {
        return true;
      }
    }
    return false;
  }

  /** 冲突说明文本，用于给用户明确的提示而不是静默丢弃 */
  conflictText(other: TimePeriod): string {
    const shared: number[] = [];
    for (let i = 0; i < this.week_nums.length; i++) {
      const w: number = this.week_nums[i];
      if (weekContains(other.week_nums, w)) {
        shared.push(w);
      }
    }
    return `${DateUtil.weekdayLabel(this.weekday)} 第${this.start_time}-${this.end_time}节`
      + ` 与「${other.class_room.length > 0 ? other.class_room : '已有安排'}」`
      + ` 第${other.start_time}-${other.end_time}节在 ${DateUtil.formatWeeks(shared)} 重叠`;
  }

  clone(): TimePeriod {
    const copy: TimePeriod = new TimePeriod();
    copy.id = this.id;
    copy.weekday = this.weekday;
    copy.week_nums = this.week_nums.slice();
    copy.class_room = this.class_room;
    copy.start_time = this.start_time;
    copy.end_time = this.end_time;
    copy.remark = this.remark;
    return copy;
  }

  describe(): string {
    return `${DateUtil.weekdayLabel(this.weekday)}  第${this.start_time} - ${this.end_time}节`;
  }
}

/**
 * 课程 × 班级（对应 class_group 表，即旧结构里的 CourseInformation）。
 *
 * `class_id` 是稳定业务主键，`class_name` 只是展示用快照；班级改名走 class_info，
 * 关联不会断——这是旧版"按班级名拼文件名、改名就丢名单"的根治方案。
 */
@ObservedV2
export class ClassGroup {
  @Trace id: number = 0;
  @Trace class_id: string = '';
  @Trace class_name: string = '';
  @Trace population: number = 0;
  @Trace color: string = DEFAULT_COLOR;
  @Trace time_periods: TimePeriod[] = [];

  static fromRow(row: ClassGroupRow, periods: TimePeriod[]): ClassGroup {
    const group: ClassGroup = new ClassGroup();
    group.id = row.id;
    group.class_id = row.class_id;
    group.class_name = row.class_name;
    group.population = row.population;
    group.color = normalizeColor(row.color);
    group.time_periods = periods;
    return group;
  }

  toRow(courseRowId: number): ClassGroupRow {
    return {
      id: this.id,
      course_id: courseRowId,
      class_id: this.class_id,
      class_name: this.class_name,
      population: this.population,
      color: normalizeColor(this.color),
      sort_order: 0
    };
  }

  /** 本周是否有课 */
  hasLessonInWeek(week: number): boolean {
    for (let i = 0; i < this.time_periods.length; i++) {
      if (this.time_periods[i].coversWeek(week)) {
        return true;
      }
    }
    return false;
  }

  /** 指定星期几、在第 week 周的上课时间段 */
  periodsOf(weekday: number, week: number): TimePeriod[] {
    const result: TimePeriod[] = [];
    for (let i = 0; i < this.time_periods.length; i++) {
      const p: TimePeriod = this.time_periods[i];
      if (p.weekday === weekday && p.coversWeek(week)) {
        result.push(p);
      }
    }
    return result;
  }

  clone(): ClassGroup {
    const copy: ClassGroup = new ClassGroup();
    copy.id = this.id;
    copy.class_id = this.class_id;
    copy.class_name = this.class_name;
    copy.population = this.population;
    copy.color = this.color;
    copy.time_periods = this.time_periods.map((p: TimePeriod) => p.clone());
    return copy;
  }
}

/** 课程（对应 course 表） */
@ObservedV2
export class Course {
  @Trace id: number = 0;
  /** 不可变业务主键 */
  @Trace course_id: string = '';
  @Trace course_name: string = '';
  @Trace course_type: string = '理论';
  /** null 表示"未填学分"，与 0 学分区分开 */
  @Trace course_score: number | null = null;
  @Trace course_remark: string = '';
  @Trace class_groups: ClassGroup[] = [];

  static create(name: string, type: string): Course {
    const course: Course = new Course();
    course.course_id = newUuid();
    course.course_name = name;
    course.course_type = type;
    return course;
  }

  static fromRow(row: CourseRow, groups: ClassGroup[]): Course {
    const course: Course = new Course();
    course.id = row.id;
    course.course_id = row.course_id;
    course.course_name = row.course_name;
    course.course_type = row.course_type;
    course.course_score = row.course_score;
    course.course_remark = row.course_remark;
    course.class_groups = groups;
    return course;
  }

  toRow(semesterId: number, teacherId: number): CourseRow {
    return {
      id: this.id,
      course_id: this.course_id.length > 0 ? this.course_id : newUuid(),
      semester_id: semesterId,
      teacher_id: teacherId,
      course_name: this.course_name,
      course_type: this.course_type,
      course_score: this.course_score,
      course_remark: this.course_remark,
      sort_order: 0
    };
  }

  /** 课程内按班名找分组；班级重名已由 class_info 唯一约束拦住 */
  findGroup(classId: string): ClassGroup | undefined {
    for (let i = 0; i < this.class_groups.length; i++) {
      if (this.class_groups[i].class_id === classId) {
        return this.class_groups[i];
      }
    }
    return undefined;
  }

  /** 这门课一共排了多少个时间段（跨班级累计） */
  countPeriods(): number {
    let total: number = 0;
    for (let i = 0; i < this.class_groups.length; i++) {
      total += this.class_groups[i].time_periods.length;
    }
    return total;
  }

  clone(): Course {
    const copy: Course = new Course();
    copy.id = this.id;
    copy.course_id = this.course_id;
    copy.course_name = this.course_name;
    copy.course_type = this.course_type;
    copy.course_score = this.course_score;
    copy.course_remark = this.course_remark;
    copy.class_groups = this.class_groups.map((g: ClassGroup) => g.clone());
    return copy;
  }
}
