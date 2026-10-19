/**
 * 课表分享包（zip）的格式定义：**导出内容怎么造、导入内容怎么解**。
 *
 * 一个包 = 4 个条目（`compressFiles` 的条目名就是各临时文件的 basename）：
 *   manifest.json      —— 权威结构化数据（导入优先读它，无损）
 *   ＜学期名＞.xls      —— 人可读的课程清单表（也能单独拿去「Excel 导入」）
 *   ＜时间表名＞.xls    —— 人可读的作息节次表（同上）
 *   导入说明.txt        —— 告诉用户这个包怎么用
 *
 * 三处刻意的设计：
 *  1. **xls 是"表头驱动的"二维表**，不是定长表格：导入时先**扫描表头行**（认「课程名称+星期」
 *     或「开始时间+结束时间」），再按表头名找列。用户在 Excel 里插了一列、调了顺序、
 *     删掉几行说明，导入照样认；写死行号列号的方案做不到这一点。
 *  2. **不能依赖行号**：`XlsReader.toTable` 会把"整行都是空格"的行直接丢掉（稀疏表铺平的结果），
 *     所以一切定位都必须靠内容，而不是位置。
 *  3. **导入不沿用包里的 course_id（UUID）**：`course.course_id` 是全局 UNIQUE，
 *     同一个包导两次、或包里含库里已有的课程时会直接撞约束。新 UUID 由入库时生成，
 *     去重交给 `UNIQUE(teacher_id, semester_id, course_name, course_type)`。
 */
import { ScheduleSlot, ScheduleTemplate } from '../model/ScheduleTemplate';
import { Semester } from '../model/Semester';
import { Teacher, TeacherCourses } from '../model/Teacher';
import { ClassGroup, Course, TimePeriod } from '../model/Course';
import { DateUtil } from '../common/DateUtil';
import {
  COURSE_TYPES,
  WEEKDAY_LABELS,
  clamp,
  cleanName,
  errText,
  normalizeColor,
  nowMs
} from '../common/Util';

/** 包格式标识（写进 manifest，导入时校验是不是我们的包） */
export const PACKAGE_FORMAT: string = 'wisdomdaily.schedule';
/** 包格式版本 */
export const PACKAGE_VERSION: number = 1;
/** 包内固定条目名 */
export const ENTRY_MANIFEST: string = 'manifest.json';
export const ENTRY_README: string = '导入说明.txt';

/** xls 类型：课程清单表 / 作息节次表 / 教务系统「教师个人课表」网格表 */
export const SHEET_KIND_COURSE: string = 'course';
export const SHEET_KIND_TEMPLATE: string = 'template';
export const SHEET_KIND_GRID: string = 'grid';

/** 表头标记：靠它们判定文件类型与定位表头行 */
const TITLE_COURSE: string = '知途课表';
const TITLE_TEMPLATE: string = '知途时间表';
const COL_COURSE_NAME: string = '课程名称';
const COL_WEEKDAY: string = '星期';
const COL_SLOT_START: string = '开始时间';
const COL_SLOT_END: string = '结束时间';

/** 元信息行的键（前 5 / 前 4 行，导入时读不读到都无所谓） */
const META_SEMESTER: string = '学期';
const META_WEEKS: string = '周数';
const META_START: string = '开始日期';
const META_TEMPLATE: string = '时间表';
const META_TEMPLATE_NAME: string = '名称';
const META_SESSIONS: string = '节数';
const META_DURATION: string = '每节时长';

const COURSE_HEADER: string[] = [
  '教师工号', '教师姓名', '课程名称', '课程类型', '学分', '班级名称', '班级人数',
  '星期', '起始节次', '结束节次', '教室', '周次', '备注'
];

const TEMPLATE_HEADER: string[] = ['节次', '开始时间', '结束时间'];

// --------------------------------------------------------------------------
// manifest.json 的形态（全部可选：旧包 / 手改过的包都得能读）
// --------------------------------------------------------------------------

interface PkgSlotJson {
  session_no?: number;
  start_time?: string;
  end_time?: string;
}

interface PkgTemplateJson {
  name?: string;
  class_sessions?: number;
  duration_time?: number;
  slots?: PkgSlotJson[];
}

interface PkgSemesterJson {
  name?: string;
  total_weeks?: number;
  start_date?: string;
}

interface PkgPeriodJson {
  weekday?: number;
  start_time?: number;
  end_time?: number;
  class_room?: string;
  remark?: string;
  week_nums?: number[];
}

interface PkgGroupJson {
  class_name?: string;
  population?: number;
  color?: string;
  time_periods?: PkgPeriodJson[];
}

interface PkgCourseJson {
  course_name?: string;
  course_type?: string;
  course_score?: number | null;
  course_remark?: string;
  class_groups?: PkgGroupJson[];
}

interface PkgTeacherJson {
  staff_no?: number;
  name?: string;
  department?: string;
  age?: number;
  sex?: string;
  telephone?: string;
  courses?: PkgCourseJson[];
}

interface PkgManifestJson {
  format?: string;
  version?: number;
  exported_at?: number;
  semester?: PkgSemesterJson;
  template?: PkgTemplateJson;
  teachers?: PkgTeacherJson[];
}

/**
 * 解析出来的导入包：已经转成内存对象图，不再依赖 JSON 形态。
 *
 * `createSemester = false` 表示"只导时间表"（Excel 里那张节次表）——
 * 建学期 / 导课程都跳过，只新增一张作息模板。
 */
export class ImportedPackage {
  semesterName: string = '';
  totalWeeks: number = 20;
  startDate: string = '';
  createSemester: boolean = true;
  templateName: string = '';
  /** 带节次的时间表；null = 包里没有（单独导课表 xls），按名字复用或新建标准时间表 */
  template: ScheduleTemplate | null = null;
  teacherCourses: TeacherCourses[] = [];
  /** 来源描述（"压缩包 / Excel 表"），只用于提示文案 */
  source: string = '';
  /** 额外的告知文案（如教务表备注里提到、但网格中没有排课时间的课程）；空串表示没有 */
  notice: string = '';

  teacherCount(): number {
    return this.teacherCourses.length;
  }

  courseCount(): number {
    let total: number = 0;
    for (let i = 0; i < this.teacherCourses.length; i++) {
      total += this.teacherCourses[i].courses.length;
    }
    return total;
  }

  periodCount(): number {
    let total: number = 0;
    for (let i = 0; i < this.teacherCourses.length; i++) {
      total += this.teacherCourses[i].countPeriods();
    }
    return total;
  }

  summary(): string {
    if (!this.createSemester) {
      return `时间表「${this.templateName}」`;
    }
    const base: string = `学期「${this.semesterName}」：${this.teacherCount()} 名教师 / ${this.courseCount()} 门课程`
      + ` / ${this.periodCount()} 个时间段`;
    return this.notice.length > 0 ? `${base}\n${this.notice}` : base;
  }
}

/** 解析结果：ok=false 时 `message` 是给用户看的原因 */
export class PackageParseResult {
  ok: boolean = false;
  kind: string = '';
  message: string = '';
  pkg: ImportedPackage | null = null;

  static fail(message: string): PackageParseResult {
    const result: PackageParseResult = new PackageParseResult();
    result.ok = false;
    result.message = message;
    return result;
  }

