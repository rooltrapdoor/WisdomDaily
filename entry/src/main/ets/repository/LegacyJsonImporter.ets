import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { DbExecutor } from '../db/DbExecutor';
import { DaoSupport } from '../dao/DaoSupport';
import { SemesterDao } from '../dao/SemesterDao';
import { ScheduleTemplateDao } from '../dao/ScheduleTemplateDao';
import { TeacherDao } from '../dao/TeacherDao';
import { CourseDao } from '../dao/CourseDao';
import { ClassInfoDao } from '../dao/ClassInfoDao';
import { TimePeriodDao } from '../dao/TimePeriodDao';
import { StudentDao } from '../dao/StudentDao';
import { AppSettingDao } from '../dao/AppSettingDao';
import { ScheduleSlot, ScheduleTemplate } from '../model/ScheduleTemplate';
import { Semester } from '../model/Semester';
import { Teacher } from '../model/Teacher';
import { ClassGroup, Course, TimePeriod } from '../model/Course';
import { Student } from '../model/Student';
import { Tables } from '../db/TableSchema';
import { DateUtil } from '../common/DateUtil';
import { Logger } from '../common/Logger';
import { errText, normalizeColor, normalizeWeeks } from '../common/Util';

const TAG: string = 'LegacyImport';
const LEGACY_ARCHIVE_DIR: string = 'legacy_json_backup';

// --------------------------------------------------------------------------
// 旧版 JSON 文档的形态（只读兼容，字段全部可选——历史数据并不可靠）
// --------------------------------------------------------------------------

interface LegacyDefaultSetting {
  semester_index?: number;
  semesters?: string[];
  teacher_index?: number;
  schedules?: string[];
}

interface LegacySchedule {
  id?: number;
  name?: string;
  class_sessions?: number;
  duration_time?: number;
  class_time?: string[][];
  citation_count?: number;
}

interface LegacyTimePeriod {
  weekday?: number;
  week_nums?: number[];
  class_room?: string;
  start_time?: number;
  end_time?: number;
  remark?: string;
}

interface LegacyCourseInformation {
  class_name?: string;
  population?: number;
  color?: string;
  time_periods?: LegacyTimePeriod[];
}

interface LegacyCourse {
  course_id?: string;
  course_name?: string;
  course_type?: string;
  course_score?: number | null;
  course_remark?: string;
  course_informations?: LegacyCourseInformation[];
}

interface LegacyTeacher {
  id?: number;
  name?: string;
  department?: string;
  age?: number;
  sex?: string;
  telephone?: string;
}

interface LegacyTeacherCourse {
  teacher?: LegacyTeacher;
  courses?: LegacyCourse[];
}

interface LegacySemesterCourses {
  semester?: string;
  total_weeks?: number;
  start_date?: string;
  schedule?: string;
  teacher_courses?: LegacyTeacherCourse[];
}

interface LegacyStudent {
  id?: string;
  name?: string;
  class_name?: string;
  age?: number;
  sex?: string;
  telephone?: number;
  remake?: string;
  is_default?: boolean;
}

interface LegacyClassStudent {
  class_name?: string;
  student?: LegacyStudent[];
}

/** 导入结果，用于日志与界面提示 */
export class ImportReport {
  semesters: number = 0;
  templates: number = 0;
  teachers: number = 0;
  courses: number = 0;
  classGroups: number = 0;
  periods: number = 0;
  weeks: number = 0;
  students: number = 0;
  skipped: string[] = [];

  summary(): string {
    return `旧数据导入：${this.semesters} 学期 / ${this.templates} 作息模板 / ${this.teachers} 教师 / `
      + `${this.courses} 课程 / ${this.classGroups} 班级分组 / ${this.periods} 时间段 / `
      + `${this.weeks} 周次 / ${this.students} 学生`
      + (this.skipped.length > 0 ? `；跳过 ${this.skipped.length} 项（详见日志）` : '');
  }
}

/**
 * 旧版 JSON 文档 → 关系库的一次性导入器。
 *
 * 定位说明：**这不是一条并行的存储方案**，而是一次单向搬迁。
 * 导入成功后，`default_setting.json` / `courses/` / `schedule/` / `Class/`
 * 会整体移动到 `filesDir/legacy_json_backup/`，
 * 于是 `hasLegacyData()` 自然返回 false —— 导入天然幂等；
 * 归档目录保留一个版本周期，用户确认无误后可自行删除。
 *
 * 顺带修掉的历史数据问题：
 *  - `start_date` 由 `2025/9/1` 归一化为 `2025-09-01`；
 *  - 颜色由 8 位 `#AARRGGBB` 归一化为 6 位 `#RRGGBB`；
 *  - 学生电话由 number 转 string（保住前导 0），`remake` 改名为 `remark`；
 *  - 班级名落到不可变的 `class_id` 上，此后改名不再丢名单。
 */
