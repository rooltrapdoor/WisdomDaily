import { common } from '@kit.AbilityKit';
import { DbExecutor } from '../db/DbExecutor';
import { ScheduleDb } from '../db/ScheduleDb';
import { DB_VERSION, Tables } from '../db/TableSchema';
import { DaoSupport } from '../dao/DaoSupport';
import { SemesterDao } from '../dao/SemesterDao';
import { ScheduleTemplateDao } from '../dao/ScheduleTemplateDao';
import { TeacherDao } from '../dao/TeacherDao';
import { CourseDao } from '../dao/CourseDao';
import { ClassInfoDao } from '../dao/ClassInfoDao';
import { TimePeriodDao } from '../dao/TimePeriodDao';
import { StudentDao } from '../dao/StudentDao';
import { AppSettingDao } from '../dao/AppSettingDao';
import { LessonDao } from '../dao/LessonDao';
import { AttendanceDao } from '../dao/AttendanceDao';
import { AppSetting } from '../model/AppSetting';
import { Semester, SemesterCourses } from '../model/Semester';
import { Teacher, TeacherCourses } from '../model/Teacher';
import { ClassGroup, Course, TimePeriod } from '../model/Course';
import { ScheduleSlot, ScheduleTemplate } from '../model/ScheduleTemplate';
import { ClassInfo, ClassRoster, Student } from '../model/Student';
import {
  AppSettingRow,
  AttendanceExportRow,
  AttendanceRow,
  ClassGroupRow,
  ClassPopulationRow,
  CourseRow,
  DanglingGroupRow,
  LessonRow,
  OrphanClassRow,
  PeriodWeekRow,
  SemesterRow,
  ScheduleSlotRow,
  ScheduleTemplateRow,
  StudentRow,
  TeacherRow,
  TimePeriodRow
} from '../model/Rows';
import { DateUtil } from '../common/DateUtil';
import { ConflictDetector, ConflictHit } from '../service/ConflictDetector';
import { SeedData } from './SeedData';
import { ImportReport, LegacyJsonImporter } from './LegacyJsonImporter';
import { RosterImportResult } from './RosterImporter';
import { ImportedPackage } from './SchedulePackage';
import { Logger } from '../common/Logger';
import { errText, cleanName, clamp } from '../common/Util';

const TAG: string = 'Repository';

/** 自愈时再也找不到原班名的分组，落到这个班名上（已存在同名档案则复用） */
const DANGLING_CLASS_FALLBACK: string = '未命名班级';

/** 冷启动一次拿全的轻量工作台数据（不含学期课表正文） */
export class Workspace {
  setting: AppSetting = AppSetting.fresh();
  semesters: Semester[] = [];
  templates: ScheduleTemplate[] = [];
}

/** 一次整学期同步的结果，用于日志与自检 */
export class SyncReport {
  semesterId: number = 0;
  coursesInserted: number = 0;
  coursesUpdated: number = 0;
  coursesDeleted: number = 0;
  groupsUpserted: number = 0;
  groupsDeleted: number = 0;
  periodsInserted: number = 0;
  periodsUpdated: number = 0;
  periodsDeleted: number = 0;
  weeksWritten: number = 0;
  durationMs: number = 0;

  summary(): string {
    return `学期#${this.semesterId} 同步完成 ${this.durationMs}ms：`
      + `课程 +${this.coursesInserted}/~${this.coursesUpdated}/-${this.coursesDeleted}，`
      + `班级分组 ${this.groupsUpserted}/-${this.groupsDeleted}，`
      + `时间段 +${this.periodsInserted}/~${this.periodsUpdated}/-${this.periodsDeleted}，`
      + `周次 ${this.weeksWritten}`;
  }
}

/**
 * 一次写完"课程 + 班级分组 + 时间段 + 周次"的结果。
 *
 * `saved=false` 有两种情形，都必须让界面能区分：
 *  - `conflicts` 非空 → 时间冲突，**整次保存已整体回滚，库里一行都没写**；
 *  - `message` 非空且无冲突 → 其它失败原因（校验 / 参数 / 数据库异常）。
 */
export class CourseGraphSaveResult {
  saved: boolean = false;
  courseRowId: number = 0;
  conflicts: ConflictHit[] = [];
  message: string = '';
}

/**
 * 事务内的"冲突 → 整体回滚"信号。
 *
 * 继承 `Error` 不是语义需要，而是 ArkTS 的硬性约束（只允许 throw Error 及其子类）。
 * 它担当的不是"异常"，而是回滚开关：由 `saveCourseGraph` 在事务回调里抛出，
 * `ScheduleDb.runInTransaction` 捕获前先回滚，再原样抛回给 `saveCourseGraph` 转成返回值。
 */
class CourseConflictSignal extends Error {
  conflicts: ConflictHit[] = [];

  constructor(conflicts: ConflictHit[]) {
    super('course-conflict');
    this.conflicts = conflicts;
  }
}

/**
 * 事务提交成功后**才**回填到调用方对象上的主键。
 *
 * 为什么不在事务里直接写回 `group.id` / `period.id`：事务可能因为冲突整体回滚，
 * 一旦回滚，内存里就握着"库里并不存在的主键"；用户点"强制保存"重试时，
 * `update` 会更新 0 行（时间段永远插不进去）→ 又造出一门"看不见的课"。
 */
class GroupIdAssignment {
  groupIndex: number = 0;
  groupId: number = 0;
  classId: string = '';
  periodIds: number[] = [];
}

/**
 * 导入课表分享包的结果（见 `importSchedulePackage`）。
 *
 * 分成这么多计数字段而不是只回一个"成功"，是因为导入后用户最想确认的正是
 * "进来几个教师 / 几门课 / 几个时间段" —— 数字对不上就说明包本身不完整，
 * 而不是导入失败。
 */
export class PackageImportReport {
  semesterId: number = 0;
  semesterName: string = '';
  /** 新学期里的第一位教师（导入后把当前指向切过去用；0 = 包里没有教师） */
  firstTeacherId: number = 0;
  templateId: number = 0;
  templateName: string = '';
  /** 时间表是新建的还是复用了同名的 */
  templateCreated: boolean = false;
  /** 是否建了学期（只导时间表时为 false） */
  createdSemester: boolean = false;
  teachers: number = 0;
  courses: number = 0;
  groups: number = 0;
  periods: number = 0;
  weeks: number = 0;

  summary(): string {
    if (!this.createdSemester) {
      return `已导入时间表「${this.templateName}」`
        + `${this.templateCreated ? '' : '（复用同名的已有时间表）'}`;
    }
    return `已导入学期「${this.semesterName}」：`
      + `${this.teachers} 名教师 / ${this.courses} 门课程 / ${this.groups} 个班级分组`
      + ` / ${this.periods} 个时间段（${this.weeks} 条周次）\n`
      + `时间表「${this.templateName}」${this.templateCreated ? '（新建）' : '（复用同名）'}`;
  }
}

/** 数据库体检指标 */
export class DbStats {
  /**
   * 当前 schema 版本（`TableSchema.DB_VERSION`）。
   *
   * 放进体检指标而不是让页面写死一个 "v4"：那个字面量 2026-09-22 时已经落后两版
   * （库到 v6、界面还写着 v4），而"关于页显示的版本号不对"这种问题没人会主动发现。
   */
  dbVersion: number = 0;
  semesters: number = 0;
  templates: number = 0;
  teachers: number = 0;
  courses: number = 0;
  classes: number = 0;
  periods: number = 0;
  weeks: number = 0;
  students: number = 0;
  /** 签到记录总行数（v6 起） */
  attendances: number = 0;
}

/**
 * 仓储层：业务语义的唯一入口。
 *
 * 分层职责：
 *   DAO        —— 一张表（或一组强归属表）的 SQL 与行映射
 *   Repository —— 事务边界、对象图组装、跨表一致性、冲突策略
 *
 * 写入策略（这是相较旧 JSON 实现最本质的变化）：
 *  1. **增量写**（默认）：界面上改一个教室、一个周次就是一条 UPDATE，不碰其它行；
 *  2. **整学期同步**（兜底）：`syncSemesterCourses` 把内存对象图当"期望态"，
 *     与库做差量（upsert 新增与变更、删除多余行），用于导入 / 恢复 / 生命周期保存，
 *     全部包在一个事务里——不会出现旧版"TRUNC 之后写到一半进程被杀、整个学期归零"。
 */
export class ScheduleRepository {
  private static instance: ScheduleRepository | null = null;
  private db: ScheduleDb = ScheduleDb.getInstance();
  /** 初始化只跑一次：页面与 Ability 都可能并发调用 init */
  private initTask: Promise<void> | null = null;
  /**
   * 是否有一次初始化正在执行中。
   *
   * 存在的理由：判断"要不要重新初始化"时不能只看 `initTask === null`，
   * 否则"连接被 close 之后"页面与 Ability 先后调用 init 会各自发起一次 doInit，
   * 首启播种 / 旧数据导入就有被执行两遍的风险。用这个标志把并发调用合流。
   */
  private initRunning: boolean = false;
  /**
   * "启动维护"（播种 / 旧数据导入 / 指针修复 / 坏行自愈）是否已经做过。
   *
   * 存在的理由：`init()` 现在多了一个只读用途的入口（卡片进程传 `allowWrites = false`，
   * 跳过全部写路径）。如果卡片先初始化过一次，之后应用进程来写时若只按
   * "连接健在"就复用，那一次**该做的维护就被永久跳过了** —— 表现是全新安装
   * 先加卡片、再打开应用，界面里一个学期都没有。所以复用条件里必须带上这个标志。
   */
  private maintenanceDone: boolean = false;