  static done(kind: string, pkg: ImportedPackage): PackageParseResult {
    const result: PackageParseResult = new PackageParseResult();
    result.ok = true;
    result.kind = kind;
    result.pkg = pkg;
    return result;
  }
}

export class SchedulePackage {
  // ------------------------------------------------------------------ 导出

  /** 课程清单表（一行 = 一个时间段；同门课多个班/多个时段就是多行） */
  static courseRows(semester: Semester, templateName: string,
    teacherCourses: TeacherCourses[]): string[][] {
    const rows: string[][] = [];
    rows.push([TITLE_COURSE]);
    rows.push([META_SEMESTER, semester.name]);
    rows.push([META_WEEKS, `${semester.total_weeks}`]);
    rows.push([META_START, semester.start_date]);
    rows.push([META_TEMPLATE, templateName]);
    rows.push(COURSE_HEADER.slice());
    for (let i = 0; i < teacherCourses.length; i++) {
      const holder: TeacherCourses = teacherCourses[i];
      for (let j = 0; j < holder.courses.length; j++) {
        const course: Course = holder.courses[j];
        for (let k = 0; k < course.class_groups.length; k++) {
          const group: ClassGroup = course.class_groups[k];
          for (let m = 0; m < group.time_periods.length; m++) {
            const period: TimePeriod = group.time_periods[m];
            rows.push([
              `${holder.teacher.staff_no}`,
              holder.teacher.name,
              course.course_name,
              course.course_type,
              course.course_score === null ? '' : `${course.course_score}`,
              group.class_name,
              `${group.population}`,
              DateUtil.weekdayLabel(period.weekday),
              `${period.start_time}`,
              `${period.end_time}`,
              period.class_room,
              period.week_nums.length === 0 ? '' : DateUtil.formatWeeks(period.week_nums),
              period.remark
            ]);
          }
        }
      }
    }
    return rows;
  }

  /** 作息节次表（一行 = 一节课的起止时间） */
  static templateRows(template: ScheduleTemplate): string[][] {
    const rows: string[][] = [];
    rows.push([TITLE_TEMPLATE]);
    rows.push([META_TEMPLATE_NAME, template.name]);
    rows.push([META_SESSIONS, `${template.class_sessions}`]);
    rows.push([META_DURATION, `${template.duration_time}`]);
    rows.push(TEMPLATE_HEADER.slice());
    for (let i = 0; i < template.slots.length; i++) {
      rows.push([`${i + 1}`, template.slots[i].start_time, template.slots[i].end_time]);
    }
    return rows;
  }

  /**
   * 「课程清单表」空白模板：表头 + **一行示例**。
   *
   * 给用户「导入说明」里下载用：让他照着示例填，比让他猜列名可靠得多。
   * 示例行的星期写「周一」（`parseWeekday` 认 周一 / 星期一 / 1 三种写法）。
   */
  static courseTemplateRows(): string[][] {
    const rows: string[][] = [];
    rows.push([TITLE_COURSE]);
    rows.push([META_SEMESTER, '2026-2027-1']);
    rows.push([META_WEEKS, '20']);
    rows.push([META_START, DateUtil.toDateString(DateUtil.weekMonday(new Date()))]);
    rows.push([META_TEMPLATE, '默认']);
    rows.push(COURSE_HEADER.slice());
    rows.push(['2024***25', '***', '软件需求工程', COURSE_TYPES[0], '3', '24软件1班',
      '34', DateUtil.weekdayLabel(1), '1', '2', '1004', '1-16周', '考试']);
    return rows;
  }

  /**
   * 「作息节次表」空白模板：表头 + 12 节标准作息（08:00 起、每节 45 分钟、课间 10 分钟）。
   *
   * 节数与钟点直接取 `ScheduleTemplate.blank()` 的出厂值，保证与 App 内置作息一致 ——
   * 用户改完节数/时长照样能导回来（导入只按「开始时间 / 结束时间」两列取值）。
   */
  static templateTemplateRows(): string[][] {
    const rows: string[][] = [];
    const template: ScheduleTemplate = ScheduleTemplate.blank('默认');
    rows.push([TITLE_TEMPLATE]);
    rows.push([META_TEMPLATE_NAME, template.name]);
    rows.push([META_SESSIONS, `${template.class_sessions}`]);
    rows.push([META_DURATION, `${template.duration_time}`]);
    rows.push(TEMPLATE_HEADER.slice());
    for (let i = 0; i < template.slots.length; i++) {
      rows.push([`${i + 1}`, template.slots[i].start_time, template.slots[i].end_time]);
    }
    return rows;
  }

  /** manifest.json 正文 */
  static manifestJson(semester: Semester, template: ScheduleTemplate,
    teacherCourses: TeacherCourses[]): string {
    const teachers: PkgTeacherJson[] = [];
    for (let i = 0; i < teacherCourses.length; i++) {
      const holder: TeacherCourses = teacherCourses[i];
      const courses: PkgCourseJson[] = [];
      for (let j = 0; j < holder.courses.length; j++) {
        const course: Course = holder.courses[j];
        const groups: PkgGroupJson[] = [];
        for (let k = 0; k < course.class_groups.length; k++) {
          const group: ClassGroup = course.class_groups[k];
          const periods: PkgPeriodJson[] = [];
          for (let m = 0; m < group.time_periods.length; m++) {
            const period: TimePeriod = group.time_periods[m];
            periods.push({
              weekday: period.weekday,
              start_time: period.start_time,
              end_time: period.end_time,
              class_room: period.class_room,
              remark: period.remark,
              week_nums: period.week_nums.slice()
            });
          }
          groups.push({
            class_name: group.class_name,
            population: group.population,
            color: normalizeColor(group.color),
            time_periods: periods
          });
        }
        courses.push({
          course_name: course.course_name,
          course_type: course.course_type,
          course_score: course.course_score,
          course_remark: course.course_remark,
          class_groups: groups
        });
      }
      teachers.push({
        staff_no: holder.teacher.staff_no,
        name: holder.teacher.name,
        department: holder.teacher.department,
        age: holder.teacher.age,
        sex: holder.teacher.sex,
        telephone: holder.teacher.telephone,
        courses: courses
      });
    }

    const slots: PkgSlotJson[] = [];
    for (let i = 0; i < template.slots.length; i++) {
      slots.push({
        session_no: i + 1,
        start_time: template.slots[i].start_time,
        end_time: template.slots[i].end_time
      });
    }

    const json: PkgManifestJson = {
      format: PACKAGE_FORMAT,
      version: PACKAGE_VERSION,
      exported_at: nowMs(),
      semester: {
        name: semester.name,
        total_weeks: semester.total_weeks,
        start_date: semester.start_date
      },
      template: {
        name: template.name,
        class_sessions: template.class_sessions,
        duration_time: template.duration_time,
        slots: slots
      },
      teachers: teachers
    };
    return JSON.stringify(json);
  }

