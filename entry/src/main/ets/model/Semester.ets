import { SemesterRow } from './Rows';
import { DateUtil } from '../common/DateUtil';
import { Teacher, TeacherCourses } from './Teacher';
import { ClassGroup, Course } from './Course';

/** 学期（对应 semester 表）。`schedule_id` 指向作息模板，改名不影响引用 */
@ObservedV2
export class Semester {
  @Trace id: number = 0;
  @Trace name: string = '';
  @Trace total_weeks: number = 20;
  /** 第 1 周周一，`YYYY-MM-DD` */
  @Trace start_date: string = '';
  /** 引用的作息模板 id；0 表示未绑定 */
  @Trace schedule_id: number = 0;
  /** 联表带出的模板名，只读展示 */
  @Trace schedule_name: string = '';
  @Trace sort_order: number = 0;

  static fromRow(row: SemesterRow): Semester {
    const semester: Semester = new Semester();
    semester.id = row.id;
    semester.name = row.name;
    semester.total_weeks = row.total_weeks;
    semester.start_date = row.start_date;
    semester.schedule_id = row.schedule_id === undefined ? 0 : row.schedule_id;
    semester.schedule_name = row.schedule_name === undefined ? '' : row.schedule_name;
    semester.sort_order = row.sort_order;
    return semester;
  }

  startDate(): Date {
    return DateUtil.parseDate(this.start_date);
  }

  /**
   * 今天落在第几周。
   * 学期进行中返回真实周次；学期尚未开始 / 已结束都返回第 1 周（这两种情况没有"今天所在周"）。
   */
  currentWeek(): number {
    return DateUtil.getCurrentWeek(this.startDate(), this.total_weeks);
  }

  /** 学期是否已结束（今天晚于最后一个周日） */
  hasEnded(): boolean {
    return DateUtil.isSemesterEnded(this.startDate(), this.total_weeks);
  }

  /** 学期是否还没开始（今天早于第一周周一） */
  notStarted(): boolean {
    return DateUtil.isSemesterNotStarted(this.startDate());
  }

  clone(): Semester {
    const copy: Semester = new Semester();
    copy.id = this.id;
    copy.name = this.name;
    copy.total_weeks = this.total_weeks;
    copy.start_date = this.start_date;
    copy.schedule_id = this.schedule_id;
    copy.schedule_name = this.schedule_name;
    copy.sort_order = this.sort_order;
    return copy;
  }
}

/**
 * 一个学期的完整课表聚合（对应旧 SemesterCoursesInterface）。
 *
 * 这是 Repository 对外交付的对象图，也是页面的绑定对象：
 *   SemesterCourses { semester, teacher_courses[ { teacher, courses[ { class_groups[ { time_periods } ] } ] } ] }
 *
 * 旧实现把整棵对象图序列化成一个 JSON 文件；现在它由多条 SQL 在启动时组装而成，
 * 单个课程、单个时间段都可以独立更新，不需要重写整学期。
 */
@ObservedV2
export class SemesterCourses {
  @Trace semester: Semester = new Semester();
  @Trace teacher_courses: TeacherCourses[] = [];
  /** 内存中的脏标记：true 表示有未落库的编辑 */
  @Trace dirty: boolean = false;

  static of(semester: Semester, teacherCourses: TeacherCourses[]): SemesterCourses {
    const courses: SemesterCourses = new SemesterCourses();
    courses.semester = semester;
    courses.teacher_courses = teacherCourses;
    return courses;
  }

  totalWeeks(): number {
    return this.semester.total_weeks;
  }

  startDate(): Date {
    return this.semester.startDate();
  }

  weekMatrix(): Date[][] {
    return DateUtil.getAllWeekDates(this.startDate(), this.totalWeeks());
  }

  /** 教师列表（顺序即数据库 sort_order） */
  teachers(): Teacher[] {
    return this.teacher_courses.map((tc: TeacherCourses) => tc.teacher);
  }

  teacherCoursesAt(index: number): TeacherCourses | undefined {
    if (index < 0 || index >= this.teacher_courses.length) {
      return undefined;
    }
    return this.teacher_courses[index];
  }

  findTeacherCourses(teacherId: number): TeacherCourses | undefined {
    const index: number = TeacherCourses.indexOfTeacher(this.teacher_courses, teacherId);
    return index < 0 ? undefined : this.teacher_courses[index];
  }

  /** 当前学期用到的全部班级 id（用于按需加载名单） */
  classIdsInUse(): string[] {
    const ids: string[] = [];
    for (let i = 0; i < this.teacher_courses.length; i++) {
      const courses: Course[] = this.teacher_courses[i].courses;
      for (let j = 0; j < courses.length; j++) {
        const groups: ClassGroup[] = courses[j].class_groups;
        for (let k = 0; k < groups.length; k++) {
          if (ids.indexOf(groups[k].class_id) < 0) {
            ids.push(groups[k].class_id);
          }
        }
      }
    }
    return ids;
  }

  /** 学期内所有课程数（跨教师） */
  countCourses(): number {
    let total: number = 0;
    for (let i = 0; i < this.teacher_courses.length; i++) {
      total += this.teacher_courses[i].courses.length;
    }
    return total;
  }

  /** 学期内所有时间段数（跨教师、跨课程、跨班级），可作为落库后的自检指标 */
  countPeriods(): number {
    let total: number = 0;
    for (let i = 0; i < this.teacher_courses.length; i++) {
      total += this.teacher_courses[i].countPeriods();
    }
    return total;
  }

  clone(): SemesterCourses {
    return SemesterCourses.of(this.semester.clone(),
      this.teacher_courses.map((tc: TeacherCourses) => tc.clone()));
  }
}