  private constructor() {
  }

  static getInstance(): ScheduleRepository {
    if (ScheduleRepository.instance === null) {
      ScheduleRepository.instance = new ScheduleRepository();
    }
    return ScheduleRepository.instance;
  }

  // ------------------------------------------------------------ 生命周期

  /**
   * 打开数据库 → 首启初始化。幂等：并发调用只会真正执行一次。
   *
   * 两条互斥路径，顺序很重要：
   *  1. 沙箱里还有旧版 JSON（老用户升级）→ 空库时先做一次性导入，再把旧文件归档；
   *  2. 全新安装 → 写入出厂种子数据。
   * 导入必须在事务提交成功**之后**才归档旧文件，否则回滚后新旧两头空。
   *
   * **连接可以被关闭，所以"初始化过"不等于"现在能用"**：
   * `EntryAbility.onDestroy()` 会 `close()` 掉数据库连接（`ScheduleDb.store` 置空），
   * 但 Ability/页面是同一个进程里的常驻单例，`initTask` 那条 Promise 早已 resolve。
   * 早先这里只判断 `initTask === null`，于是 close 之后 init() 变成空操作，
   * 后续每一次读写都打在已关闭的连接上（`ScheduleDb.executor()` 直接抛"尚未初始化"）——
   * 页面表现就是"退出后台再进来，所有课程都不显示了"。
   * 因此这里必须同时看两件事：**有没有初始化过** + **连接是否还活着**。
   *
   * @param allowWrites 这次需不需要写权限。桌面卡片（`EntryFormAbility`）传 `false`：
   *                    只要读得到数据，播种 / 导入 / 自愈一概不做 —— 卡片的定时刷新
   *                    本来就不该对库做任何写操作（详见 `ScheduleDb` 的类注释）。
   *                    默认 `true`。
   */
  async init(context: common.Context, allowWrites: boolean = true): Promise<void> {
    // ① 连接健在、且该做的启动维护也做完了：直接复用，绝大多数调用走这条
    if (this.initTask !== null && this.db.isReady && (this.maintenanceDone || !allowWrites)) {
      return;
    }
    // ② 有一次初始化在路上：先等它落地，再判断要不要补做维护（避免重复建库/播种）
    if (this.initTask !== null && this.initRunning) {
      try {
        await this.initTask;
      } catch (e) {
        Logger.warn(TAG, `等待在途初始化失败（下一轮会重试）：${errText(e)}`);
      }
      if (this.db.isReady && (this.maintenanceDone || !allowWrites)) {
        return;
      }
    }
    // ③ 没初始化过，或连接已被 close() 释放（含上次初始化失败的兜底重试）→ 真正打开一次
    this.initRunning = true;
    const task: Promise<void> = this.doInit(context, allowWrites);
    this.initTask = task.then(() => {
      // 只有"可写"的那一次才算把播种 / 迁移 / 自愈做完（只读用途什么都没做）
      this.maintenanceDone = this.maintenanceDone || allowWrites;
      this.initRunning = false;
    }, (e: Object) => {
      this.initRunning = false;
      Logger.error(TAG, `数据库初始化失败：${errText(e)}`);
      throw e as Error;
    });
    await this.initTask;
  }

  private async doInit(context: common.Context, allowWrites: boolean): Promise<void> {
    await this.db.init(context, allowWrites);

    if (!allowWrites) {
      // 只读用途（卡片进程）：读得到就读，绝不进任何写路径
      Logger.info(TAG, '只读用途：跳过播种 / 旧数据导入 / 指针修复 / 坏行自愈');
      return;
    }

    const probe: DbExecutor = this.db.executor();
    const hasLegacy: boolean = LegacyJsonImporter.hasLegacyData(context);

    if (hasLegacy && !(await SeedData.isSeeded(probe))) {
      await this.db.runInTransaction(async (exec: DbExecutor) => {
        await LegacyJsonImporter.run(context, exec);
        await AppSettingDao.ensureRow(exec);
        await AppSettingDao.repairPointers(exec);
        await ScheduleRepository.repairDanglingClassGroups(exec);
      });
      // 事务已提交，这时才搬走旧文件
      LegacyJsonImporter.archiveLegacyData(context);
      Logger.info(TAG, '旧版 JSON 数据已迁移至关系库，原文件已归档');
      return;
    }

    if (hasLegacy) {
      Logger.info(TAG, '检测到旧版数据但库里已有内容，跳过一次性导入（避免重复写入）');
    }

    // 稳态零写：先用**只读**语句探一遍，确认"确实有需要修的东西"再开写事务。
    //
    // 为什么在意这一次写入：下面的 ensureRow / repairPointers 哪怕一行都没改，
    // 也要先进一个写事务、先拿一次写锁。而桌面卡片进程同时也在用这个库，
    // 两边的写锁一撞，后来者就抛 `14800024`（SQLite: The database file is locked）——
    // 用户看到的是"课表加载失败 + 整页空白"。稳态下把这次写事务省掉，竞争窗口就没了。
    const seeded: boolean = await SeedData.isSeeded(probe);
    const settingDirty: boolean = await AppSettingDao.needsRepair(probe);
    const dangling: number = (await CourseDao.listDanglingGroups(probe)).length;
    if (seeded && !settingDirty && dangling === 0) {
      Logger.info(TAG, '数据库已就绪，本轮无需写入');
      return;
    }

    await this.db.runInTransaction(async (exec: DbExecutor) => {
      await SeedData.seedIfEmpty(exec);
      await AppSettingDao.ensureRow(exec);
      await AppSettingDao.repairPointers(exec);
      await ScheduleRepository.repairDanglingClassGroups(exec);
    });
  }

  /**
   * 启动自愈：补齐"班级分组指向不存在的班级档案"的坏行。
   *
   * 为什么需要它：`saveCourseGraph` 曾经把新班的 `class_id` 只写进自己的局部变量，
   * 没有在落库前交给 DAO（详见 `CourseDao.upsertGroup` 的注释），于是库里留下了
   * `class_group.class_id = ''` 的分组。这类坏行有三重表现，且彼此对不上号：
   *   - 课表（`v_lesson` 六表 JOIN，含 `class_info`）整组被吃掉 → 课不显示，重启也不显示；
   *   - 学生管理（`class_group JOIN class_info`）数不到 → 班级列表少一个；
   *   - 课表管理只数 `course` / `class_group` 两张表 → 课程和分组**都还在**。
   * 用户看到的就是"管理里有两门课，课表里只有一门"。改写入路径只能保证**以后**不再产生，
   * 已经落库的坏行必须在这里补回来，否则用户只能自己重填班名。
   *
   * 修复策略（只动有依据的行，绝不瞎猜）：
   *  1. 先找坏行：`class_id` 在 `class_info` 里找不到（空串也算）；
   *  2. 再找候选：没有任何分组引用的"孤儿"班级档案 —— 坏行和它本来是同一次保存写进去的，
   *     所以按 `created_at` 与所属课程 `created_at` 的时间差取最近的那个配对，
   *     同时排除该课程已经在用的班（避免撞 `UNIQUE(course_id, class_id)`）；
   *  3. 连孤儿都没有，就落到 `未命名班级`。宁可让它在课表上显示出来由用户改名，
   *     也不要继续整组静默消失 —— 看不见的数据是修不了的。
   *
   * 幂等：没有坏行时只是两条 `NOT EXISTS` 查询，直接返回。
   */
  private static async repairDanglingClassGroups(exec: DbExecutor): Promise<number> {
    const broken: DanglingGroupRow[] = await CourseDao.listDanglingGroups(exec);
    if (broken.length === 0) {
      return 0;
    }
    const orphans: OrphanClassRow[] = await ClassInfoDao.listUnreferenced(exec);
    let repaired: number = 0;
    for (let i = 0; i < broken.length; i++) {
      const row: DanglingGroupRow = broken[i];
      const used: string[] = await ScheduleRepository.classIdsOfCourse(exec, row.course_id);
      let bestIndex: number = -1;
      let bestGap: number = 0;
      for (let j = 0; j < orphans.length; j++) {
        if (used.indexOf(orphans[j].class_id) >= 0) {
          continue;
        }
        const gap: number = Math.abs(orphans[j].created_at - row.course_created_at);
        if (bestIndex < 0 || gap < bestGap) {
          bestIndex = j;
          bestGap = gap;
        }
      }
      let classId: string = '';
      if (bestIndex >= 0) {
        classId = orphans[bestIndex].class_id;
        orphans.splice(bestIndex, 1);
      } else {
        classId = await ClassInfoDao.ensureByName(exec, DANGLING_CLASS_FALLBACK);
      }
      await CourseDao.bindGroupClass(exec, row.id, classId);
      repaired++;
      Logger.warn(TAG, `数据自愈：班级分组 #${row.id}（课程 #${row.course_id}，`
        + `原 class_id='${row.class_id}'）的班级关联已补上 → ${classId}`);
    }
    return repaired;
  }