  /** 包内说明文件：用户拿到 zip 第一眼就该知道怎么用 */
  static readmeText(semesterName: string, templateName: string): string {
    return `每日知途 · 课表分享包\n`
      + `================================\n\n`
      + `学期：${semesterName}\n`
      + `时间表：${templateName}\n`
      + `导出时间：${DateUtil.toDateString(new Date())}\n\n`
      + `包内文件\n`
      + `--------------------------------\n`
      + `1. manifest.json   结构化数据（导入时优先读它，改坏了会导致导入失败）\n`
      + `2. 课程清单表.xls  课程/班级/时间段一览，可用 Excel 打开编辑后单独导入\n`
      + `3. 作息节次表.xls  每节课的起止时间，可用 Excel 打开编辑后单独导入\n\n`
      + `怎么导入\n`
      + `--------------------------------\n`
      + `在 App 首页点顶栏的「下载」图标 → 选「ZIP 压缩包导入」，选中这个 zip 即可。\n`
      + `也可以只把其中某个 .xls 拿出来，用「Excel 文件导入」。\n\n`
      + `想改内容再导回来？\n`
      + `--------------------------------\n`
      + `导入 zip 时以 manifest.json 为准（它才带得全学期起始日、每节时长这些元信息）。\n`
      + `所以**改了 xls 就不要再打回 zip 里**，而是把它单独用「Excel 文件导入」导入。\n\n`
      + `注意事项\n`
      + `--------------------------------\n`
      + `· 导入会新建一个学期 / 时间表，不会覆盖已有数据；同名的会自动加序号。\n`
      + `· 学生名单不在本包内（名单属于班级，跨学期共享）。\n`
      + `· 签到记录不在本包内。\n`;
  }

  // ------------------------------------------------------------------ 导入

  /** 解析 manifest.json */
  static parseManifest(text: string): PackageParseResult {
    if (text.trim().length === 0) {
      return PackageParseResult.fail('manifest.json 是空文件');
    }
    let parsed: PkgManifestJson;
    try {
      parsed = JSON.parse(text) as PkgManifestJson;
    } catch (e) {
      return PackageParseResult.fail(`manifest.json 不是合法的 JSON：${errText(e)}`);
    }

    const pkg: ImportedPackage = new ImportedPackage();
    pkg.source = '压缩包';
    pkg.createSemester = true;

    const sem: PkgSemesterJson | undefined = parsed.semester;
    pkg.semesterName = sem === undefined || sem.name === undefined
      ? '' : cleanName(sem.name, '', 32);
    pkg.totalWeeks = clamp(sem === undefined || sem.total_weeks === undefined
      ? 20 : Math.round(sem.total_weeks), 1, 60);
    pkg.startDate = sem === undefined || sem.start_date === undefined ? '' : sem.start_date.trim();

    const tplJson: PkgTemplateJson | undefined = parsed.template;
    if (tplJson !== undefined) {
      const tpl: ScheduleTemplate = new ScheduleTemplate();
      tpl.is_builtin = false;
      tpl.name = cleanName(tplJson.name === undefined ? '' : tplJson.name, '导入时间表', 32);
      tpl.duration_time = clamp(tplJson.duration_time === undefined
        ? 45 : Math.round(tplJson.duration_time), 1, 300);
      const slotsJson: PkgSlotJson[] = tplJson.slots === undefined ? [] : tplJson.slots;
      const slots: ScheduleSlot[] = [];
      for (let i = 0; i < slotsJson.length; i++) {
        const row: PkgSlotJson = slotsJson[i];
        const start: string = row.start_time === undefined ? '' : row.start_time.trim();
        const end: string = row.end_time === undefined ? '' : row.end_time.trim();
        if (start.length > 0 && end.length > 0) {
          slots.push(ScheduleSlot.of(slots.length + 1, start, end));
        }
      }
      if (slots.length === 0) {
        // 包里没有节次（老包 / 手写的包）：用 12 节标准作息兜底，保证节数与节次表一致
        const standard: ScheduleTemplate = ScheduleTemplate.blank(tpl.name);
        for (let i = 0; i < standard.slots.length; i++) {
          slots.push(ScheduleSlot.of(slots.length + 1, standard.slots[i].start_time, standard.slots[i].end_time));
        }
      }
      tpl.slots = slots;
      tpl.class_sessions = slots.length;
      pkg.template = tpl;
      pkg.templateName = tpl.name;
    }

    const teachersJson: PkgTeacherJson[] = parsed.teachers === undefined ? [] : parsed.teachers;
    const holders: TeacherCourses[] = [];
    for (let i = 0; i < teachersJson.length; i++) {
      const tj: PkgTeacherJson = teachersJson[i];
      const teacher: Teacher = new Teacher();
      teacher.id = 0;
      teacher.staff_no = tj.staff_no === undefined ? 0 : Math.round(tj.staff_no);
      teacher.name = cleanName(tj.name === undefined ? '' : tj.name, `教师${i + 1}`, 32);
      teacher.department = textOrUndefined(tj.department);
      teacher.age = tj.age === undefined ? undefined : Math.round(tj.age);
      teacher.sex = textOrUndefined(tj.sex);
      teacher.telephone = textOrUndefined(tj.telephone);

      const coursesJson: PkgCourseJson[] = tj.courses === undefined ? [] : tj.courses;
      const courses: Course[] = [];
      for (let j = 0; j < coursesJson.length; j++) {
        const course: Course = SchedulePackage.toCourse(coursesJson[j], pkg.totalWeeks)!;
        if (course !== null) {
          courses.push(course);
        }
      }
      holders.push(TeacherCourses.of(teacher, courses));
    }
    pkg.teacherCourses = holders;
    return PackageParseResult.done('manifest', pkg);
  }

  /**
   * 解析一张 .xls 出来的二维表，自动判别是**课程清单表**还是**作息节次表**。
   */
  static parseSheet(table: string[][]): PackageParseResult {
    if (table.length === 0) {
      return PackageParseResult.fail('表格里没读到任何内容（文件可能是空的，或不是 .xls 格式）');
    }
    let headerRow: number = -1;
    let kind: string = '';
    for (let i = 0; i < table.length; i++) {
      const row: string[] = table[i];
      if (hasHeader(row, COL_COURSE_NAME) && hasHeader(row, COL_WEEKDAY)) {
        headerRow = i;
        kind = SHEET_KIND_COURSE;
        break;
      }
      if (hasHeader(row, COL_SLOT_START) && hasHeader(row, COL_SLOT_END)) {
        headerRow = i;
        kind = SHEET_KIND_TEMPLATE;
        break;
      }
      // 教务系统导出的「教师个人课表」：表头行是「星期一…星期日」，没有上面两种列名。
      // 放在最后判，并要求表头行**下方**确实有节次 / 钟点痕迹 —— 否则任何一张
      // 带星期表头的普通表格都会被抢走。
      if (weekdayLabelCount(row) >= 3 && hasGridBody(table, i)) {
        headerRow = i;
        kind = SHEET_KIND_GRID;
        break;
      }
    }
    if (headerRow < 0) {
      return PackageParseResult.fail('没找到表头行：这个文件既不像「课程清单表」（缺 课程名称/星期 列），'
        + '也不像「作息节次表」（缺 开始时间/结束时间 列），\n'
        + '也没认出教务系统的「教师个人课表」（表头需有 星期一…星期日，且格子里有「[04-05]节」这类节次）。\n'
        + '请用 App 导出的模板填写，或直接导入完整 zip。');
    }

    const meta: Map<string, string> = new Map<string, string>();
    for (let i = 0; i < headerRow; i++) {
      const row: string[] = table[i];
      if (row.length >= 2) {
        const key: string = row[0].trim();
        const value: string = row[1].trim();
        if (key.length > 0 && value.length > 0) {
          meta.set(key, value);
        }
      }
    }

    if (kind === SHEET_KIND_GRID) {
      return SchedulePackage.parseTeacherGridSheet(table, headerRow);
    }
    return kind === SHEET_KIND_COURSE
      ? SchedulePackage.parseCourseSheet(table, headerRow, meta)
      : SchedulePackage.parseTemplateSheet(table, headerRow, meta);
  }

