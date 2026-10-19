import { DbExecutor, RsReader } from '../db/DbExecutor';
import { TimePeriod } from '../model/Course';
import { Tables } from '../db/TableSchema';

/**
 * 冲突维度的取值，与 SQL 里输出的 `kind` 字面量保持一致。
 * '教师' —— 同一教师在同一时间要上两门课（硬冲突）
 * '班级' —— 同一班级在同一时间被两门课占用（硬冲突）
 */
export const CONFLICT_KIND_TEACHER: string = '教师';
export const CONFLICT_KIND_CLASS: string = '班级';

/** 一条冲突事实 */
export interface ConflictHit {
  kind: string;
  /** 冲突归属的对象：教师姓名 或 班级名 */
  owner: string;
  course_name: string;
  class_name: string;
  class_room: string;
  weekday: number;
  start_time: number;
  end_time: number;
  /** 与本次提交重叠的具体周次 */
  overlapped_weeks: number[];
}

/**
 * 时间冲突检测。
 *
 * 旧实现的三个问题，这里逐一修掉：
 *  1. 只看"包含关系"（`t.start <= n.start && t.end >= n.end`），部分重叠检测不到；
 *  2. 完全忽略周次——单周课和双周课会被误判冲突，单双周轮转排课根本排不进去；
 *  3. 检测到冲突后**静默丢弃**，用户以为存上了，实际课表少了一节。
 *
 * 现在的做法：周次交集下推到 SQL（`pw.week_no IN (...)`），
 * 时间重叠交给索引（`idx_period_group(class_group_id, weekday, start_time)`），
 * 结果**返回给调用方**由界面明确提示，绝不静默处理。
 */
export class ConflictDetector {
  private static readonly QUALIFY_FROM: string =
    `FROM ${Tables.TIME_PERIOD} tp
       JOIN ${Tables.CLASS_GROUP} cg ON cg.id = tp.class_group_id
       JOIN ${Tables.COURSE} c ON c.id = cg.course_id
       JOIN ${Tables.CLASS_INFO} ci ON ci.class_id = cg.class_id
       JOIN ${Tables.TEACHER} t ON t.id = c.teacher_id
       JOIN ${Tables.PERIOD_WEEK} pw ON pw.time_period_id = tp.id`;

  private static readonly QUALIFY_COLS: string =
    `tp.id AS period_id, tp.weekday, tp.start_time, tp.end_time, tp.class_room,
     c.course_name, ci.class_name, t.name AS teacher_name, pw.week_no`;

  /**
   * 教师维度：同一个老师不能在同一周、同一天、同一节次出现在两个地方。
   * 覆盖"同课程不同班"与"不同课程"两种情况。
   */
  static async checkTeacherDimension(exec: DbExecutor, semesterId: number, teacherId: number,
    candidate: TimePeriod, excludePeriodId: number = 0): Promise<ConflictHit[]> {
    if (candidate.week_nums.length === 0) {
      return [];
    }
    const placeholders: string = ConflictDetector.weekPlaceholders(candidate.week_nums.length);
    const args: Array<number | string> = [semesterId, teacherId, candidate.weekday,
      candidate.end_time, candidate.start_time, excludePeriodId];
    for (let i = 0; i < candidate.week_nums.length; i++) {
      args.push(candidate.week_nums[i]);
    }
    const sql: string =
      `SELECT ${ConflictDetector.QUALIFY_COLS}, '${CONFLICT_KIND_TEACHER}' AS kind, t.name AS owner
         ${ConflictDetector.QUALIFY_FROM}
        WHERE c.semester_id = ?
          AND c.teacher_id = ?
          AND tp.weekday = ?
          AND tp.start_time <= ?
          AND tp.end_time >= ?
          AND tp.id <> ?
          AND pw.week_no IN (${placeholders})
        ORDER BY tp.weekday ASC, tp.start_time ASC, pw.week_no ASC`;
    return ConflictDetector.run(exec, sql, args);
  }