  isReady(): boolean {
    return this.db.isReady;
  }

  /** 手动触发一次旧数据导入（设置页的"导入旧版数据"入口）。幂等：没有旧数据时直接返回空报告 */
  async importLegacyData(context: common.Context): Promise<ImportReport> {
    if (!LegacyJsonImporter.hasLegacyData(context)) {
      return new ImportReport();
    }
    const report: ImportReport = await this.db.runInTransaction(async (exec: DbExecutor) => {
      const result: ImportReport = await LegacyJsonImporter.run(context, exec);
      await AppSettingDao.ensureRow(exec);
      await AppSettingDao.repairPointers(exec);
      await ScheduleRepository.repairDanglingClassGroups(exec);
      return result;
    });
    LegacyJsonImporter.archiveLegacyData(context);
    return report;
  }

  // -------------------------------------------------------------- 读取

  /** 冷启动读：设置 + 学期列表 + 作息模板列表（3 组查询，都很轻） */
  async loadWorkspace(): Promise<Workspace> {
    const exec: DbExecutor = this.db.executor();
    const space: Workspace = new Workspace();

    const semesterRows: SemesterRow[] = await SemesterDao.listAll(exec);
    space.semesters = semesterRows.map((row: SemesterRow) => Semester.fromRow(row));
    space.templates = await this.loadTemplates(exec);

    const settingRow = await AppSettingDao.load(exec);
    space.setting = settingRow === undefined ? AppSetting.fresh() : AppSetting.fromRow(settingRow);
    return space;
  }

  private async loadTemplates(exec: DbExecutor): Promise<ScheduleTemplate[]> {
    const templateRows: ScheduleTemplateRow[] = await ScheduleTemplateDao.listAll(exec);
    const slotRows: ScheduleSlotRow[] = await ScheduleTemplateDao.listAllSlots(exec);
    const byTemplateId: Map<number, ScheduleTemplate> = new Map<number, ScheduleTemplate>();
    const templates: ScheduleTemplate[] = [];
    for (let i = 0; i < templateRows.length; i++) {
      const tpl: ScheduleTemplate = ScheduleTemplate.fromRow(templateRows[i], []);
      byTemplateId.set(tpl.id, tpl);
      templates.push(tpl);
    }
    // 一次读回所有节次，再按 schedule_id 分发，避免"每个模板查一次"的 N+1
    for (let i = 0; i < slotRows.length; i++) {
      const slotRow: ScheduleSlotRow = slotRows[i];
      const tpl: ScheduleTemplate | undefined = byTemplateId.get(slotRow.schedule_id);
      if (tpl !== undefined) {
        tpl.slots.push(ScheduleSlot.of(slotRow.session_no, slotRow.start_time, slotRow.end_time));
      }
    }
    return templates;
  }

  /**
   * 加载一个学期的完整对象图（启动课表页时调用）。
   *
   * 5 条查询搞定，不做按周展开：
   *   semester / teacher / course / class_group / time_period+period_week，
   * 然后在内存里按外键关系拼装。刻意不用 v_lesson 视图——视图把周次展开，
   * 一个 20 周的时间段会变成 20 行，整学期能膨胀到几万行，启动得不偿失。
   */
  async loadSemesterCourses(semesterId: number): Promise<SemesterCourses> {
    const exec: DbExecutor = this.db.executor();
    const semesterRow: SemesterRow | undefined = await SemesterDao.findById(exec, semesterId);
    if (semesterRow === undefined) {
      throw new Error(`学期不存在：${semesterId}`);
    }
    const semester: Semester = Semester.fromRow(semesterRow);
    const maxWeek: number = semester.total_weeks;

    const teacherRows: TeacherRow[] = await TeacherDao.listBySemester(exec, semesterId);
    const courseRows: CourseRow[] = await CourseDao.listBySemester(exec, semesterId);
    const groupRows: ClassGroupRow[] = await CourseDao.listGroupsBySemester(exec, semesterId);
    const periodRows: TimePeriodRow[] = await TimePeriodDao.listBySemester(exec, semesterId);
    const weekRows: PeriodWeekRow[] = await TimePeriodDao.listWeeksBySemester(exec, semesterId, maxWeek);

    // 周次按时间段归组
    const weeksByPeriod: Map<number, number[]> = new Map<number, number[]>();
    for (let i = 0; i < weekRows.length; i++) {
      const periodId: number = weekRows[i].time_period_id;
      const bucket: number[] | undefined = weeksByPeriod.get(periodId);
      if (bucket === undefined) {
        weeksByPeriod.set(periodId, [weekRows[i].week_no]);
      } else {
        bucket.push(weekRows[i].week_no);
      }
    }

    // 时间段按班级分组归组
    const periodsByGroup: Map<number, TimePeriod[]> = new Map<number, TimePeriod[]>();
    for (let i = 0; i < periodRows.length; i++) {
      const row: TimePeriodRow = periodRows[i];
      const weeksFound: number[] | undefined = weeksByPeriod.get(row.id);
      const weeks: number[] = weeksFound === undefined ? [] : weeksFound;
      const period: TimePeriod = TimePeriod.fromRow(row, weeks, maxWeek);
      const bucket: TimePeriod[] | undefined = periodsByGroup.get(row.class_group_id);
      if (bucket === undefined) {
        periodsByGroup.set(row.class_group_id, [period]);
      } else {
        bucket.push(period);
      }
    }

    // 班级分组按课程归组
    const groupsByCourse: Map<number, ClassGroup[]> = new Map<number, ClassGroup[]>();
    for (let i = 0; i < groupRows.length; i++) {
      const row: ClassGroupRow = groupRows[i];
      const periodsFound: TimePeriod[] | undefined = periodsByGroup.get(row.id);
      const periods: TimePeriod[] = periodsFound === undefined ? [] : periodsFound;
      const group: ClassGroup = ClassGroup.fromRow(row, periods);
      const bucket: ClassGroup[] | undefined = groupsByCourse.get(row.course_id);
      if (bucket === undefined) {
        groupsByCourse.set(row.course_id, [group]);
      } else {
        bucket.push(group);
      }
    }

    // 课程按教师归组
    const coursesByTeacher: Map<number, Course[]> = new Map<number, Course[]>();
    for (let i = 0; i < courseRows.length; i++) {
      const row: CourseRow = courseRows[i];
      const groupsFound: ClassGroup[] | undefined = groupsByCourse.get(row.id);
      const groups: ClassGroup[] = groupsFound === undefined ? [] : groupsFound;
      const course: Course = Course.fromRow(row, groups);
      const bucket: Course[] | undefined = coursesByTeacher.get(row.teacher_id);
      if (bucket === undefined) {
        coursesByTeacher.set(row.teacher_id, [course]);
      } else {
        bucket.push(course);
      }
    }

    const teacherCourses: TeacherCourses[] = teacherRows.map((row: TeacherRow) => {
      const coursesFound: Course[] | undefined = coursesByTeacher.get(row.id);
      const courses: Course[] = coursesFound === undefined ? [] : coursesFound;
      return TeacherCourses.of(Teacher.fromRow(row), courses);
    });

    Logger.info(TAG, `学期「${semester.name}」加载完成：`
      + `${teacherRows.length} 教师 / ${courseRows.length} 课程 / ${groupRows.length} 班级分组 / ${periodRows.length} 时间段`);

    return SemesterCourses.of(semester, teacherCourses);
  }

  async loadRoster(classId: string): Promise<ClassRoster> {
    const exec: DbExecutor = this.db.executor();
    const infoRow = await ClassInfoDao.findById(exec, classId);
    const info: ClassInfo = infoRow === undefined
      ? new ClassInfo()
      : ClassInfo.fromRow(infoRow);
    const studentRows: StudentRow[] = await StudentDao.listByClass(exec, classId);
    return ClassRoster.of(info, studentRows.map((row: StudentRow) => Student.fromRow(row)));
  }

  /**
   * 待办页「学习」清单：今天的课程（按当前指针的学期 + 教师，今天所在周、今天星期）。
   *
   * 只读、无副作用；指针未设 / 学期未开始 / 已结束都返回空数组（不猜、不回退到第 1 周）。
   */
  async loadTodayLessons(): Promise<LessonRow[]> {
    const exec: DbExecutor = this.db.executor();
    const settingRow: AppSettingRow | undefined = await AppSettingDao.load(exec);
    if (settingRow === undefined || settingRow.semester_id === undefined || settingRow.semester_id <= 0) {
      return [];
    }
    const teacherId: number = settingRow.teacher_id === undefined ? 0 : settingRow.teacher_id;
    const semesterRow: SemesterRow | undefined = await SemesterDao.findById(exec, settingRow.semester_id);
    if (semesterRow === undefined) {
      return [];
    }
    const semester: Semester = Semester.fromRow(semesterRow);
    const start: Date = semester.startDate();
    const today: Date = DateUtil.today();
    if (!DateUtil.isDateInSemester(start, today, semester.total_weeks)) {
      return [];
    }
    const week: number = DateUtil.getWeekNumber(start, today, semester.total_weeks);
    const weekday: number = DateUtil.toDbWeekday(today.getDay());
    const rows: LessonRow[] = teacherId > 0
      ? await LessonDao.weekOfTeacher(exec, semester.id, teacherId, week)
      : await LessonDao.weekOfSemester(exec, semester.id, week);
    const out: LessonRow[] = [];
    for (let i = 0; i < rows.length; i++) {
      if (rows[i].weekday === weekday) {
        out.push(rows[i]);
      }
    }
    return out;
  }