  /**
   * 解析教务系统导出的「教师个人课表」网格表。
   *
   * 这张表的形态（各高校大同小异，本工程按重庆工商大学派斯学院的实际导出对齐）：
   *   第 1~2 行：标题 ／ 「学年学期：2026-2027-1   教师：***   学院：…   打印日期：…」
   *   表头行   ：〔空〕· 星期一 · … · 星期日
   *   表体     ：A 列「第一大节\n08:00-10:35」，其余格子里塞课程块，一格多门课用**空行**分隔：
   *                软件需求工程 / 1-12周 / 1004[02-03]节 / 24软件1班:34 / 考试 / 32
   *   末行     ：合并的「备注：…」（列出全部课程，含本表未排时间的）
   *
   * 四处刻意的做法：
   *  1. **块内不按行序取字段，按特征取**（以「周」结尾 = 周次、含 `[..]` = 教室+节次、
   *     含冒号且后半是数字 = 班级:人数、纯数字 = 学时）—— 教务系统换版本调行序时不会静默错位。
   *  2. **同一门课的多个教学班合并成一门课**：表格里「软件需求工程」分别对应 24软件1~5 班，
   *     每班各有自己的星期/节次/周次/教室 —— 恰好就是本工程的「课程 → 班级分组 → 时间段」三层，
   *     所以按课程名聚合、再按班级名聚合，而不是把每个格子拍成一条独立课程。
   *  3. **必须去重**：同一门课的时间段会被教务系统在多个大节行里重复打印（实测
   *     「计算思维与人工智能基础实践 10-11 节」在第五大节的两行里各出现一次），
   *     照单全收会得到两条完全一样的记录。
   *  4. **节次以格子里的 `[04-05]节` 为准**，A 列的大节钟点只用来推导作息节次表
   *     （见 `buildSlotsFromBigSections`）；推不出来就退回 `template = null`，
   *     由仓库按时间表名新建一张标准 12 节表。
   */
  private static parseTeacherGridSheet(table: string[][], headerRow: number): PackageParseResult {
    const header: string[] = table[headerRow];
    const weekdayCols: number[] = [];
    const weekdayNums: number[] = [];
    for (let c = 0; c < header.length; c++) {
      const weekday: number = weekdayOfLabel(header[c]);
      if (weekday > 0) {
        weekdayCols.push(c);
        weekdayNums.push(weekday);
      }
    }

    // A 列 = 「不是星期列、且表体里有内容」的第一列（放「第N大节 + 钟点」）
    let labelCol: number = -1;
    for (let c = 0; c < header.length && labelCol < 0; c++) {
      if (weekdayCols.indexOf(c) >= 0) {
        continue;
      }
      for (let r = headerRow + 1; r < table.length; r++) {
        if (cellAt(table[r], c).length > 0) {
          labelCol = c;
          break;
        }
      }
    }

    // 表体：底部「备注：…」单独留出来（用来提示哪些课没排进网格）
    const body: string[][] = [];
    let remark: string = '';
    for (let r = headerRow + 1; r < table.length; r++) {
      const row: string[] = table[r];
      const joined: string = row.join(' ').trim();
      if (joined.indexOf('备注') >= 0) {
        remark = joined;
        continue;
      }
      if (joined.length === 0) {
        continue;
      }
      body.push(row);
    }

    // 周数上限：只认「以周结尾的片段」里的数字 —— 教室号（1004 / 5511）绝不能被算进来
    let maxWeek: number = 0;
    for (let r = 0; r < body.length; r++) {
      const row: string[] = body[r];
      for (let c = 0; c < row.length; c++) {
        maxWeek = Math.max(maxWeek, maxWeekInText(row[c]));
      }
    }
    maxWeek = Math.max(maxWeek, maxWeekInText(remark));
    const totalWeeks: number = clamp(maxWeek > 0 ? maxWeek : 20, 1, 60);

    const ranges: number[][] = [];
    const entries: GridEntry[] = [];
    for (let r = 0; r < body.length; r++) {
      const row: string[] = body[r];
      ranges.push(labelCol >= 0 ? bigSectionRange(cellAt(row, labelCol)) : []);
      for (let k = 0; k < weekdayCols.length; k++) {
        const text: string = cellAt(row, weekdayCols[k]);
        if (text.length === 0) {
          continue;
        }
        const blocks: string[][] = splitCellBlocks(text);
        for (let b = 0; b < blocks.length; b++) {
          const gridCell: GridCellJson = parseGridBlock(blocks[b]);
          if (gridCell.start_time <= 0 || gridCell.course_name.length === 0) {
            continue;
          }
          entries.push({ weekday: weekdayNums[k], cell: gridCell });
        }
      }
    }
    if (entries.length === 0) {
      return PackageParseResult.fail('认出了教师课表的表头（星期一…星期日），但格子里没解析出课程。\n'
        + '请确认这是教务系统导出的「教师个人课表」，且格子里有「教室[04-05]节」这样的内容。');
    }

    const seen: string[] = [];
    const uniqGrid: GridEntry[] = [];
    for (let i = 0; i < entries.length; i++) {
      const entry: GridEntry = entries[i];
      const key: string = `${entry.cell.course_name}|${entry.cell.class_name}|${entry.weekday}`
        + `|${entry.cell.start_time}-${entry.cell.end_time}|${entry.cell.weeks_text}|${entry.cell.class_room}`;
      if (seen.indexOf(key) >= 0) {
        continue;
      }
      seen.push(key);
      uniqGrid.push(entry);
    }

    const pkg: ImportedPackage = new ImportedPackage();
    pkg.source = '教务教师课表';
    pkg.createSemester = true;
    pkg.totalWeeks = totalWeeks;
    // 教务表不带学期起始日：按"本周一"推定，用户可在学期详情里改
    pkg.startDate = DateUtil.toDateString(DateUtil.weekMonday(new Date()));

    const teacherName: string = cleanName(firstMetaValue(table, headerRow, ['教师', '教师姓名']), '', 32);
    pkg.semesterName = cleanName(firstMetaValue(table, headerRow, ['学年学期', '学期']), '', 32);
    if (pkg.semesterName.length === 0) {
      pkg.semesterName = `导入学期 ${DateUtil.toDateString(new Date())}`;
    }

    const courses: Course[] = [];
    // ⚠️ 变量名**不要**叫 `unique`：es2abc 的 TS 解析器把它当 `unique symbol` 的关键字，
    //    一旦出现在 `<` 右侧（`i < unique.length`）就报 `SyntaxError: Type expected`，
    //    而且报错列号指向 `.`，与真实原因毫无关系。见 .workbuddy/tools/arkcheck.py。
    for (let i = 0; i < uniqGrid.length; i++) {
      const entry: GridEntry = uniqGrid[i];
      const gridCell: GridCellJson = entry.cell;
      let course: Course | undefined = undefined;
      for (let j = 0; j < courses.length; j++) {
        if (courses[j].course_name === gridCell.course_name) {
          course = courses[j];
          break;
        }
      }
      if (course === undefined) {
        course = Course.create(gridCell.course_name, COURSE_TYPES[0]);
        course.course_remark = gridCellRemark(gridCell);
        courses.push(course);
      }
      const className: string = cleanName(gridCell.class_name, '未命名班级', 32);
      let group: ClassGroup | undefined = undefined;
      for (let j = 0; j < course.class_groups.length; j++) {
        if (course.class_groups[j].class_name === className) {
          group = course.class_groups[j];
          break;
        }
      }
      if (group === undefined) {
        group = new ClassGroup();
        group.class_name = className;
        group.population = gridCell.population;
        course.class_groups.push(group);
      } else if (group.population <= 0 && gridCell.population > 0) {
        group.population = gridCell.population;
      }
      const period: TimePeriod = new TimePeriod();
      period.weekday = entry.weekday;
      period.start_time = gridCell.start_time;
      period.end_time = Math.max(gridCell.end_time, gridCell.start_time);
      period.class_room = gridCell.class_room;
      period.remark = gridCell.assess;
      period.week_nums = parseWeeks(gridCell.weeks_text, totalWeeks);
      group.time_periods.push(period);
    }

    const teacher: Teacher = new Teacher();
    teacher.staff_no = 0;
    teacher.name = cleanName(teacherName, '导入教师', 32);
    pkg.teacherCourses = [TeacherCourses.of(teacher, courses)];

    const slots: ScheduleSlot[] = buildSlotsFromBigSections(ranges);
    if (slots.length > 0) {
      const template: ScheduleTemplate = new ScheduleTemplate();
      const base: string = pkg.semesterName.length > 0 ? pkg.semesterName : teacher.name;
      template.name = cleanName(`${base}作息`, '教务作息', 32);
      template.class_sessions = slots.length;
      template.duration_time = LESSON_MINUTES;
      template.slots = slots;
      pkg.template = template;
      pkg.templateName = template.name;
    }

    const missing: string[] = missingCoursesInRemark(remark, courses);
    if (missing.length > 0) {
      pkg.notice = `备注里还提到 ${missing.length} 门课在表格中没有排课时间：${missing.join('、')}`;
    }
    return PackageParseResult.done(SHEET_KIND_GRID, pkg);
  }