  /**
   * 班级维度：同一个班在同一时间不能被两门课占用（可能来自不同教师）。
   * 这是旧版完全没做的事——它只在一门课自己的 `course_informations` 里比对。
   */
  static async checkClassDimension(exec: DbExecutor, semesterId: number, classIds: string[],
    candidate: TimePeriod, excludePeriodId: number = 0): Promise<ConflictHit[]> {
    if (candidate.week_nums.length === 0 || classIds.length === 0) {
      return [];
    }
    const weekPlaceholders: string = ConflictDetector.weekPlaceholders(candidate.week_nums.length);
    const classPlaceholders: string = ConflictDetector.weekPlaceholders(classIds.length);
    const args: Array<number | string> = [semesterId, candidate.weekday,
      candidate.end_time, candidate.start_time, excludePeriodId];
    for (let i = 0; i < classIds.length; i++) {
      args.push(classIds[i]);
    }
    for (let i = 0; i < candidate.week_nums.length; i++) {
      args.push(candidate.week_nums[i]);
    }
    const sql: string =
      `SELECT ${ConflictDetector.QUALIFY_COLS}, '${CONFLICT_KIND_CLASS}' AS kind, ci.class_name AS owner
         ${ConflictDetector.QUALIFY_FROM}
        WHERE c.semester_id = ?
          AND tp.weekday = ?
          AND tp.start_time <= ?
          AND tp.end_time >= ?
          AND tp.id <> ?
          AND cg.class_id IN (${classPlaceholders})
          AND pw.week_no IN (${weekPlaceholders})
        ORDER BY tp.weekday ASC, tp.start_time ASC, pw.week_no ASC`;
    return ConflictDetector.run(exec, sql, args);
  }

  /** 两个维度一起查，并按 (kind + period_id) 去重 */
  static async check(exec: DbExecutor, semesterId: number, teacherId: number, classIds: string[],
    candidate: TimePeriod, excludePeriodId: number = 0): Promise<ConflictHit[]> {
    const teacherHits: ConflictHit[] =
      await ConflictDetector.checkTeacherDimension(exec, semesterId, teacherId, candidate, excludePeriodId);
    const classHits: ConflictHit[] =
      await ConflictDetector.checkClassDimension(exec, semesterId, classIds, candidate, excludePeriodId);

    const merged: ConflictHit[] = teacherHits.slice();
    for (let i = 0; i < classHits.length; i++) {
      const hit: ConflictHit = classHits[i];
      let duplicated: boolean = false;
      for (let j = 0; j < merged.length; j++) {
        const exist: ConflictHit = merged[j];
        if (exist.start_time === hit.start_time && exist.end_time === hit.end_time
          && exist.class_name === hit.class_name && exist.course_name === hit.course_name) {
          duplicated = true;
          break;
        }
      }
      if (!duplicated) {
        merged.push(hit);
      }
    }
    return merged;
  }

  /** 把冲突列表转成可直接展示给用户的一句话 */
  static describe(hits: ConflictHit[]): string {
    if (hits.length === 0) {
      return '';
    }
    const first: ConflictHit = hits[0];
    const more: string = hits.length > 1 ? ` 等 ${hits.length} 处` : '';
    return `时间冲突：与「${first.course_name} / ${first.class_name}」`
      + ` 第${first.start_time}-${first.end_time}节（${first.class_room.length > 0 ? first.class_room : '未填教室'}）`
      + ` 在 ${ConflictDetector.weekText(first.overlapped_weeks)} 重叠${more}`;
  }

  private static weekText(weeks: number[]): string {
    if (weeks.length === 0) {
      return '同一周次';
    }
    const sorted: number[] = weeks.slice().sort((a: number, b: number) => a - b);
    return `第${sorted.join(',')}周`;
  }

  private static weekPlaceholders(count: number): string {
    const parts: string[] = [];
    for (let i = 0; i < count; i++) {
      parts.push('?');
    }
    return parts.join(',');
  }

  private static async run(exec: DbExecutor, sql: string,
    args: Array<number | string>): Promise<ConflictHit[]> {
    const rs = await exec.querySql(sql, args);
    const hits: ConflictHit[] = [];
    const periodIndex: number[] = [];
    try {
      while (rs.goToNextRow()) {
        const reader: RsReader = new RsReader(rs);
        const periodId: number = reader.num('period_id');
        const weekNo: number = reader.num('week_no');
        const found: number = periodIndex.indexOf(periodId);
        if (found >= 0) {
          // 同一条时间段的多周会在 IN 之后产生多行，这里把周次并到同一条冲突里
          hits[found].overlapped_weeks.push(weekNo);
          continue;
        }
        periodIndex.push(periodId);
        hits.push({
          kind: reader.str('kind'),
          owner: reader.str('owner'),
          course_name: reader.str('course_name'),
          class_name: reader.str('class_name'),
          class_room: reader.str('class_room'),
          weekday: reader.num('weekday', 1),
          start_time: reader.num('start_time', 1),
          end_time: reader.num('end_time', 2),
          overlapped_weeks: [weekNo]
        });
      }
    } finally {
      rs.close();
    }
    return hits;
  }
}