  /** 只取"某教师某周"的课（切周时用它做定向刷新，不必重载整学期） */
  /**
   * 当前指针学期所用时间表的节次钟点（待办页课程行显示 "08:00-09:40" 用）。
   * 无学期指针 / 模板缺失时回退第一张模板；全空返回空数组（课程行就不显示钟点）。
   */
  async loadCurrentSlots(): Promise<ScheduleSlot[]> {
    const exec: DbExecutor = this.db.executor();
    const templates: ScheduleTemplate[] = await this.loadTemplates(exec);
    if (templates.length === 0) {
      return [];
    }
    const settingRow: AppSettingRow | undefined = await AppSettingDao.load(exec);
    if (settingRow !== undefined && settingRow.semester_id !== undefined && settingRow.semester_id > 0) {
      const semesterRow: SemesterRow | undefined = await SemesterDao.findById(exec, settingRow.semester_id);
      if (semesterRow !== undefined && semesterRow.schedule_id! > 0) {
        for (let i = 0; i < templates.length; i++) {
          if (templates[i].id === semesterRow.schedule_id) {
            return templates[i].slots;
          }
        }
      }
    }
    return templates[0].slots;
  }

  /** 当前指针教师的姓名（无指针 / 未找到返回空串；待办面板问候语用） */
  async loadCurrentTeacherName(): Promise<string> {
    const exec: DbExecutor = this.db.executor();
    const settingRow: AppSettingRow | undefined = await AppSettingDao.load(exec);
    if (settingRow === undefined || settingRow.teacher_id === undefined || settingRow.teacher_id <= 0) {
      return '';
    }
    const row: TeacherRow | undefined = await TeacherDao.findById(exec, settingRow.teacher_id);
    return row === undefined ? '' : row.name;
  }

  async loadWeekLessons(semesterId: number, teacherId: number, week: number): Promise<LessonRow[]> {
    return LessonDao.weekOfTeacher(this.db.executor(), semesterId, teacherId, week);
  }

  // ------------------------------------------------ 诊断（空课表自证，只读）

  /** 诊断：某教师在某学期的全部周课次行数（不限周次） */
  async countLessonsOfTeacher(semesterId: number, teacherId: number): Promise<number> {
    return LessonDao.countOfTeacher(this.db.executor(), semesterId, teacherId);
  }

  /** 诊断：某教师实际有课的周次列表（升序去重） */
  async weeksOfTeacher(semesterId: number, teacherId: number): Promise<number[]> {
    return LessonDao.weeksOfTeacher(this.db.executor(), semesterId, teacherId);
  }

  /** 诊断：某学期全部教师的课次行数（不限周次） */
  async countLessonsOfSemester(semesterId: number): Promise<number> {
    return LessonDao.countOfSemester(this.db.executor(), semesterId);
  }

  // ------------------------------------------------------ 当前指向的维护

  async savePointers(semesterId: number, teacherId: number): Promise<void> {
    await this.db.runInTransaction(async (exec: DbExecutor) => {
      await AppSettingDao.savePointers(exec, semesterId, teacherId);
    });
  }

  async setThemeMode(themeMode: number): Promise<void> {
    await this.db.runInTransaction(async (exec: DbExecutor) => {
      await AppSettingDao.setThemeMode(exec, themeMode);
    });
  }

  /** 保存界面颜色（主题色 / 今日高亮色），供"我的 → 界面设置"的拾色器调用 */
  async saveUiColors(themeColor: string, todayColor: string): Promise<void> {
    await this.db.runInTransaction(async (exec: DbExecutor) => {
      await AppSettingDao.setUiColors(exec, themeColor, todayColor);
    });
  }

  /**
   * 保存上课提醒设置（是否提醒次日 / 是否提前提醒 / 提前几分钟），供"我的 → 上课提醒"调用。
   *
   * 走**非事务**执行器：这里是"一条幂等 `INSERT OR IGNORE` + 一条 `UPDATE`"，
   * 本身就是单语句原子写，包一个显式事务除了多持一次写锁没有任何收益。
   * 桌面卡片与应用共用同一个库文件，写锁持得越短，`14800024`（database file is locked）
   * 的机会越小 —— 设置类写（本方法、`saveUiColors`、`setThemeMode`）都属于这种
   * "一句话就能写完"的写入，能用 `executor()` 就不用 `runInTransaction`。
   */
  async saveReminderSettings(nextDay: boolean, ahead: boolean, aheadMinutes: number): Promise<void> {
    await AppSettingDao.setReminders(this.db.executor(), nextDay, ahead, aheadMinutes);
  }

  /**
   * 首启录入机主（姓名 + 教师工号），之后系统默认以此为默认教师信息。
   *
   * 一个事务里做三件事：
   *  1. 写 app_setting 的 owner 两列（跨学期持久的"我是谁"）；
   *  2. 在当前学期登记该教师——若同工号已存在则认领并同步改名；
   *     若学期里只有首启种子教师且尚未挂任何课，则直接把种子改成机主本人（不产生第二个教师）；
   *  3. 把 app_setting.teacher_id 指向他，立即成为当前默认教师。
   */
  async saveOwnerProfile(name: string, staffNo: number): Promise<void> {
    const clean: string = cleanName(name, '未命名教师');
    await this.db.runInTransaction(async (exec: DbExecutor) => {
      await AppSettingDao.setOwnerProfile(exec, clean, staffNo);

      const settingRow = await AppSettingDao.load(exec);
      const semesterId: number =
        settingRow === undefined || settingRow.semester_id === undefined ? 0 : settingRow.semester_id;
      if (semesterId <= 0) {
        Logger.info(TAG, `机主已保存（${staffNo} ${clean}），当前无学期可登记`);
        return;
      }

      const teacherRows: TeacherRow[] = await TeacherDao.listBySemester(exec, semesterId);
      let teacherId: number = 0;

      // 同工号已存在 → 认领，改名同步
      for (let i = 0; i < teacherRows.length; i++) {
        if (teacherRows[i].staff_no === staffNo) {
          const teacher: Teacher = Teacher.fromRow(teacherRows[i]);
          teacher.name = clean;
          await TeacherDao.update(exec, teacher);
          teacherId = teacher.id;
          break;
        }
      }

      // 只有首启种子教师且还没挂任何课 → 直接改成机主本人
      if (teacherId === 0 && teacherRows.length === 1) {
        const courseCount: number = await CourseDao.countBySemester(exec, semesterId);
        if (courseCount === 0) {
          const seed: Teacher = Teacher.fromRow(teacherRows[0]);
          seed.name = clean;
          seed.staff_no = staffNo;
          await TeacherDao.update(exec, seed);
          teacherId = seed.id;
        }
      }

      // 都不是 → 新登记一位
      if (teacherId === 0) {
        const teacher: Teacher = Teacher.create(clean, staffNo);
        const order: number = await TeacherDao.countBySemester(exec, semesterId);
        teacherId = await TeacherDao.insert(exec, teacher, semesterId, order);
      }

      await AppSettingDao.savePointers(exec, semesterId, teacherId);
      Logger.info(TAG, `机主教师已登记并指向：${staffNo} ${clean}（teacher=${teacherId}）`);
    });
  }

  // ------------------------------------------------------------ 学期管理

  async createSemester(name: string, templateId: number, totalWeeks: number,
    startDate: string): Promise<Semester> {
    return this.db.runInTransaction(async (exec: DbExecutor) => {
      const clean: string = cleanName(name, '新建学期');
      const nextOrder: number = await DaoSupport.scalarNumber(exec,
        `SELECT COALESCE(MAX(sort_order), -1) + 1 AS v FROM ${Tables.SEMESTER}`, []);
      const semester: Semester = new Semester();
      semester.name = clean;
      semester.total_weeks = totalWeeks;
      semester.start_date = startDate;
      semester.schedule_id = templateId;
      const newId: number = await SemesterDao.insert(exec, semester, nextOrder);
      semester.id = newId;
      semester.sort_order = nextOrder;

      // 新学期自动带出机主（默认教师），避免"新建学期后还得手动建教师"
      const settingRow = await AppSettingDao.load(exec);
      if (settingRow !== undefined && settingRow.owner_staff_no !== undefined && settingRow.owner_staff_no > 0) {
        const ownerName: string = settingRow.owner_name === undefined ? '默认教师' : settingRow.owner_name;
        const owner: Teacher = Teacher.create(ownerName, settingRow.owner_staff_no);
        await TeacherDao.insert(exec, owner, newId, 0);
      }
      return semester;
    });
  }