  // ---------------------------------------------------------- 表格 → 对象

  private static parseCourseSheet(table: string[][], headerRow: number,
    meta: Map<string, string>): PackageParseResult {
    const header: string[] = table[headerRow];
    const pkg: ImportedPackage = new ImportedPackage();
    pkg.source = 'Excel 表';
    pkg.createSemester = true;

    const nameText: string | undefined = meta.get(META_SEMESTER);
    pkg.semesterName = cleanName(nameText === undefined ? '' : nameText, '', 32);
    const weeksText: string | undefined = meta.get(META_WEEKS);
    pkg.totalWeeks = clamp(parseInt(weeksText === undefined ? '' : weeksText, 10) || 20, 1, 60);
    const startText: string | undefined = meta.get(META_START);
    pkg.startDate = startText === undefined ? '' : startText.trim();
    const tplText: string | undefined = meta.get(META_TEMPLATE);
    pkg.templateName = cleanName(tplText === undefined ? '' : tplText, '导入时间表', 32);

    // 先按「教师工号 + 教师姓名」把行归到教师下，再按「课程名称 + 类型」归课程
    const holders: TeacherCourses[] = [];
    const teacherKey: string[] = [];
    let rowCount: number = 0;

    for (let i = headerRow + 1; i < table.length; i++) {
      const row: string[] = table[i];
      const courseName: string = cell(row, header, COL_COURSE_NAME);
      if (courseName.length === 0) {
        continue;
      }
      const teacherName: string = cleanName(cell(row, header, '教师姓名'), '导入教师', 32);
      const staffText: string = cell(row, header, '教师工号');
      const staffNo: number = parseInt(staffText, 10) || 0;

      let holderIndex: number = -1;
      for (let k = 0; k < teacherKey.length; k++) {
        if (teacherKey[k] === `${staffNo}#${teacherName}`) {
          holderIndex = k;
          break;
        }
      }
      if (holderIndex < 0) {
        const teacher: Teacher = new Teacher();
        teacher.staff_no = staffNo;
        teacher.name = teacherName;
        holders.push(TeacherCourses.of(teacher, []));
        teacherKey.push(`${staffNo}#${teacherName}`);
        holderIndex = holders.length - 1;
      }
      const holder: TeacherCourses = holders[holderIndex];

      const courseType: string = sanitizeType(cell(row, header, '课程类型'));
      const scoreText: string = cell(row, header, '学分');
      let courseIndex: number = -1;
      for (let k = 0; k < holder.courses.length; k++) {
        if (holder.courses[k].course_name === courseName
          && holder.courses[k].course_type === courseType) {
          courseIndex = k;
          break;
        }
      }
      if (courseIndex < 0) {
        const course: Course = new Course();
        course.course_id = '';
        course.course_name = courseName;
        course.course_type = courseType;
        course.course_score = parseScore(scoreText);
        course.course_remark = cell(row, header, '备注');
        holder.courses.push(course);
        courseIndex = holder.courses.length - 1;
      }
      const course: Course = holder.courses[courseIndex];

      const className: string = cleanName(cell(row, header, '班级名称'), '未命名班级', 32);
      let groupIndex: number = -1;
      for (let k = 0; k < course.class_groups.length; k++) {
        if (course.class_groups[k].class_name === className) {
          groupIndex = k;
          break;
        }
      }
      if (groupIndex < 0) {
        const group: ClassGroup = new ClassGroup();
        group.class_id = '';
        group.class_name = className;
        group.population = Math.max(0, parseInt(cell(row, header, '班级人数'), 10) || 0);
        course.class_groups.push(group);
        groupIndex = course.class_groups.length - 1;
      }
      const group: ClassGroup = course.class_groups[groupIndex];

      const period: TimePeriod = new TimePeriod();
      period.weekday = parseWeekday(cell(row, header, COL_WEEKDAY));
      const start: number = clamp(parseInt(cell(row, header, '起始节次'), 10) || 1, 1, 24);
      const end: number = clamp(parseInt(cell(row, header, '结束节次'), 10) || start, start, 24);
      period.start_time = start;
      period.end_time = end;
      period.class_room = cell(row, header, '教室');
      period.week_nums = parseWeeks(cell(row, header, '周次'), pkg.totalWeeks);
      group.time_periods.push(period);
      rowCount++;
    }

    // 班级颜色与人数：同一门课的不同班各自一份，颜色由库里默认色兜底
    pkg.teacherCourses = holders;
    if (pkg.semesterName.length === 0) {
      pkg.semesterName = `导入学期 ${DateUtil.toDateString(new Date())}`;
    }
    if (!isDateText(pkg.startDate)) {
      pkg.startDate = DateUtil.toDateString(DateUtil.weekMonday(DateUtil.today()));
    }
    if (rowCount === 0) {
      return PackageParseResult.fail('表头认出来了，但一行课程数据都没读到：'
        + '请检查「课程名称」列是否为空。');
    }
    return PackageParseResult.done(SHEET_KIND_COURSE, pkg);
  }