export class LegacyJsonImporter {
  /** 沙箱里是否还存在旧版 JSON 数据 */
  static hasLegacyData(context: common.Context): boolean {
    const filesDir: string = context.filesDir;
    if (fs.accessSync(`${filesDir}/default_setting.json`)) {
      return true;
    }
    return fs.accessSync(`${filesDir}/courses`);
  }

  /**
   * 执行导入。调用方需保证在一个事务里，
   * 任何一步失败都整体回滚，旧数据保持原样、不搬家。
   */
  static async run(context: common.Context, exec: DbExecutor): Promise<ImportReport> {
    const report: ImportReport = new ImportReport();
    const filesDir: string = context.filesDir;

    const rawSetting: Object | null = LegacyJsonImporter.readRaw(`${filesDir}/default_setting.json`);
    const setting: LegacyDefaultSetting | null =
      rawSetting === null ? null : rawSetting as LegacyDefaultSetting;

    // 1) 作息模板
    const templateIds: Map<string, number> = new Map<string, number>();
    const scheduleNames: string[] =
      (setting === null || setting.schedules === undefined) ? ['默认'] : setting.schedules;
    for (let i = 0; i < scheduleNames.length; i++) {
      const name: string = scheduleNames[i];
      const rawTemplate: Object | null =
        LegacyJsonImporter.readRaw(`${filesDir}/schedule/schedule_${name}.json`);
      const legacy: LegacySchedule | null =
        rawTemplate === null ? null : rawTemplate as LegacySchedule;
      const template: ScheduleTemplate = legacy === null
        ? ScheduleTemplate.standard(name)
        : LegacyJsonImporter.toTemplate(legacy, name);
      const templateId: number = await ScheduleTemplateDao.insert(exec, template);
      templateIds.set(name, templateId);
      report.templates++;
    }
    if (templateIds.size === 0) {
      templateIds.set('默认', await ScheduleTemplateDao.insert(exec, ScheduleTemplate.standard('默认')));
      report.templates++;
    }
    const defaultTemplateFound: number | undefined = templateIds.get('默认');
    const defaultTemplateId: number = defaultTemplateFound === undefined ? 0 : defaultTemplateFound;

    // 2) 学期
    const semesterNames: string[] =
      (setting === null || setting.semesters === undefined || setting.semesters.length === 0)
        ? ['默认学期'] : setting.semesters;
    const semesterIds: Map<string, number> = new Map<string, number>();
    for (let i = 0; i < semesterNames.length; i++) {
      const name: string = semesterNames[i];
      const rawCourses: Object | null = LegacyJsonImporter.readRaw(`${filesDir}/courses/course_${name}.json`);
      const legacy: LegacySemesterCourses | null =
        rawCourses === null ? null : rawCourses as LegacySemesterCourses;

      const totalWeeks: number = (legacy === null || legacy.total_weeks === undefined || legacy.total_weeks <= 0)
        ? 20 : legacy.total_weeks;

      const semester: Semester = new Semester();
      semester.name = name;
      semester.total_weeks = totalWeeks;
      semester.start_date = legacy === null
        ? DateUtil.toDateString(DateUtil.weekMonday(DateUtil.today()))
        : DateUtil.toDateString(DateUtil.parseDate(legacy.start_date));
      const boundTemplateId: number | undefined =
        legacy === null || legacy.schedule === undefined ? undefined : templateIds.get(legacy.schedule);
      semester.schedule_id = boundTemplateId === undefined ? defaultTemplateId : boundTemplateId;

      const semesterId: number = await SemesterDao.insert(exec, semester, i);
      semesterIds.set(name, semesterId);
      report.semesters++;

      if (legacy === null) {
        report.skipped.push(`courses/course_${name}.json 缺失，仅创建空学期`);
        continue;
      }

      // 3) 教师 → 课程 → 班级分组 → 时间段
      const teacherCourses: LegacyTeacherCourse[] =
        legacy.teacher_courses === undefined ? [] : legacy.teacher_courses;
      for (let t = 0; t < teacherCourses.length; t++) {
        const legacyTeacher: LegacyTeacher | undefined = teacherCourses[t].teacher;
        if (legacyTeacher === undefined) {
          report.skipped.push(`${name} 中有一条教师记录缺少 teacher 字段`);
          continue;
        }
        const teacher: Teacher = new Teacher();
        teacher.staff_no = legacyTeacher.id === undefined ? 0 : legacyTeacher.id;
        teacher.name = legacyTeacher.name === undefined ? '请修改教师姓名' : legacyTeacher.name;
        teacher.department = legacyTeacher.department;
        teacher.age = legacyTeacher.age;
        teacher.sex = legacyTeacher.sex;
        teacher.telephone = legacyTeacher.telephone;
        const teacherId: number = await TeacherDao.upsert(exec, teacher, semesterId, t);
        report.teachers++;

        const legacyCourses: LegacyCourse[] = teacherCourses[t].courses === undefined
          ? [] : teacherCourses[t].courses!;
        for (let c = 0; c < legacyCourses.length; c++) {
          const legacyCourse: LegacyCourse = legacyCourses[c];
          const course: Course = new Course();
          course.course_id = legacyCourse.course_id === undefined ? '' : legacyCourse.course_id;
          course.course_name = legacyCourse.course_name === undefined ? '未命名课程' : legacyCourse.course_name;
          course.course_type = legacyCourse.course_type === undefined ? '理论' : legacyCourse.course_type;
          course.course_score = legacyCourse.course_score === undefined ? null : legacyCourse.course_score;
          course.course_remark = legacyCourse.course_remark === undefined ? '' : legacyCourse.course_remark;
          const courseRowId: number = await CourseDao.insert(exec, course, semesterId, teacherId, c);
          report.courses++;

          const informations: LegacyCourseInformation[] =
            legacyCourse.course_informations === undefined ? [] : legacyCourse.course_informations;
          for (let g = 0; g < informations.length; g++) {
            const info: LegacyCourseInformation = informations[g];
            const className: string = info.class_name === undefined ? '未命名班级' : info.class_name;
            const classId: string = await ClassInfoDao.ensureByName(exec, className);
            const group: ClassGroup = new ClassGroup();
            group.class_id = classId;
            group.class_name = className;
            group.population = info.population === undefined ? 0 : info.population;
            group.color = normalizeColor(info.color);
            const groupId: number = await CourseDao.upsertGroup(exec, courseRowId, group, g, classId);
            report.classGroups++;

            const legacyPeriods: LegacyTimePeriod[] = info.time_periods === undefined ? [] : info.time_periods;
            for (let p = 0; p < legacyPeriods.length; p++) {
              const legacyPeriod: LegacyTimePeriod = legacyPeriods[p];
              const period: TimePeriod = new TimePeriod();
              period.weekday = legacyPeriod.weekday === undefined ? 1 : legacyPeriod.weekday;
              period.week_nums = normalizeWeeks(
                legacyPeriod.week_nums === undefined ? [] : legacyPeriod.week_nums, totalWeeks);
              period.class_room = legacyPeriod.class_room === undefined ? '' : legacyPeriod.class_room;
              period.start_time = legacyPeriod.start_time === undefined ? 1 : legacyPeriod.start_time;
              period.end_time = legacyPeriod.end_time === undefined ? 2 : legacyPeriod.end_time;
              period.remark = legacyPeriod.remark === undefined ? '' : legacyPeriod.remark;
              await TimePeriodDao.insert(exec, groupId, period, totalWeeks);
              report.periods++;
              report.weeks += period.week_nums.length;
            }
          }
        }
      }
    }

    // 4) 班级名单
    const classFiles: string[] = LegacyJsonImporter.listFiles(`${filesDir}/Class`);
    for (let i = 0; i < classFiles.length; i++) {
      const fileName: string = classFiles[i];
      const rawRoster: Object | null = LegacyJsonImporter.readRaw(`${filesDir}/Class/${fileName}`);
      if (rawRoster === null) {
        report.skipped.push(`Class/${fileName} 解析失败`);
        continue;
      }
      const roster: LegacyClassStudent = rawRoster as LegacyClassStudent;
      if (roster.class_name === undefined) {
        report.skipped.push(`Class/${fileName} 缺少 class_name`);
        continue;
      }
      const classId: string = await ClassInfoDao.ensureByName(exec, roster.class_name);
      const legacyStudents: LegacyStudent[] = roster.student === undefined ? [] : roster.student;
      const students: Student[] = [];
      for (let s = 0; s < legacyStudents.length; s++) {
        const item: LegacyStudent = legacyStudents[s];
        const student: Student = new Student();
        student.student_no = item.id === undefined ? '' : item.id;
        student.name = item.name === undefined ? '' : item.name;
        student.age = item.age;
        student.sex = item.sex;
        // 数字化电话补回字符串，避免前导 0 丢失
        student.telephone = item.telephone === undefined ? undefined : `${item.telephone}`;
        student.remark = item.remake;
        student.is_builtin = item.is_default === undefined ? false : item.is_default;
        students.push(student);
      }
      report.students += await StudentDao.replaceRoster(exec, classId, students);
    }

    // 5) 恢复"当前学期 / 当前教师"指向（旧版是数组下标，这里换算成真实主键）
    const semesterIndex: number = setting === null || setting.semester_index === undefined
      ? 0 : setting.semester_index;
    const safeSemesterIndex: number =
      semesterIndex >= 0 && semesterIndex < semesterNames.length ? semesterIndex : 0;
    const currentSemesterId: number | undefined = semesterIds.get(semesterNames[safeSemesterIndex]);
    let currentTeacherId: number = 0;
    if (currentSemesterId !== undefined) {
      const teacherCount: number = await DaoSupport.scalarNumber(exec,
        `SELECT COUNT(*) AS v FROM ${Tables.TEACHER} WHERE semester_id = ?`, [currentSemesterId]);
      if (teacherCount > 0) {
        const teacherIndex: number = setting === null || setting.teacher_index === undefined
          ? 0 : setting.teacher_index;
        const safeTeacherIndex: number =
          teacherIndex >= 0 && teacherIndex < teacherCount ? teacherIndex : 0;
        currentTeacherId = await DaoSupport.scalarNumber(exec,
          `SELECT id AS v FROM ${Tables.TEACHER} WHERE semester_id = ?
            ORDER BY sort_order ASC, id ASC LIMIT 1 OFFSET ?`, [currentSemesterId, safeTeacherIndex]);
      }
    }
    await AppSettingDao.savePointers(exec,
      currentSemesterId === undefined ? 0 : currentSemesterId, currentTeacherId);

    Logger.info(TAG, report.summary());
    return report;
  }