  /** 学期改名 / 改周数 / 改起始日 / 换作息模板：一条 UPDATE，不会再产生"设置与数据不同步" */
  async updateSemester(semester: Semester): Promise<void> {
    await this.db.runInTransaction(async (exec: DbExecutor) => {
      await SemesterDao.update(exec, semester);
    });
  }

  async deleteSemester(semesterId: number): Promise<boolean> {
    return this.db.runInTransaction(async (exec: DbExecutor) => {
      const count: number = await SemesterDao.count(exec);
      if (count <= 1) {
        // 至少保留一个学期，与旧版 popSemester 的保护一致
        return false;
      }
      await SemesterDao.deleteCascade(exec, semesterId);
      await AttendanceDao.pruneOrphans(exec);
      await AppSettingDao.repairPointers(exec);
      return true;
    });
  }

  // ------------------------------------------------------------ 课程编辑

  /**
   * **整体保存一门课的完整对象图**（课程 + 班级分组 + 时间段 + 周次），所有写入在同一个事务里。
   *
   * 为什么必须整体写（这是"新增课程后课表里看不到"的根因）：
   * 课表是按 `v_lesson` 视图渲染的，它要求 course / teacher / class_group / class_info /
   * time_period / period_week 六张表的行**都存在**。而 `insertCourse` / `upsertClassGroup` /
   * `savePeriod` 各自开事务，冲突时 `savePeriod` 直接跳过写入 —— 于是库里留下
   * "课程有了、班级有了、时间段没有"的空壳：`课程管理` 里数得到，课表上永远不显示，
   * 重启也照样不显示（docs/01 AC-11 明确禁止这种半截数据）。
   *
   * 现在的语义：
   *  - 先把表单里删掉的分组 / 时间段删掉，再写课程 → 分组 → 时间段 → 周次，全程一个事务；
   *  - 任何一段冲突且 `force=false` → 抛 `CourseConflictSignal` → **整体回滚**，一行都不落库，
   *    冲突事实通过返回值交给界面；用户改完时间可以原样重试；
   *  - 主键只在提交成功后回填到 `course` / `groups`，回滚时内存不留假 id。
   */
  async saveCourseGraph(semesterId: number, teacherId: number, course: Course, groups: ClassGroup[],
    removedGroupIds: number[], removedPeriodIds: number[], maxWeek: number,
    force: boolean = false): Promise<CourseGraphSaveResult> {
    const result: CourseGraphSaveResult = new CourseGraphSaveResult();
    if (semesterId <= 0 || teacherId <= 0) {
      result.message = '参数异常：学期或教师未指定，未写入任何数据';
      Logger.warn(TAG, result.message);
      return result;
    }
    if (groups.length === 0) {
      result.message = '请至少添加一个班级分组';
      return result;
    }

    const assignments: GroupIdAssignment[] = [];
    let courseRowId: number = 0;
    try {
      courseRowId = await this.db.runInTransaction(async (exec: DbExecutor) => {
        // 1) 清理表单里被删除的分组 / 时间段（缺行删除是空操作）
        for (let i = 0; i < removedGroupIds.length; i++) {
          await CourseDao.deleteGroup(exec, removedGroupIds[i]);
        }
        for (let i = 0; i < removedPeriodIds.length; i++) {
          await TimePeriodDao.deleteById(exec, removedPeriodIds[i]);
        }
        // 被删掉的分组/时段带着它们的点名记录一起走（见 AttendanceDao.pruneOrphans 的注释）
        await AttendanceDao.pruneOrphans(exec);

        // 2) 课程自身：有主键走更新，否则插入
        let rowId: number = course.id;
        if (rowId > 0) {
          await CourseDao.update(exec, course);
        } else {
          const nextOrder: number = await DaoSupport.scalarNumber(exec,
            `SELECT COALESCE(MAX(sort_order), -1) + 1 AS v FROM ${Tables.COURSE}
              WHERE semester_id = ? AND teacher_id = ?`, [semesterId, teacherId]);
          rowId = await CourseDao.insert(exec, course, semesterId, teacherId, nextOrder);
        }

        // 3) 班级分组 → 时间段 → 周次
        const seenClassIds: string[] = [];
        for (let gi = 0; gi < groups.length; gi++) {
          const group: ClassGroup = groups[gi];
          const assignment: GroupIdAssignment = new GroupIdAssignment();
          assignment.groupIndex = gi;

          // 班名 → 稳定主键；已有主键则把（可能改过的）班名同步回 class_info
          let classId: string = group.class_id;
          if (classId.length === 0) {
            classId = await ClassInfoDao.ensureByName(exec, cleanName(group.class_name, '未命名班级'));
          } else if (cleanName(group.class_name, '').length > 0) {
            await ClassInfoDao.rename(exec, classId, group.class_name);
          }
          assignment.classId = classId;

          // 兜底：同一门课的两个分组绝不允许落到同一个 class_id —— 那会让第二个
          // 分组在 upsertGroup 里命中同一行走 UPDATE，两个班在库里合并成一个
          // （复制班级曾把 class_id 一起复制，正是这样合并的）。抛错 = 整体回滚。
          if (seenClassIds.indexOf(classId) >= 0) {
            throw new Error('同一门课程的多个班级指向了同一个班级档案，已取消本次保存：请检查各班级名称是否填了不同的值');
          }
          seenClassIds.push(classId);

          // 班级维度要带上本课程的全部班（含本次新增的），否则新班漏检班级冲突
          const classIds: string[] = await ScheduleRepository.classIdsOfCourse(exec, rowId);
          if (classId.length > 0 && classIds.indexOf(classId) < 0) {
            classIds.push(classId);
          }

          // classId 必须显式传给 DAO：对新班而言此刻 group.class_id 还是空串，
          // 若让 DAO 从 group 里取值，落库的 class_id 就是 ''，而 v_lesson 是
          // 六表 JOIN（含 class_info），空串关联不上班级档案 → 整组课在课表上消失。
          // 详见 CourseDao.upsertGroup 的注释。
          const groupId: number = await CourseDao.upsertGroup(exec, rowId, group, gi, classId);
          assignment.groupId = groupId;

          for (let pi = 0; pi < group.time_periods.length; pi++) {
            const period: TimePeriod = group.time_periods[pi];
            const hits: ConflictHit[] =
              await ConflictDetector.check(exec, semesterId, teacherId, classIds, period, period.id);
            if (hits.length > 0 && !force) {
              // 抛出去 = 整体回滚：不会留下"课程有了、时间段没有"的空壳
              throw new CourseConflictSignal(hits);
            }
            let periodId: number = period.id;
            if (periodId > 0) {
              await TimePeriodDao.update(exec, period, maxWeek);
            } else {
              periodId = await TimePeriodDao.insert(exec, groupId, period, maxWeek);
            }
            assignment.periodIds.push(periodId);
          }
          assignments.push(assignment);
        }
        return rowId;
      });
    } catch (e) {
      if (e instanceof CourseConflictSignal) {
        result.saved = false;
        result.conflicts = (e as CourseConflictSignal).conflicts;
        result.message = ConflictDetector.describe(result.conflicts);
        Logger.warn(TAG, `课程未保存（已整体回滚，存在冲突）：${result.message}`);
        return result;
      }
      throw e as Error;
    }

    // 4) 提交成功，才把真实主键回填给调用方（回滚路径绝不会走到这里）
    course.id = courseRowId;
    for (let i = 0; i < assignments.length; i++) {
      const assignment: GroupIdAssignment = assignments[i];
      const index: number = assignment.groupIndex;
      if (index < 0 || index >= groups.length) {
        continue;
      }
      const group: ClassGroup = groups[index];
      group.id = assignment.groupId;
      if (assignment.classId.length > 0) {
        group.class_id = assignment.classId;
      }
      for (let j = 0; j < assignment.periodIds.length && j < group.time_periods.length; j++) {
        group.time_periods[j].id = assignment.periodIds[j];
      }
    }

    result.saved = true;
    result.courseRowId = courseRowId;
    Logger.info(TAG, `课程「${course.course_name}」整体保存成功：course=${courseRowId}，`
      + `${groups.length} 个班级分组`);
    return result;
  }

  /** 本课程已登记的班级 id 集合（冲突检测的班级维度要覆盖全部班，不只当前编辑的那个） */
  private static async classIdsOfCourse(exec: DbExecutor, courseRowId: number): Promise<string[]> {
    const rows: ClassGroupRow[] = await CourseDao.listGroupsByCourse(exec, courseRowId);
    const ids: string[] = [];
    for (let i = 0; i < rows.length; i++) {
      if (ids.indexOf(rows[i].class_id) < 0) {
        ids.push(rows[i].class_id);
      }
    }
    return ids;
  }