  private static parseTemplateSheet(table: string[][], headerRow: number,
    meta: Map<string, string>): PackageParseResult {
    const header: string[] = table[headerRow];
    const pkg: ImportedPackage = new ImportedPackage();
    pkg.source = 'Excel 表';
    pkg.createSemester = false;

    const nameText: string | undefined = meta.get(META_TEMPLATE_NAME);
    const tpl: ScheduleTemplate = new ScheduleTemplate();
    tpl.is_builtin = false;
    tpl.name = cleanName(nameText === undefined ? '' : nameText, '导入时间表', 32);
    const durationText: string | undefined = meta.get(META_DURATION);
    tpl.duration_time = clamp(parseInt(durationText === undefined ? '' : durationText, 10) || 45, 1, 300);

    const slots: ScheduleSlot[] = [];
    for (let i = headerRow + 1; i < table.length; i++) {
      const row: string[] = table[i];
      const start: string = cell(row, header, COL_SLOT_START);
      const end: string = cell(row, header, COL_SLOT_END);
      if (start.length === 0 && end.length === 0) {
        continue;
      }
      if (start.length === 0 || end.length === 0) {
        return PackageParseResult.fail(`第 ${i + 1} 行的开始/结束时间只填了一半，`
          + '请补全或删掉这一行。');
      }
      if (!isHm(start) || !isHm(end)) {
        return PackageParseResult.fail(`第 ${i + 1} 行的时间「${start} / ${end}」不是 HH:mm 格式。`);
      }
      slots.push(ScheduleSlot.of(slots.length + 1, start, end));
    }
    if (slots.length === 0) {
      return PackageParseResult.fail('这张节次表里一节课都没有读到（开始时间/结束时间列是空的）');
    }
    tpl.slots = slots;
    tpl.class_sessions = slots.length;
    pkg.template = tpl;
    pkg.templateName = tpl.name;
    return PackageParseResult.done(SHEET_KIND_TEMPLATE, pkg);
  }

  private static toCourse(json: PkgCourseJson, maxWeek: number): Course | null {
    const name: string = cleanName(json.course_name, '', 64);
    if (name.length === 0) {
      return null;
    }
    const course: Course = new Course();
    course.course_id = '';
    course.course_name = name;
    course.course_type = sanitizeType(json.course_type);
    course.course_score = json.course_score === undefined || json.course_score === null
      ? null : parseScore(`${json.course_score}`);
    course.course_remark = json.course_remark === undefined ? '' : json.course_remark;

    const groupsJson: PkgGroupJson[] = json.class_groups === undefined ? [] : json.class_groups;
    for (let i = 0; i < groupsJson.length; i++) {
      const gj: PkgGroupJson = groupsJson[i];
      const group: ClassGroup = new ClassGroup();
      group.class_id = '';
      group.class_name = cleanName(gj.class_name, '未命名班级', 32);
      group.population = gj.population === undefined
        ? 0 : Math.max(0, Math.round(gj.population));
      group.color = normalizeColor(gj.color);
      const periodsJson: PkgPeriodJson[] = gj.time_periods === undefined ? [] : gj.time_periods;
      for (let j = 0; j < periodsJson.length; j++) {
        const pj: PkgPeriodJson = periodsJson[j];
        const period: TimePeriod = new TimePeriod();
        period.weekday = clamp(pj.weekday === undefined ? 1 : Math.round(pj.weekday), 1, 7);
        const start: number = clamp(pj.start_time === undefined ? 1 : Math.round(pj.start_time), 1, 24);
        period.start_time = start;
        period.end_time = clamp(pj.end_time === undefined ? start : Math.round(pj.end_time), start, 24);
        period.class_room = pj.class_room === undefined ? '' : pj.class_room;
        period.remark = pj.remark === undefined ? '' : pj.remark;
        period.week_nums = normalizeWeekNums(pj.week_nums, maxWeek);
        group.time_periods.push(period);
      }
      course.class_groups.push(group);
    }
    return course;
  }
}

// --------------------------------------------------------------------------
// 解析小工具（文件内私有）
// --------------------------------------------------------------------------

function hasHeader(row: string[], label: string): boolean {
  for (let i = 0; i < row.length; i++) {
    if (row[i].trim() === label) {
      return true;
    }
  }
  return false;
}

/** 按**表头名**取列（而不是写死列号）：用户在 Excel 里调过顺序也照样认 */
function cell(row: string[], header: string[], label: string): string {
  for (let i = 0; i < header.length; i++) {
    if (header[i].trim() === label) {
      return i < row.length ? row[i].trim() : '';
    }
  }
  return '';
}

function textOrUndefined(text: string | undefined): string | undefined {
  if (text === undefined) {
    return undefined;
  }
  const trimmed: string = text.trim();
  return trimmed.length === 0 ? undefined : trimmed;
}

function sanitizeType(raw: string | undefined): string {
  const text: string = raw === undefined ? '' : raw.trim();
  return COURSE_TYPES.indexOf(text) >= 0 ? text : COURSE_TYPES[0];
}

/** 学分：空/非法/越界都当「未填」（库里有 CHECK `> 0 AND <= 30`，写 0 会被拦） */
function parseScore(raw: string): number | null {
  const text: string = raw.trim();
  if (text.length === 0) {
    return null;
  }
  const value: number = parseFloat(text);
  if (isNaN(value) || value <= 0 || value > 30) {
    return null;
  }
  return value;
}

/** `HH:mm` 形态校验（不用正则：保持与 DateUtil.hmToMinutes 同一套"手写解析"口径） */
function isHm(text: string): boolean {
  const colon: number = text.indexOf(':');
  if (colon <= 0 || colon >= text.length - 1) {
    return false;
  }
  const hour: number = parseInt(text.substring(0, colon), 10);
  const minute: number = parseInt(text.substring(colon + 1), 10);
  if (isNaN(hour) || isNaN(minute)) {
    return false;
  }
  return hour >= 0 && hour <= 23 && minute >= 0 && minute <= 59;
}

/** `YYYY-MM-DD` 形态校验 */
function isDateText(text: string): boolean {
  if (text.length !== 10 || text.charAt(4) !== '-' || text.charAt(7) !== '-') {
    return false;
  }
  return !isNaN(parseInt(text.substring(0, 4), 10))
    && !isNaN(parseInt(text.substring(5, 7), 10))
    && !isNaN(parseInt(text.substring(8, 10), 10));
}

/** 「周一」/「星期一」/「1」都能读 */
function parseWeekday(raw: string): number {
  const text: string = raw.trim();
  for (let i = 0; i < WEEKDAY_LABELS.length; i++) {
    const short: string = WEEKDAY_LABELS[i];
    if (text === short || text === `星期${short.charAt(1)}` || text === `${i + 1}`) {
      return i + 1;
    }
  }
  return 1;
}

/**
 * 周次文本 → 周次数组。认 `1-8周` / `1,3,5周` / `1-4,9-12周` /
 * 逗号/顿号/波浪线等分隔的变体；空串按"全周"处理（用户把这一格删了多半是想要全周）。
 */
function parseWeeks(raw: string, maxWeek: number): number[] {
  const text: string = raw.replace(/周/g, '')
    .replace(/[，、;；\s]/g, ',')
    .replace(/[~～－—]/g, '-')
    .trim();
  if (text.length === 0) {
    return normalizeWeekNums([], maxWeek);
  }
  const out: number[] = [];
  const segments: string[] = text.split(',');
  for (let i = 0; i < segments.length; i++) {
    const segment: string = segments[i].trim();
    if (segment.length === 0) {
      continue;
    }
    const dash: number = segment.indexOf('-');
    if (dash < 0) {
      const single: number = parseInt(segment, 10);
      if (!isNaN(single)) {
        out.push(single);
      }
      continue;
    }
    const from: number = parseInt(segment.substring(0, dash), 10);
    const to: number = parseInt(segment.substring(dash + 1), 10);
    if (isNaN(from) || isNaN(to)) {
      continue;
    }
    const low: number = Math.min(from, to);
    const high: number = Math.max(from, to);
    for (let w = low; w <= high; w++) {
      out.push(w);
    }
  }
  return normalizeWeekNums(out, maxWeek);
}