  /**
   * 搬迁旧文件，使导入天然幂等。
   * 必须在事务提交之后调用——事务还没落地就把源文件搬走，一旦回滚就两头皆空。
   */
  static archiveLegacyData(context: common.Context): void {
    const filesDir: string = context.filesDir;
    const archiveDir: string = `${filesDir}/${LEGACY_ARCHIVE_DIR}`;
    try {
      if (!fs.accessSync(archiveDir)) {
        fs.mkdirSync(archiveDir);
      }
    } catch (e) {
      Logger.error(TAG, `创建归档目录失败：${errText(e)}`);
      return;
    }
    const targets: string[] = ['default_setting.json', 'courses', 'schedule', 'Class'];
    for (let i = 0; i < targets.length; i++) {
      const from: string = `${filesDir}/${targets[i]}`;
      const to: string = `${archiveDir}/${targets[i]}`;
      try {
        if (fs.accessSync(from)) {
          fs.renameSync(from, to);
          Logger.info(TAG, `已归档：${targets[i]}`);
        }
      } catch (e) {
        Logger.warn(TAG, `归档 ${targets[i]} 失败：${errText(e)}`);
      }
    }
  }

  // ------------------------------------------------------------- 内部工具

  private static toTemplate(legacy: LegacySchedule, fallbackName: string): ScheduleTemplate {
    const template: ScheduleTemplate = new ScheduleTemplate();
    template.name = legacy.name === undefined ? fallbackName : legacy.name;
    template.duration_time = legacy.duration_time === undefined ? 45 : legacy.duration_time;
    template.is_builtin = template.name === '默认';

    const table: string[][] = legacy.class_time === undefined ? [] : legacy.class_time;
    const slots: ScheduleSlot[] = [];
    for (let i = 0; i < table.length; i++) {
      const pair: string[] = table[i];
      if (pair !== undefined && pair.length >= 2) {
        slots.push(ScheduleSlot.of(i + 1, pair[0], pair[1]));
      }
    }
    if (slots.length === 0) {
      // 旧文件节次表缺失时用标准作息兜底，保证 class_sessions 与 slots 数量一致
      const standard: ScheduleTemplate = ScheduleTemplate.standard(template.name);
      template.slots = standard.slots;
      template.class_sessions = standard.class_sessions;
      return template;
    }
    template.slots = slots;
    template.class_sessions = slots.length;
    return template;
  }

  private static readRaw(path: string): Object | null {
    try {
      if (!fs.accessSync(path)) {
        return null;
      }
      const text: string = fs.readTextSync(path);
      if (text.trim().length === 0) {
        return null;
      }
      return JSON.parse(text) as Object;
    } catch (e) {
      Logger.error(TAG, `读取失败 ${path}：${errText(e)}`);
      return null;
    }
  }

  private static listFiles(dir: string): string[] {
    try {
      if (!fs.accessSync(dir)) {
        return [];
      }
      return fs.listFileSync(dir);
    } catch (e) {
      Logger.warn(TAG, `列举目录失败 ${dir}：${errText(e)}`);
      return [];
    }
  }
}