  /**
   * 删除课程：级联清掉它的班级分组、时间段、周次。
   *
   * **注意**：课程的"新增 / 修改"一律走 `saveCourseGraph`（单事务课程图），
   * 这里刻意不再提供 `insertCourse` / `updateCourse` / `upsertClassGroup` / `savePeriod`
   * 这类"分步写"的入口 —— 它们各自开事务，组合使用时会产出
   * "课程写了、时间段没写"的空壳课程（课表按 `v_lesson` 渲染，空壳永远不显示）。
   * 写路径只留一条，才不会有人再把半截状态写进库。
   */
  async deleteCourse(courseRowId: number): Promise<void> {
    await this.db.runInTransaction(async (exec: DbExecutor) => {
      await CourseDao.deleteCascade(exec, courseRowId);
      await AttendanceDao.pruneOrphans(exec);
    });
  }

  // ------------------------------------------------------------ 教师管理

  async upsertTeacher(semesterId: number, teacher: Teacher): Promise<number> {
    return this.db.runInTransaction(async (exec: DbExecutor) => {
      const nextOrder: number = await TeacherDao.countBySemester(exec, semesterId);
      if (teacher.id > 0) {
        await TeacherDao.update(exec, teacher);
        return teacher.id;
      }
      return TeacherDao.upsert(exec, teacher, semesterId, nextOrder);
    });
  }

  async deleteTeacher(teacherId: number): Promise<void> {
    await this.db.runInTransaction(async (exec: DbExecutor) => {
      await TeacherDao.deleteCascade(exec, teacherId);
      await AttendanceDao.pruneOrphans(exec);
      await AppSettingDao.repairPointers(exec);
    });
  }

  // -------------------------------------------------------- 班级与时间段

  /** 删除"课程 × 班级"（编辑班级时删掉仅剩的那个班 = 删除该班） */
  async deleteClassGroup(groupId: number): Promise<void> {
    await this.db.runInTransaction(async (exec: DbExecutor) => {
      await CourseDao.deleteGroup(exec, groupId);
      await AttendanceDao.pruneOrphans(exec);
    });
  }

  async deletePeriod(periodId: number): Promise<void> {
    await this.db.runInTransaction(async (exec: DbExecutor) => {
      await TimePeriodDao.deleteById(exec, periodId);
      await AttendanceDao.pruneOrphans(exec);
    });
  }

  async deletePeriodsOfGroup(classGroupId: number): Promise<void> {
    await this.db.runInTransaction(async (exec: DbExecutor) => {
      await TimePeriodDao.deleteByClassGroup(exec, classGroupId);
      await AttendanceDao.pruneOrphans(exec);
    });
  }

  /** 删除某时间段在某周的一次课；周次清零时时间段一并删除 */
  async deleteWeekOfPeriod(timePeriodId: number, weekNo: number): Promise<void> {
    await this.db.runInTransaction(async (exec: DbExecutor) => {
      await TimePeriodDao.deleteWeek(exec, timePeriodId, weekNo);
      // **这一次课**的签到记录要精确删掉 —— 时间段本身还在，pruneOrphans 认不出它。
      // 留着的话，下次新建同一时段的课会把上一轮的点名结果"继承"过去。
      await AttendanceDao.deleteBySession(exec, timePeriodId, weekNo);
      await AttendanceDao.pruneOrphans(exec);
    });
  }

  /** 某时间段当前生效的全部周次（课程详情 sheet 展示用） */
  async weeksOfPeriod(timePeriodId: number): Promise<number[]> {
    return TimePeriodDao.weeksOf(this.db.executor(), timePeriodId, 999);
  }

  /**
   * 为编辑页加载一门课程的完整对象图（班级分组 + 时间段 + 周次）。
   * 与 loadSemesterCourses 不同：只取这一门课，但时间段逐条带周次。
   */
  async loadCourseForEdit(courseRowId: number): Promise<Course | undefined> {
    const exec: DbExecutor = this.db.executor();
    const courseRow: CourseRow | undefined = await CourseDao.findById(exec, courseRowId);
    if (courseRow === undefined) {
      return undefined;
    }
    const course: Course = Course.fromRow(courseRow, []);

    const groupRows: ClassGroupRow[] = await CourseDao.listGroupsByCourse(exec, courseRowId);
    for (let i = 0; i < groupRows.length; i++) {
      const groupRow: ClassGroupRow = groupRows[i];
      const periodRows: TimePeriodRow[] = await TimePeriodDao.listByClassGroup(exec, groupRow.id);
      const periods: TimePeriod[] = [];
      for (let j = 0; j < periodRows.length; j++) {
        const weeks: number[] = await TimePeriodDao.weeksOf(exec, periodRows[j].id, 999);
        periods.push(TimePeriod.fromRow(periodRows[j], weeks, 999));
      }
      course.class_groups.push(ClassGroup.fromRow(groupRow, periods));
    }
    return course;
  }

  // ---------------------------------------------------------------- 名单

  async replaceRoster(className: string, students: Student[]): Promise<string> {
    return this.db.runInTransaction(async (exec: DbExecutor) => {
      let classId: string = await ClassInfoDao.ensureByName(exec, className);
      await StudentDao.replaceRoster(exec, classId, students);
      await AttendanceDao.pruneOrphans(exec);
      return classId;
    });
  }

  async appendStudents(classId: string, students: Student[]): Promise<number> {
    return this.db.runInTransaction(async (exec: DbExecutor) => {
      const base: number = await StudentDao.countByClass(exec, classId);
      let written: number = 0;
      for (let i = 0; i < students.length; i++) {
        await StudentDao.insert(exec, students[i], classId, base + i);
        written++;
      }
      return written;
    });
  }

  /** 学生详情：按主键取一个学生（页面异步回填用） */
  async findStudent(id: number): Promise<Student | undefined> {
    const row: StudentRow | undefined = await StudentDao.findById(this.db.executor(), id);
    return row === undefined ? undefined : Student.fromRow(row);
  }

  /** 学生详情：保存学号 / 姓名 / 性别 / 年龄 / 电话 / 备注（不改所属班级） */
  async saveStudent(student: Student): Promise<void> {
    await this.db.runInTransaction(async (exec: DbExecutor) => {
      await StudentDao.update(exec, student);
    });
  }

  /**
   * 名册「添加学生信息」：往指定班插一条新学生。
   *
   * `sort_order` 取当前人数（排在末尾）；名册展示按学号升序，所以这个值只影响同学号时的先后。
   * 学号重复由 (class_id, student_no) 唯一约束兜底，调用方（页面）会先自查并给人话提示。
   */
  async addStudent(classId: string, student: Student): Promise<number> {
    return this.db.runInTransaction(async (exec: DbExecutor) => {
      const sortOrder: number = await StudentDao.countByClass(exec, classId);
      student.class_id = classId;
      student.id = await StudentDao.insert(exec, student, classId, sortOrder);
      return student.id;
    });
  }

  async deleteStudent(id: number): Promise<void> {
    await this.db.runInTransaction(async (exec: DbExecutor) => {
      await StudentDao.deleteById(exec, id);
      await AttendanceDao.pruneOrphans(exec);
    });
  }

  /** 名册多选删除：一个事务里删掉全部勾选的学生，中途失败整体回滚 */
  async deleteStudents(ids: number[]): Promise<void> {
    if (ids.length === 0) {
      return;
    }
    await this.db.runInTransaction(async (exec: DbExecutor) => {
      for (let i = 0; i < ids.length; i++) {
        await StudentDao.deleteById(exec, ids[i]);
      }
      await AttendanceDao.pruneOrphans(exec);
    });
  }

  /**
   * 导入名册：**按学号合并**，整批一个事务。
   *
   * 为什么是合并不是整体替换：模板里只有学号/姓名/性别，而学生卡片还有年龄、电话、备注
   * —— 整体替换会把这些手工补的字段连同"文件里没列到的学生"一起抹掉。合并则天然幂等，
   * 同一份文件导两遍结果一致，也不会因为用户在 Excel 里漏了一行就丢人。
   */
  async mergeRoster(classId: string, students: Student[]): Promise<RosterImportResult> {
    return this.db.runInTransaction(async (exec: DbExecutor) => {
      const result: RosterImportResult = new RosterImportResult();
      const existing: StudentRow[] = await StudentDao.listByClass(exec, classId);
      const byNo: Map<string, StudentRow> = new Map();
      for (let i = 0; i < existing.length; i++) {
        byNo.set(existing[i].student_no, existing[i]);
      }

      let order: number = existing.length;
      for (let i = 0; i < students.length; i++) {
        const incoming: Student = students[i];
        const hit: StudentRow | undefined = byNo.get(incoming.student_no);
        if (hit === undefined) {
          await StudentDao.insert(exec, incoming, classId, order);
          order++;
          result.added++;
          continue;
        }
        const current: Student = Student.fromRow(hit);
        const sameName: boolean = current.name === incoming.name;
        const currentSex: string = current.sex === undefined ? '' : current.sex;
        const incomingSex: string = incoming.sex === undefined ? '' : incoming.sex;
        if (sameName && currentSex === incomingSex) {
          result.unchanged++;
          continue;
        }
        current.name = incoming.name;
        current.sex = incoming.sex;
        await StudentDao.update(exec, current);
        result.updated++;
      }
      return result;
    });
  }