/** 去重 + 夹到 1..maxWeek + 升序；空数组表示"没填"，落库时按全周补 */
function normalizeWeekNums(weeks: number[] | undefined, maxWeek: number): number[] {
  const limit: number = clamp(maxWeek, 1, 60);
  if (weeks === undefined || weeks.length === 0) {
    const all: number[] = [];
    for (let w = 1; w <= limit; w++) {
      all.push(w);
    }
    return all;
  }
  const kept: number[] = [];
  for (let i = 0; i < weeks.length; i++) {
    const week: number = Math.round(weeks[i]);
    if (week >= 1 && week <= limit && kept.indexOf(week) < 0) {
      kept.push(week);
    }
  }
  kept.sort((a: number, b: number) => a - b);
  return kept.length === 0 ? normalizeWeekNums(undefined, limit) : kept;
}

// --------------------------------------------------------------------------
// 教务系统「教师个人课表」网格表的解析辅助
// --------------------------------------------------------------------------

/** 一节课的标准时长与课间；大节时长 = 45×n + 10×(n-1)，据此反推每个大节含几小节 */
const LESSON_MINUTES: number = 45;
const LESSON_GAP_MINUTES: number = 10;

/** 一个格子里的课程块（教务表把同一格塞多门课，用空行分隔） */
interface GridCellJson {
  course_name: string;
  weeks_text: string;
  class_room: string;
  start_time: number;
  end_time: number;
  class_name: string;
  population: number;
  assess: string;
  hours: string;
}

/** 课程块 + 它所在的星期几 */
interface GridEntry {
  weekday: number;
  cell: GridCellJson;
}

/** 取某行某列（越界返回空串） */
function cellAt(row: string[], col: number): string {
  return col >= 0 && col < row.length ? row[col].trim() : '';
}

/** 「星期一」/「周一」/「礼拜天」→ 1..7；认不出返回 0 */
function weekdayOfLabel(text: string): number {
  const token: string = text.trim();
  if (token.length < 2) {
    return 0;
  }
  const head: string = token.substring(0, 1);
  if (head !== '周' && head !== '星' && head !== '礼') {
    return 0;
  }
  const index: number = '一二三四五六日天'.indexOf(token.substring(token.length - 1));
  if (index < 0) {
    return 0;
  }
  // 「日」「天」都指周日
  return index >= 6 ? 7 : index + 1;
}

/** 一行里「星期X」的个数（≥3 才把这一行当教务表的表头） */
function weekdayLabelCount(row: string[]): number {
  let count: number = 0;
  for (let i = 0; i < row.length; i++) {
    if (weekdayOfLabel(row[i]) > 0) {
      count++;
    }
  }
  return count;
}

/** 表头行**下方**是否真有节次 / 钟点痕迹（防止把普通"星期表"抢认成教务课表） */
function hasGridBody(table: string[][], headerRow: number): boolean {
  for (let r = headerRow + 1; r < table.length; r++) {
    const row: string[] = table[r];
    for (let c = 0; c < row.length; c++) {
      const text: string = row[c];
      if (text.indexOf('大节') >= 0) {
        return true;
      }
      if (text.indexOf('[') >= 0 && text.indexOf('节') >= 0) {
        return true;
      }
    }
  }
  return false;
}

/**
 * 文本里「以周结尾的片段」中的最大数字；没有则 0。
 *
 * 为什么要限定"以周结尾"：格子里的教室号（1004 / 5511）和节次（02-03）也是数字，
 * 全文扫数字会把教室号当成周数（"5511 周"），直接把学期拉成 5511 周。
 */
function maxWeekInText(text: string): number {
  let best: number = 0;
  let token: string = '';
  for (let i = 0; i <= text.length; i++) {
    const ch: string = i < text.length ? text[i] : ' ';
    if (ch === ' ' || ch === '\n' || ch === '\r' || ch === '\t' || ch === '　'
      || ch === ';' || ch === '；' || ch === ',' || ch === '，' || ch === '、') {
      if (token.length > 0 && token.substring(token.length - 1) === '周') {
        best = Math.max(best, maxDigitsIn(token));
      }
      token = '';
      continue;
    }
    token += ch;
  }
  return best;
}

/** 一串字符里的最大连续数字 */
function maxDigitsIn(text: string): number {
  let best: number = 0;
  let digits: string = '';
  for (let i = 0; i <= text.length; i++) {
    const ch: string = i < text.length ? text[i] : '-';
    if (ch >= '0' && ch <= '9') {
      digits += ch;
      continue;
    }
    if (digits.length > 0) {
      best = Math.max(best, parseInt(digits, 10) || 0);
      digits = '';
    }
  }
  return best;
}

/** 整串都是数字 */
function isDigits(text: string): boolean {
  if (text.length === 0) {
    return false;
  }
  for (let i = 0; i < text.length; i++) {
    const ch: string = text[i];
    if (ch < '0' || ch > '9') {
      return false;
    }
  }
  return true;
}

/**
 * 严格的 `HH:mm`：必须是「两位数字 + 冒号 + 两位数字」。
 *
 * 为什么不能用上面那个 `isHm`：它内部走 `parseInt`，而 **`parseInt` 会跳过前导空白**，
 * 所以跨换行符的窗口 `"\n10:5"` 会被它判成合法并把值算成 `10:05` —— 实测把第二大节的
 * 10:55 读成 10:05、第三大节的 14:10 读成 14:01，推出的作息表整段偏掉。
 */
function isStrictHm(text: string): boolean {
  if (text.length !== 5 || text.substring(2, 3) !== ':') {
    return false;
  }
  return isDigits(text.substring(0, 2)) && isDigits(text.substring(3, 5));
}

/** A 列「第一大节\n08:00-10:35」→ [起分钟, 止分钟]；认不出返回空数组 */
function bigSectionRange(label: string): number[] {
  const minutes: number[] = [];
  for (let i = 0; i + 5 <= label.length; i++) {
    const slice: string = label.substring(i, i + 5);
    if (isStrictHm(slice)) {
      minutes.push(DateUtil.hmToMinutes(slice));
      i += 4;
    }
  }
  if (minutes.length >= 2) {
    return [minutes[0], minutes[1]];
  }
  if (minutes.length === 1) {
    return [minutes[0], minutes[0] + LESSON_MINUTES];
  }
  return [];
}

/**
 * 由「大节钟点」推出逐节作息表。
 *
 * 大节时长满足 `45×n + 10×(n-1)`（n = 该大节含几个小节、课间固定 10 分钟），
 * 所以 `n = round((时长 + 10) / 55)`；再按 45 分钟一节、10 分钟课间依次排出钟点。
 * 认不出钟点的行跳过，但不打断顺序累加。实测本校五个大节（08:00-10:35 / 10:55-12:35 /
 * 14:10-15:50 / 16:10-17:50 / 19:10-21:45 分三段）恰好推出 12 节，与教务的小节号完全对上。
 */