  async renameClass(classId: string, newName: string): Promise<void> {
    await this.db.runInTransaction(async (exec: DbExecutor) => {
      await ClassInfoDao.rename(exec, classId, cleanName(newName, '未命名班级'));
    });
  }

  // ---------------------------------------------------------------- 签到（点名）

  /** 某一次课（时间段 × 周次）已有的点名结果 —— 点名页进来时按它回填手势状态 */
  async loadAttendance(periodId: number, weekNo: number): Promise<AttendanceRow[]> {
    return AttendanceDao.listBySession(this.db.executor(), periodId, weekNo);
  }

  /**
   * 保存某一次课的点名结果：**整批替换**（先清本次课、再写入），单事务。
   *
   * 为什么不是逐行 upsert：老师点完一轮就是一份完整快照，"这次课只写了三个人"的
   * 中间态没有任何意义；整批替换天然幂等，重复点「完成」也不会写出重影行。
   */
  async saveAttendance(periodId: number, weekNo: number, rows: AttendanceRow[]): Promise<number> {
    return this.db.runInTransaction(async (exec: DbExecutor) => {
      return AttendanceDao.replaceSession(exec, periodId, weekNo, rows);
    });
  }

  /** 导出用：某班全部签到行（含课次排序键），考勤/课堂状态的列号由页面按时间顺序定 */
  async loadClassAttendance(classId: string): Promise<AttendanceExportRow[]> {
    return AttendanceDao.listByClass(this.db.executor(), classId);
  }

  async populationReport(semesterId: number): Promise<ClassPopulationRow[]> {
    return StudentDao.populationReport(this.db.executor(), semesterId);
  }

  // ------------------------------------------------------------ 作息模板

  async saveTemplate(template: ScheduleTemplate): Promise<number> {
    return this.db.runInTransaction(async (exec: DbExecutor) => {
      if (template.id > 0) {
        await ScheduleTemplateDao.update(exec, template);
        await ScheduleTemplateDao.replaceSlots(exec, template.id, template.slots);
        return template.id;
      }
      return ScheduleTemplateDao.insert(exec, template);
    });
  }

  /** 按 id 读单张作息模板（含节次）。全屏编辑页只关心这一张，不必拉全表 */
  async loadTemplate(templateId: number): Promise<ScheduleTemplate | undefined> {
    const exec: DbExecutor = this.db.executor();
    const row: ScheduleTemplateRow | undefined = await ScheduleTemplateDao.findById(exec, templateId);
    if (row === undefined) {
      return undefined;
    }
    const slots: ScheduleSlot[] = await ScheduleTemplateDao.slotsOf(exec, templateId);
    return ScheduleTemplate.fromRow(row, slots);
  }

  /**
   * 复制一张时间表（节次、时长、节数全部照搬）。
   *
   * 名称取「原名 副本」，重名则顺延序号——`schedule_template.name` 是 UNIQUE，
   * 直接插同名会抛异常。副本一定是非内置的，否则删不掉。
   */
  async duplicateTemplate(templateId: number): Promise<ScheduleTemplate | undefined> {
    return this.db.runInTransaction(async (exec: DbExecutor) => {
      const row: ScheduleTemplateRow | undefined = await ScheduleTemplateDao.findById(exec, templateId);
      if (row === undefined) {
        return undefined;
      }
      const slots: ScheduleSlot[] = await ScheduleTemplateDao.slotsOf(exec, templateId);
      const copy: ScheduleTemplate = ScheduleTemplate.fromRow(row, slots).clone();
      copy.id = 0;
      copy.is_builtin = false;
      copy.citation_count = 0;
      copy.name = await ScheduleRepository.uniqueTemplateNameIn(exec, `${row.name} 副本`);
      copy.id = await ScheduleTemplateDao.insert(exec, copy);
      Logger.info(TAG, `已复制时间表：${row.name} → ${copy.name}（id=${copy.id}）`);
      return copy;
    });
  }

  /** 在库内找一个未被占用的模板名（UNIQUE 约束不允许重名） */
  private static async uniqueTemplateNameIn(exec: DbExecutor, base: string): Promise<string> {
    let candidate: string = base;
    let index: number = 2;
    while (await ScheduleTemplateDao.findByName(exec, candidate) !== undefined) {
      candidate = `${base} ${index}`;
      index++;
    }
    return candidate;
  }

  /** 同上，学期名也是 UNIQUE（导入同名学期要顺延序号而不是报错） */
  private static async uniqueSemesterNameIn(exec: DbExecutor, base: string): Promise<string> {
    let candidate: string = base;
    let index: number = 2;
    while (await SemesterDao.findByName(exec, candidate) !== undefined) {
      candidate = `${base} ${index}`;
      index++;
    }
    return candidate;
  }

  /** 被学期引用或内置的模板不允许删除 */
  async deleteTemplate(templateId: number): Promise<boolean> {
    return this.db.runInTransaction(async (exec: DbExecutor) => {
      const row = await ScheduleTemplateDao.findById(exec, templateId);
      if (row === undefined) {
        return false;
      }
      const template: ScheduleTemplate = ScheduleTemplate.fromRow(row, []);
      if (!template.canDelete()) {
        return false;
      }
      await ScheduleTemplateDao.deleteById(exec, templateId);
      return true;
    });
  }

  async bindTemplate(semesterId: number, templateId: number): Promise<void> {
    await this.db.runInTransaction(async (exec: DbExecutor) => {
      await SemesterDao.updateScheduleRef(exec, semesterId, templateId);
    });
  }

  // ------------------------------------------------------------ 整学期同步

  /**
   * 把内存对象图整体同步进数据库（兜底路径）。
   *
   * 用于：导入备份、外部数据导入、页面销毁前的兜底保存。
   * 差异算法：库里有、内存没有 → 删；内存有、库里没有 → 插；两边都有 → 比 id 更新。
   * 整个过程一个事务，中途异常全部回滚，不会留下半截数据。
   */
  async syncSemesterCourses(courses: SemesterCourses): Promise<SyncReport> {
    const startedAt: number = new Date().getTime();
    const report: SyncReport = new SyncReport();
    const semesterId: number = courses.semester.id;
    const maxWeek: number = courses.semester.total_weeks;
    report.semesterId = semesterId;

    await this.db.runInTransaction(async (exec: DbExecutor) => {
      // 1) 学期自身字段
      await SemesterDao.update(exec, courses.semester);

      // 2) 现状快照
      const dbCourses: CourseRow[] = await CourseDao.listBySemester(exec, semesterId);
      const dbGroups: ClassGroupRow[] = await CourseDao.listGroupsBySemester(exec, semesterId);
      const dbPeriods: TimePeriodRow[] = await TimePeriodDao.listBySemester(exec, semesterId);

      const dbCourseIds: number[] = dbCourses.map((row: CourseRow) => row.id);
      const dbGroupIds: number[] = dbGroups.map((row: ClassGroupRow) => row.id);
      const dbPeriodIds: number[] = dbPeriods.map((row: TimePeriodRow) => row.id);

      const keptCourseIds: number[] = [];
      const keptGroupIds: number[] = [];
      const keptPeriodIds: number[] = [];

      const teacherRows: TeacherRow[] = await TeacherDao.listBySemester(exec, semesterId);
      const teacherIds: number[] = teacherRows.map((row: TeacherRow) => row.id);

      // 3) 教师（存在则更新，不存在则插入）
      for (let i = 0; i < courses.teacher_courses.length; i++) {
        const holder: TeacherCourses = courses.teacher_courses[i];
        let teacherId: number = holder.teacher.id;
        if (teacherId > 0 && teacherIds.indexOf(teacherId) >= 0) {
          await TeacherDao.update(exec, holder.teacher);
        } else {
          teacherId = await TeacherDao.upsert(exec, holder.teacher, semesterId, i);
          holder.teacher.id = teacherId;
        }

        // 4) 课程
        for (let j = 0; j < holder.courses.length; j++) {
          const course: Course = holder.courses[j];
          let courseRowId: number = 0;
          if (course.id > 0 && dbCourseIds.indexOf(course.id) >= 0) {
            await CourseDao.update(exec, course);
            courseRowId = course.id;
            report.coursesUpdated++;
          } else {
            courseRowId = await CourseDao.insert(exec, course, semesterId, teacherId, j);
            course.id = courseRowId;
            report.coursesInserted++;
          }
          keptCourseIds.push(courseRowId);

          // 5) 班级分组
          for (let k = 0; k < course.class_groups.length; k++) {
            const group: ClassGroup = course.class_groups[k];
            if (group.class_id.length === 0) {
              group.class_id = await ClassInfoDao.ensureByName(exec, group.class_name);
            }
            const groupId: number = await CourseDao.upsertGroup(exec, courseRowId, group, k, group.class_id);
            group.id = groupId;
            keptGroupIds.push(groupId);
            report.groupsUpserted++;

            // 6) 时间段与周次
            for (let m = 0; m < group.time_periods.length; m++) {
              const period: TimePeriod = group.time_periods[m];
              if (period.id > 0 && dbPeriodIds.indexOf(period.id) >= 0) {
                await TimePeriodDao.update(exec, period, maxWeek);
                report.periodsUpdated++;
              } else {
                period.id = await TimePeriodDao.insert(exec, groupId, period, maxWeek);
                report.periodsInserted++;
              }
              keptPeriodIds.push(period.id);
              report.weeksWritten += period.week_nums.length;
            }
          }
        }
      }

      // 7) 删除内存里已经不存在的行（自底向上，先子后父）
      for (let i = 0; i < dbPeriodIds.length; i++) {
        if (keptPeriodIds.indexOf(dbPeriodIds[i]) < 0) {
          await TimePeriodDao.deleteById(exec, dbPeriodIds[i]);
          report.periodsDeleted++;
        }
      }
      for (let i = 0; i < dbGroupIds.length; i++) {
        if (keptGroupIds.indexOf(dbGroupIds[i]) < 0) {
          await CourseDao.deleteGroup(exec, dbGroupIds[i]);
          report.groupsDeleted++;
        }
      }
      for (let i = 0; i < dbCourseIds.length; i++) {
        if (keptCourseIds.indexOf(dbCourseIds[i]) < 0) {
          await CourseDao.deleteCascade(exec, dbCourseIds[i]);
          report.coursesDeleted++;
        }
      }
    });

    report.durationMs = new Date().getTime() - startedAt;
    Logger.info(TAG, report.summary());
    return report;
  }

  /**
   * 导入一个课表分享包（zip 的 manifest 或一张可识别的 .xls 都先转成 `ImportedPackage`）。
   *
   * 与 `syncSemesterCourses` 的区别是**语义**：sync 是"把内存对象图同步进**已有**学期"
   * （库里多出来的行会被删掉），而导入是"**新建**一个学期再把包里的内容写进去"——
   * 绝不能碰用户已有的任何学期，否则导入一份别人的课表就会把自己的课删光。
   *
   * 全程**一个事务**：时间表 / 学期 / 教师 / 课程 / 班级分组 / 时间段 / 周次，
   * 中途任何一步失败都整体回滚，不会留下"学期建了、课程没写"的半截数据。
   *
   * 刻意**不做冲突检测**：包是"照原样搬运"，源课表本身若已有重叠时间段，
   * 导入更应该如实复现（而不是拒收），校验期交给用户在课表页自行调整。
   *
   * 名称冲突一律**顺延序号**（学期名、时间表名都是 UNIQUE）：
   * 同一个包导第二次不该报错，而应该是"多出一个 xx 2"。
   */
  async importSchedulePackage(pkg: ImportedPackage): Promise<PackageImportReport> {
    const report: PackageImportReport = new PackageImportReport();
    let pointerTeacherId: number = 0;
    let pointerSemesterId: number = 0;

    await this.db.runInTransaction(async (exec: DbExecutor) => {
      // ① 时间表：包里带了节次就新建一张（保证节次原样落地），没带就按名字复用
      if (pkg.template !== null) {
        const tpl: ScheduleTemplate = pkg.template.clone();
        tpl.id = 0;
        tpl.is_builtin = false;
        tpl.citation_count = 0;
        tpl.name = await ScheduleRepository.uniqueTemplateNameIn(exec, tpl.name);
        report.templateId = await ScheduleTemplateDao.insert(exec, tpl);
        report.templateName = tpl.name;
        report.templateCreated = true;
      } else {
        const wanted: string = pkg.templateName.length > 0 ? pkg.templateName : '导入时间表';
        const found: ScheduleTemplateRow | undefined = await ScheduleTemplateDao.findByName(exec, wanted);
        if (found !== undefined) {
          report.templateId = found.id;
          report.templateName = found.name;
        } else {
          const tpl: ScheduleTemplate = ScheduleTemplate.blank(
            await ScheduleRepository.uniqueTemplateNameIn(exec, wanted));
          report.templateId = await ScheduleTemplateDao.insert(exec, tpl);
          report.templateName = tpl.name;
          report.templateCreated = true;
        }
      }

      // ② 只导时间表（Excel 里那张节次表）：到此为止，不建学期
      if (!pkg.createSemester) {
        Logger.info(TAG, `导入时间表「${report.templateName}」（id=${report.templateId}），未建学期`);
        return;
      }

      // ③ 学期
      const semester: Semester = new Semester();
      semester.name = await ScheduleRepository.uniqueSemesterNameIn(exec,
        cleanName(pkg.semesterName, `导入学期 ${DateUtil.toDateString(DateUtil.today())}`, 32));
      semester.total_weeks = clamp(Math.round(pkg.totalWeeks), 1, 60);
      semester.start_date = pkg.startDate.length > 0
        ? pkg.startDate
        : DateUtil.toDateString(DateUtil.weekMonday(DateUtil.today()));
      semester.schedule_id = report.templateId;
      const nextOrder: number = await DaoSupport.scalarNumber(exec,
        `SELECT COALESCE(MAX(sort_order), -1) + 1 AS v FROM ${Tables.SEMESTER}`, []);
      const semesterId: number = await SemesterDao.insert(exec, semester, nextOrder);
      semester.id = semesterId;
      semester.sort_order = nextOrder;
      report.semesterId = semesterId;
      report.semesterName = semester.name;
      report.createdSemester = true;
      pointerSemesterId = semesterId;

      // ④ 教师 → 课程 → 班级分组 → 时间段
      for (let i = 0; i < pkg.teacherCourses.length; i++) {
        const holder: TeacherCourses = pkg.teacherCourses[i];
        holder.teacher.id = 0;
        const teacherId: number = await TeacherDao.upsert(exec, holder.teacher, semesterId, i);
        holder.teacher.id = teacherId;
        report.teachers++;
        if (pointerTeacherId === 0) {
          pointerTeacherId = teacherId;
        }

        // 同教师下"课程名 + 类型"只能一门（`course` 表的 UNIQUE 约束），
        // 包里有重复就只留第一门 —— 否则插到第二门时整个导入会回滚
        const seenCourseKeys: string[] = [];
        for (let j = 0; j < holder.courses.length; j++) {
          const course: Course = holder.courses[j];
          const courseKey: string = `${course.course_name}#${course.course_type}`;
          if (seenCourseKeys.indexOf(courseKey) >= 0) {
            Logger.warn(TAG, `导入跳过重复课程：「${course.course_name}」（${course.course_type}）`);
            continue;
          }
          seenCourseKeys.push(courseKey);
          course.id = 0;
          course.course_id = '';
          const courseRowId: number = await CourseDao.insert(exec, course, semesterId, teacherId, j);
          course.id = courseRowId;
          report.courses++;

          for (let k = 0; k < course.class_groups.length; k++) {
            const group: ClassGroup = course.class_groups[k];
            group.id = 0;
            const classId: string = await ClassInfoDao.ensureByName(exec,
              cleanName(group.class_name, '未命名班级', 32));
            group.class_id = classId;
            const groupId: number = await CourseDao.upsertGroup(exec, courseRowId, group, k, classId);
            group.id = groupId;
            report.groups++;

            for (let m = 0; m < group.time_periods.length; m++) {
              const period: TimePeriod = group.time_periods[m];
              period.id = 0;
              period.id = await TimePeriodDao.insert(exec, groupId, period, semester.total_weeks);
              report.periods++;
              report.weeks += period.week_nums.length;
            }
          }
        }
      }
    });

    // 把当前指向切到刚导入的学期：不切的话用户会以为"导入没生效"（课表页还在看旧学期）
    if (pointerSemesterId > 0) {
      await this.savePointers(pointerSemesterId, pointerTeacherId);
    }
    Logger.info(TAG, `导入课表包完成：${report.summary().split('\n').join(' ')}`);
    return report;
  }

  // ------------------------------------------------------------ 统计与备份

  async stats(semesterId: number): Promise<DbStats> {
    const exec: DbExecutor = this.db.executor();
    const stats: DbStats = new DbStats();
    stats.dbVersion = DB_VERSION;
    stats.semesters = await SemesterDao.count(exec);
    stats.templates = await ScheduleTemplateDao.count(exec);
    stats.teachers = await TeacherDao.countBySemester(exec, semesterId);
    stats.courses = await CourseDao.countBySemester(exec, semesterId);
    stats.classes = await ClassInfoDao.count(exec);
    stats.periods = await TimePeriodDao.countBySemester(exec, semesterId);
    stats.weeks = await TimePeriodDao.countWeeksBySemester(exec, semesterId);
    stats.students = await DaoSupport.scalarNumber(exec,
      `SELECT COUNT(*) AS v FROM ${Tables.STUDENT}`, []);
    stats.attendances = await AttendanceDao.countAll(exec);
    return stats;
  }

  /** 关系库原生备份：一条命令产出一个完整一致的文件，不需要应用层序列化整棵对象图 */
  async backup(destFileName: string): Promise<void> {
    await this.db.backup(destFileName);
  }

  async restore(srcFileName: string): Promise<void> {
    await this.db.restore(srcFileName);
  }

  async close(): Promise<void> {
    await this.db.close();
  }

  /** 供上层在 catch 里统一转成可读文本 */
  static describeError(e: Object): string {
    return errText(e);
  }
}