function buildSlotsFromBigSections(ranges: number[][]): ScheduleSlot[] {
  const slots: ScheduleSlot[] = [];
  for (let i = 0; i < ranges.length; i++) {
    const range: number[] = ranges[i];
    if (range.length < 2) {
      continue;
    }
    const duration: number = range[1] - range[0];
    if (duration < LESSON_MINUTES) {
      continue;
    }
    const count: number = clamp(
      Math.round((duration + LESSON_GAP_MINUTES) / (LESSON_MINUTES + LESSON_GAP_MINUTES)), 1, 6);
    let cursor: number = range[0];
    for (let k = 0; k < count; k++) {
      const end: number = cursor + LESSON_MINUTES;
      if (end > range[1]) {
        break;
      }
      slots.push(ScheduleSlot.of(slots.length + 1,
        DateUtil.hmFromMinutes(cursor), DateUtil.hmFromMinutes(end)));
      cursor = end + LESSON_GAP_MINUTES;
    }
  }
  return slots;
}

/** 把格子文本按**空行**切成若干个课程块 */
function splitCellBlocks(text: string): string[][] {
  const blocks: string[][] = [];
  const lines: string[] = text.split('\r\n').join('\n').split('\r').join('\n').split('\n');
  let current: string[] = [];
  for (let i = 0; i < lines.length; i++) {
    const line: string = lines[i].trim();
    if (line.length === 0) {
      if (current.length > 0) {
        blocks.push(current);
        current = [];
      }
      continue;
    }
    current.push(line);
  }
  if (current.length > 0) {
    blocks.push(current);
  }
  return blocks;
}

/**
 * 一个课程块 → 结构化字段。
 *
 * **不按行序取字段**，而是逐行判断它像什么：含 `[..]` = 教室 + 节次、以「周」结尾 = 周次、
 * 含冒号且后半是数字 = 班级:人数、纯数字 = 学时、其余 = 考核方式。
 * 教务系统调整打印行序时，这样比"第 3 行一定是教室"稳得多。
 */
function parseGridBlock(lines: string[]): GridCellJson {
  const result: GridCellJson = {
    course_name: lines.length > 0 ? lines[0] : '',
    weeks_text: '',
    class_room: '',
    start_time: 0,
    end_time: 0,
    class_name: '',
    population: 0,
    assess: '',
    hours: ''
  };
  for (let i = 1; i < lines.length; i++) {
    const line: string = lines[i];
    const open: number = line.indexOf('[');
    const close: number = line.indexOf(']');
    if (open > 0 && close > open) {
      const span: string = line.substring(open + 1, close).trim();
      const dash: number = span.indexOf('-');
      const from: number = parseInt(dash > 0 ? span.substring(0, dash) : span, 10);
      const to: number = dash > 0 ? parseInt(span.substring(dash + 1), 10) : from;
      if (!isNaN(from) && from > 0) {
        result.start_time = from;
        result.end_time = isNaN(to) || to < from ? from : to;
        result.class_room = line.substring(0, open).trim();
        continue;
      }
    }
    if (line.substring(line.length - 1) === '周') {
      result.weeks_text = line;
      continue;
    }
    const colon: number = lastColonIndex(line);
    if (colon > 0 && colon < line.length - 1) {
      const name: string = line.substring(0, colon).trim();
      const count: number = parseInt(line.substring(colon + 1).trim(), 10);
      if (name.length > 0 && !isNaN(count) && count > 0) {
        result.class_name = name;
        result.population = Math.round(count);
        continue;
      }
    }
    if (line === '考试' || line === '考查' || line === '考核') {
      result.assess = line;
      continue;
    }
    if (isDigits(line)) {
      result.hours = line;
    }
  }
  return result;
}

/** 最后一个冒号（半角或全角）的位置；没有返回 -1 */
function lastColonIndex(text: string): number {
  return Math.max(text.lastIndexOf(':'), text.lastIndexOf('：'));
}

/** 表头行以上的「键：值」；也兼容「A 列键 / B 列值」的 meta 两格形态 */
function firstMetaValue(table: string[][], headerRow: number, keys: string[]): string {
  for (let r = 0; r < headerRow; r++) {
    const row: string[] = table[r];
    for (let c = 0; c < row.length; c++) {
      const text: string = row[c].trim();
      for (let k = 0; k < keys.length; k++) {
        const value: string = valueAfterLabel(text, keys[k]);
        if (value.length > 0) {
          return value;
        }
      }
    }
    if (row.length >= 2) {
      const key: string = row[0].trim();
      const value: string = row[1].trim();
      for (let k = 0; k < keys.length; k++) {
        if (value.length > 0 && (key === keys[k] || key === `${keys[k]}：` || key === `${keys[k]}:`)) {
          return value;
        }
      }
    }
  }
  return '';
}

/** 从「教师：***」里取出「***」；标签后必须紧跟冒号，值取到空白 / 逗号为止 */
function valueAfterLabel(text: string, label: string): string {
  const at: number = text.indexOf(label);
  if (at < 0) {
    return '';
  }
  let rest: string = text.substring(at + label.length);
  if (rest.length === 0) {
    return '';
  }
  const head: string = rest.substring(0, 1);
  if (head !== '：' && head !== ':') {
    return '';
  }
  rest = rest.substring(1);
  let value: string = '';
  for (let i = 0; i < rest.length; i++) {
    const ch: string = rest[i];
    if (ch === ' ' || ch === '\t' || ch === '　' || ch === ',' || ch === '，') {
      break;
    }
    value += ch;
  }
  return value.trim();
}

/** 考核方式 + 学时 → 课程备注 */
function gridCellRemark(gridCell: GridCellJson): string {
  const parts: string[] = [];
  if (gridCell.assess.length > 0) {
    parts.push(gridCell.assess);
  }
  if (gridCell.hours.length > 0) {
    parts.push(`${gridCell.hours} 学时`);
  }
  return parts.join(' · ');
}

/** 备注行里列出、但没有排进网格的课程名（导完提示一句，省得用户以为漏导了） */
function missingCoursesInRemark(remark: string, courses: Course[]): string[] {
  const missing: string[] = [];
  if (remark.length === 0) {
    return missing;
  }
  const at: number = firstColonIndex(remark);
  const text: string = at >= 0 ? remark.substring(at + 1) : remark;
  const segments: string[] = text.split(';').join('；').split('；');
  for (let i = 0; i < segments.length; i++) {
    const segment: string = segments[i].trim();
    if (segment.length === 0) {
      continue;
    }
    const name: string = firstToken(segment);
    if (name.length === 0 || missing.indexOf(name) >= 0) {
      continue;
    }
    let found: boolean = false;
    for (let j = 0; j < courses.length; j++) {
      if (courses[j].course_name === name) {
        found = true;
        break;
      }
    }
    if (!found) {
      missing.push(name);
    }
  }
  return missing;
}

/** 第一个冒号（半角或全角）的位置；没有返回 -1 */
function firstColonIndex(text: string): number {
  const full: number = text.indexOf('：');
  const half: number = text.indexOf(':');
  if (full < 0) {
    return half;
  }
  if (half < 0) {
    return full;
  }
  return Math.min(full, half);
}

/** 取第一个空白前的片段 */
function firstToken(text: string): string {
  for (let i = 0; i < text.length; i++) {
    const ch: string = text[i];
    if (ch === ' ' || ch === '\t' || ch === '　') {
      return text.substring(0, i);
    }
  }
  return text;
}
