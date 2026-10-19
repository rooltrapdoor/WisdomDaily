import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { DbStats, PackageImportReport, ScheduleRepository, Workspace } from '../repository/ScheduleRepository';
import { AttendanceExportRow, AttendanceRow, ClassPopulationRow, LessonRow } from '../model/Rows';
import { Semester, SemesterCourses } from '../model/Semester';
import { ScheduleTemplate, ScheduleSlot } from '../model/ScheduleTemplate';
import { Teacher, TeacherCourses } from '../model/Teacher';
import { ClassRoster, Student } from '../model/Student';
import { DateUtil } from '../common/DateUtil';
import { textColorOf, clamp, colorOr, normalizeColor, alphaOf, withAlpha, hueColor,
  hexToHsv, hsvToHex, compareNo, delay, isDbLocked, clampNotifyMinutes, errDetail, HSV,
  THEME_COLOR_DEFAULT, TODAY_COLOR_DEFAULT, NOTIFY_AHEAD_DEFAULT_MINUTES, PAGE_BG_COLOR } from '../common/Util';
import { Logger } from '../common/Logger';
import { LessonReminder } from '../service/LessonReminder';
import { appAccount } from '@kit.BasicServicesKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { XlsReader } from '../common/XlsReader';
import { XlsWriter, XlsRect } from '../common/XlsWriter';
import { RosterImporter, RosterImportResult, RosterParseResult } from '../repository/RosterImporter';
import {
  ENTRY_MANIFEST,
  ENTRY_README,
  ImportedPackage,
  PackageParseResult,
  SchedulePackage
} from '../repository/SchedulePackage';
import { ZipUtil } from '../common/ZipUtil';
import { TodoPanel } from './Todo';
import { WidgetLaunch, WidgetOpenRequest } from '../widget/WidgetLaunch';
import {
  AttendMark,
  AttendStatus,
  DEFAULT_RANDOM_COUNT,
  MAX_RANDOM_COUNT,
  MAX_SIGNIN_COLUMNS,
  MIN_RANDOM_COUNT
} from '../model/Attendance';

const TAG: string = 'IndexPage';

/** 课表网格布局常量 */
interface LAYOUT_Interface {
  /** 左侧时间轴宽度（vp） */
  timeColWidth: number;

  /** 一节课卡片高度（vp） */
  sessionHeight: number;

  /** 顶部周次条高度（vp） */
  weekHeaderHeight: number;

  /** 单个管理入口卡片高度（vp） */
  manageItemHeight: number;

  /**
   * 底部导航栏高度（vp）。
   * 导航栏用 `barOverlap(true)` + 全透明底色做**浮层**（内容铺到它之下、原样透出来），
   * 因此滚动内容末尾要按这个高度让位，否则最后一屏内容永远压在导航栏之下。
   */
  tabBarHeight: number;
}

const LAYOUT: LAYOUT_Interface = {
  /** 左侧时间轴宽度（vp） */
  timeColWidth: 48,
  /** 一节课卡片高度（vp） */
  sessionHeight: 56,
  /** 顶部周次条高度（vp） */
  weekHeaderHeight: 56,
  /** 单个管理入口卡片高度（vp） */
  manageItemHeight: 76,
  /** 底部导航栏高度（vp） */
  tabBarHeight: 56
};

/** 管理面板（bindSheet）尺寸常量 */
interface MANAGE_SHEET_Interface {
  /** 头部行高（返回 / 标题 / 关闭） */
  headerHeight: number;

  /**
   * 主体滚动区的**最大**高度（vp）。注意这只是上限，不是高度：
   * 面板用 `SheetSize.FIT_CONTENT`，内容多高面板就多高，只有内容超过它才内部滚动。
   */
  bodyMaxHeight: number;

  /** 内容末尾的呼吸位（小间距，不做大留白） */
  bottomGap: number;
}

/**
 * 管理面板尺寸。
 *
 * 面板高度**随内容自适应**（`SheetSize.FIT_CONTENT`），这样短内容（如「关于」）
 * 不会像固定 `SheetSize.MEDIUM`（约屏高 60%）那样在底部留一大片空白；
 * 同时用 `bodyMaxHeight` 给一个上限，长内容（如班级名册）到此为止、面板内部滚动。
 */
const MANAGE_SHEET: MANAGE_SHEET_Interface = {
  headerHeight: 40,
  bodyMaxHeight: 520,
  bottomGap: 8
};

const WEEKDAY_LABELS: string[] = ['一', '二', '三', '四', '五', '六', '日'];

// ---- 班级名册：学生列表与 Excel 导入 ----

/** 名册 Excel 的列数：对齐用户手里的模板（序号/学号/姓名/性别 + 考勤5子列 + 课堂状态5子列） */
const ROSTER_COLS: number = 14;
/** 导出/模板文件的文件名后缀（第一行**标题**只用班级名，不加后缀） */
const ROSTER_TITLE_SUFFIX: string = '学生名单';
/** 名册里一行学生的高度（vp） */
const ROSTER_ROW_HEIGHT: number = 62;
/** 名册列表的最大高度：超过就在列表内部滚动，面板不会被撑爆 */
const ROSTER_LIST_MAX_HEIGHT: number = 320;
/** 学期管理里一行学期的高度（vp）——与名册行同款（内边距 12 + 两行文字） */
const SEMESTER_ROW_HEIGHT: number = 62;
/** 学期列表的最大高度：超过就在列表内部滚动，面板不会被撑爆 */
const SEMESTER_LIST_MAX_HEIGHT: number = 320;
const TPL_ROW_HEIGHT: number = 62;
const TPL_LIST_MAX_HEIGHT: number = 320;
const TEACHER_ROW_HEIGHT: number = 62;
const TEACHER_LIST_MAX_HEIGHT: number = 320;

/**
 * 「查看本节课程情况」面板主体的最大高度。
 *
 * 课程详情 sheet 是 `FIT_CONTENT`、**外层没有可滚动的兜底**（管理面板有一层
 * `Scroll`，这里没有），所以整个面板主体（统计 + 逐人列表）收在**一个** Scroll 里
 * 并给一个上限：面板总高 = 头部(≈68) + 课程信息块(最多 ≈228) + 本面板，
 * 手机可用高约 700 vp，这块留 280 才不会在信息最满（备注/时段备注都有）时被切掉。
 * 短名单贴着内容、长名单在面板内部滚动 —— 与「靠内容显隐改高度」是两回事，
 * 上限是固定值，面板高度不随人数抖动。
 */
const CHECKIN_VIEW_PANEL_MAX_HEIGHT: number = 280;
/** 「查看本节课程情况」里一行学生的高度（vp） */
const CHECKIN_VIEW_ROW_HEIGHT: number = 48;

/**
 * 导出表里「一次点名 = 一列」的列键。
 *
 * 之所以要 `weekNo + periodId` 两个字段：`time_period` 是**每周复用**的（第 1 周的周一
 * 第 1 节和第 2 周的周一第 1 节是同一条时段记录），只用 `periodId` 会把两周的点名
 * 混成同一列；只用 `weekNo` 又分不开同一周里的多节课。排序键另用 `weekday + startTime`
 * —— "第几次点名"是**按时间先后**排的，同周里上午的课必须排在下周之前。
 */
class RosterSession {
  weekNo: number = 0;
  weekday: number = 0;
  startTime: number = 0;
  periodId: number = 0;
}

/** 管理页「+」新建学期的默认名称与周数 */
const DEFAULT_SEMESTER_NAME: string = '默认学期';
const DEFAULT_SEMESTER_WEEKS: number = 20;

/**
 * 「查看本节课程情况」列表里的一行。
 *
 * 只装**展示所需的字段**，不直接持有 `Student` / `AttendanceRow`：这两个对象各自带一堆
 * 这里用不到的列（性别、手机号、created_at…），而这个数组是 `@Local` 状态 —— 整体替换时
 * 深度比较的开销会跟着对象大小走。点名结果只有"状态 + 等级 + 分数"三件事，装齐就够渲染。
 */
class CheckinViewRow {
  studentNo: string = '';
  name: string = '';
  /** AttendStatus.NONE / PRESENT / ABSENT / LEAVE */
  status: string = AttendStatus.NONE;
  /** 等级 1~5；0 = 没评级 */
  grade: number = 0;
  /** 等级换算出的分数；0 = 没有 */
  score: number = 0;
}

// ---- 左右滑动切换周次（跟手轮播）----
/** 松手判定"翻页"的位移阈值：至少 DRAG_THRESHOLD_MIN_VP，或超过页宽的 DRAG_THRESHOLD_RATIO */
const DRAG_THRESHOLD_MIN_VP: number = 56;
const DRAG_THRESHOLD_RATIO: number = 0.22;
/** 拖向"不存在的那一周"（学期边界）时的阻尼上限位移（vp） */
const EDGE_RESIST_CAP: number = 32;
/** 翻页动画时长（ms）：跟手松手后把整页滑到位 */
const PAGE_FLIP_MS: number = 200;
/** 回弹动画时长（ms）：未达阈值 → 撤销这次滑动 */
const SNAP_BACK_MS: number = 180;

/**
 * 构建标记：出现在"空课表诊断快照"的第一行。
 *
 * 用途只有一个 —— 确认设备上跑的**是不是刚装上的这一版**。此前排查"课表一片空白"时
 * 反复出现"改了没生效"的困惑，改完必须能自证：快照里的标记不对，说明装的是旧包，
 * 后面的所有现象都不必再分析。每次改动 `Index.ets` 请同步更新此串。
 */
const BUILD_TAG: string = 'build-2026-09-28-d';

/**
 * 刷新撞上"数据库被占用"后，隔多久自动重试一次。
 *
 * 这类失败是另一个进程（桌面卡片按 30 分钟策略刷新）正持着写锁造成的，毫秒级就过去了，
 * 所以给一次机会就够；等太久反而让首屏白屏时间变长。
 */
const REFRESH_RETRY_DELAY_MS: number = 600;

/**
 * 把 `Area.width` / `Area.height` 统一成 vp 数值。
 *
 * `Length = string | number | Resource`。实测 API 20 的 `onAreaChange` 给的是 **number**（vp），
 * 所以单纯判 `typeof === 'number'` 在真机/模拟器上通常能过；但 `Length` 的其余形态
 * （`'438.00'`、Resource）在别的版本上出现过，一旦漏判 `pagerWidth` 就恒为 0 ——
 * 后果是邻居页不渲染、翻页位移算不出来，而界面上只表现为"滑动没有反应"，
 * 排查时极难联想到是"量页宽"这一步。这里统一归一，成本为零。
 */
function vpOf(value: Length): number {
  if (typeof value === 'number') {
    return value;
  }
  const parsed: number = Number.parseFloat(`${value}`);
  return isNaN(parsed) ? 0 : parsed;
}

/** 课程详情 sheet 的空哨兵：course_row_id = 0 表示当前无选中课程 */
function emptyLessonRow(): LessonRow {
  return {
    course_row_id: 0,
    course_id: '',
    course_name: '',
    course_type: '',
    course_score: null,
    course_remark: '',
    semester_id: 0,
    teacher_id: 0,
    staff_no: 0,
    teacher_name: '',
    class_group_id: 0,
    class_id: '',
    class_name: '',
    population: 0,
    color: '#F0F0F0',
    time_period_id: 0,
    weekday: 1,
    start_time: 1,
    end_time: 1,
    class_room: '',
    remark: '',
    week_no: 0
  };
}

/**
 * 课表主页 + “我的”面板。
 *
 * 状态管理策略（兼容 docs/06 去 V2 方向）：
 *  - 页面只用 `@Local` 顶层引用；
 *  - 切换周 / 学期 / 教师 → 调 Repository 重取整树或整周数据，然后替换 `@Local` 引用；
 *  - 不依赖 `@ObjectLink` 做嵌套响应式。
 */
@Entry
@ComponentV2
struct Index {
  @Local ready: boolean = false;
  @Local message: string = '正在初始化数据库…';
  /**
   * 最近一次课表加载失败的原因（空串 = 正常）。
   *
   * 为什么要落到状态里并在页面上显式呈现：加载失败时 `semesterCourses` / `lessons` 都是空的，
   * 页面看起来就是"所有课程都不见了"，用户第一反应是数据丢了。有了这条提示 + 重试入口，
   * 才能一眼区分"读取失败"与"数据真的没有了"（后者在 ⋯→课表管理 里课程数仍不为 0）。
   */
  @Local loadError: string = '';
  /**
   * 空课表诊断快照（仅在"本周一节课都没有"时非空）。
   * 屏幕上"真的没排课"和"数据查不到 / 画不出来"长得一模一样，这组行是把两者分开的唯一手段。
   */
  @Local diagLines: string[] = [];
  @Local stats: DbStats = new DbStats();
  @Local semesters: Semester[] = [];
  @Local templates: ScheduleTemplate[] = [];
  @Local semesterCourses: SemesterCourses | null = null;
  @Local currentWeek: number = 1;
  @Local currentTeacherId: number = 0;
  @Local lessons: LessonRow[] = [];
  /**
   * 上一周 / 下一周课程，只服务"左右跟手预览"。
   * 与 `lessons`（当前周）一起构成轮播的三页，切周时直接在这三者之间**轮转**、不回表查询，
   * 所以手指还没推出去，相邻周的课表就已经准备好了。
   */
  @Local prevLessons: LessonRow[] = [];
  @Local nextLessons: LessonRow[] = [];
  /**
   * 周轮播的跟手位移（vp）：0 = 停在当前周，负 = 向左拖（露出下一周），正 = 向右拖（露出上一周）。
   * 手势过程中逐帧写入；松手后由 `settleDrag()` 决定"翻页"（动画到 ± 一页）还是"回弹撤销"（动画回 0）。
   */
  @Local dragOffset: number = 0;
  /** 轮播视口宽度（vp）：由 `onAreaChange` 实测，是页宽与翻页动画位移的唯一基准 */
  @Local pagerWidth: number = 0;
  @Local population: ClassPopulationRow[] = [];
  @Local busy: boolean = false;
  @Local activeTabIndex: number = 0;

  // ---- 机主（默认教师）首启录入 ----
  @Local ownerConfigured: boolean = false;
  @Local showOwnerSetup: boolean = false;
  @Local inputName: string = '';
  @Local inputStaffNo: string = '';
  @Local ownerName: string = '';
  @Local ownerStaffNo: number = 0;

  // ---- 课程详情 sheet ----
  @Local sheetLesson: LessonRow = emptyLessonRow();
  @Local showLessonSheet: boolean = false;
  /** sheet 内二级菜单：none（详情+按钮）/ checkin / checkinView（只读考勤）/ edit / delete */
  @Local sheetAction: string = 'none';
  /** 该时间段的全部生效周次（打开 sheet 时异步加载） */
  @Local sheetWeeks: number[] = [];
  @Local sheetBusy: boolean = false;
  /**
   * 「随机指定人数点名」的人数。
   *
   * 用 **± 步进器而不是输入框**：这个 sheet 是 `FIT_CONTENT`，面板高度一变内部点击
   * 就会命中旧布局（见 §12.3.2 第 17 点），而输入框会顶起软键盘、把面板整体推高。
   * 加减两下就能调的数字，不值得为它冒一次"点偏"的风险。
   */
  @Local sheetRandomCount: number = DEFAULT_RANDOM_COUNT;
  /**
   * 「查看本节课程情况」的只读快照：本班名单顺序 × 这一次课的点名结果。
   *
   * 与点名页不同，这里**只读**、只作展示：不挂手势、不落库，看完点「返回」即销毁。
   * 数据在打开那一刻一次性读齐（名单 + 签到记录两次查询），刷新靠**整体替换数组**，
   * 不就地改（就地改 @Local 数组的成员不触发刷新）。
   */
  @Local checkinViewRows: CheckinViewRow[] = [];
  /** 这一次课在库里到底有没有点名记录：false 时列表全显示"未点名"，面板给一句提示 */
  @Local checkinViewHasRecord: boolean = false;
  @Local checkinViewLoaded: boolean = false;
  /**
   * 读取失败的原因（空串 = 没出错）。
   *
   * 必须与"名单为空"分开：读库失败时列表同样是空的，若共用一句「还没有导入学生名单」，
   * 用户会去翻名册导入 —— 而真正的问题在数据库。宁可在面板里把错误摊出来。
   */
  @Local checkinViewError: string = '';

  // ---- 管理 sheet（首页顶栏 ic_more 弹出） ----
  @Local showManageSheet: boolean = false;
  /** sheet 内当前管理视图：menu / time / teacher / student / course / semester / checkin / setting / about */
  @Local manageView: string = 'menu';
  @Local manageBusy: boolean = false;
  /** 教师新增草稿 */
  @Local teacherDraftName: string = '';
  @Local teacherDraftStaffNo: string = '';
  /** 教师管理：表单态。0=收起（只显「添加教师」按钮）；-1=新增表单；>0=编辑该教师 */
  @Local teacherFormId: number = 0;
  /** 教师管理：多选模式（长按某项进入；选项全取消时自动退出） */
  @Local teacherSelectMode: boolean = false;
  /** 教师管理：多选模式里被选中的教师 id（长按 = 选中第一项，全选按钮批量补齐） */
  @Local teacherSelectedIds: number[] = [];
  /** 学期新建草稿 */
  @Local semesterDraftName: string = '';
  @Local semesterDraftWeeks: string = '20';
  @Local semesterDraftStart: string = '';
  /** 学期编辑（>0 表示正在编辑该学期）：名称 / 周数 / 开始日期 三件套一起改 */
  @Local semesterEditId: number = 0;
  @Local semesterEditName: string = '';
  @Local semesterEditWeeks: string = '20';
  @Local semesterEditStart: string = '';
  /** 学期管理：多选模式（长按某项进入；选项全取消时自动退出） */
  @Local semesterSelectMode: boolean = false;
  /** 学期管理：多选模式里被选中的学期 id（长按 = 选中第一项，全选按钮批量补齐） */
  @Local semesterSelectedIds: number[] = [];
  /** 学期管理：列表 / 新建 两态（新建页独占面板内容区；「查看」详情由 semesterEditId 驱动） */
  @Local semesterPageMode: string = 'list';
  /** 班级管理：当前查看名册的班级（空 = 显示班级列表） */
  @Local rosterClassId: string = '';
  @Local roster: ClassRoster | null = null;
  /**
   * 班级管理：正在查看/修改的学生 id（0 = 不在学生详情）。
   * 详情做成面板内的下一层（`manageView === 'studentDetail'`），而不是全屏浮层 ——
   * bindSheet 是系统层、一定压在页面内容之上，页面内的浮层反而会被它盖住。
   */
  @Local studentEditId: number = 0;
  /** 学生详情表单草稿：刻意用基本类型，避免把状态按值传进 @Builder 造成冻结 */
  @Local draftStudentNo: string = '';
  @Local draftStudentName: string = '';
  @Local draftStudentSex: string = '';
  @Local draftStudentAge: string = '';
  @Local draftStudentPhone: string = '';
  @Local draftStudentRemark: string = '';
  @Local studentBusy: boolean = false;
  @Local rosterImportBusy: boolean = false;
  /** 名册多选模式：长按某个学生进入，底部操作行换成「全选/删除」 */
  @Local rosterSelectMode: boolean = false;
  /** 多选模式下已勾选的学生主键；整体替换数组触发 UI 刷新，不就地改 */
  @Local rosterSelectedIds: number[] = [];
  /**
   * 导出用的签到快照：**导出前现读一次**，不参与 UI 观察（名册列表本身不显示考勤）。
   *
   * 只读不显示却要放成结构体字段、而不是"导出时局部变量"的原因：读库是异步的，
   * 而 `rosterRows()` 是同步的纯拼表函数（模板导出也走它），同步函数没法 await。
   */
  private rosterAttend: AttendanceExportRow[] = [];

  // ---- 课表分享 / 导入（顶栏 ic_share 导出、ic_download 导入，都走管理面板的 export / import 视图） ----
  /** 导出面板：选中的学期 id */
  @Local pkgSemesterId: number = 0;
  /** 导出面板：选中的时间表 id */
  @Local pkgTemplateId: number = 0;
  /** 导出/导入进行中（禁用按钮，防重复触发） */
  @Local pkgBusy: boolean = false;

  // ---- 界面设置（主题色 / 今日高亮色，落地在 app_setting） ----
  @Local uiThemeColor: string = THEME_COLOR_DEFAULT;
  @Local uiTodayColor: string = TODAY_COLOR_DEFAULT;
  @Local showUiColorPicker: boolean = false;
  /** 当前拾色目标：theme（主题色）/ today（今日高亮色） */
  @Local colorTarget: string = 'theme';
  @Local pickerHue: number = 0;
  @Local pickerSaturation: number = 1;
  @Local pickerValue: number = 1;
  @Local pickerAlpha: number = 1;
  @Local pickerBoxSize: number = 260;
  /** 打开拾色器时备份原色：拖动时实时预览，取消（✕/点遮罩）时回滚到它 */
  @Local colorBackup: string = '';

  // ---- 上课提醒（"我的 → 上课提醒"，落地在 app_setting，提醒本身由 LessonReminder 调度） ----
  @Local notifyNextDay: boolean = false;
  @Local notifyAhead: boolean = false;
  /** 提前量（分钟）的有效值 —— 真正参与调度的是它，不是输入框里的文本 */
  @Local notifyAheadMinutes: number = NOTIFY_AHEAD_DEFAULT_MINUTES;
  /** 输入框文本：用户打字过程中是半成品（空串、"3分钟"），失焦/回车时才收敛成分钟数 */
  @Local notifyAheadText: string = `${NOTIFY_AHEAD_DEFAULT_MINUTES}`;

  // ---- 管理菜单顶部的周次滑杆 ----
  @Local weekSlider: number = 1;
  /**
   * 上一次 refresh 载入的学期 id；-1 表示还没载入过。
   * 用于区分"同一个学期内的刷新（保留用户所在周）"与"冷启动 / 切换学期（落到今天所在周）"。
   */
  private loadedSemesterId: number = -1;
  /** 冷启动那次 `refresh()` 的 Promise：卡片点课的消费逻辑要等它，而不是再发一次并发刷新 */
  private initRefresh: Promise<void> | undefined = undefined;
  /** 冷启动首次加载是否已结束（用于区分"等首次加载"与"自己刷一次"） */
  private firstLoadDone: boolean = false;
  /**
   * 底部导航的翻页控制器。
   *
   * 只有"从卡片空态点进来"时才用它：用户可能把应用停在「我的」那一屏，而卡片上写的是
   * "今天没课啦"——点进去当然是**看课表**，所以要把页签切回「首页」。
   * 页签切换只能靠控制器（`Tabs` 的 `index` 参数是初值，不是可观察状态）。
   */
  private tabsController: TabsController = new TabsController();

  // ---- 时间管理：多选模式（编辑走全屏页 pages/TemplateEdit） ----
  @Local tplSelectMode: boolean = false;
  /** 时间管理：多选模式里被选中的时间表 id（长按 = 选中第一项，全选按钮批量补齐） */
  @Local tplSelectedIds: number[] = [];
  /** 从全屏时间表编辑页返回后要恢复的管理视图（空 = 不恢复） */
  @Local restoreManageView: string = '';
  /** 待办面板刷新信号：从全屏新增页返回（onPageShow）后自增，面板 @Monitor 重载 */
  @Local todoRefreshTick: number = 0;

  aboutToAppear(): void {
    this.initRefresh = this.refresh();
    this.initRefresh.then(() => {
      this.firstLoadDone = true;
    });
    // 冷启动就可能是"从卡片点课进来的"：请求在 EntryAbility.onCreate 里已登记好
    this.consumeCardLaunch();
  }

  onPageShow(): void {
    // 从卡片点课进来（或应用在后台被卡片点开）：由 consumeCardLaunch 统一"刷新 + 定位"，
    // 这里不再单独刷新，避免两次 refresh 并发把定位好的周次又拉回今天所在周
    if (WidgetLaunch.hasPending()) {
      this.consumeCardLaunch();
      return;
    }
    // 从课程编辑页 / 全屏时间表编辑页返回后刷新课表
    if (this.ready) {
      this.refresh();
    }
    // 从待办全屏新增页返回：自增信号让待办面板重载
    this.todoRefreshTick++;
    // 全屏时间表编辑页返回：把管理面板恢复到离开时那一屏（通常是「时间管理」）
    if (this.restoreManageView.length > 0) {
      const view: string = this.restoreManageView;
      this.restoreManageView = '';
      this.openManageSheet(view);
    }
  }

  /**
   * 消费"卡片被点击"留下的待办（点某节课 / 点空态卡片两种，见 `openLessonFromCard`）。
   *
   * 为什么在 `onPageShow` / `aboutToAppear` 而不是靠状态观察：
   * 请求来自 EntryAbility（另一个生命周期入口），只需要"取一次、处理一次"，
   * 用 `WidgetLaunch.take()` 这个显式交接点最简单，也不必给 V2 组件引入全局可观察状态。
   *
   * 冷启动时首次 `refresh()` 已在 `aboutToAppear` 里跑起来，这里**等它完成**而不是再发一次：
   * 两次并发刷新会在"冷启动落到今天所在周"这件事上互相覆盖，
   * 可能把刚刚切到目标周的结果又拉回去。
   */
  private async consumeCardLaunch(): Promise<void> {
    if (!WidgetLaunch.hasPending()) {
      return;
    }
    const req: WidgetOpenRequest | undefined = WidgetLaunch.take();
    if (req === undefined) {
      return;
    }
    try {
      const first: Promise<void> | undefined = this.initRefresh;
      if (!this.firstLoadDone && first !== undefined) {
        await first;
      } else {
        await this.refresh();
      }
      await this.openLessonFromCard(req);
    } catch (e) {
      Logger.error(TAG, `按卡片定位课程失败：${ScheduleRepository.describeError(e)}`);
      this.notify('从卡片打开失败');
    }
  }

  /**
   * 卡片被点击 → 落到应用里。
   *
   * 两种意图共用这条通道，靠"有没有时间段 id"分流（见 `WidgetOpenRequest.periodId`）：
   *  - **点某一行课程** → 按卡片给的"周次 + 时间段 id"找到那一课次并打开详情面板；
   *  - **点空态卡片** → 没有课可开，只把用户带到课表（`openTimetableFromCard`）。
   */
  private async openLessonFromCard(req: WidgetOpenRequest): Promise<void> {
    if (req.periodId <= 0) {
      await this.openTimetableFromCard(req);
      return;
    }
    const sem: Semester | undefined = this.currentSemester();
    if (sem === undefined) {
      this.notify('还没有学期，无法定位卡片上的课程');
      return;
    }
    const week: number = clamp(req.weekNo, 1, sem.total_weeks);
    if (this.currentWeek !== week) {
      await this.switchWeek(week);
    }
    let lesson: LessonRow | undefined = this.lessonOfPeriod(this.lessons, req);
    if (lesson === undefined) {
      lesson = await this.findLessonAcrossTeachers(sem.id, week, req);
    }
    if (lesson === undefined) {
      this.notify('卡片上的这节课已不在课表中（可能已被删除）');
      return;
    }
    // 管理面板此刻若开着，先关掉，避免两个 sheet 叠在一起
    this.showManageSheet = false;
    const found: LessonRow = lesson;
    this.notify('');
    this.openLessonSheet(found);
  }

  /**
   * 卡片**空态**被点击：把用户带到课表页。
   *
   * 没有"某一节课"要打开，所以这里只做三件事：收起可能还开着的面板、把底部页签切回「首页」、
   * 把周次对齐到卡片显示的那一周。用户上次可能把应用翻到了别的周（甚至停在「我的」那一屏）
   * 就回了桌面，这一下能把课表拉回"卡片刚说的那一周" —— 否则会出现"卡片说今天没课，
   * 点进去看到的是另一周的课表"。
   *
   * 环境类空态（`还没有学期` / `学期还没开始|已结束` / `还没选择教师`）没有有效周次
   * （`weekNo` 为 0），那就只拉起应用并切到课表页 —— 课表页本身就是这几种情况的提示页。
   */
  private async openTimetableFromCard(req: WidgetOpenRequest): Promise<void> {
    this.showLessonSheet = false;
    this.showManageSheet = false;
    // 页签只有控制器能切（`Tabs` 的 index 是初值）；`activeTabIndex` 同步一份，
    // 因为"本来就停在第 0 页"时不会触发 onChange，导航栏的选中态得靠它保证一致。
    this.tabsController.changeIndex(0);
    this.activeTabIndex = 0;
    if (req.weekNo <= 0) {
      return;
    }
    const sem: Semester | undefined = this.currentSemester();
    if (sem === undefined) {
      return;
    }
    const week: number = clamp(req.weekNo, 1, sem.total_weeks);
    if (this.currentWeek !== week) {
      await this.switchWeek(week);
    }
  }

  /** 在本周课程里按时间段 id 找那一课次（顺带核对星期，防串周） */
  private lessonOfPeriod(rows: LessonRow[], req: WidgetOpenRequest): LessonRow | undefined {
    for (let i = 0; i < rows.length; i++) {
      if (rows[i].time_period_id === req.periodId && rows[i].week_no === req.weekNo) {
        return rows[i];
      }
    }
    for (let i = 0; i < rows.length; i++) {
      if (rows[i].time_period_id === req.periodId) {
        return rows[i];
      }
    }
    return undefined;
  }

  /** 兜底：本学期其它教师名下同周同时间段的课（用户切了教师视角时卡片仍能定位） */
  private async findLessonAcrossTeachers(semesterId: number, week: number,
    req: WidgetOpenRequest): Promise<LessonRow | undefined> {
    if (this.semesterCourses === null) {
      return undefined;
    }
    const repo: ScheduleRepository = ScheduleRepository.getInstance();
    const holders: TeacherCourses[] = this.semesterCourses.teacher_courses;
    for (let i = 0; i < holders.length; i++) {
      const teacherId: number = holders[i].teacher.id;
      if (teacherId === this.currentTeacherId) {
        continue;
      }
      const rows: LessonRow[] = await repo.loadWeekLessons(semesterId, teacherId, week);
      const hit: LessonRow | undefined = this.lessonOfPeriod(rows, req);
      if (hit !== undefined) {
        return hit;
      }
    }
    return undefined;
  }

  private context(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }

  /**
   * 读库 → 装配整页状态。
   *
   * @param isRetry 本次是不是"撞上数据库被占用之后的自动重试"。自动重试只给一次，
   *                避免真的坏了时无限循环（`retryLoad()` 那个手动按钮不受此限）。
   */
  private async refresh(isRetry: boolean = false): Promise<void> {
    try {
      const repo: ScheduleRepository = ScheduleRepository.getInstance();
      await repo.init(this.context());

      const space: Workspace = await repo.loadWorkspace();
      this.semesters = space.semesters;
      this.templates = space.templates;

      // 机主信息：未配置 → 强制进入录入门禁
      this.ownerConfigured = space.setting.hasOwner();
      this.ownerName = space.setting.owner_name;
      this.ownerStaffNo = space.setting.owner_staff_no;
      this.inputName = this.ownerName;
      this.inputStaffNo = this.ownerStaffNo > 0 ? `${this.ownerStaffNo}` : '';
      this.showOwnerSetup = !this.ownerConfigured;

      // 界面颜色（主题色 / 今日高亮色）：库里可能是脏值，用 colorOr 回退到默认色
      this.uiThemeColor = colorOr(space.setting.theme_color, THEME_COLOR_DEFAULT);
      this.uiTodayColor = colorOr(space.setting.today_color, TODAY_COLOR_DEFAULT);

      // 上课提醒设置：冷启动对齐一次。输入框只在**首次加载**时回填 ——
      // 刷新很频繁（切周、编辑返回都会触发），每次都覆盖的话，用户正打字时会被后台刷新抹掉。
      this.notifyNextDay = space.setting.notify_next_day;
      this.notifyAhead = space.setting.notify_ahead;
      this.notifyAheadMinutes = clampNotifyMinutes(space.setting.notify_ahead_minutes);
      if (!this.ready) {
        this.notifyAheadText = `${this.notifyAheadMinutes}`;
      }

      if (this.semesters.length === 0) {
        this.ready = true;
        this.diagLines = [];
        this.notify('数据库就绪，但没有任何学期');
        // 学期被删光时也要重建一次提醒：调度器发现"没有学期"就把旧的清干净，
        // 否则会留下几条指向已删课表的提醒，用户既看不到也无从取消。
        await LessonReminder.sync(this.context());
        return;
      }

      // 定位当前学期：setting.semester_id 优先，否则取第一个
      let currentSemester: Semester | undefined = undefined;
      for (let i = 0; i < this.semesters.length; i++) {
        if (this.semesters[i].id === space.setting.semester_id) {
          currentSemester = this.semesters[i];
          break;
        }
      }
      if (currentSemester === undefined) {
        currentSemester = this.semesters[0];
      }

      // 加载整学期对象图（含教师、课程、班级、时间段）
      this.semesterCourses = await repo.loadSemesterCourses(currentSemester.id);

      // 当前教师：setting.teacher_id 优先，否则默认教师（机主），否则第一个
      let teacher: Teacher | undefined = undefined;
      if (this.currentTeacherId === 0) {
        // 冷启动以 setting 为准
        this.currentTeacherId = space.setting.teacher_id;
      }
      const holders: TeacherCourses[] = this.semesterCourses.teacher_courses;
      for (let i = 0; i < holders.length; i++) {
        if (holders[i].teacher.id === this.currentTeacherId) {
          teacher = holders[i].teacher;
          break;
        }
      }
      if (teacher === undefined && holders.length > 0) {
        teacher = holders[0].teacher;
        this.currentTeacherId = teacher.id;
      }

      // 当前周：冷启动 / 首次加载 / 切换学期 → 落到"今天所在周次"
      // （学期未开始或已结束则退回第 1 周）；
      // 同一个学期内的刷新（编辑返回等）→ 保留用户当前浏览的周次，不跳周。
      const semOfLoad: Semester = this.semesterCourses.semester;
      const todayWeek: number = semOfLoad.currentWeek();
      if (!this.ready || this.loadedSemesterId !== semOfLoad.id) {
        this.currentWeek = todayWeek;
      } else if (this.currentWeek < 1 || this.currentWeek > semOfLoad.total_weeks) {
        this.currentWeek = todayWeek;
      }
      this.loadedSemesterId = semOfLoad.id;
      this.weekSlider = this.currentWeek;

      // 加载本周课程与统计
      if (teacher !== undefined) {
        this.lessons = await repo.loadWeekLessons(currentSemester.id, teacher.id, this.currentWeek);
      } else {
        this.lessons = [];
      }
      // 相邻两周一并预载：左右滑动要"跟手就能看到上/下一周"，内容必须先就位
      await this.loadNeighborLessons();
      this.stats = await repo.stats(currentSemester.id);
      this.population = await repo.populationReport(currentSemester.id);

      // 空表自证：本周一节都没有时，把"库里到底有什么"摊在屏幕上。
      // 这一步只读、且自带 try/catch，绝不会把课表加载本身弄挂。
      await this.collectEmptyDiag(repo, currentSemester, teacher);

      this.ready = true;
      this.loadError = '';
      this.notify('');
      // 课表可能刚被改过，提醒内容要跟着变：按当前课表重建未来几天的提醒。
      // 调度器自带 20 秒节流（refresh 触发很频繁）与整体 try/catch，不会拖累课表加载。
      await LessonReminder.sync(this.context());
      Logger.info(TAG, '刷新完成');
    } catch (e) {
      // 数据库被另一个进程（桌面卡片的定时刷新）短暂占用时，等一拍重来一次就恢复了：
      // 14800024「database file is locked」是**瞬时**的锁竞争，不是数据坏了 ——
      // 直接按失败处理会把整页打成"课表加载失败 + 一片空白"，用户第一反应是数据丢了。
      if (!isRetry && isDbLocked(e)) {
        Logger.warn(TAG, `刷新遇数据库占用，${REFRESH_RETRY_DELAY_MS}ms 后自动重试一次`);
        await delay(REFRESH_RETRY_DELAY_MS);
        await this.refresh(true);
        return;
      }
      this.ready = true;
      this.diagLines = [];
      this.loadError = ScheduleRepository.describeError(e);
      this.notify(`课表加载失败：${this.loadError}`);
      Logger.error(TAG, `刷新失败：${this.loadError}`);
    }
  }

  /**
   * 收集"空课表"诊断快照。
   *
   * 只在**本周一节课都没有**时填充 —— 正常显示课表时立刻清空，不占屏幕。
   *
   * 为什么要做这件事：课表空白有两个完全不同的原因，而屏幕上表现一致：
   *   A. 库里确实没有这节课（写路径 / 教师归属 / 周次没覆盖到本周）；
   *   B. 库里有、查询也取到了，但没能画出来（`ForEach` key 复用、条件分支、布局裁剪）。
   * 只看屏幕永远分不清 A 和 B，于是每轮排查都在猜。把各层原始计数摊出来，一次就能判：
   *   - 「该教师全部周 = 0」 → A（数据没写进去 / 挂错教师）
   *   - 「该教师全部周 > 0，但它落在第 x,y 周，而当前显示第 z 周」 → 周次没覆盖（A 的变体）
   *   - 「本周 N 节，N > 0」 → B（数据在，是渲染问题）
   *
   * 整段包 try/catch：诊断自身失败只留一行提示，不影响课表加载。
   */
  private async collectEmptyDiag(repo: ScheduleRepository, sem: Semester,
    teacher: Teacher | undefined): Promise<void> {
    if (this.lessons.length > 0) {
      this.diagLines = [];
      return;
    }
    try {
      const teacherId: number = teacher === undefined ? -1 : teacher.id;
      const holderCount: number = this.semesterCourses === null
        ? 0 : this.semesterCourses.teacher_courses.length;
      const mine: number = teacherId > 0
        ? await repo.countLessonsOfTeacher(sem.id, teacherId) : 0;
      const weeks: number[] = teacherId > 0
        ? await repo.weeksOfTeacher(sem.id, teacherId) : [];
      const all: number = await repo.countLessonsOfSemester(sem.id);

      const lines: string[] = [];
      lines.push(`诊断快照 ${BUILD_TAG}`);
      lines.push(`学期 #${sem.id}「${sem.name}」共 ${sem.total_weeks} 周（按今天算在第 ${sem.currentWeek()} 周）`);

      // 全部学期：能一眼看出"课是不是建在了另一个学期里"
      const semLabels: string[] = [];
      for (let i = 0; i < this.semesters.length; i++) {
        const s: Semester = this.semesters[i];
        semLabels.push(`${s.id === sem.id ? '▶' : ''}#${s.id}「${s.name}」`);
      }
      lines.push(`全部学期 ${this.semesters.length} 个（▶ 为当前）：${semLabels.join(' ')}`);

      lines.push(teacher === undefined
        ? `教师未匹配到（currentTeacherId=${this.currentTeacherId}，本学期登记 ${holderCount} 位）`
        : `教师 #${teacher.id}「${teacher.displayName()}」（本学期登记 ${holderCount} 位）`);

      // 本学期每位教师的课程数 / 时间段数：能一眼看出"课是不是挂在另一位教师名下"
      if (this.semesterCourses !== null) {
        const holderLabels: string[] = [];
        for (let i = 0; i < this.semesterCourses.teacher_courses.length; i++) {
          const tc: TeacherCourses = this.semesterCourses.teacher_courses[i];
          let periods: number = 0;
          for (let j = 0; j < tc.courses.length; j++) {
            for (let k = 0; k < tc.courses[j].class_groups.length; k++) {
              periods += tc.courses[j].class_groups[k].time_periods.length;
            }
          }
          holderLabels.push(`${tc.teacher.id === teacherId ? '▶' : ''}${tc.teacher.displayName()}:`
            + `${tc.courses.length}门/${periods}段`);
        }
        lines.push(`本学期各教师（▶ 为当前）：${holderLabels.join(' ')}`);
      }

      lines.push(`当前显示：第 ${this.currentWeek} 周`);
      lines.push(`本周 ${this.lessons.length} 节｜上周 ${this.prevLessons.length}｜下周 ${this.nextLessons.length} 节`);
      lines.push(weeks.length === 0
        ? `该教师在本学期全部周共 ${mine} 行（一节都没有）`
        : `该教师在本学期全部周共 ${mine} 行，落在第 ${weeks.join(',')} 周`);
      lines.push(`本学期全部教师共 ${all} 行（v_lesson 展开后）`);
      lines.push(`库内 course ${this.stats.courses} 门｜time_period ${this.stats.periods} 段｜period_week ${this.stats.weeks} 行`);
      lines.push(`连接 ready=${repo.isReady()}｜学期对象=${this.semesterCourses === null ? '未加载' : '已加载'}`);
      this.diagLines = lines;
      Logger.info(TAG, `空表诊断：${lines.join(' | ')}`);
    } catch (e) {
      this.diagLines = [`诊断收集失败：${ScheduleRepository.describeError(e)}`];
      Logger.error(TAG, `空表诊断收集失败：${ScheduleRepository.describeError(e)}`);
    }
  }

  /** 加载失败后的重试（失败提示条上的按钮）：完整重跑一次 refresh */
  private async retryLoad(): Promise<void> {
    this.loadError = '';
    await this.refresh();
  }

  /** 切换周后只刷新本周课程，不重载整学期 */
  private async switchWeek(week: number): Promise<void> {
    if (this.semesterCourses === null) {
      return;
    }
    const totalWeeks: number = this.semesterCourses.semester.total_weeks;
    const next: number = clamp(week, 1, totalWeeks);
    if (next === this.currentWeek) {
      return;
    }
    this.currentWeek = next;
    this.weekSlider = next;
    await this.reloadWeekLessons();
  }

  // ---------------------------------------------------------------- 左右滑动切周（跟手轮播）

  /** 还有上一周吗（第 1 周再往右没有相邻周，只能"拽一下再回弹"） */
  private hasPrevWeek(): boolean {
    return this.currentWeek > 1;
  }

  /** 还有下一周吗（最后一周再往左同理） */
  private hasNextWeek(): boolean {
    if (this.semesterCourses === null) {
      return false;
    }
    return this.currentWeek < this.semesterCourses.semester.total_weeks;
  }

  /**
   * 预载相邻两周的课程，供"左右跟手预览"使用。
   *
   * 只查相邻两周，不重载整学期；返回后校验"基准周没变"再落状态 —— 否则一次慢查询回来时
   * 用户已经又切了几周，会把过期数据写成当前周的邻居。
   */
  private async loadNeighborLessons(): Promise<void> {
    if (this.semesterCourses === null || this.currentTeacherId <= 0) {
      this.prevLessons = [];
      this.nextLessons = [];
      return;
    }
    const base: number = this.currentWeek;
    const teacherId: number = this.currentTeacherId;
    const semesterId: number = this.semesterCourses.semester.id;
    const repo: ScheduleRepository = ScheduleRepository.getInstance();
    const prev: LessonRow[] = base > 1
      ? await repo.loadWeekLessons(semesterId, teacherId, base - 1) : [];
    const next: LessonRow[] = base < this.semesterCourses.semester.total_weeks
      ? await repo.loadWeekLessons(semesterId, teacherId, base + 1) : [];
    if (this.currentWeek !== base) {
      return;
    }
    this.prevLessons = prev;
    this.nextLessons = next;
  }

  /**
   * 边缘阻尼：拖向"不存在的那一周"时把位移压到 1/4 并封顶。
   * 观感是"拽得动但拽不远"，松手必然回弹 —— 相当于这次滑动被撤销。
   */
  private resistOffset(raw: number): number {
    const atEdge: boolean = (raw < 0 && !this.hasNextWeek()) || (raw > 0 && !this.hasPrevWeek());
    if (!atEdge) {
      return raw;
    }
    return clamp(raw / 4, -EDGE_RESIST_CAP, EDGE_RESIST_CAP);
  }

  /**
   * 松手结算一次滑动。
   *
   * - 越过阈值、且那一侧确实有相邻周 → **翻页**：先把整页动画滑到位；动画结束的那一帧里
   *   同时"换数据 + 位移归零"，视口里始终是同一张周课表，看不出跳变。
   * - 其余情况（没越过阈值 / 那一侧没有相邻周 / 手势被打断）→ **撤销**：动画回弹到 0，周次不变。
   */
  private settleDrag(offsetX: number): void {
    const pageWidth: number = this.pagerWidth;
    const threshold: number = pageWidth > 0
      ? Math.max(DRAG_THRESHOLD_MIN_VP, pageWidth * DRAG_THRESHOLD_RATIO)
      : DRAG_THRESHOLD_MIN_VP;
    const goNext: boolean = offsetX <= -threshold && this.hasNextWeek();
    const goPrev: boolean = offsetX >= threshold && this.hasPrevWeek();

    if (!goNext && !goPrev) {
      animateTo({
        duration: SNAP_BACK_MS,
        curve: Curve.EaseOut
      }, () => {
        this.dragOffset = 0;
      });
      return;
    }

    animateTo({
      duration: PAGE_FLIP_MS,
      curve: Curve.FastOutSlowIn,
      onFinish: () => {
        this.dragOffset = 0;
        this.commitWeek(goNext);
      }
    }, () => {
      this.dragOffset = goNext ? -pageWidth : pageWidth;
    });
  }

  /**
   * 提交切周：把相邻周的课程**就地提升**为当前周。
   *
   * 与 `switchWeek` 的区别是不回表 —— `lessons / prevLessons / nextLessons` 三份数据轮转，
   * 当前周的新内容在手指松开前就已加载完毕，因此不会出现"标题已经是第 N+1 周、格子还是
   * 第 N 周"的空档。随后异步补载新的相邻周。
   */
  private commitWeek(goNext: boolean): void {
    if (this.semesterCourses === null) {
      return;
    }
    const center: LessonRow[] = this.lessons;
    if (goNext) {
      this.currentWeek = this.currentWeek + 1;
      this.lessons = this.nextLessons;
      this.prevLessons = center;
    } else {
      this.currentWeek = this.currentWeek - 1;
      this.lessons = this.prevLessons;
      this.nextLessons = center;
    }
    this.weekSlider = this.currentWeek;
    this.loadNeighborLessons();
  }

  /** 点击日期 → 跳回今天所在周（学期已结束 / 未开始 / 已在本周则只提示） */
  private goToTodayWeek(): void {
    if (this.semesterCourses === null) {
      return;
    }
    const sem: Semester = this.semesterCourses.semester;
    if (sem.hasEnded()) {
      this.notify(`${sem.name} 已结束，没有"当前周"可跳转`);
      return;
    }
    if (sem.notStarted()) {
      this.notify(`${sem.name} 尚未开始，当前显示第 1 周`);
      return;
    }
    const todayWeek: number = sem.currentWeek();
    if (todayWeek === this.currentWeek) {
      this.notify(`已在当前周（第${this.currentWeek}周）`);
      return;
    }
    this.switchWeek(todayWeek);
  }

  private async reloadWeekLessons(): Promise<void> {
    if (this.semesterCourses === null || this.currentTeacherId <= 0) {
      this.lessons = [];
      this.prevLessons = [];
      this.nextLessons = [];
      return;
    }
    const repo: ScheduleRepository = ScheduleRepository.getInstance();
    this.lessons = await repo.loadWeekLessons(this.semesterCourses.semester.id, this.currentTeacherId, this.currentWeek);
    await this.loadNeighborLessons();
  }

  /**
   * 统一提示出口：所有操作反馈都走 AlertDialog 弹窗。
   * `message` 状态仅保留最近一条文案（日志 / 首启页兜底展示），顶栏不再显示它。
   */
  private notify(msg: string): void {
    this.message = msg;
    if (msg.length === 0) {
      return;
    }
    AlertDialog.show({
      message: msg,
      autoCancel: true,
      alignment: DialogAlignment.Center,
      confirm: {
        value: '知道了',
        action: () => {
        }
      }
    });
  }

  /**
   * 顶部第一行：学期名 + 周次。
   * 学期已结束时不再显示周次（此时"第 N 周"没有意义），改为提示「已结束」。
   */
  private semesterLine(): string {
    const sem: Semester | undefined = this.currentSemester();
    if (sem === undefined) {
      return '';
    }
    return sem.hasEnded() ? `${sem.name} · 第${this.currentWeek}周 · 已结束` : `${sem.name} · 第${this.currentWeek}周`;
  }

  /** 顶部第二行：今天的日期（如“9月18日 周五”），替代原先重复的“学期 · 周次” */
  private todayLabel(): string {
    const today: Date = DateUtil.today();
    const weekday: number = today.getDay();
    const label: string = weekday === 0 ? WEEKDAY_LABELS[6] : WEEKDAY_LABELS[weekday - 1];
    return `${today.getFullYear()}年${today.getMonth() + 1}月${today.getDate()}日 周${label}`;
  }

  /**
   * 切换教师后重载本周课程。
   *
   * 注意这里**必须显式落盘指向**（`savePointers`）：它直接决定"下次打开看到谁的课表"。
   * 早先只改内存里的 `currentTeacherId`，于是——在教师管理里切到 B 老师、并且把课程都建在 B 名下，
   * 退出应用再进来时 `app_setting.teacher_id` 还停在 A 老师：A 名下没有课，课表整片空白，
   * 看起来就像"所有课程都不见了"。docs/01 FR-TEACHER-03 / AC-04 明确要求这个选择可持久化。
   */
  private async switchTeacher(teacherId: number): Promise<void> {
    this.currentTeacherId = teacherId;
    const sem: Semester | undefined = this.currentSemester();
    if (sem !== undefined) {
      try {
        await ScheduleRepository.getInstance().savePointers(sem.id, teacherId);
      } catch (e) {
        this.notify(`教师视角已切换，但保存指向失败：${ScheduleRepository.describeError(e)}`);
      }
    }
    await this.reloadWeekLessons();
  }

  /** 切换学期：保存指向并整页刷新 */
  private async switchSemester(semesterId: number): Promise<void> {
    if (this.semesterCourses === null || this.semesterCourses.semester.id === semesterId) {
      return;
    }
    let teacherId: number = 0;
    const target: Semester | undefined = this.findSemester(semesterId);
    if (target === undefined) {
      return;
    }
    // 尝试找目标学期里同 staff_no 的教师，保持视角连续
    const courses: SemesterCourses = await ScheduleRepository.getInstance().loadSemesterCourses(semesterId);
    if (this.ownerStaffNo > 0) {
      for (let i = 0; i < courses.teacher_courses.length; i++) {
        if (courses.teacher_courses[i].teacher.staff_no === this.ownerStaffNo) {
          teacherId = courses.teacher_courses[i].teacher.id;
          break;
        }
      }
    }
    if (teacherId === 0 && courses.teacher_courses.length > 0) {
      teacherId = courses.teacher_courses[0].teacher.id;
    }
    await ScheduleRepository.getInstance().savePointers(semesterId, teacherId);
    this.currentTeacherId = teacherId;
    await this.refresh();
  }

  private findSemester(id: number): Semester | undefined {
    for (let i = 0; i < this.semesters.length; i++) {
      if (this.semesters[i].id === id) {
        return this.semesters[i];
      }
    }
    return undefined;
  }

  private currentSemester(): Semester | undefined {
    return this.semesterCourses === null ? undefined : this.semesterCourses.semester;
  }

  private currentTeacher(): Teacher | undefined {
    if (this.semesterCourses === null) {
      return undefined;
    }
    for (let i = 0; i < this.semesterCourses.teacher_courses.length; i++) {
      const t: Teacher = this.semesterCourses.teacher_courses[i].teacher;
      if (t.id === this.currentTeacherId) {
        return t;
      }
    }
    return undefined;
  }

  private selectedTemplate(): ScheduleTemplate | undefined {
    const sem: Semester | undefined = this.currentSemester();
    if (sem === undefined) {
      return undefined;
    }
    for (let i = 0; i < this.templates.length; i++) {
      if (this.templates[i].id === sem.schedule_id) {
        return this.templates[i];
      }
    }
    return this.templates.length > 0 ? this.templates[0] : undefined;
  }

  private sessionCount(): number {
    const tpl: ScheduleTemplate | undefined = this.selectedTemplate();
    return tpl === undefined ? 12 : tpl.slots.length;
  }

  private sessionRange(): number[] {
    const result: number[] = [];
    for (let i = 1; i <= this.sessionCount(); i++) {
      result.push(i);
    }
    return result;
  }

  private slotAt(sessionNo: number): ScheduleSlot | undefined {
    const tpl: ScheduleTemplate | undefined = this.selectedTemplate();
    if (tpl === undefined) {
      return undefined;
    }
    for (let i = 0; i < tpl.slots.length; i++) {
      if (tpl.slots[i].session_no === sessionNo) {
        return tpl.slots[i];
      }
    }
    return undefined;
  }

  /**
   * 指定周的 7 个日期（周一~周日）。
   *
   * 带 `week` 参数是因为课表现在是"三页轮播"：左右两页要各自渲染**相邻周**的日期，
   * 不能再默认读 `currentWeek`。周次越界（第 0 周 / 超出总周数）返回空数组。
   */
  private weekDates(week: number): Date[] {
    const sem: Semester | undefined = this.currentSemester();
    if (sem === undefined || week < 1 || week > sem.total_weeks) {
      return [];
    }
    const matrix: Date[][] = DateUtil.getAllWeekDates(sem.startDate(), sem.total_weeks);
    const idx: number = clamp(week, 1, matrix.length) - 1;
    return matrix[idx];
  }

  /** 指定周第一天（周一）的月份标签，如“9月”；无数据返回空串 */
  private weekFirstMonthLabel(week: number): string {
    const dates: Date[] = this.weekDates(week);
    if (dates.length === 0) {
      return '';
    }
    return `${dates[0].getMonth() + 1}月`;
  }

  /** 从某一周的课程里挑出某一天的所有课（原来固定读 `this.lessons`，现在按页传入） */
  private lessonsOfDay(weekday: number, weekLessons: LessonRow[]): LessonRow[] {
    const result: LessonRow[] = [];
    for (let i = 0; i < weekLessons.length; i++) {
      if (weekLessons[i].weekday === weekday) {
        result.push(weekLessons[i]);
      }
    }
    return result;
  }

  /**
   * 轮播某一页（槽位）对应哪一周：-1 上一周 / 0 当前周 / +1 下一周。
   *
   * **必须在 @Builder 内部调用，不要把它算好再当参数传进 @Builder。**
   *
   * ArkUI 的规则是：@Builder 的参数按值传递时**不参与状态观察** ——
   * "状态变量的改变不会引起 @Builder 方法内的 UI 刷新"。所以轮播三页一律**不接收**
   * 周次或课程数组（那会让整页在首帧之后彻底冻结），只接收一个恒定的槽位，
   * 真正的数据在这里现读现取，依赖才建立得起来。
   */
  private weekOfSlot(slot: number): number {
    return clamp(this.currentWeek + slot, 1, this.weekTotal());
  }

  /**
   * 某一页（槽位）的星期条上，第 `index` 天是不是"今天"。
   *
   * 单独拎出来是因为 `@Builder` 函数体**只允许写 UI 语法、不能声明局部变量**，
   * 所以 weekHeader 里没法先取一次周次再复用；这个方法让每个调用点都是一次
   * 直接的状态读取（依赖因此建立得起来），同时保持可读。
   */
  private isTodayInSlot(slot: number, index: number): boolean {
    return this.isTodayInWeek(this.weekOfSlot(slot), index);
  }

  /** 某一页（槽位）的课程数组；理由同 `weekOfSlot` —— 直接读 `this.*` 才有依赖 */
  private lessonsOfSlot(slot: number): LessonRow[] {
    if (slot < 0) {
      return this.prevLessons;
    }
    if (slot > 0) {
      return this.nextLessons;
    }
    return this.lessons;
  }

  /**
   * 某一天课程的"内容签名"，用来给 `weekPage` 外层 ForEach 生成 key。
   *
   * **这是"新增课程后课表不刷新 / 退出后台再进来课程全不显示"的根因（ForEach 复用陷阱）。**
   *
   * `weekPage` 里的外层 ForEach 只按 `${week}-${weekday}` 建 key，而 `dayColumn(weekday, weekLessons)`
   * 的课程数组是**按值传参**的。于是只要周次没变，`this.lessons` 即使换成了新数组，key 也完全不变 ——
   * ArkUI 会复用旧的 `dayColumn` 子树、**不重新执行 item builder**，内层 ForEach 里仍然是旧数组：
   *   - 新增 / 编辑课程：数据确实落库了（`⋯→课表管理` 的课程数会涨），课表却一直显示旧内容；
   *   - 冷启动：页面先以 `lessons = []` 渲染过一帧（`refresh()` 是异步的），
   *     等数据到位后若落点仍是同一周，同样因 key 不变而保留那一帧的**空课表** → 整片空白。
   *
   * 对比改参数化之前的写法：`dayColumn` 直接在内部读 `this.lessons`，框架能把 `this.lessons`
   * 记为这棵子树的依赖，数据变了自然会更新；改成按值传参后这条依赖就断了。
   * 所以凡是"外层 ForEach 的 item builder 把数组/对象按值传给内层"，外层 key 就必须覆盖内层
   * 实际展示的字段（与 `groupSignature` 同一套做法）。
   */
  private daySignature(weekday: number, weekLessons: LessonRow[]): string {
    let sig: string = '';
    for (let i = 0; i < weekLessons.length; i++) {
      const l: LessonRow = weekLessons[i];
      if (l.weekday !== weekday) {
        continue;
      }
      sig += `${l.time_period_id}:${l.start_time}-${l.end_time}:${l.course_name}:`
        + `${l.class_name}:${l.class_room}:${l.color}:${l.population}|`;
    }
    return sig;
  }

  /**
   * 当前作息模板的内容签名。
   *
   * 时间轴那一列的 ForEach 原来只按 `${sessionNo}` 建 key，而它展示的节次起止时间来自
   * `this.templates`（经 `selectedTemplate()`）。改完时间表返回后，节数 / 时段变了但 key 没变，
   * 时间轴就会停留在旧时刻。并入模板签名后，模板一变 key 就变。
   */
  private templateSignature(): string {
    const tpl: ScheduleTemplate | undefined = this.selectedTemplate();
    if (tpl === undefined) {
      return 'none';
    }
    let sig: string = `${tpl.id}:${tpl.slots.length}`;
    for (let i = 0; i < tpl.slots.length; i++) {
      const slot: ScheduleSlot = tpl.slots[i];
      sig += `|${slot.session_no}:${slot.start_time}-${slot.end_time}`;
    }
    return sig;
  }

  /** 指定周的某一天是否就是今天（用于"今天"高亮；轮播里相邻周也可以各自判定） */
  private isTodayInWeek(week: number, weekdayIndex: number): boolean {
    const dates: Date[] = this.weekDates(week);
    if (dates.length === 0 || weekdayIndex < 0 || weekdayIndex >= dates.length) {
      return false;
    }
    const d: Date = dates[weekdayIndex];
    const today: Date = DateUtil.today();
    return d.getFullYear() === today.getFullYear()
      && d.getMonth() === today.getMonth()
      && d.getDate() === today.getDate();
  }

  // ---------------------------------------------------------------- 操作

  private async runBackup(): Promise<void> {
    this.busy = true;
    try {
      await ScheduleRepository.getInstance().backup('wisdomdaily_backup.db');
      this.notify('数据库备份完成：wisdomdaily_backup.db');
    } catch (e) {
      this.notify(`备份失败：${ScheduleRepository.describeError(e)}`);
    }
    this.busy = false;
  }

  private async saveOwner(): Promise<void> {
    const name: string = this.inputName.trim();
    const staffNo: number = parseInt(this.inputStaffNo.trim());
    if (name.length === 0) {
      this.notify('请输入姓名');
      return;
    }
    if (isNaN(staffNo) || staffNo <= 0) {
      this.notify('请输入有效的教师工号（数字）');
      return;
    }
    this.busy = true;
    try {
      await ScheduleRepository.getInstance().saveOwnerProfile(name, staffNo);
      this.notify(`默认教师已保存：${staffNo} ${name}`);
      await this.refresh();
    } catch (e) {
      this.notify(`保存失败：${ScheduleRepository.describeError(e)}`);
      Logger.error(TAG, this.message);
    }
    this.busy = false;
  }

  private navToCourseEdit(): void {
    const sem: Semester | undefined = this.currentSemester();
    const teacher: Teacher | undefined = this.currentTeacher();
    if (sem === undefined || teacher === undefined) {
      this.notify('请先选择学期和教师');
      return;
    }
    router.pushUrl({
      url: 'pages/CourseEdit',
      params: {
        semesterId: sem.id,
        teacherId: teacher.id,
        maxWeek: sem.total_weeks,
        maxSession: this.sessionCount(),
        semesterName: sem.name,
        teacherName: teacher.displayName()
      }
    });
  }

  // ---------------------------------------------------------------- 管理 sheet

  /** 打开 / 切换管理 sheet 视图（面板 ic_more 进 menu，菜单项进对应子视图） */
  private openManageSheet(view: string): void {
    if (view === 'teacher') {
      this.teacherDraftName = '';
      this.teacherDraftStaffNo = '';
      this.teacherSelectMode = false;
      this.teacherSelectedIds = [];
      this.teacherFormId = 0;
    } else if (view === 'semester') {
      this.semesterDraftName = `学期 ${this.semesters.length + 1}`;
      this.semesterDraftWeeks = '20';
      this.semesterDraftStart = DateUtil.toDateString(DateUtil.weekMonday(DateUtil.today()));
      this.semesterEditId = 0;
      this.semesterSelectMode = false;
      this.semesterSelectedIds = [];
      this.semesterPageMode = 'list';
    } else if (view === 'student') {
      this.rosterClassId = '';
      this.roster = null;
      this.studentEditId = 0;
    } else if (view === 'time') {
      this.tplSelectMode = false;
      this.tplSelectedIds = [];
    } else if (view === 'export') {
      // 默认就选中"用户现在看的那个学期"，时间表跟着它的绑定走 —— 绝大多数导出就是点一下确认
      const current: Semester | undefined = this.currentSemester();
      const fallback: number = this.semesters.length > 0 ? this.semesters[0].id : 0;
      this.pkgSemesterId = current === undefined ? fallback : current.id;
      this.pkgTemplateId = this.templateIdOfSemester(this.pkgSemesterId);
    }
    this.manageView = view;
    this.showManageSheet = true;
  }

  private closeManageSheet(): void {
    this.showManageSheet = false;
    this.manageView = 'menu';
  }

  private manageTitle(): string {
    if (this.manageView === 'time') {
      return '时间管理';
    }
    if (this.manageView === 'teacher') {
      return '教师管理';
    }
    if (this.manageView === 'studentDetail') {
      return this.studentEditId < 0 ? '添加学生' : '学生详情';
    }
    if (this.manageView === 'student') {
      return this.rosterClassId.length > 0 ? '班级名册' : '班级管理';
    }
    if (this.manageView === 'course') {
      return '课表管理';
    }
    if (this.manageView === 'semester') {
      if (this.semesterPageMode === 'create') {
        return '新建学期';
      }
      return this.semesterEditId > 0 ? '学期详情' : '学期管理';
    }
    if (this.manageView === 'checkin') {
      return '签到信息';
    }
    if (this.manageView === 'setting') {
      return '全局设置';
    }
    if (this.manageView === 'about') {
      return '关于';
    }
    if (this.manageView === 'export') {
      return '导出课表';
    }
    if (this.manageView === 'import') {
      return '导入课表';
    }
    if (this.manageView === 'help') {
      return '导入说明';
    }
    return '管理';
  }

  /** 教师管理：新增教师（写入当前学期）。返回是否真的添加成功（表单确认共用） */
  private async addTeacher(): Promise<boolean> {
    const sem: Semester | undefined = this.currentSemester();
    if (sem === undefined) {
      this.notify('请先选择学期');
      return false;
    }
    const name: string = this.teacherDraftName.trim();
    const staffNo: number = parseInt(this.teacherDraftStaffNo.trim());
    if (name.length === 0) {
      this.notify('请输入教师姓名');
      return false;
    }
    if (isNaN(staffNo) || staffNo <= 0) {
      this.notify('请输入有效工号（数字）');
      return false;
    }
    this.manageBusy = true;
    let ok: boolean = false;
    try {
      const teacher: Teacher = Teacher.create(name, staffNo);
      await ScheduleRepository.getInstance().upsertTeacher(sem.id, teacher);
      this.teacherDraftName = '';
      this.teacherDraftStaffNo = '';
      this.notify(`已添加教师：${staffNo} ${name}`);
      await this.refresh();
      ok = true;
    } catch (e) {
      this.notify(`添加教师失败：${ScheduleRepository.describeError(e)}`);
    }
    this.manageBusy = false;
    return ok;
  }

  /** 教师管理：展开新增表单（收起态底栏「添加教师」入口） */
  private openTeacherAdd(): void {
    if (this.teacherSelectMode || this.manageBusy) {
      return;
    }
    this.teacherDraftName = '';
    this.teacherDraftStaffNo = '';
    this.teacherFormId = -1;
  }

  /** 教师管理：展开编辑表单（左滑「编辑」入口），预填当前姓名/工号 */
  private openTeacherEdit(teacherId: number): void {
    if (this.teacherSelectMode || this.manageBusy) {
      return;
    }
    const rows: TeacherCourses[] = this.teacherCourseRows();
    for (let i = 0; i < rows.length; i++) {
      if (rows[i].teacher.id === teacherId) {
        this.teacherDraftName = rows[i].teacher.name;
        this.teacherDraftStaffNo = `${rows[i].teacher.staff_no}`;
        this.teacherFormId = teacherId;
        return;
      }
    }
  }

  /** 教师管理：收起表单（未保存的修改丢弃） */
  private closeTeacherForm(): void {
    if (this.manageBusy) {
      return;
    }
    this.teacherFormId = 0;
    this.teacherDraftName = '';
    this.teacherDraftStaffNo = '';
  }

  /** 教师管理：表单确认。teacherFormId=-1 走新增；>0 保存修改（克隆保留可选字段+工号冲突拦截） */
  private async saveTeacherForm(): Promise<void> {
    if (this.teacherFormId === -1) {
      const ok: boolean = await this.addTeacher();
      if (ok) {
        this.teacherFormId = 0;
      }
      return;
    }
    if (this.manageBusy) {
      return;
    }
    const sem: Semester | undefined = this.currentSemester();
    if (sem === undefined) {
      this.notify('请先选择学期');
      return;
    }
    const teacherId: number = this.teacherFormId;
    const rows: TeacherCourses[] = this.teacherCourseRows();
    let target: Teacher | undefined = undefined;
    for (let i = 0; i < rows.length; i++) {
      if (rows[i].teacher.id === teacherId) {
        target = rows[i].teacher;
        break;
      }
    }
    if (target === undefined) {
      this.notify('教师不存在或已删除');
      this.teacherFormId = 0;
      return;
    }
    const name: string = this.teacherDraftName.trim();
    const staffNo: number = parseInt(this.teacherDraftStaffNo.trim());
    if (name.length === 0) {
      this.notify('请输入教师姓名');
      return;
    }
    if (isNaN(staffNo) || staffNo <= 0) {
      this.notify('请输入有效工号（数字）');
      return;
    }
    for (let i = 0; i < rows.length; i++) {
      if (rows[i].teacher.id !== teacherId && rows[i].teacher.staff_no === staffNo) {
        this.notify('该工号已被其他教师使用');
        return;
      }
    }
    if (name === target.name && staffNo === target.staff_no) {
      this.closeTeacherForm();
      return;
    }
    this.manageBusy = true;
    try {
      // TeacherDao.update 是全列覆写 → 必须克隆原对象，保留 department/age/sex/telephone
      const edited: Teacher = new Teacher();
      edited.id = target.id;
      edited.name = name;
      edited.staff_no = staffNo;
      edited.department = target.department;
      edited.age = target.age;
      edited.sex = target.sex;
      edited.telephone = target.telephone;
      await ScheduleRepository.getInstance().upsertTeacher(sem.id, edited);
      this.teacherFormId = 0;
      this.teacherDraftName = '';
      this.teacherDraftStaffNo = '';
      this.notify(`已保存教师：${staffNo} ${name}`);
      await this.refresh();
    } catch (e) {
      this.notify(`保存教师失败：${ScheduleRepository.describeError(e)}`);
    }
    this.manageBusy = false;
  }

  /** 教师管理：删除单个教师（AlertDialog 二次确认；其名下课程级联删除） */
  private confirmDeleteTeacher(teacherId: number): void {
    if (this.manageBusy) {
      return;
    }
    const rows: TeacherCourses[] = this.teacherCourseRows();
    let name: string = '';
    for (let i = 0; i < rows.length; i++) {
      if (rows[i].teacher.id === teacherId) {
        name = rows[i].teacher.displayName();
        break;
      }
    }
    AlertDialog.show({
      title: '删除教师',
      message: `确定删除「${name}」吗？其名下课程会一并删除，删除后无法恢复。`,
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: '#EF4444',
        action: () => {
          this.deleteTeacherById(teacherId);
        }
      }
    });
  }

  private async deleteTeacherById(teacherId: number): Promise<void> {
    this.manageBusy = true;
    try {
      await ScheduleRepository.getInstance().deleteTeacher(teacherId);
      this.notify('教师及其课程已删除');
      if (this.currentTeacherId === teacherId) {
        this.currentTeacherId = 0;
      }
      await this.refresh();
    } catch (e) {
      this.notify(`删除教师失败：${ScheduleRepository.describeError(e)}`);
    }
    this.manageBusy = false;
  }



  /** 班级管理：查看某班级名册 */
  private async openRoster(classId: string): Promise<void> {
    this.manageBusy = true;
    try {
      this.roster = await ScheduleRepository.getInstance().loadRoster(classId);
      this.rosterClassId = classId;
    } catch (e) {
      this.notify(`加载名册失败：${ScheduleRepository.describeError(e)}`);
    }
    this.manageBusy = false;
  }

  /** 名单变动后：重载当前名册 + 刷新全局统计（班级列表里的「名册 N 人」要跟着变） */
  private async afterRosterChange(): Promise<void> {
    if (this.rosterClassId.length > 0) {
      try {
        this.roster = await ScheduleRepository.getInstance().loadRoster(this.rosterClassId);
      } catch (e) {
        this.notify(`加载名册失败：${ScheduleRepository.describeError(e)}`);
      }
    }
    await this.refresh();
  }

  /**
   * 名册「添加学生信息」：打开一张空白学生表单。
   *
   * `studentEditId` 三个取值：<0 新增 / >0 改已有 / 0 没有选中。
   * 新增时 `class_id` 取当前名册的班，保存时才落到库里。
   */
  private openNewStudent(): void {
    if (this.rosterClassId.length === 0) {
      this.notify('请先打开一个班级');
      return;
    }
    this.studentEditId = -1;
    this.draftStudentNo = '';
    this.draftStudentName = '';
    this.draftStudentSex = '';
    this.draftStudentAge = '';
    this.draftStudentPhone = '';
    this.draftStudentRemark = '';
    this.manageView = 'studentDetail';
  }

  /** 班级管理：打开学生详情。改动先落在草稿上，点「保存」才写库 */
  private openStudentDetail(id: number): void {
    const student: Student | undefined = this.rosterStudent(id);
    if (student === undefined) {
      this.notify('这条学生记录已不存在，请重新打开名册');
      return;
    }
    this.studentEditId = id;
    this.draftStudentNo = student.student_no;
    this.draftStudentName = student.name;
    this.draftStudentSex = student.sex === undefined ? '' : student.sex;
    this.draftStudentAge = student.age === undefined ? '' : `${student.age}`;
    this.draftStudentPhone = student.telephone === undefined ? '' : student.telephone;
    this.draftStudentRemark = student.remark === undefined ? '' : student.remark;
    this.manageView = 'studentDetail';
  }

  /** 学生详情：返回名册（放弃未保存的改动） */
  private closeStudentDetail(): void {
    this.studentEditId = 0;
    this.manageView = 'student';
  }

  /** 学生详情：保存 */
  private async saveStudentDetail(): Promise<void> {
    const id: number = this.studentEditId;
    if (id === 0 || this.studentBusy) {
      return;
    }
    const studentNo: string = this.draftStudentNo.trim();
    const name: string = this.draftStudentName.trim();
    if (studentNo.length === 0) {
      this.notify('学号不能为空');
      return;
    }
    if (name.length === 0) {
      this.notify('姓名不能为空');
      return;
    }
    // (class_id, student_no) 上有唯一约束：先自查一次，给出人话提示而不是库错误
    const siblings: Student[] = this.rosterStudents();
    for (let i = 0; i < siblings.length; i++) {
      if (siblings[i].id !== id && siblings[i].student_no === studentNo) {
        this.notify(`学号 ${studentNo} 已被本班其他学生占用`);
        return;
      }
    }
    const ageText: string = this.draftStudentAge.trim();
    let age: number | undefined = undefined;
    if (ageText.length > 0) {
      const parsed: number = parseInt(ageText);
      if (isNaN(parsed) || parsed <= 0 || parsed > 200) {
        this.notify('年龄需为 1-200 之间的数字');
        return;
      }
      age = parsed;
    }

    this.studentBusy = true;
    try {
      const repository: ScheduleRepository = ScheduleRepository.getInstance();
      if (id < 0) {
        // 新增：挂到当前名册的班上，学号重复在上面的兄弟检查里已经拦过
        const created: Student = new Student();
        created.student_no = studentNo;
        created.name = name;
        created.sex = this.draftStudentSex.length === 0 ? undefined : this.draftStudentSex;
        created.age = age;
        const newPhone: string = this.draftStudentPhone.trim();
        created.telephone = newPhone.length === 0 ? undefined : newPhone;
        const newRemark: string = this.draftStudentRemark.trim();
        created.remark = newRemark.length === 0 ? undefined : newRemark;
        await repository.addStudent(this.rosterClassId, created);
        await this.afterRosterChange();
        this.closeStudentDetail();
        this.notify('已添加学生');
        this.studentBusy = false;
        return;
      }
      const student: Student | undefined = await repository.findStudent(id);
      if (student === undefined) {
        this.studentBusy = false;
        this.closeStudentDetail();
        await this.afterRosterChange();
        this.notify('该学生已不存在，可能已被删除');
        return;
      }
      student.student_no = studentNo;
      student.name = name;
      student.sex = this.draftStudentSex.length === 0 ? undefined : this.draftStudentSex;
      student.age = age;
      const phone: string = this.draftStudentPhone.trim();
      student.telephone = phone.length === 0 ? undefined : phone;
      const remark: string = this.draftStudentRemark.trim();
      student.remark = remark.length === 0 ? undefined : remark;
      await repository.saveStudent(student);
      await this.afterRosterChange();
      this.closeStudentDetail();
      this.notify('已保存');
    } catch (e) {
      this.notify(`保存失败：${ScheduleRepository.describeError(e)}`);
    }
    this.studentBusy = false;
  }

  /** 名册左滑「删除」：先确认再落库 */
  private confirmDeleteStudent(id: number): void {
    const student: Student | undefined = this.rosterStudent(id);
    if (student === undefined) {
      return;
    }
    const who: string = student.name.length > 0 ? student.name : student.student_no;
    AlertDialog.show({
      title: '删除学生',
      message: `确定把「${who}」从本班名册里删除吗？删掉后无法恢复。`,
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: '#EF4444',
        action: () => {
          this.deleteStudent(id);
        }
      }
    });
  }

  private async deleteStudent(id: number): Promise<void> {
    this.manageBusy = true;
    try {
      await ScheduleRepository.getInstance().deleteStudent(id);
      await this.afterRosterChange();
      this.notify('已删除该学生');
    } catch (e) {
      this.notify(`删除失败：${ScheduleRepository.describeError(e)}`);
    }
    this.manageBusy = false;
  }

  // ---- 名册多选：长按进入，全选/删除，底部常规操作行随之隐藏 ----

  /** 多选模式：某个学生当前是否被勾选 */
  private isStudentSelected(id: number): boolean {
    return this.rosterSelectedIds.indexOf(id) >= 0;
  }

  /** 长按某个学生：进入多选模式，并把它作为第一个勾选项 */
  private enterRosterSelect(id: number): void {
    if (this.rosterCount() === 0) {
      return;
    }
    this.rosterSelectMode = true;
    this.rosterSelectedIds = [id];
  }

  /** 退出多选模式：清空勾选，底部恢复常规操作行 */
  private exitRosterSelect(): void {
    this.rosterSelectMode = false;
    this.rosterSelectedIds = [];
  }

  /** 多选模式下点击某行：切换它的勾选状态（整体替换数组触发刷新） */
  private toggleStudentSelected(id: number): void {
    const idx: number = this.rosterSelectedIds.indexOf(id);
    if (idx >= 0) {
      const next: number[] = this.rosterSelectedIds.slice();
      next.splice(idx, 1);
      this.rosterSelectedIds = next;
    } else {
      this.rosterSelectedIds = this.rosterSelectedIds.concat([id]);
    }
  }

  /** 「全选」按钮当前是不是"已全选"状态（全选时按钮变「取消全选」） */
  private rosterAllSelected(): boolean {
    return this.rosterCount() > 0 && this.rosterSelectedIds.length === this.rosterCount();
  }

  /** 全选按钮：未全选 → 勾上全部；已全选 → 全部取消 */
  private toggleRosterSelectAll(): void {
    if (this.rosterAllSelected()) {
      this.rosterSelectedIds = [];
      return;
    }
    const list: Student[] = this.rosterStudents();
    const ids: number[] = [];
    for (let i = 0; i < list.length; i++) {
      ids.push(list[i].id);
    }
    this.rosterSelectedIds = ids;
  }

  /** 多选「删除」：先确认再整批落库（删除入口只在明确选择删除对象处） */
  private confirmDeleteSelected(): void {
    const count: number = this.rosterSelectedIds.length;
    if (count === 0 || this.manageBusy) {
      return;
    }
    AlertDialog.show({
      title: '删除选中学生',
      message: `确定把选中的 ${count} 名学生从本班名册里删除吗？删掉后无法恢复。`,
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: '#EF4444',
        action: () => {
          this.deleteSelectedStudents();
        }
      }
    });
  }

  private async deleteSelectedStudents(): Promise<void> {
    this.manageBusy = true;
    try {
      await ScheduleRepository.getInstance().deleteStudents(this.rosterSelectedIds.slice());
      this.exitRosterSelect();
      await this.afterRosterChange();
      this.notify('已删除选中的学生');
    } catch (e) {
      this.notify(`删除失败：${ScheduleRepository.describeError(e)}`);
    }
    this.manageBusy = false;
  }

  /**
   * 名册表格内容：**列结构对齐用户手里的模板**（课程名称+班级名称+平时分.xls）——
   * 第 0 行标题 = 班级名（只有班级名，不加别的字）；
   * 第 1 行表头 = 序号/学号/姓名/性别 + 「考勤」「课堂状态」两个组头；
   * 第 2 行 = 考勤、课堂状态各自的 1~5 子列号；
   * 之后是学生行：序号从 1 排 + 签到结果（见 `fillAttendanceCells`）。
   * 应用侧导入只读「学号/姓名/性别」，其余列原样忽略。
   *
   * `withStudents = false` 是**下载模板**用的（只有标题与表头，考勤/状态列留给老师手工填），
   * 那种情况下 `scored` 无意义，传什么都行。
   */
  private rosterRows(withStudents: boolean, scored: boolean): string[][] {
    const rows: string[][] = [];
    const blank: string[] = new Array<string>(ROSTER_COLS).fill('');
    const title: string[] = blank.slice();
    title[0] = this.rosterClassName();
    rows.push(title);
    rows.push(['序号', '学号', '姓名', '性别', '考勤', '', '', '', '', '课堂状态', '', '', '', '']);
    rows.push(['', '', '', '', '1', '2', '3', '4', '5', '1', '2', '3', '4', '5']);
    if (withStudents) {
      const students: Student[] = this.rosterStudents();
      // 列定义与查表索引**在循环外算一次**：每个学生都重建一遍是 O(学生数 × 签到行数)
      const sessions: RosterSession[] = this.rosterSessions();
      const index: Map<string, AttendanceExportRow> = this.rosterAttendIndex();
      for (let i = 0; i < students.length; i++) {
        // sex 是 `string | undefined`（未填性别的学生库里就是 NULL），导出单元格必须是 string
        const sex: string = students[i].sex === undefined ? '' : students[i].sex !;
        const row: string[] = blank.slice();
        row[0] = `${i + 1}`;
        row[1] = students[i].student_no;
        row[2] = students[i].name;
        row[3] = sex;
        this.fillAttendanceCells(row, students[i].id, sessions, index, scored);
        rows.push(row);
      }
    }
    return rows;
  }

  /** 导出前重新读一次当前班级的签到记录；失败只是"这次导出没有考勤列"，不该整张表导不出 */
  private async loadRosterAttendance(): Promise<void> {
    this.rosterAttend = [];
    if (this.rosterClassId.length === 0) {
      return;
    }
    try {
      this.rosterAttend =
        await ScheduleRepository.getInstance().loadClassAttendance(this.rosterClassId);
    } catch (e) {
      Logger.error(TAG, `读取签到记录失败（导出将不含考勤列）：${ScheduleRepository.describeError(e)}`);
    }
  }

  /**
   * 导出表的**列定义**：一次点名 = 一列，按课次时间先后取前 `MAX_SIGNIN_COLUMNS` 次。
   *
   * 表上只有「考勤 1~5 / 课堂状态 1~5」十列，超过 5 次的点名无处安放 —— 与其悄悄
   * 把它们并入第 5 列（老师对不上账），不如只导出最早 5 次，并在提示里说清次数。
   */
  private rosterSessions(): RosterSession[] {
    const sessions: RosterSession[] = [];
    for (let i = 0; i < this.rosterAttend.length; i++) {
      const row: AttendanceExportRow = this.rosterAttend[i];
      let known: boolean = false;
      for (let j = 0; j < sessions.length; j++) {
        if (sessions[j].weekNo === row.week_no && sessions[j].periodId === row.time_period_id) {
          known = true;
          break;
        }
      }
      if (!known) {
        const session: RosterSession = new RosterSession();
        session.weekNo = row.week_no;
        session.weekday = row.weekday;
        session.startTime = row.start_time;
        session.periodId = row.time_period_id;
        sessions.push(session);
      }
    }
    sessions.sort((a: RosterSession, b: RosterSession): number => {
      if (a.weekNo !== b.weekNo) {
        return a.weekNo - b.weekNo;
      }
      if (a.weekday !== b.weekday) {
        return a.weekday - b.weekday;
      }
      if (a.startTime !== b.startTime) {
        return a.startTime - b.startTime;
      }
      return a.periodId - b.periodId;
    });
    return sessions.slice(0, MAX_SIGNIN_COLUMNS);
  }

  /**
   * `学生主键 + 第几周 + 时段` → 签到行的查表索引。
   *
   * 为什么拼字符串键而不是嵌套 Map：`attendance` 上有
   * `UNIQUE(time_period_id, week_no, student_id)`，一个学生一次课最多一条记录，
   * 扁平索引不会互相覆盖；而两层 Map 在 ArkTS 里要多写一轮 has/get/判空。
   */
  private rosterAttendIndex(): Map<string, AttendanceExportRow> {
    const index: Map<string, AttendanceExportRow> = new Map<string, AttendanceExportRow>();
    for (let i = 0; i < this.rosterAttend.length; i++) {
      const row: AttendanceExportRow = this.rosterAttend[i];
      index.set(`${row.student_id}-${row.week_no}-${row.time_period_id}`, row);
    }
    return index;
  }

  /**
   * 把一个学生的签到结果填进考勤列与课堂状态列。
   *
   * 两种导出口径 —— 老师写手册的记法 vs 要交上去算分的口径：
   * - **原表**（`scored = false`）：考勤列只写出勤之外的记号（旷课 ×、请假 ⊕，出勤留空），
   *   课堂状态列写等级 1~5；
   * - **算分后**（`scored = true`）：考勤列把出勤也补成 √（"只要是 1~5 的考勤就是 √"），
   *   课堂状态列写等级对应的分数。
   *
   * 分数**不是导出时现算**：它在老师选等级那一刻就算好落库（见 `model/Attendance.ets`），
   * 同一个学生导两次分数必须一样 —— 否则老师没法拿它对账。
   * 没点过名的（库里根本没有这一行）留空，两种口径都不写。
   */
  private fillAttendanceCells(row: string[], studentId: number, sessions: RosterSession[],
    index: Map<string, AttendanceExportRow>, scored: boolean): void {
    for (let i = 0; i < sessions.length; i++) {
      const hit: AttendanceExportRow | undefined =
        index.get(`${studentId}-${sessions[i].weekNo}-${sessions[i].periodId}`);
      if (hit === undefined) {
        continue;
      }
      // 考勤列 4~8、课堂状态列 9~13（与表头两个组头的位置一一对应）
      const attendCol: number = 4 + i;
      const stateCol: number = 9 + i;
      if (hit.status === AttendStatus.ABSENT) {
        row[attendCol] = AttendMark.ABSENT;
      } else if (hit.status === AttendStatus.LEAVE) {
        row[attendCol] = AttendMark.LEAVE;
      } else if (hit.status === AttendStatus.PRESENT && scored) {
        row[attendCol] = AttendMark.PRESENT;
      }
      if (hit.status === AttendStatus.PRESENT && hit.grade > 0) {
        if (scored) {
          // 分数理论上一定 > 0（选等级时与 grade 同时写入）；真为 0 时宁可留空也不写等级，
          // 一张"算分后"的表里冒出一列 1~5 的等级，比空格更容易让人误判
          if (hit.score > 0) {
            row[stateCol] = `${hit.score}`;
          }
        } else {
          row[stateCol] = `${hit.grade}`;
        }
      }
    }
  }

  /**
   * 名册表格的**合并单元格**区（与模板一致）：
   * 标题横向合并整行；序号/学号/姓名/性别在表头两行间纵向合并；
   * 考勤、课堂状态两个组头各自横向合并 5 列。行列都含端点。
   */
  private rosterMerges(): XlsRect[] {
    const merges: XlsRect[] = [];
    merges.push(new XlsRect(0, 0, 0, ROSTER_COLS - 1));
    merges.push(new XlsRect(1, 2, 0, 0));
    merges.push(new XlsRect(1, 2, 1, 1));
    merges.push(new XlsRect(1, 2, 2, 2));
    merges.push(new XlsRect(1, 2, 3, 3));
    merges.push(new XlsRect(1, 1, 4, 8));
    merges.push(new XlsRect(1, 1, 9, 13));
    return merges;
  }

  /** 名册表格的边框范围：从标题行到最后一行（模板是全表细边框） */
  private rosterBorder(withStudents: boolean): XlsRect {
    const students: Student[] = this.rosterStudents();
    const lastRow: number = withStudents ? 2 + students.length : 2;
    return new XlsRect(0, lastRow, 0, ROSTER_COLS - 1);
  }

  /** 把生成好的文件（.xls / .zip）另存到用户挑的位置（文件选择器的「另存为」）；取消返回空串 */
  private async savePickedFile(bytes: Uint8Array, fileName: string): Promise<string> {
    const context: common.UIAbilityContext = this.context();
    const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
    options.newFileNames = [fileName];
    const view: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    const uris: string[] = await view.save(options);
    if (uris.length === 0) {
      return '';
    }
    const file: fileIo.File = fileIo.openSync(uris[0],
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, bytes.buffer);
    } finally {
      fileIo.closeSync(file);
    }
    return uris[0];
  }

  /** 下载**模板**：只有标题行与表头，留给用户照着填 */
  private async downloadRosterTemplate(): Promise<void> {
    if (this.rosterImportBusy || this.rosterClassId.length === 0) {
      return;
    }
    this.rosterImportBusy = true;
    Logger.info(TAG, '下载模板：开始，生成模板');
    try {
      const bytes: Uint8Array = XlsWriter.buildEx(this.rosterRows(false, false),
        this.rosterMerges(), this.rosterBorder(false));
      const uri: string = await this.savePickedFile(bytes,
        `${this.rosterClassName()}${ROSTER_TITLE_SUFFIX}模板.xls`);
      this.notify(uri.length === 0 ? '已取消保存模板' : `模板已保存到：${uri}`);
    } catch (e) {
      Logger.error(TAG, `下载模板失败：${ScheduleRepository.describeError(e)}`);
      this.notify(`下载模板失败：${ScheduleRepository.describeError(e)}`);
    }
    this.rosterImportBusy = false;
  }

  /**
   * 导出**当前班级的名单**：标题 + 表头 + 名册里已有的学生 + 签到结果。
   *
   * `scored = false` → **原表**口径（考勤列旷课 × / 请假 ⊕、出勤留空；课堂状态列等级 1~5）；
   * `scored = true`  → **算分后**口径（考勤列出勤 √ / 旷课 × / 请假 ⊕；课堂状态列分数）。
   * 两种口径共用同一份 `rosterRows`，只是往格子里填的字不同 —— 不存在"两套表结构"，
   * 也就不会出现某天改了列又只改了其中一种导出。
   */
  private async exportRoster(scored: boolean): Promise<void> {
    if (this.rosterImportBusy || this.rosterClassId.length === 0) {
      return;
    }
    this.rosterImportBusy = true;
    Logger.info(TAG, `导出名单：开始（口径=${scored ? '算分后' : '原表'}）`);
    try {
      // 先读库再拼表：`rosterRows` 是同步的，拿到数据才有列可填
      await this.loadRosterAttendance();
      const count: number = this.rosterStudents().length;
      const sessions: number = this.rosterSessions().length;
      const bytes: Uint8Array = XlsWriter.buildEx(this.rosterRows(true, scored),
        this.rosterMerges(), this.rosterBorder(true));
      const uri: string = await this.savePickedFile(bytes,
        `${this.rosterClassName()}${ROSTER_TITLE_SUFFIX}${scored ? '（算分后）' : ''}.xls`);
      if (uri.length === 0) {
        this.notify('已取消导出');
      } else if (count === 0) {
        this.notify('这个班还没有学生，导出的文件里只有表头');
      } else if (sessions === 0) {
        this.notify(`已导出 ${count} 名学生（这个班还没有点名记录，考勤列是空的）：${uri}`);
      } else {
        this.notify(`已导出 ${count} 名学生、${sessions} 次点名：${uri}`);
      }
    } catch (e) {
      Logger.error(TAG, `导出名单失败：${ScheduleRepository.describeError(e)}`);
      this.notify(`导出失败：${ScheduleRepository.describeError(e)}`);
    }
    this.rosterImportBusy = false;
  }

  /**
   * 「导出班级名单」点开后的二选一：原表口径 / 算分后口径。
   *
   * 与「导入班级名单」一样用 `AlertDialog`（独立窗口）而不是在面板里展开一块菜单 ——
   * 面板是 `FIT_CONTENT`，内容高度一变内部点击就会命中旧布局（见 §12.3.2 第 17 点）。
   */
  private openRosterExportMenu(): void {
    if (this.rosterImportBusy || this.rosterClassId.length === 0) {
      return;
    }
    AlertDialog.show({
      title: '导出班级名单',
      message: '原表口径：考勤列写 ×（旷课）/ ⊕（请假）、出勤留空，课堂状态列写等级 1~5。\n' +
        '算分后口径：考勤列写 √ / × / ⊕，课堂状态列写等级换算出的分数。',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '算分后导出',
        action: () => {
          this.exportRoster(true);
        }
      },
      secondaryButton: {
        value: '原表导出',
        action: () => {
          this.exportRoster(false);
        }
      }
    });
  }

  /** 班级管理：选一个 .xls 文件导入到当前班级 */
  private async pickRosterFile(): Promise<void> {
    if (this.rosterImportBusy || this.rosterClassId.length === 0) {
      Logger.info(TAG, `选择文件导入：忽略（busy=${this.rosterImportBusy} classId 空=${this.rosterClassId.length === 0}）`);
      return;
    }
    this.rosterImportBusy = true;
    Logger.info(TAG, '选择文件导入：开始，唤起文件选择器');
    try {
      const context: common.UIAbilityContext = this.context();
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      // 只列 .xls：本读取器只认 BIFF8，让用户选到 .xlsx 只会得到一个难懂的报错
      options.fileSuffixFilters = ['.xls'];
      const view: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
      const uris: string[] = await view.select(options);
      if (uris.length === 0) {
        this.notify('已取消选择文件');
        this.rosterImportBusy = false;
        return;
      }
      await this.importRosterFrom(uris[0]);
    } catch (e) {
      Logger.error(TAG, `选择文件导入失败：${ScheduleRepository.describeError(e)}`);
      this.notify(`导入失败：${ScheduleRepository.describeError(e)}`);
    }
    this.rosterImportBusy = false;
  }

  /** 读选中的 .xls → 解析 → 按学号合并入库 */
  private async importRosterFrom(uri: string): Promise<void> {
    Logger.info(TAG, `选择文件导入：读取文件 ${uri}`);
    const bytes: Uint8Array = this.readPickedBytes(uri, 8 * 1024 * 1024, '8 MB');

    const table: string[][] = XlsReader.readFirstSheet(bytes);
    const parsed: RosterParseResult = RosterImporter.parse(table);
    const result: RosterImportResult = await ScheduleRepository.getInstance()
      .mergeRoster(this.rosterClassId, parsed.students);
    result.skipped += parsed.skipped;
    await this.afterRosterChange();
    this.notify(`导入完成：${result.summary()}`);
  }

  /** 学期管理：给「新建学期」选开始日期（同样夹到周一） */
  private pickSemesterDraftStart(): void {
    DatePickerDialog.show({
      start: new Date(2000, 0, 1),
      end: new Date(2100, 11, 31),
      selected: DateUtil.weekMonday(DateUtil.parseDate(this.semesterDraftStart)),
      onDateAccept: (value: Date) => {
        this.semesterDraftStart = DateUtil.toDateString(DateUtil.weekMonday(value));
      }
    });
  }

  /** 学期管理：按草稿新建学期并指向它（成功后退回学期列表） */
  private async createSemesterFromDraft(): Promise<void> {
    if (this.templates.length === 0) {
      this.notify('没有可用作息模板，无法新建学期');
      return;
    }
    const name: string = this.semesterDraftName.trim();
    if (name.length === 0) {
      this.notify('请输入学期名称');
      return;
    }
    const weeks: number = parseInt(this.semesterDraftWeeks.trim());
    if (isNaN(weeks) || weeks < 1 || weeks > 40) {
      this.notify('周数需在 1-40 之间');
      return;
    }
    this.manageBusy = true;
    try {
      const tpl: ScheduleTemplate = this.templates[0];
      const start: string = this.semesterDraftStart.length > 0
        ? this.semesterDraftStart
        : DateUtil.toDateString(DateUtil.weekMonday(DateUtil.today()));
      const sem: Semester = await ScheduleRepository.getInstance()
        .createSemester(name, tpl.id, weeks, start);
      await ScheduleRepository.getInstance().savePointers(sem.id, this.currentTeacherId);
      this.notify(`已新建学期：${sem.name}`);
      this.semesterPageMode = 'list';
      await this.refresh();
    } catch (e) {
      this.notify(`新建学期失败：${ScheduleRepository.describeError(e)}`);
    }
    this.manageBusy = false;
  }

  /** 学期管理：进入某个学期的编辑态（名称 / 周数 / 开始日期 一起改） */
  private openSemesterEdit(semesterId: number): void {
    const target: Semester | undefined = this.findSemester(semesterId);
    if (target === undefined) {
      return;
    }
    this.semesterEditId = target.id;
    this.semesterEditName = target.name;
    this.semesterEditWeeks = `${target.total_weeks}`;
    this.semesterEditStart = target.start_date;
  }

  /**
   * 学期管理：选开始日期。
   *
   * 选完统一夹到「所在周的周一」——周次是按整周算的，起始日不是周一的话
   * 第 1 周会被算成半周，weekNumber 整个错位。
   */
  private pickSemesterStart(): void {
    DatePickerDialog.show({
      start: new Date(2000, 0, 1),
      end: new Date(2100, 11, 31),
      selected: DateUtil.weekMonday(DateUtil.parseDate(this.semesterEditStart)),
      onDateAccept: (value: Date) => {
        this.semesterEditStart = DateUtil.toDateString(DateUtil.weekMonday(value));
      }
    });
  }

  /** 学期管理：保存编辑（名称 / 周数 / 开始日期） */
  private async saveSemesterEdit(semesterId: number): Promise<void> {
    const target: Semester | undefined = this.findSemester(semesterId);
    if (target === undefined) {
      return;
    }
    const name: string = this.semesterEditName.trim();
    if (name.length === 0) {
      this.notify('学期名称不能为空');
      return;
    }
    const weeks: number = parseInt(this.semesterEditWeeks.trim());
    if (isNaN(weeks) || weeks < 1 || weeks > 40) {
      this.notify('周数需在 1-40 之间');
      return;
    }
    if (this.semesterEditStart.length === 0) {
      this.notify('请选择学期开始日期');
      return;
    }
    this.manageBusy = true;
    try {
      const copy: Semester = target.clone();
      copy.name = name;
      copy.total_weeks = weeks;
      copy.start_date = this.semesterEditStart;
      await ScheduleRepository.getInstance().updateSemester(copy);
      this.semesterEditId = 0;
      this.notify('学期设置已保存');
      await this.refresh();
    } catch (e) {
      this.notify(`保存失败：${ScheduleRepository.describeError(e)}`);
    }
    this.manageBusy = false;
  }

  /** 学期管理：删除单个学期（AlertDialog 二次确认；「至少保留一个」由 repo 把关） */
  private confirmDeleteSemester(semesterId: number): void {
    if (this.manageBusy) {
      return;
    }
    const target: Semester | undefined = this.findSemester(semesterId);
    if (target === undefined) {
      return;
    }
    AlertDialog.show({
      title: '删除学期',
      message: `确定删除「${target.name}」吗？学期里的课程、班级、时间段与点名记录会一并删除，删掉后无法恢复。`,
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: '#EF4444',
        action: () => {
          this.deleteSemesterById(semesterId);
        }
      }
    });
  }

  private async deleteSemesterById(semesterId: number): Promise<void> {
    this.manageBusy = true;
    try {
      const ok: boolean = await ScheduleRepository.getInstance().deleteSemester(semesterId);
      this.notify(ok ? '学期已删除' : '至少保留一个学期，无法删除');
      await this.refresh();
    } catch (e) {
      this.notify(`删除学期失败：${ScheduleRepository.describeError(e)}`);
    }
    this.manageBusy = false;
  }

  /** 学期管理：长按进入多选，并把长按的那一项选上 */
  private enterSemesterSelect(semesterId: number): void {
    this.semesterEditId = 0;
    this.semesterSelectMode = true;
    this.semesterSelectedIds = [semesterId];
  }

  /** 学期管理：退出多选（清空选中） */
  private exitSemesterSelect(): void {
    this.semesterSelectMode = false;
    this.semesterSelectedIds = [];
  }

  /** 学期管理：多选态点一行 = 切换选中；全部取消时自动退出多选 */
  private toggleSemesterSelect(semesterId: number): void {
    const idx: number = this.semesterSelectedIds.indexOf(semesterId);
    if (idx >= 0) {
      const kept: number[] = [];
      for (let i = 0; i < this.semesterSelectedIds.length; i++) {
        if (this.semesterSelectedIds[i] !== semesterId) {
          kept.push(this.semesterSelectedIds[i]);
        }
      }
      this.semesterSelectedIds = kept;
    } else {
      this.semesterSelectedIds = this.semesterSelectedIds.concat([semesterId]);
    }
    if (this.semesterSelectedIds.length === 0) {
      this.exitSemesterSelect();
    }
  }

  /** 学期管理：全选 / 取消全选（左下角按钮；全满再点 = 退出多选） */
  private toggleSemesterSelectAll(): void {
    if (this.semesterSelectedIds.length >= this.semesters.length) {
      this.exitSemesterSelect();
      return;
    }
    const ids: number[] = [];
    for (let i = 0; i < this.semesters.length; i++) {
      ids.push(this.semesters[i].id);
    }
    this.semesterSelectedIds = ids;
  }

  /** 学期管理：批量删除确认（AlertDialog 是独立窗口，不参与面板高度变化） */
  private confirmDeleteSelectedSemesters(): void {
    const count: number = this.semesterSelectedIds.length;
    if (count === 0 || this.manageBusy) {
      return;
    }
    AlertDialog.show({
      title: '删除选中学期',
      message: `确定把选中的 ${count} 个学期删除吗？学期里的课程、班级、时间段与点名记录会一并删除，删掉后无法恢复。`,
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: '#EF4444',
        action: () => {
          this.deleteSelectedSemesters();
        }
      }
    });
  }

  /** 学期管理：批量删除选中项（「至少保留一个」由 repo 逐条把关） */
  private async deleteSelectedSemesters(): Promise<void> {
    this.manageBusy = true;
    let deleted: number = 0;
    try {
      for (let i = 0; i < this.semesterSelectedIds.length; i++) {
        const ok: boolean = await ScheduleRepository.getInstance()
          .deleteSemester(this.semesterSelectedIds[i]);
        if (ok) {
          deleted++;
        }
      }
      if (deleted === this.semesterSelectedIds.length) {
        this.notify(`已删除 ${deleted} 个学期`);
      } else if (deleted > 0) {
        this.notify(`已删除 ${deleted} 个学期（其余未删：至少保留一个学期）`);
      } else {
        this.notify('至少保留一个学期，无法删除');
      }
      this.exitSemesterSelect();
      await this.refresh();
    } catch (e) {
      this.notify(`批量删除失败：${ScheduleRepository.describeError(e)}`);
    }
    this.manageBusy = false;
  }

  /** 学期列表高度：按学期数算并封顶 —— 与名册同一策略，面板高度稳定 */
  private semesterListHeight(): number {
    const count: number = this.semesters.length;
    const raw: number = count * SEMESTER_ROW_HEIGHT + Math.max(0, count - 1) * 8;
    return clamp(raw, SEMESTER_ROW_HEIGHT, SEMESTER_LIST_MAX_HEIGHT);
  }

  /** 时间管理：长按进入多选，并把长按的那一项选上 */
  private enterTplSelect(tplId: number): void {
    this.tplSelectMode = true;
    this.tplSelectedIds = [tplId];
  }

  /** 时间管理：退出多选（清空选中） */
  private exitTplSelect(): void {
    this.tplSelectMode = false;
    this.tplSelectedIds = [];
  }

  /** 时间管理：多选态点一行 = 切换选中；全部取消时自动退出多选 */
  private toggleTplSelect(tplId: number): void {
    const idx: number = this.tplSelectedIds.indexOf(tplId);
    if (idx >= 0) {
      const kept: number[] = [];
      for (let i = 0; i < this.tplSelectedIds.length; i++) {
        if (this.tplSelectedIds[i] !== tplId) {
          kept.push(this.tplSelectedIds[i]);
        }
      }
      this.tplSelectedIds = kept;
    } else {
      this.tplSelectedIds = this.tplSelectedIds.concat([tplId]);
    }
    if (this.tplSelectedIds.length === 0) {
      this.exitTplSelect();
    }
  }

  /** 时间管理：全选 / 取消全选（左下角按钮；全满再点 = 退出多选） */
  private toggleTplSelectAll(): void {
    if (this.tplSelectedIds.length >= this.templates.length) {
      this.exitTplSelect();
      return;
    }
    const ids: number[] = [];
    for (let i = 0; i < this.templates.length; i++) {
      ids.push(this.templates[i].id);
    }
    this.tplSelectedIds = ids;
  }

  /** 时间管理：批量删除确认（内置模板与被学期引用的由 repo 逐条把关） */
  private confirmDeleteSelectedTemplates(): void {
    const count: number = this.tplSelectedIds.length;
    if (count === 0 || this.manageBusy) {
      return;
    }
    AlertDialog.show({
      title: '删除选中时间表',
      message: `确定把选中的 ${count} 个时间表删除吗？内置模板与仍被学期引用的时间表会跳过，删除后无法恢复。`,
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: '#EF4444',
        action: () => {
          this.deleteSelectedTemplates();
        }
      }
    });
  }

  /** 时间管理：批量删除选中项（内置 / 被引用的删不掉，按实际删数汇报） */
  private async deleteSelectedTemplates(): Promise<void> {
    this.manageBusy = true;
    let deleted: number = 0;
    try {
      for (let i = 0; i < this.tplSelectedIds.length; i++) {
        const ok: boolean = await ScheduleRepository.getInstance()
          .deleteTemplate(this.tplSelectedIds[i]);
        if (ok) {
          deleted++;
        }
      }
      if (deleted === this.tplSelectedIds.length) {
        this.notify(`已删除 ${deleted} 个时间表`);
      } else if (deleted > 0) {
        this.notify(`已删除 ${deleted} 个时间表（其余为内置模板或仍被学期引用）`);
      } else {
        this.notify('内置模板或被学期引用的时间表不能删除');
      }
      this.exitTplSelect();
      await this.refresh();
    } catch (e) {
      this.notify(`批量删除失败：${ScheduleRepository.describeError(e)}`);
    }
    this.manageBusy = false;
  }

  /** 时间列表高度：按时间表数算并封顶 —— 与名册同一策略，面板高度稳定 */
  private tplListHeight(): number {
    const count: number = this.templates.length;
    const raw: number = count * TPL_ROW_HEIGHT + Math.max(0, count - 1) * 8;
    return clamp(raw, TPL_ROW_HEIGHT, TPL_LIST_MAX_HEIGHT);
  }

  /** 教师管理：长按进入多选，并把长按的那一项选上 */
  private enterTeacherSelect(teacherId: number): void {
    this.teacherSelectMode = true;
    this.teacherSelectedIds = [teacherId];
  }

  /** 教师管理：退出多选（清空选中） */
  private exitTeacherSelect(): void {
    this.teacherSelectMode = false;
    this.teacherSelectedIds = [];
  }

  /** 教师管理：多选态点一行 = 切换选中；全部取消时自动退出多选 */
  private toggleTeacherSelect(teacherId: number): void {
    const idx: number = this.teacherSelectedIds.indexOf(teacherId);
    if (idx >= 0) {
      const kept: number[] = [];
      for (let i = 0; i < this.teacherSelectedIds.length; i++) {
        if (this.teacherSelectedIds[i] !== teacherId) {
          kept.push(this.teacherSelectedIds[i]);
        }
      }
      this.teacherSelectedIds = kept;
    } else {
      this.teacherSelectedIds = this.teacherSelectedIds.concat([teacherId]);
    }
    if (this.teacherSelectedIds.length === 0) {
      this.exitTeacherSelect();
    }
  }

  /** 教师管理：全选 / 取消全选（左下角按钮；全满再点 = 退出多选） */
  private toggleTeacherSelectAll(): void {
    const rows: TeacherCourses[] = this.teacherCourseRows();
    if (this.teacherSelectedIds.length >= rows.length) {
      this.exitTeacherSelect();
      return;
    }
    const ids: number[] = [];
    for (let i = 0; i < rows.length; i++) {
      ids.push(rows[i].teacher.id);
    }
    this.teacherSelectedIds = ids;
  }

  /** 教师管理：批量删除确认（AlertDialog 是独立窗口，不参与面板高度变化） */
  private confirmDeleteSelectedTeachers(): void {
    const count: number = this.teacherSelectedIds.length;
    if (count === 0 || this.manageBusy) {
      return;
    }
    AlertDialog.show({
      title: '删除选中教师',
      message: `确定把选中的 ${count} 位教师删除吗？他们名下的课程会一并删除，删除后无法恢复。`,
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: '#EF4444',
        action: () => {
          this.deleteSelectedTeachers();
        }
      }
    });
  }

  /** 教师管理：批量删除选中教师（课程级联删除；删到当前教师时切回未选中视角） */
  private async deleteSelectedTeachers(): Promise<void> {
    this.manageBusy = true;
    let deleted: number = 0;
    try {
      for (let i = 0; i < this.teacherSelectedIds.length; i++) {
        await ScheduleRepository.getInstance().deleteTeacher(this.teacherSelectedIds[i]);
        if (this.currentTeacherId === this.teacherSelectedIds[i]) {
          this.currentTeacherId = 0;
        }
        deleted++;
      }
      this.notify(`已删除 ${deleted} 位教师及其课程`);
      this.exitTeacherSelect();
      await this.refresh();
    } catch (e) {
      this.notify(`已删除 ${deleted} 位教师，其余删除失败：${ScheduleRepository.describeError(e)}`);
    }
    this.manageBusy = false;
  }

  /** 教师列表高度：按教师数算并封顶 —— 与名册同一策略，面板高度稳定 */
  private teacherListHeight(): number {
    const count: number = this.teacherCourseRows().length;
    const raw: number = count * TEACHER_ROW_HEIGHT + Math.max(0, count - 1) * 8;
    return clamp(raw, TEACHER_ROW_HEIGHT, TEACHER_LIST_MAX_HEIGHT);
  }

  // ------------------------------------------- 管理菜单：周次滑杆 / 学期快切

  /** 当前学期总周数（未加载时按 1 处理，保证 Slider 的 min 不会大于 max） */
  private weekTotal(): number {
    return this.semesterCourses === null ? 1 : this.semesterCourses.semester.total_weeks;
  }

  /**
   * 周次滑杆回调。
   * 拖动过程中只更新本地值——否则每移动一像素就查一次库；
   * 松手（End）或点击轨道（Click）才真正切周并重载该周课程。
   */
  private onWeekSlider(value: number, mode: SliderChangeMode): void {
    this.weekSlider = clamp(Math.round(value), 1, this.weekTotal());
    if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
      this.switchWeek(this.weekSlider);
    }
  }

  private hasSemesterNamed(name: string): boolean {
    for (let i = 0; i < this.semesters.length; i++) {
      if (this.semesters[i].name === name) {
        return true;
      }
    }
    return false;
  }

  /** 学期名在库里是 UNIQUE，重名会直接抛错；这里自动加序号保证唯一 */
  private uniqueSemesterName(base: string): string {
    if (!this.hasSemesterNamed(base)) {
      return base;
    }
    let index: number = 2;
    while (this.hasSemesterNamed(`${base} ${index}`)) {
      index++;
    }
    return `${base} ${index}`;
  }

  /**
   * 管理菜单「+」：新建一个学期。
   *
   * 名称默认「默认学期」（重名自动加序号），周数 20，开学日取本周一，
   * 时间表沿用当前学期那张（没有则用第一张）；建完立即切过去。
   */
  private async createQuickSemester(): Promise<void> {
    if (this.templates.length === 0) {
      this.notify('没有可用时间表，请先在「时间管理」中新建');
      return;
    }
    const name: string = this.uniqueSemesterName(DEFAULT_SEMESTER_NAME);
    let templateId: number = this.templates[0].id;
    const sem: Semester | undefined = this.currentSemester();
    if (sem !== undefined && sem.schedule_id > 0) {
      templateId = sem.schedule_id;
    }
    this.manageBusy = true;
    try {
      const start: string = DateUtil.toDateString(DateUtil.weekMonday(DateUtil.today()));
      const created: Semester = await ScheduleRepository.getInstance()
        .createSemester(name, templateId, DEFAULT_SEMESTER_WEEKS, start);
      // 新学期还没有课程，教师指向留空，refresh 会按"机主工号"自动兜底
      await ScheduleRepository.getInstance().savePointers(created.id, 0);
      this.currentTeacherId = 0;
      // 新学期的开学日就是本周一，因此"今天所在周"= 第 1 周（统一走同一套推导）
      this.currentWeek = created.currentWeek();
      this.weekSlider = this.currentWeek;
      await this.refresh();
      this.notify(`已新建学期：${created.name}`);
    } catch (e) {
      this.notify(`新建学期失败：${ScheduleRepository.describeError(e)}`);
    }
    this.manageBusy = false;
  }

  // --------------------------------------------------- 时间管理（多张时间表）

  private hasTemplateNamed(name: string): boolean {
    for (let i = 0; i < this.templates.length; i++) {
      if (this.templates[i].name === name) {
        return true;
      }
    }
    return false;
  }

  private uniqueTemplateName(base: string): string {
    if (!this.hasTemplateNamed(base)) {
      return base;
    }
    let index: number = 2;
    while (this.hasTemplateNamed(`${base} ${index}`)) {
      index++;
    }
    return `${base} ${index}`;
  }

  /** 该时间表是否正被当前学期使用（含"学期未绑定 → 回落第一张"的情况） */
  private isTemplateInUse(templateId: number): boolean {
    const sem: Semester | undefined = this.currentSemester();
    if (sem === undefined) {
      return false;
    }
    if (sem.schedule_id > 0) {
      return sem.schedule_id === templateId;
    }
    return this.templates.length > 0 && this.templates[0].id === templateId;
  }

  /**
   * 新建时间表：先按 12 节标准作息落库，再进全屏编辑页。
   *
   * 为什么是先落库：编辑页是按 id 加载草稿的（`aboutToAppear` 只认 `templateId`），
   * 必须有一个真实 id 才能进得去；若当前学期还没绑定时间表，顺手把它绑上。
   */
  private async newTemplate(): Promise<void> {
    this.manageBusy = true;
    try {
      const draft: ScheduleTemplate = ScheduleTemplate.blank(this.uniqueTemplateName('时间表'));
      const templateId: number = await ScheduleRepository.getInstance().saveTemplate(draft);
      const sem: Semester | undefined = this.currentSemester();
      if (sem !== undefined && sem.schedule_id <= 0) {
        await ScheduleRepository.getInstance().bindTemplate(sem.id, templateId);
      }
      await this.refresh();
      this.navToTemplateEdit(templateId);
    } catch (e) {
      this.notify(`新建时间表失败：${ScheduleRepository.describeError(e)}`);
    }
    this.manageBusy = false;
  }

  /** 进入全屏时间表编辑页（编辑页按 id 自行加载草稿，这里只传 id 与主题色） */
  private editTemplate(templateId: number): void {
    this.navToTemplateEdit(templateId);
  }

  /**
   * 跳转全屏时间表编辑页。
   *
   * 必须先收起管理 sheet：sheet 是浮在页面之上的独立图层，直接 push 页面会与它叠在一起。
   * 顺手记下"回到这一屏"，返回时由 onPageShow 重新打开，用户不会丢失上下文。
   */
  private navToTemplateEdit(templateId: number): void {
    if (templateId <= 0) {
      this.notify('时间表不存在，可能已被删除');
      return;
    }
    this.restoreManageView = 'time';
    this.showManageSheet = false;
    router.pushUrl({
      url: 'pages/TemplateEdit',
      params: {
        templateId: templateId,
        themeColor: this.uiThemeColor
      }
    });
  }

  /** 时间表：复制一份（节次与作息照搬，名称加「副本」） */
  private async duplicateTemplate(templateId: number): Promise<void> {
    this.manageBusy = true;
    try {
      const created: ScheduleTemplate | undefined =
        await ScheduleRepository.getInstance().duplicateTemplate(templateId);
      this.notify(created === undefined ? '时间表不存在，可能已被删除' : `已复制为「${created.name}」`);
      await this.refresh();
    } catch (e) {
      this.notify(`复制时间表失败：${ScheduleRepository.describeError(e)}`);
    }
    this.manageBusy = false;
  }

  /** 把某张时间表应用到当前学期 */
  private async applyTemplate(templateId: number): Promise<void> {
    const sem: Semester | undefined = this.currentSemester();
    if (sem === undefined) {
      this.notify('请先选择学期');
      return;
    }
    if (sem.schedule_id === templateId) {
      this.notify('该时间表已应用于当前学期');
      return;
    }
    this.manageBusy = true;
    try {
      await ScheduleRepository.getInstance().bindTemplate(sem.id, templateId);
      await this.refresh();
      this.notify('已应用到当前学期');
    } catch (e) {
      this.notify(`应用时间表失败：${ScheduleRepository.describeError(e)}`);
    }
    this.manageBusy = false;
  }

  /** 删除时间表（二次确认）；内置模板或被学期引用的一律不允许删 */  /** 时间管理：删除单个时间表（AlertDialog 二次确认；内置 / 被引用的由 repo 把关） */
  private confirmDeleteTemplate(tplId: number): void {
    if (this.manageBusy) {
      return;
    }
    let name: string = '';
    for (let i = 0; i < this.templates.length; i++) {
      if (this.templates[i].id === tplId) {
        name = this.templates[i].name;
        break;
      }
    }
    AlertDialog.show({
      title: '删除时间表',
      message: `确定删除「${name}」吗？删除后无法恢复。`,
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: '#EF4444',
        action: () => {
          this.deleteTemplateById(tplId);
        }
      }
    });
  }

  private async deleteTemplateById(tplId: number): Promise<void> {
    this.manageBusy = true;
    try {
      const ok: boolean = await ScheduleRepository.getInstance().deleteTemplate(tplId);
      this.notify(ok ? '时间表已删除' : '内置模板或被学期引用的时间表不能删除');
      await this.refresh();
    } catch (e) {
      this.notify(`删除时间表失败：${ScheduleRepository.describeError(e)}`);
    }
    this.manageBusy = false;
  }



  // ------------------------------------------------------- 界面颜色（拾色器）

  /** 打开拾色器：target = theme（主题色）/ today（今日高亮色） */
  private openColorPicker(target: string): void {
    this.colorTarget = target;
    const current: string = target === 'today' ? this.uiTodayColor : this.uiThemeColor;
    this.colorBackup = current;
    const hsv: HSV = hexToHsv(current);
    this.pickerHue = hsv.h;
    this.pickerSaturation = hsv.s;
    this.pickerValue = hsv.v;
    this.pickerAlpha = alphaOf(current);
    this.showUiColorPicker = true;
  }

  /** 拾色器里的纯色（不含透明度） */
  private pickerHex(): string {
    return hsvToHex(this.pickerHue, this.pickerSaturation, this.pickerValue);
  }

  /** 拾色器最终颜色：8 位 ARGB，透明度真实生效 */
  private pickerARGB(): string {
    return withAlpha(this.pickerHex(), this.pickerAlpha);
  }

  private pickerTitle(): string {
    return this.colorTarget === 'today' ? '高亮色' : '主题色';
  }

  /**
   * 把当前取色结果实时写到目标颜色上。
   *
   * 拖动方块 / 色相条 / 透明度条 / 手改 HEX 时都会调它，所以拾色器背后的首页
   * （顶栏图标、周次栏月份、底部导航高亮）会立刻跟着变色，不用等按「确定」。
   */
  private applyLiveColor(): void {
    const color: string = this.pickerARGB();
    if (this.colorTarget === 'today') {
      this.uiTodayColor = color;
    } else {
      this.uiThemeColor = color;
    }
  }

  /** 确定：颜色在拖动时已写进状态，这里只需收起面板并落库 */
  private confirmUiColor(): void {
    this.applyLiveColor();
    this.showUiColorPicker = false;
    this.persistUiColors();
  }

  /** 取消（✕ / 点遮罩）：回滚到打开拾色器前的颜色，不落库 */
  private cancelUiColor(): void {
    if (this.colorTarget === 'today') {
      this.uiTodayColor = this.colorBackup;
    } else {
      this.uiThemeColor = this.colorBackup;
    }
    this.showUiColorPicker = false;
  }

  private async persistUiColors(): Promise<void> {
    try {
      await ScheduleRepository.getInstance().saveUiColors(this.uiThemeColor, this.uiTodayColor);
    } catch (e) {
      this.notify(`保存界面颜色失败：${ScheduleRepository.describeError(e)}`);
    }
  }

  private resetUiColors(): void {
    this.uiThemeColor = normalizeColor(THEME_COLOR_DEFAULT);
    this.uiTodayColor = normalizeColor(TODAY_COLOR_DEFAULT);
    this.persistUiColors();
  }

  // ------------------------------------------------------- 上课提醒

  /**
   * 拨动"提醒第二天的课"。
   *
   * 打开时才申请通知授权：没打算用提醒的用户不该在装完应用就被弹一次授权框。
   */
  private async onNotifyNextDayChange(on: boolean): Promise<void> {
    this.notifyNextDay = on;
    if (on) {
      await this.ensureNotifyPermission();
    }
    const saved: boolean = await this.persistReminders();
    if (!saved) {
      // 存储失败时把开关拨回去：界面显示"已打开"而库里是关的，比直接报错更糟
      this.notifyNextDay = !on;
    }
  }

  private async onNotifyAheadChange(on: boolean): Promise<void> {
    this.notifyAhead = on;
    if (on) {
      await this.ensureNotifyPermission();
      this.notifyAheadText = `${this.notifyAheadMinutes}`;
    }
    const saved: boolean = await this.persistReminders();
    if (!saved) {
      this.notifyAhead = !on;
    }
  }

  /**
   * 输入框失焦 / 回车：把文本收敛成分钟数。
   *
   * 文本可能是空串、"3分钟"、"abc" 或 100000 —— 一律交给 `clampNotifyMinutes` 收进
   * [1, 120]；解析不出来就退回上一次的有效值。**无论哪种情况都把文本回写成规范形式**，
   * 否则用户会看着"abc"以为设置生效了。
   */
  private async commitAheadMinutes(): Promise<void> {
    const parsed: number = parseInt(this.notifyAheadText, 10);
    const minutes: number = clampNotifyMinutes(isNaN(parsed) ? this.notifyAheadMinutes : parsed);
    const previous: number = this.notifyAheadMinutes;
    // 无论是否改动都要回写文本：用户看到的必须是"真正生效的那个数"
    this.notifyAheadMinutes = minutes;
    this.notifyAheadText = `${minutes}`;
    if (minutes === previous) {
      return;
    }
    const saved: boolean = await this.persistReminders();
    if (!saved) {
      this.notifyAheadMinutes = previous;
      this.notifyAheadText = `${previous}`;
    }
  }

  /**
   * 申请通知授权。
   *
   * 系统授权框在用户拒绝之后不会再弹，所以被拒时就落成一句文字提示，
   * 告诉用户去哪儿打开 —— 只留一句，不做循环弹框。
   */
  private async ensureNotifyPermission(): Promise<void> {
    const granted: boolean = await LessonReminder.ensureNotificationEnabled(this.context());
    if (granted) {
      return;
    }
    this.notify('系统通知是关闭的，提醒不会弹出来。请到「设置 → 通知和状态栏」里允许「每日知途」发送通知');
  }

  /**
   * 保存提醒设置并按新设置重建提醒（force：开关一拨就要生效，不能被 20 秒节流挡住）。
   *
   * 两件事**分阶段报错**，因为失败的后果完全不同：
   *  - 设置没落库 → 这次拨动等于没发生，界面必须把开关回滚并明确告诉用户；
   *  - 提醒没登记上 → 设置其实已经保存好了，只记日志（下次刷新课表还会重建一遍），
   *    谎报成"设置没保存"会让用户反复拨同一个开关。
   *
   * @returns 设置是否已经落库。false 时调用方负责回滚界面上的开关 ——
   *          界面显示"已打开"而库里是关的，比报错本身更麻烦。
   */
  private async persistReminders(): Promise<boolean> {
    try {
      await ScheduleRepository.getInstance()
        .saveReminderSettings(this.notifyNextDay, this.notifyAhead, this.notifyAheadMinutes);
    } catch (e) {
      Logger.error(TAG, `保存提醒设置失败：${errDetail(e)}`);
      this.notify(`提醒设置没能保存：${ScheduleRepository.describeError(e)}`);
      return false;
    }
    try {
      await LessonReminder.sync(this.context(), true);
    } catch (e) {
      Logger.error(TAG, `按新设置重建提醒失败：${errDetail(e)}`);
      this.notify(`设置已保存，但系统提醒没能登记：${ScheduleRepository.describeError(e)}`);
    }
    return true;
  }

  private onColorBoxTouch(event: TouchEvent): void {
    if (event.touches.length === 0) {
      return;
    }
    if (event.type === TouchType.Down || event.type === TouchType.Move) {
      const x: number = event.touches[0].x;
      const y: number = event.touches[0].y;
      this.pickerSaturation = clamp(x / this.pickerBoxSize, 0, 1);
      this.pickerValue = clamp(1 - y / this.pickerBoxSize, 0, 1);
      this.applyLiveColor();
    }
  }

  private onHueTouch(event: TouchEvent): void {
    if (event.touches.length === 0) {
      return;
    }
    if (event.type === TouchType.Down || event.type === TouchType.Move) {
      const x: number = event.touches[0].x;
      this.pickerHue = clamp(Math.round((x / this.pickerBoxSize) * 360), 0, 360);
      this.applyLiveColor();
    }
  }

  private onAlphaTouch(event: TouchEvent): void {
    if (event.touches.length === 0) {
      return;
    }
    if (event.type === TouchType.Down || event.type === TouchType.Move) {
      const x: number = event.touches[0].x;
      this.pickerAlpha = clamp(x / this.pickerBoxSize, 0, 1);
      this.applyLiveColor();
    }
  }

  private onPickerHexInput(value: string): void {
    const hsv: HSV = hexToHsv(value);
    this.pickerHue = hsv.h;
    this.pickerSaturation = hsv.s;
    this.pickerValue = hsv.v;
    this.pickerAlpha = alphaOf(value);
    this.applyLiveColor();
  }

  // ---------------------------------------------------------------- 课程详情 sheet

  /** 点击课程卡片：打开详情 sheet，并异步加载该时间段的全部周次 */
  private openLessonSheet(lesson: LessonRow): void {
    this.sheetLesson = lesson;
    this.sheetAction = 'none';
    this.sheetWeeks = [];
    this.showLessonSheet = true;
    this.loadSheetWeeks(lesson.time_period_id);
  }

  private async loadSheetWeeks(periodId: number): Promise<void> {
    try {
      this.sheetWeeks = await ScheduleRepository.getInstance().weeksOfPeriod(periodId);
    } catch (e) {
      // 加载失败退化为只显示当前周
      this.sheetWeeks = [this.sheetLesson.week_no];
      Logger.warn(TAG, `加载时间段周次失败：${ScheduleRepository.describeError(e)}`);
    }
  }

  /** sheet 上"上课周次"的展示文本：连续周次压缩成区间 */
  private sheetWeeksText(): string {
    if (this.sheetWeeks.length === 0) {
      return `第${this.sheetLesson.week_no}周`;
    }
    const parts: string[] = [];
    let start: number = this.sheetWeeks[0];
    let prev: number = this.sheetWeeks[0];
    for (let i = 1; i < this.sheetWeeks.length; i++) {
      if (this.sheetWeeks[i] === prev + 1) {
        prev = this.sheetWeeks[i];
      } else {
        parts.push(start === prev ? `${start}` : `${start}-${prev}`);
        start = this.sheetWeeks[i];
        prev = this.sheetWeeks[i];
      }
    }
    parts.push(start === prev ? `${start}` : `${start}-${prev}`);
    return `第 ${parts.join('、')} 周`;
  }

  private sheetSessionText(): string {
    return `周${WEEKDAY_LABELS[this.sheetLesson.weekday - 1]} 第${this.sheetLesson.start_time}-${this.sheetLesson.end_time}节`;
  }

  private sheetScoreText(): string {
    return this.sheetLesson.course_score === null ? '未填写' : `${this.sheetLesson.course_score}`;
  }

  private closeLessonSheet(): void {
    this.showLessonSheet = false;
    this.sheetAction = 'none';
  }

  /** 跳转课程编辑页：mode = editGroup（编辑此班级）/ editCourse（编辑此课程） */
  private navToLessonEdit(mode: string): void {
    this.showLessonSheet = false;
    this.sheetAction = 'none';
    const sem: Semester | undefined = this.currentSemester();
    if (sem === undefined) {
      this.notify('请先选择学期');
      return;
    }
    router.pushUrl({
      url: 'pages/CourseEdit',
      params: {
        semesterId: sem.id,
        teacherId: this.sheetLesson.teacher_id,
        maxWeek: sem.total_weeks,
        maxSession: this.sessionCount(),
        semesterName: sem.name,
        teacherName: this.sheetLesson.teacher_name,
        mode: mode,
        courseRowId: this.sheetLesson.course_row_id,
        focusGroupId: mode === 'editGroup' ? this.sheetLesson.class_group_id : 0
      }
    });
  }

  /**
   * 随机抽取人数的上限：不超过本班登记人数（登记人数为 0 时退回通用上限）。
   * 抽 200 人但班里只有 30 个，点名页会显示"随机 30 人"，数字对不上反而像出了 bug。
   */
  private randomCountCeiling(): number {
    const pop: number = this.sheetLesson.population;
    return pop <= 0 ? MAX_RANDOM_COUNT : clamp(pop, MIN_RANDOM_COUNT, MAX_RANDOM_COUNT);
  }

  /**
   * 进全屏点名页。
   *
   * 带上 `time_period_id + week_no` 这一对：**签到记录是按"某一次课"存的**
   * （同一门课第 3 周与第 4 周是两份），只带课程 id 会把各周的点名结果混成一份。
   * `week_no` 取的就是卡片/课表当前显示的那一周 —— 用户看到的和点到的必须是同一次课。
   */
  private navToCheckIn(mode: string): void {
    this.showLessonSheet = false;
    this.sheetAction = 'none';
    const lesson: LessonRow = this.sheetLesson;
    router.pushUrl({
      url: 'pages/CheckIn',
      params: {
        periodId: lesson.time_period_id,
        weekNo: lesson.week_no,
        classId: lesson.class_id,
        courseName: lesson.course_name,
        className: lesson.class_name,
        classRoom: lesson.class_room,
        weekday: lesson.weekday,
        startSession: lesson.start_time,
        endSession: lesson.end_time,
        mode: mode,
        randomCount: this.sheetRandomCount,
        themeColor: this.uiThemeColor
      }
    });
  }

  /**
   * 打开「查看本节课程情况」：只读地摊开**这一次课**的点名结果。
   *
   * 与点名页的关键区别是**它不需要落库**，所以不跳全屏页、就地在这一层展开 ——
   * 老师多半是在点名前瞄一眼"上次点名点成什么样了"，看完就要接着点。
   *
   * 两次查询（名单 + 签到）都在这里一次性读齐：`@Builder` 体内不能 await，
   * 而列表要按**名单顺序**排（签到表里只有 student_id，没有学号姓名），
   * 所以必须先把名单拿到手再拼。
   */
  private async openCheckinView(): Promise<void> {
    if (this.sheetBusy) {
      return;
    }
    this.sheetBusy = true;
    this.sheetAction = 'checkinView';
    this.checkinViewRows = [];
    this.checkinViewHasRecord = false;
    this.checkinViewLoaded = false;
    this.checkinViewError = '';
    const lesson: LessonRow = this.sheetLesson;
    try {
      const repo: ScheduleRepository = ScheduleRepository.getInstance();
      const roster: ClassRoster = await repo.loadRoster(lesson.class_id);
      const records: AttendanceRow[] =
        await repo.loadAttendance(lesson.time_period_id, lesson.week_no);
      if (records.length > 0) {
        this.checkinViewHasRecord = true;
      }
      // student_id → 签到行：一次课一个学生最多一条（表上有 UNIQUE 约束），同名不会被覆盖
      const byStudent: Map<number, AttendanceRow> = new Map<number, AttendanceRow>();
      for (let i = 0; i < records.length; i++) {
        byStudent.set(records[i].student_id, records[i]);
      }
      // 名单顺序就是列表顺序（与名册页一致的自然序），不是签到表的写入顺序
      const students: Student[] = roster.students.slice();
      students.sort((a: Student, b: Student) => compareNo(a.student_no, b.student_no));
      const rows: CheckinViewRow[] = [];
      for (let i = 0; i < students.length; i++) {
        const row: CheckinViewRow = new CheckinViewRow();
        row.studentNo = students[i].student_no;
        row.name = students[i].name;
        const hit: AttendanceRow | undefined = byStudent.get(students[i].id);
        if (hit !== undefined) {
          row.status = hit.status;
          row.grade = hit.grade;
          row.score = hit.score;
        }
        rows.push(row);
      }
      this.checkinViewRows = rows;
      this.checkinViewLoaded = true;
      Logger.info(TAG,
        `查看本节课程情况：第${lesson.week_no}周 ${lesson.class_name} 名单 ${rows.length} 人 / 签到 ${records.length} 条`);
    } catch (e) {
      this.checkinViewLoaded = true;
      this.checkinViewError = ScheduleRepository.describeError(e);
      Logger.error(TAG, `读取本节课程情况失败：${this.checkinViewError}`);
      this.notify(`读取考勤失败：${this.checkinViewError}`);
    }
    this.sheetBusy = false;
  }

  /** 「查看本节课程情况」的副标题：这一次课到底是哪一周、第几节 */
  private checkinViewSessionText(): string {
    const lesson: LessonRow = this.sheetLesson;
    return `第${lesson.week_no}周 周${WEEKDAY_LABELS[lesson.weekday - 1]} `
      + `第${lesson.start_time}-${lesson.end_time}节`;
  }

  /** 按点名结果数人头：`status` 传 AttendStatus 里的取值 */
  private checkinViewCount(status: string): number {
    let n: number = 0;
    for (let i = 0; i < this.checkinViewRows.length; i++) {
      if (this.checkinViewRows[i].status === status) {
        n++;
      }
    }
    return n;
  }

  /**
   * 已评级的平均分（保留 1 位小数）。
   *
   * 只统计**评过级**的人：没点名、旷课、请假的都没有分数，把它们当 0 分平均会把
   * "全班考勤良好"算成四五十分，比不显示更容易误导。
   */
  private checkinViewAvgScore(): string {
    let sum: number = 0;
    let n: number = 0;
    for (let i = 0; i < this.checkinViewRows.length; i++) {
      const row: CheckinViewRow = this.checkinViewRows[i];
      if (row.status === AttendStatus.PRESENT && row.score > 0) {
        sum += row.score;
        n++;
      }
    }
    if (n === 0) {
      return '—';
    }
    return (sum / n).toFixed(1);
  }

  /** 一行的展示符号：出勤 √ / 旷课 × / 请假 ⊕ / 未点名 ·（与点名页同一套记号） */
  private checkinViewMark(row: CheckinViewRow): string {
    if (row.status === AttendStatus.PRESENT) {
      return AttendMark.PRESENT;
    }
    if (row.status === AttendStatus.ABSENT) {
      return AttendMark.ABSENT;
    }
    if (row.status === AttendStatus.LEAVE) {
      return AttendMark.LEAVE;
    }
    return '·';
  }

  private checkinViewMarkColor(row: CheckinViewRow): string {
    if (row.status === AttendStatus.PRESENT) {
      return '#16A34A';
    }
    if (row.status === AttendStatus.ABSENT) {
      return '#DC2626';
    }
    if (row.status === AttendStatus.LEAVE) {
      return '#D97706';
    }
    return '#D1D5DB';
  }

  private checkinViewRowBg(row: CheckinViewRow): string {
    if (row.status === AttendStatus.PRESENT) {
      return '#F0FDF4';
    }
    if (row.status === AttendStatus.ABSENT) {
      return '#FEF2F2';
    }
    if (row.status === AttendStatus.LEAVE) {
      return '#FFFBEB';
    }
    return '#FFFFFF';
  }

  /** 一行的说明文字：等级档位 + 分数 / 旷课 / 请假 / 未点名 */
  private checkinViewDetail(row: CheckinViewRow): string {
    if (row.status === AttendStatus.PRESENT) {
      return row.grade > 0 ? `${row.grade} 档 · ${row.score} 分` : '出勤（未评等级）';
    }
    if (row.status === AttendStatus.ABSENT) {
      return '旷课';
    }
    if (row.status === AttendStatus.LEAVE) {
      return '请假';
    }
    return '未点名';
  }

  /** 汇总格：大数字 + 小标签（出勤 / 旷课 / 请假 / 未点名 四格同宽） */
  @Builder
  checkinViewStat(label: string, value: number, color: string) {
    Column({ space: 2 }) {
      Text(`${value}`)
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(color)
      Text(label)
        .fontSize(11)
        .fontColor('#6B7280')
    }
    .layoutWeight(1)
    .padding({ top: 8, bottom: 8 })
    .backgroundColor('#F9FAFB')
    .borderRadius(10)
  }

  /** 一行学生：序号 + 学号姓名 | 说明 | 记号（与点名页同一套符号与配色） */
  @Builder
  checkinViewRow(row: CheckinViewRow, index: number) {
    Row({ space: 10 }) {
      Text(`${index + 1}`)
        .fontSize(12)
        .fontColor('#9CA3AF')
        .width(22)
        .textAlign(TextAlign.Center)
      Column({ space: 2 }) {
        Text(row.name)
          .fontSize(14)
          .fontColor('#111827')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(row.studentNo)
          .fontSize(11)
          .fontColor('#9CA3AF')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Text(this.checkinViewDetail(row))
        .fontSize(11)
        .fontColor('#6B7280')
      Text(this.checkinViewMark(row))
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.checkinViewMarkColor(row))
        .width(26)
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .height(CHECKIN_VIEW_ROW_HEIGHT)
    .padding({ left: 8, right: 10 })
    .backgroundColor(this.checkinViewRowBg(row))
    .borderRadius(10)
  }

  /**
   * 「查看本节课程情况」面板：这一次课的点名结果只读摊开。
   *
   * 为什么不用 AlertDialog：它只能是一段纯文字，几十号人的逐个结果塞不进去；
   * 为什么不做成第二个 sheet：课程详情已经占了这一层，同节点再 bindSheet 会顶掉它。
   */
  @Builder
  checkinViewPanel() {
    Column({ space: 10 }) {
      // 面板主体收在**一个** Scroll 里：统计与列表一起滚，总高由
      // CHECKIN_VIEW_PANEL_MAX_HEIGHT 封顶（课程详情 sheet 外层没有兜底滚动）。
      // 「返回」放在 Scroll **外面** —— 滚到长名单底部时它必须还在原地。
      Scroll() {
        Column({ space: 10 }) {
          // 这是哪一次课 —— 面板里必须自证，否则从签到面板翻进来容易忘了当前在第几周
          // （time_period 每周复用，同一门课不同周的点名结果长得一模一样）
          Row() {
            Text(this.checkinViewSessionText())
              .fontSize(12)
              .fontColor('#6B7280')
              .layoutWeight(1)
            Text(`${this.sheetLesson.course_name} · ${this.sheetLesson.class_name}`)
              .fontSize(12)
              .fontColor('#9CA3AF')
          }
          .width('100%')

          if (!this.checkinViewLoaded) {
            Text('读取中…')
              .fontSize(12)
              .fontColor('#9CA3AF')
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 12, bottom: 12 })
          } else if (this.checkinViewError.length > 0) {
            // 读库失败与"名单为空"必须分开报：共用一个空态会把人引到"去导入名单"上
            Text(`读取考勤失败：${this.checkinViewError}`)
              .fontSize(12)
              .fontColor('#DC2626')
              .width('100%')
              .padding({ top: 8, bottom: 8 })
          } else {
            Row({ space: 8 }) {
              this.checkinViewStat('出勤', this.checkinViewCount(AttendStatus.PRESENT), '#16A34A')
              this.checkinViewStat('旷课', this.checkinViewCount(AttendStatus.ABSENT), '#DC2626')
              this.checkinViewStat('请假', this.checkinViewCount(AttendStatus.LEAVE), '#D97706')
              this.checkinViewStat('未点名', this.checkinViewCount(AttendStatus.NONE), '#6B7280')
            }
            .width('100%')

            Row() {
              Text(`已点名 ${this.checkinViewRows.length - this.checkinViewCount(AttendStatus.NONE)} / ${this.checkinViewRows.length}`)
                .fontSize(12)
                .fontColor('#6B7280')
              Blank()
              Text(`已评级平均分 ${this.checkinViewAvgScore()}`)
                .fontSize(12)
                .fontColor('#6B7280')
            }
            .width('100%')

            if (!this.checkinViewHasRecord) {
              Text('这一次课还没有点名记录 —— 上面的数字全是「未点名」。')
                .fontSize(11)
                .fontColor('#D97706')
                .width('100%')
            }

            if (this.checkinViewRows.length === 0) {
              Text(`「${this.sheetLesson.class_name}」还没有导入学生名单`)
                .fontSize(12)
                .fontColor('#9CA3AF')
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding({ top: 12, bottom: 12 })
            } else {
              // 列表**不给高度上限**：整块被外层 Scroll 兜着，人数多就一起滚
              Column({ space: 6 }) {
                ForEach(this.checkinViewRows, (row: CheckinViewRow, index: number) => {
                  this.checkinViewRow(row, index)
                }, (row: CheckinViewRow, index: number) => `${index}-${row.studentNo}`)
              }
              .width('100%')
            }
          }
        }
        .width('100%')
      }
      .width('100%')
      .constraintSize({ maxHeight: CHECKIN_VIEW_PANEL_MAX_HEIGHT })
      .scrollBar(BarState.Off)
      .align(Alignment.TopStart)

      this.sheetMenuOption('返回', '', '#6B7280', 'back')
    }
    .width('100%')
    .padding({ top: 14 })
  }

  /** 删除本班级本周的课：仅移除当前周这一次（period_week 一行，清零则删时间段） */
  private async deleteThisWeekOnce(): Promise<void> {
    if (this.sheetBusy) {
      return;
    }
    this.sheetBusy = true;
    try {
      const lesson: LessonRow = this.sheetLesson;
      await ScheduleRepository.getInstance().deleteWeekOfPeriod(lesson.time_period_id, lesson.week_no);
      this.closeLessonSheet();
      this.notify(`已删除「${lesson.class_name}」第${lesson.week_no}周的一次课`);
      Logger.info(TAG, this.message);
      await this.refresh();
    } catch (e) {
      this.notify(`删除失败：${ScheduleRepository.describeError(e)}`);
      Logger.error(TAG, this.message);
    }
    this.sheetBusy = false;
  }

  /** 删除本班级的课：整个班级分组（含全部时间段与周次） */
  private async deleteThisClass(): Promise<void> {
    if (this.sheetBusy) {
      return;
    }
    this.sheetBusy = true;
    try {
      const lesson: LessonRow = this.sheetLesson;
      await ScheduleRepository.getInstance().deleteClassGroup(lesson.class_group_id);
      this.closeLessonSheet();
      this.notify(`已删除班级「${lesson.class_name}」的全部课程安排`);
      Logger.info(TAG, this.message);
      await this.refresh();
    } catch (e) {
      this.notify(`删除失败：${ScheduleRepository.describeError(e)}`);
      Logger.error(TAG, this.message);
    }
    this.sheetBusy = false;
  }

  /** 删除本门课程：课程与其全部班级、时间段、周次级联清除 */
  private async deleteThisCourse(): Promise<void> {
    if (this.sheetBusy) {
      return;
    }
    this.sheetBusy = true;
    try {
      const lesson: LessonRow = this.sheetLesson;
      await ScheduleRepository.getInstance().deleteCourse(lesson.course_row_id);
      this.closeLessonSheet();
      this.notify(`已删除课程「${lesson.course_name}」`);
      Logger.info(TAG, this.message);
      await this.refresh();
    } catch (e) {
      this.notify(`删除失败：${ScheduleRepository.describeError(e)}`);
      Logger.error(TAG, this.message);
    }
    this.sheetBusy = false;
  }

  // ---------------------------------------------------------------- Builder

  @Builder
  ownerSetupCard() {
    Column({ space: 16 }) {
      Text(this.ownerConfigured ? '修改默认教师' : '欢迎使用每日知途')
        .fontSize(20).fontWeight(FontWeight.Bold).fontColor('#111827');
      Text(this.ownerConfigured
        ? '修改后将作为各学期的默认教师信息'
        : '首次使用请先录入你的姓名与教师工号，之后系统将默认以此为你的教师信息')
        .fontSize(12).fontColor('#6B7280');

      Column({ space: 8 }) {
        Text('姓名').fontSize(13).fontColor('#374151');
        TextInput({ placeholder: '请输入姓名', text: this.inputName })
          .fontSize(15)
          .height(44)
          .backgroundColor('#FFFFFF')
          .borderRadius(8)
          .onChange((value: string) => {
            this.inputName = value;
          })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      Column({ space: 8 }) {
        Text('教师工号').fontSize(13).fontColor('#374151');
        TextInput({ placeholder: '如 2024***25', text: this.inputStaffNo })
          .type(InputType.Number)
          .fontSize(15)
          .height(44)
          .backgroundColor('#FFFFFF')
          .borderRadius(8)
          .onChange((value: string) => {
            this.inputStaffNo = value;
          })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      Row({ space: 10 }) {
        if (this.ownerConfigured) {
          Button('取消')
            .fontSize(14)
            .layoutWeight(1)
            .backgroundColor('#9CA3AF')
            .onClick(() => {
              this.showOwnerSetup = false;
            })
        }
        Button(this.busy ? '保存中…' : '保存')
          .fontSize(14)
          .layoutWeight(1)
          .backgroundColor(this.uiThemeColor)
          .enabled(!this.busy)
          .onClick(() => {
            this.saveOwner();
          })
      }
      .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(20)
    .backgroundColor('#FFFFFF')
    .borderRadius(14)
  }

  /**
   * 加载失败提示条：贴在顶栏下方。
   *
   * 课表是"读不到就一片空白"的形态，空白本身无法区分"没有课"和"读取失败"。
   * 这条红条既说明原因，也给出一个明确的重试入口 —— 数据仍在数据库里，重试通常即可恢复。
   */
  @Builder
  loadErrorBar() {
    Row({ space: 8 }) {
      Text(`课表加载失败：${this.loadError}`)
        .fontSize(11)
        .fontColor('#B91C1C')
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text('重试')
        .fontSize(12)
        .fontColor('#FFFFFF')
        .backgroundColor('#EF4444')
        .borderRadius(10)
        .padding({ left: 10, right: 10, top: 4, bottom: 4 })
        .onClick(() => {
          this.retryLoad();
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 6, bottom: 6 })
    .backgroundColor('#FEF2F2')
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 未就绪占位：`ready` 仍为 false 时（首帧，或数据库初始化迟迟不返回）显示。
   *
   * 少了这一段，"还在加载"与"加载完了但确实没有课"在屏幕上是同一张空白课表，而这两件事
   * 该做的事完全相反：前者只需等待（一直停在这里就要查 `init` 为什么没返回），后者要去查数据。
   */
  @Builder
  loadingPlaceholder() {
    Row({ space: 8 }) {
      LoadingProgress().width(18).height(18).color('#6B7280')
      Text('正在加载课表…（若长时间停在此处，说明数据库初始化没有返回）')
        .fontSize(12).fontColor('#6B7280').layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    .backgroundColor('#F3F4F6')
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 空课表诊断卡：只在"本周一节课都没有"时渲染。
   *
   * 它不是错误提示（那是 `loadErrorBar` 的职责），而是**现场取证** —— 把学期 / 教师 /
   * 周次 / 各层计数直接摊在原本空着的课表位置上，一张截图就能判定是"数据没写进去"
   * 还是"取到了但没画出来"。正常有课时这段不渲染，不占一点版面。
   */
  @Builder
  emptyDiagCard() {
    Column({ space: 3 }) {
      Row() {
        Text('本周课表为空 · 诊断快照')
          .fontSize(12).fontWeight(FontWeight.Bold).fontColor('#92400E')
        Blank()
        Text('请截图反馈').fontSize(11).fontColor('#B45309')
      }
      .width('100%')
      .margin({ bottom: 2 })

      ForEach(this.diagLines, (line: string, index: number) => {
        Text(line)
          .fontSize(11)
          .fontColor('#78350F')
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }, (line: string, index: number) => `${index}-${line}`)
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#FEF3C7')
    .borderRadius(10)
    .margin({ left: 12, right: 12, top: 4, bottom: 8 })
  }

  @Builder
  topBar() {
    Row() {
      Column({ space: 2 }) {
        Text(this.semesterLine())
          .fontSize(13).fontColor('#6B7280');
        // 固定时间区域：显示今天日期，点击跳回当前周
        Text(this.todayLabel())
          .fontSize(15).fontWeight(FontWeight.Bold).fontColor('#111827')
          .onClick(() => this.goToTodayWeek());
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 顶栏图标统一吃「主题色」：图标是页面的强调元素，文字保持深色保证可读
      Row({ space: 16 }) {
        Image($r('app.media.ic_add'))
          .width(22)
          .height(22)
          .fillColor(this.uiThemeColor)
          .onClick(() => this.navToCourseEdit())
        // 下载 = 导入课表（Excel / ZIP / 官网），分享 = 导出课表为 zip 分享包
        Image($r('app.media.ic_download'))
          .width(22)
          .height(22)
          .fillColor(this.uiThemeColor)
          .onClick(() => this.openManageSheet('import'))
        Image($r('app.media.ic_share'))
          .width(22)
          .height(22)
          .fillColor(this.uiThemeColor)
          .onClick(() => this.openManageSheet('export'))
        Image($r('app.media.ic_more'))
          .width(22)
          .height(22)
          .fillColor(this.uiThemeColor)
          .onClick(() => this.openManageSheet('menu'))
      }
    }
    .width('100%')
    .height(56)
    .padding({ left: 16, right: 16 })
    .backgroundColor('#F3F4F6')
  }

  /**
   * 顶部星期条（周一~周日 + 日期）。
   *
   * 只收**恒定的槽位**，周次在函数内现取（`this.weekOfSlot(slot)`）：星期条长在轮播的
   * 每一页里，左右跟手拖动时要和下方课表**一起平移**，日期才不会"卡住不动"。
   * 高亮按"这一页是否包含今天"判定，于是滑到相邻周时不会把今天标在别的日期上。
   *
   * 走槽位而不是把周次当参数传进来，是因为 @Builder 的**按值参数不参与状态观察**：
   * 早先传 `week` 时，切周后这里的日期会一直停在首帧那一周。
   */
  @Builder
  weekHeader(slot: number) {
    Row() {
      // 左侧占位，与时间轴对齐：显示本周第一天的月份（吃「高亮色」，与"今天"同色系）
      Column() {
        Text(this.weekFirstMonthLabel(this.weekOfSlot(slot))).fontSize(14).fontColor(this.uiTodayColor);
      }
      .width(LAYOUT.timeColWidth)
      .justifyContent(FlexAlign.Center)

      // 周一 ~ 周日
      ForEach(this.weekDates(this.weekOfSlot(slot)), (date: Date, index: number) => {
        Column({ space: 2 }) {
          Text(`周${WEEKDAY_LABELS[index]}`)
            .fontSize(12)
            .fontColor(this.isTodayInSlot(slot, index) ? this.uiTodayColor : '#6B7280')
            .fontWeight(this.isTodayInSlot(slot, index) ? FontWeight.Bold : FontWeight.Normal)
          Text(`${date.getDate()}`)
            .fontSize(14)
            .fontColor(this.isTodayInSlot(slot, index) ? '#FFFFFF' : '#111827')
            .fontWeight(this.isTodayInSlot(slot, index) ? FontWeight.Bold : FontWeight.Medium)
            .backgroundColor(this.isTodayInSlot(slot, index) ? this.uiTodayColor : 'transparent')
            .borderRadius(12)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        }
        .layoutWeight(1)
        .onClick(() => {
          // 点击今天的日期 → 跳回本周课表；点其他日期无动作（那一列属于当前展示的周）
          if (this.isTodayInSlot(slot, index)) {
            this.goToTodayWeek();
          }
        })
      }, (date: Date, index: number) => `${this.weekOfSlot(slot)}-${date.getTime()}-${index}`)
    }
    .width('100%')
    .height(LAYOUT.weekHeaderHeight)
    .backgroundColor('#F3F4F6')
  }

  /** 该节次开始时间；无作息配置返回空串（UI 据此隐藏） */
  private slotStart(sessionNo: number): string {
    const slot: ScheduleSlot | undefined = this.slotAt(sessionNo);
    return slot === undefined ? '' : slot.start_time;
  }

  /** 该节次结束时间；无作息配置返回空串 */
  private slotEnd(sessionNo: number): string {
    const slot: ScheduleSlot | undefined = this.slotAt(sessionNo);
    return slot === undefined ? '' : slot.end_time;
  }

  @Builder
  timeAxis() {
    Column() {
      ForEach(this.sessionRange(), (sessionNo: number) => {
        Column({ space: 1 }) {
          Text(`${sessionNo}`)
            .fontSize(11)
            .fontColor('#9CA3AF')
            .height(14)
          if (this.slotStart(sessionNo).length > 0) {
            Text(this.slotStart(sessionNo))
              .fontSize(9)
              .fontColor('#9CA3AF')
              .height(12)
            Text(this.slotEnd(sessionNo))
              .fontSize(9)
              .fontColor('#9CA3AF')
              .height(12)
          }
        }
        .width(LAYOUT.timeColWidth)
        .height(LAYOUT.sessionHeight)
        .justifyContent(FlexAlign.Center)
        .border({ width: { bottom: 1 }, color: '#E5E7EB' })
        // key 带上模板签名：节次起止时间来自 this.templates，模板改完返回后必须重建时间轴
      }, (sessionNo: number) => `${sessionNo}-${this.templateSignature()}`)
    }
    .width(LAYOUT.timeColWidth)
  }

  @Builder
  courseCard(lesson: LessonRow) {
    Column({ space: 1 }) {
      Text(`${lesson.course_name}`)
        .fontSize(10)
        .fontWeight(FontWeight.Medium)
        .fontColor(textColorOf(lesson.color))
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ minHeight: 13 })
      Text(lesson.class_name.length > 0 ? lesson.class_name : '—')
        .fontSize(9)
        .fontColor(textColorOf(lesson.color))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (lesson.class_room.length > 0) {
        Text(`@${lesson.class_room}`)
          .fontSize(9)
          .fontColor(textColorOf(lesson.color))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      // 人数：只要有就显示，不再限制跨节数
      if (lesson.population > 0) {
        Text(`${lesson.population}人`)
          .fontSize(8)
          .fontColor(textColorOf(lesson.color))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('96%')
    .padding(3)
    .clip(true)
    .backgroundColor(lesson.color)
    .borderRadius(6)
    .position({
      y: (lesson.start_time - 1) * LAYOUT.sessionHeight,
      x: '2%'
    })
    .height((lesson.end_time - lesson.start_time + 1) * LAYOUT.sessionHeight - 2)
    .onClick(() => {
      this.openLessonSheet(lesson);
    })
  }

  /**
   * 一天的格子（背景格 + 课程块）。
   *
   * 只接收 `weekday` 与**恒定的槽位** `slot`，这一页那一周的课程在函数内部现读
   *（`this.lessonsOfSlot(slot)`）—— 所以背景格与课程块永远同源，不会出现
   *"日期是第 N+1 周、课程还是第 N 周"；也因为不走参数，数据一变就能刷新。
   */
  @Builder
  dayColumn(weekday: number, slot: number) {
    Stack() {
      // 背景格
      Column() {
        ForEach(this.sessionRange(), (sessionNo: number) => {
          Column()
            .width('100%')
            .height(LAYOUT.sessionHeight)
            .border({ width: { bottom: 1 }, color: '#E5E7EB' })
        }, (sessionNo: number) => `${sessionNo}`)
      }
      .width('100%')
      .height(this.sessionCount() * LAYOUT.sessionHeight)

      // 课程卡片
      // 数据源直接读状态（@Builder 体内不能声明局部变量）：早先这一列拿的是"按值传进来
      // 的课程数组"，依赖被切断 —— 数据换了、周次没变 → key 不变、子树沿用 → 这一列
      // 永远停在首帧那份**空数组**上（新增课程不显示、退出重进整片空白）。
      // key 必须覆盖全部展示字段：否则改课程名/教室/颜色后 key 不变，ArkUI 复用旧组件导致界面不更新
      ForEach(this.lessonsOfDay(weekday, this.lessonsOfSlot(slot)), (lesson: LessonRow) => {
        this.courseCard(lesson)
      }, (lesson: LessonRow) => `${lesson.time_period_id}-${lesson.week_no}-${lesson.course_name}`
        + `-${lesson.class_name}-${lesson.class_room}-${lesson.color}-${lesson.population}`
        + `-${lesson.start_time}-${lesson.end_time}`)
    }
    .layoutWeight(1)
    .height(this.sessionCount() * LAYOUT.sessionHeight)
  }

  /**
   * 轮播的一页：一整周的课表（星期条 + 可纵向滚动的网格）。
   *
   * `slot` 是这一页相对视口的槽位：-1 左（上一周）、0 中（当前周）、1 右（下一周）。
   * 横向位置 = 槽位 × 页宽 + 跟手位移 —— 两者都是 vp 数值，合成一个表达式，
   * 因此不需要百分比 translate（百分比是相对组件自身宽度的，动画目标值也取不到数）。
   */
  @Builder
  weekPage(slot: number) {
    Column({ space: 0 }) {
      this.weekHeader(slot)

      Scroll() {
        Column({ space: 0 }) {
          Row() {
            this.timeAxis()
            ForEach(this.weekdayRange(), (weekday: number) => {
              this.dayColumn(weekday, slot)
              // key 里必须带上这一页的课程签名：`this.lessonsOfSlot(slot)` 是**直接读状态**，
              // 它既是依赖登记点（数据一变这一页就重跑），又让 key 随内容变化（列子树必然重建）。
              // 只写 `${slot}-${weekday}` 的话，数据换了 key 不变 → ArkUI 复用旧列 → 一直空着。
            }, (weekday: number) => `${slot}-${weekday}`
              + `-${this.daySignature(weekday, this.lessonsOfSlot(slot))}`)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)

          // 底部让位：导航栏是 `barOverlap(true)` 的浮层，网格最后 56vp 会压在它底下。
          // 留出等高空白，最后一节课才能被滚到导航栏之上（也才点得开）；
          // 不滚到底时，课表仍然是"从全透明导航栏下穿过"的观感。
          Column().height(LAYOUT.tabBarHeight)
        }
        .width('100%')
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.TopStart)
    }
    .width('100%')
    .height('100%')
    .translate({ x: slot * this.pagerWidth + this.dragOffset })
  }

  /**
   * 课表区：三页横向轮播（上一周 / 当前周 / 下一周），**跟手预览 + 松手回弹**。
   *
   * - 拖动中：`dragOffset` 逐帧跟着手指，两侧页露出相邻周的真实课表（含星期条日期）。
   * - 松手：越过阈值就翻页，否则动画回弹 —— 也就是这次滑动被"撤销"（见 `settleDrag`）。
   * - 视觉上只有中间一页可见：`clip(true)` 把两侧页裁掉。
   */
  @Builder
  timetableGrid() {
    Stack() {
      // 三页只传**槽位**，不传周次与课程数组：按值传进 @Builder 的参数不参与状态观察，
      // 一旦把 `this.lessons` 这样传进去，整页在首帧之后就不再刷新（详见 weekOfSlot 注释）。
      //
      // 相邻页等量到页宽（`pagerWidth`）之后再渲染：宽度未知时三页会叠在同一处，
      // 反而把当前周盖住。中间页始终渲染，首帧就是正确内容。
      if (this.pagerWidth > 0) {
        this.weekPage(-1)
      }
      this.weekPage(0)
      if (this.pagerWidth > 0) {
        this.weekPage(1)
      }
    }
    .width('100%')
    .layoutWeight(1)
    .clip(true)
    // 量出视口宽度：页宽与翻页动画的位移都靠它（animateTo 的目标必须是具体 vp 数值）
    .onAreaChange((oldValue: Area, newValue: Area) => {
      // 宽度可能是 `'438.00'` 这样的字符串，统一归一到 vp 数值
      const width: number = vpOf(newValue.width);
      if (width > 0 && width !== this.pagerWidth) {
        this.pagerWidth = width;
      }
    })
    // 左右滑动切换周次（跟手预览 + 松手回弹撤销）。纵向滚动不受影响：手势只认水平方向。
    .gesture(
      PanGesture({ fingers: 1, direction: PanDirection.Horizontal })
        .onActionUpdate((event: GestureEvent) => {
          this.dragOffset = this.resistOffset(event.offsetX);
        })
        .onActionEnd((event: GestureEvent) => {
          this.settleDrag(event.offsetX);
        })
        .onActionCancel(() => {
          // 手势被系统打断（来电、侧滑返回等）：等同"没滑成"，回弹撤销
          this.settleDrag(0);
        })
    )
  }

  @Builder
  sectionTitle(title: string, hint: string) {
    Row() {
      Text(title).fontSize(15).fontWeight(FontWeight.Bold).fontColor('#111827');
      Blank();
      Text(hint).fontSize(11).fontColor('#9CA3AF');
    }
    .width('100%')
    .padding({ top: 6, bottom: 4 })
  }

  @Builder
  manageButton(label: string, icon: Resource, view: string) {
    Column({ space: 6 }) {
      Image(icon)
        .width(28)
        .height(28)
        .fillColor(this.uiThemeColor)
      Text(label)
        .fontSize(12)
        .fontColor('#374151')
    }
    .width('100%')
    .height(LAYOUT.manageItemHeight)
    .backgroundColor('#FFFFFF')
    .borderRadius(10)
    .justifyContent(FlexAlign.Center)
    .onClick(() => this.openManageSheet(view))
  }

  private weekdayRange(): number[] {
    return [1, 2, 3, 4, 5, 6, 7];
  }

  /**
   * 界面设置里的一行取色入口。
   *
   * 注意：颜色**不通过参数传入**，而是直接在属性表达式里读 @Local —— ArkUI 的
   * @Builder 按值传参不具备刷新能力，把颜色当参数传进来会导致「改完颜色这一行
   * 还显示旧色」。
   */
  @Builder
  uiColorRow(label: string, desc: string, target: string) {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text(label).fontSize(14).fontColor('#111827')
        Text(desc).fontSize(11).fontColor('#9CA3AF')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text(target === 'today' ? this.uiTodayColor : this.uiThemeColor)
        .fontSize(11)
        .fontColor('#9CA3AF')
      // 色块：同心圆双层描边，半透明色也能看清
      Column() {
        Column()
          .width(18)
          .height(18)
          .borderRadius(9)
          .border({ width: 2, color: '#FFFFFF' })
          .backgroundColor(target === 'today' ? this.uiTodayColor : this.uiThemeColor)
      }
      .width(26)
      .height(26)
      .borderRadius(13)
      .border({ width: 2, color: '#D1D5DB' })
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .onClick(() => this.openColorPicker(target))
  }

  /**
   * 「我的」面板：只保留机主信息与界面相关设置。
   *
   * 周次滑杆、学期切换、教师切换等"操作类"功能已整体挪到首页顶栏 ic_more
   * 弹开的管理面板（见 manageMenuView / manageTeacherView）。
   */
  @Builder
  myPanel() {
    Scroll() {
      Column({ space: 14 }) {
        // 机主信息
        this.sectionTitle('机主信息', '默认教师')
        Column({ space: 8 }) {
          Row() {
            Text('姓名').fontSize(13).fontColor('#6B7280');
            Blank();
            Text(this.ownerName.length > 0 ? this.ownerName : '未设置').fontSize(13).fontColor('#111827');
          }
          .width('100%')
          Row() {
            Text('教师工号').fontSize(13).fontColor('#6B7280');
            Blank();
            Text(this.ownerStaffNo > 0 ? `${this.ownerStaffNo}` : '未设置').fontSize(13).fontColor('#111827');
          }
          .width('100%')
          Button('修改默认教师')
            .fontSize(13)
            .width('100%')
            .height(38)
            .backgroundColor(this.uiThemeColor)
            .onClick(() => {
              this.inputName = this.ownerName;
              this.inputStaffNo = this.ownerStaffNo > 0 ? `${this.ownerStaffNo}` : '';
              this.showOwnerSetup = true;
            })
        }
        .width('100%')
        .padding(14)
        .backgroundColor('#FFFFFF')
        .borderRadius(10)

        // 界面设置：主题色 / 高亮色（均可用拾色器调，拖动时实时预览）
        this.sectionTitle('界面设置', '点击任意一行调整颜色')
        Column({ space: 4 }) {
          this.uiColorRow('主题色', '顶栏图标、按钮、滑杆、导航高亮等强调色', 'theme')
          Divider().color('#F3F4F6')
          this.uiColorRow('高亮色', '首页月份与周次栏里"今天"的高亮色', 'today')
          Divider().color('#F3F4F6')
          Button('恢复默认颜色')
            .fontSize(13)
            .width('100%')
            .height(38)
            .backgroundColor('#F3F4F6')
            .fontColor('#374151')
            .onClick(() => this.resetUiColors())
        }
        .width('100%')
        .padding(14)
        .backgroundColor('#FFFFFF')
        .borderRadius(10)

        // 上课提醒：两个开关 + 一个提前量输入框（默认 20 分钟）。
        // 真正的提醒由系统"后台代理提醒"在应用不运行时弹出，这里只负责设置与文案。
        this.sectionTitle('上课提醒', '到点由系统通知提醒，应用不在运行也能收到')
        Column({ space: 12 }) {
          Row({ space: 12 }) {
            Column({ space: 2 }) {
              Text('提醒第二天的课').fontSize(14).fontColor('#111827');
              Text('第二天有课时，当天 22:00 提醒一次').fontSize(11).fontColor('#9CA3AF');
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Toggle({ type: ToggleType.Switch, isOn: this.notifyNextDay })
              .selectedColor(this.uiThemeColor)
              .onChange((isOn: boolean) => {
                this.onNotifyNextDayChange(isOn);
              })
          }
          .width('100%')

          Divider().color('#F3F4F6')

          Row({ space: 12 }) {
            Column({ space: 2 }) {
              Text('是否提前提醒').fontSize(14).fontColor('#111827');
              Text('当天有课时，在上课前提前提醒').fontSize(11).fontColor('#9CA3AF');
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Toggle({ type: ToggleType.Switch, isOn: this.notifyAhead })
              .selectedColor(this.uiThemeColor)
              .onChange((isOn: boolean) => {
                this.onNotifyAheadChange(isOn);
              })
          }
          .width('100%')

          // 提前量只在开关打开时才出现：关着的时候摆个输入框，用户会以为"填了就生效"
          if (this.notifyAhead) {
            Row({ space: 8 }) {
              Text('提前').fontSize(13).fontColor('#6B7280')
              TextInput({ text: this.notifyAheadText })
                .type(InputType.Number)
                .width(72)
                .height(34)
                .fontSize(13)
                .textAlign(TextAlign.Center)
                .backgroundColor('#F3F4F6')
                .onChange((value: string) => {
                  this.notifyAheadText = value;
                })
                .onSubmit(() => {
                  this.commitAheadMinutes();
                })
                .onBlur(() => {
                  this.commitAheadMinutes();
                })
              Text('分钟').fontSize(13).fontColor('#6B7280')
              Blank()
            }
            .width('100%')
          }

          Text(`若某节课开始前 ${this.notifyAheadMinutes} 分钟内还有另一节课没下课，这节课不会提醒 —— `
            + `提醒时刻正落在别人的课堂上，弹出来没有意义`)
            .fontSize(11)
            .fontColor('#9CA3AF')
            .width('100%')
        }
        .width('100%')
        .padding(14)
        .backgroundColor('#FFFFFF')
        .borderRadius(10)

        Text('更多功能（时间表、教师、学期、课表管理等）已移到首页右上角「⋯」')
          .fontSize(11)
          .fontColor('#9CA3AF')
          .width('100%')
          .textAlign(TextAlign.Center)

        // 底部让位：导航栏是 barOverlap 浮层，按导航栏等高留白，
        // 面板最后一项才能滚到它之上（不足一屏时相当于底部留白）
        Column().height(LAYOUT.tabBarHeight)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    // Scroll 内容不满一屏时默认会被垂直居中（CommonMethod.align 默认 Center），
    // 显式 TopStart 才能让页面信息一律贴着顶部排
    .align(Alignment.TopStart)
  }

  @Builder
  tabContent() {
    Tabs({ barPosition: BarPosition.End, controller: this.tabsController }) {
      TabContent() {
        // 一个组件只能挂**一个** bindSheet：同一节点上第二次 .bindSheet() 会直接覆盖前一次
        // （SDK 里 bindSheet 是 CommonMethod 的普通属性，没有多 sheet 重载）。
        // 所以「课程详情」与「管理面板」必须挂在两个不同节点上 —— 早先两个都写在一个 Column 上，
        // 管理面板把课程详情的绑定顶掉了，点课程块自然不出 sheet。
        Column({ space: 0 }) {
          // 内层节点：挂课程详情 sheet
          Column({ space: 0 }) {
            this.topBar()
            if (!this.ready) {
              this.loadingPlaceholder()
            }
            if (this.loadError.length > 0) {
              this.loadErrorBar()
            }
            // 空课表自证：本周没课时，把库里到底有什么摊在屏幕上（有课时不渲染）
            if (this.loadError.length === 0 && this.diagLines.length > 0) {
              this.emptyDiagCard()
            }
            // 注意：这里**不再单独放星期条** —— 星期条已经长在轮播的每一页里
            //（见 `weekPage`），这样左右跟手拖动时日期能和课表一起平移。
            this.timetableGrid()
          }
          .width('100%')
          .height('100%')
          .bindSheet($$this.showLessonSheet, this.lessonSheetBuilder(), {
            height: SheetSize.FIT_CONTENT,
            dragBar: true,
            onDisappear: () => {
              this.closeLessonSheet();
            }
          })
        }
        .width('100%')
        .height('100%')
        .backgroundColor(PAGE_BG_COLOR)
        // 外层节点：挂管理面板 sheet
        // height 用 FIT_CONTENT（不是 MEDIUM）：面板高度跟着内容走，
        // 短内容（如「关于」）不再在底部留一大片空白；长内容由 MANAGE_SHEET.bodyMaxHeight 封顶后内部滚动。
        .bindSheet($$this.showManageSheet, this.manageSheetBuilder(), {
          height: SheetSize.FIT_CONTENT,
          dragBar: true,
          showClose: false,
          onDisappear: () => {
            this.showManageSheet = false;
            this.manageView = 'menu';
          }
        })
      }
      .tabBar(this.tabBarBuilder('首页', $r('app.media.ic_home'), 0))

      TabContent() {
        // 待办面板：独立组件（pages/Todo.ets），主题色随「我的」拾色器联动
        TodoPanel({ uiThemeColor: this.uiThemeColor, refreshTick: this.todoRefreshTick })
          .width('100%')
          .height('100%')
      }
      .tabBar(this.tabBarBuilder('待办', $r('app.media.ic_toDo'), 1))

      TabContent() {
        Column({ space: 0 }) {
          Row() {
            Text('我的').fontSize(18).fontWeight(FontWeight.Bold).fontColor('#111827')
          }
          .width('100%')
          .height(56)
          .padding({ left: 16, right: 16 })
          .backgroundColor(PAGE_BG_COLOR)

          this.myPanel()
        }
        .width('100%')
        .height('100%')
        .backgroundColor(PAGE_BG_COLOR)
      }
      .tabBar(this.tabBarBuilder('我的', $r('app.media.ic_mine'), 2))
    }
    .vertical(false)
    .barHeight(LAYOUT.tabBarHeight)
    .barMode(BarMode.Fixed)
    // **完全透明**的导航栏：只留下两枚图标 + 两行文字浮在内容之上，
    // 底下那一层（课表网格 / 「我的」面板）的文字原样可见、不被糊掉。
    // 三件事必须同时成立，缺一个就透不出来：
    //  1. `barOverlap(true)` —— 让 TabContent 铺到导航栏**之下**。不设的话内容区会被
    //     导航栏高度顶开，底下什么都没有，"透过"也就无从谈起（SDK 默认 false）。
    //  2. `barBackgroundColor(Color.Transparent)` —— 显式声明全透明底色。SDK 默认值
    //     本来就是 `Color.Transparent`，写出来是为了钉住语义：以后任何人想加底色都会
    //     看到"这是一条有意的透明"（一旦设成不透明色就变成实心条，透不出来了）。
    //  3. `barBackgroundBlurStyle(BlurStyle.NONE)` —— 关掉毛玻璃。SDK 默认值也是
    //     `BlurStyle.NONE`，但上一版这里用的是 `BlurStyle.Regular`，毛玻璃会把底下的
    //     课表糊成一块色斑、文字读不出来；改回 NONE 才是"完全透明"。
    .barOverlap(true)
    .barBackgroundColor(Color.Transparent)
    .barBackgroundBlurStyle(BlurStyle.NONE)
    .onChange((index: number) => {
      this.activeTabIndex = index;
    })
  }

  /**
   * 底部导航的一格：图标 + 文字标签。
   *
   * 图标用 SVG 图源 + `fillColor` 上色（`fillColor` 会覆盖 svg 里写死的 fill），
   * 所以选中/未选中不需要两套图，跟文字用同一个颜色表达式即可。
   * 选中态直接读 `this.activeTabIndex` —— 不把它当参数传进来，避免 @Builder
   * 按值传参不刷新的问题。
   *
   * **格子本身不给底色、也不画分隔线**：导航栏是 `barOverlap(true)` 之上的全透明浮层，
   * 只输出图标与文字两类像素，其余部分一律让底下那层透上来。
   * 这里要是写上 `backgroundColor('#FFFFFF')`，格子就变成实心的，"透过导航栏看课表"立刻失效；
   * 同理，之前那条 1px 半透明黑分隔线也会横切过底层的文字，已随"完全透明"一并去掉
   * （如果之后又想要边界感，加法是 `.border({ width: { top: 1 }, color: '#1A000000' })`）。
   */
  @Builder
  tabBarBuilder(title: string, icon: Resource, index: number) {
    Column({ space: 2 }) {
      Image(icon)
        .width(22)
        .height(22)
        .objectFit(ImageFit.Contain)
        .fillColor(this.activeTabIndex === index ? this.uiThemeColor : '#6B7280')
        .accessibilityText(title)
      Text(title)
        .fontSize(11)
        .fontColor(this.activeTabIndex === index ? this.uiThemeColor : '#6B7280')
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  // ---------------------------------------------------------------- 课程详情 sheet

  @Builder
  sheetInfoRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor('#6B7280')
        .width(72)
      Text(value)
        .fontSize(13)
        .fontColor('#111827')
        .layoutWeight(1)
    }
    .width('100%')
  }

  /** 二级菜单选项行：action 见 runSheetAction 的分发 */
  @Builder
  sheetMenuOption(label: string, desc: string, color: string, action: string) {
    Row({ space: 10 }) {
      Column({ space: 2 }) {
        Text(label)
          .fontSize(15)
          .fontColor(color)
        if (desc.length > 0) {
          Text(desc)
            .fontSize(11)
            .fontColor('#9CA3AF')
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Text('›')
        .fontSize(18)
        .fontColor('#9CA3AF')
    }
    .width('100%')
    .padding({ top: 12, bottom: 12, left: 14, right: 14 })
    .backgroundColor('#F9FAFB')
    .borderRadius(10)
    .onClick(() => this.runSheetAction(action))
  }

  /**
   * 「随机指定人数点名」这一项：**标题右侧内嵌人数步进器**。
   *
   * 不用通用的 `sheetMenuOption`：人数原本独自占一行（左边标签 + 右边加减），
   * 两行说的是同一件事，"上面这一行到底在调什么"还得先看下面才知道。
   * 合成一行之后，"随机指定人数点名  − 10 +" 自己就说清了。
   *
   * 步进器嵌在可点卡片里**不会误触**：ArkUI 的点击由最内层命中的节点消费，
   * 点 ± 只调人数、点标题才进点名页。人数用 ± 而不是输入框，理由见 `sheetRandomCount`。
   */
  @Builder
  sheetCheckinRandomOption() {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text('随机指定人数点名')
          .fontSize(15)
          .fontColor(this.uiThemeColor)
          .layoutWeight(1)

        // 步进器：白底小控件，压在灰色卡片上才看得出"这是个能按的东西"
        Row() {
          Text('−')
            .fontSize(20)
            .fontColor(this.sheetRandomCount <= MIN_RANDOM_COUNT ? '#D1D5DB' : '#374151')
            .width(34)
            .height(30)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.sheetRandomCount = clamp(this.sheetRandomCount - 1, MIN_RANDOM_COUNT, this.randomCountCeiling());
            })
          Text(`${this.sheetRandomCount}`)
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#111827')
            .width(40)
            .textAlign(TextAlign.Center)
          Text('+')
            .fontSize(20)
            .fontColor(this.sheetRandomCount >= this.randomCountCeiling() ? '#D1D5DB' : '#374151')
            .width(34)
            .height(30)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.sheetRandomCount = clamp(this.sheetRandomCount + 1, MIN_RANDOM_COUNT, this.randomCountCeiling());
            })
        }
        .backgroundColor('#FFFFFF')
        .borderRadius(8)
        .border({ width: 0.5, color: '#E5E7EB' })
      }
      .width('100%')

      Text(this.checkinRandomHint())
        .fontSize(11)
        .fontColor('#9CA3AF')
        .width('100%')
    }
    .width('100%')
    .padding({ top: 12, bottom: 12, left: 14, right: 14 })
    .backgroundColor('#F9FAFB')
    .borderRadius(10)
    .onClick(() => this.runSheetAction('checkinRandom'))
  }

  /**
   * 「随机指定人数点名」下面那行提示。
   *
   * 人数**必须出现在这里**：标题右侧被步进器占走了，而"这一次要点几个人"是
   * 按下按钮前最需要确认的一件事。提示读的就是 `sheetRandomCount`，
   * 所以加减人数时这句话跟着变（不必再往别处同步一次）。
   */
  private checkinRandomHint(): string {
    return `从本班名单里随机指定 ${this.sheetRandomCount} 人 —— 点到谁就点谁，出勤与否仍由你逐个滑出来`;
  }

  private runSheetAction(action: string): void {
    if (this.sheetBusy) {
      return;
    }
    if (action === 'checkinRandom') {
      this.navToCheckIn('random');
    } else if (action === 'checkinAll') {
      this.navToCheckIn('all');
    } else if (action === 'checkinView') {
      this.openCheckinView();
    } else if (action === 'editGroup') {
      this.navToLessonEdit('editGroup');
    } else if (action === 'editCourse') {
      this.navToLessonEdit('editCourse');
    } else if (action === 'deleteWeek') {
      this.deleteThisWeekOnce();
    } else if (action === 'deleteGroup') {
      this.deleteThisClass();
    } else if (action === 'deleteCourse') {
      this.deleteThisCourse();
    } else if (action === 'back') {
      // 「查看本节课程情况」是**签到面板的下一层**：从它返回应该退回签到面板，
      // 而不是一步跳回课程详情 —— 老师多半是"看完了想接着点名"，
      // 直接跳回详情就得把「签到」再点一遍，白走一趟。
      this.sheetAction = this.sheetAction === 'checkinView' ? 'checkin' : 'none';
    }
  }

  @Builder
  lessonSheetBuilder() {
    Column({ space: 0 }) {
      // 标题：色块 + 课程名 + 班级
      Row({ space: 10 }) {
        Column()
          .width(16)
          .height(16)
          .borderRadius(8)
          .backgroundColor(this.sheetLesson.color)
        Column({ space: 2 }) {
          Text(this.sheetLesson.course_name)
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor('#111827')
          Text(`${this.sheetLesson.class_name} · ${this.sheetLesson.population}人`)
            .fontSize(12)
            .fontColor('#6B7280')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .padding({ top: 18, bottom: 10 })

      // 详情
      Column({ space: 8 }) {
        this.sheetInfoRow('课程类型', this.sheetLesson.course_type)
        this.sheetInfoRow('学分', this.sheetScoreText())
        this.sheetInfoRow('任课教师', this.sheetLesson.teacher_name)
        this.sheetInfoRow('上课时间', this.sheetSessionText())
        this.sheetInfoRow('上课周次', this.sheetWeeksText())
        this.sheetInfoRow('教室',
          this.sheetLesson.class_room.length > 0 ? this.sheetLesson.class_room : '未设置')
        if (this.sheetLesson.course_remark.length > 0) {
          this.sheetInfoRow('课程备注', this.sheetLesson.course_remark)
        }
        if (this.sheetLesson.remark.length > 0) {
          this.sheetInfoRow('时段备注', this.sheetLesson.remark)
        }
      }
      .width('100%')
      .padding(14)
      .backgroundColor('#F9FAFB')
      .borderRadius(12)

      // 操作区（二级菜单）
      if (this.sheetAction === 'none') {
        // 三键一行：**删除在左、签到居中、编辑在右**。
        // 用户要求"编辑与删除互换位置、中间插入签到" —— 顺手把破坏性动作推到最左、
        // 与右侧的"‹ 返回"拉开距离：拇指最常落在右侧，误触删除的代价最大。
        Row({ space: 10 }) {
          Button('删除')
            .fontSize(15)
            .layoutWeight(1)
            .height(44)
            .backgroundColor('#EF4444')
            .enabled(!this.sheetBusy)
            .onClick(() => {
              this.sheetAction = 'delete';
            })
          Button('签到')
            .fontSize(15)
            .layoutWeight(1)
            .height(44)
            .backgroundColor('#16A34A')
            .enabled(!this.sheetBusy)
            .onClick(() => {
              this.sheetAction = 'checkin';
            })
          Button('编辑')
            .fontSize(15)
            .layoutWeight(1)
            .height(44)
            .backgroundColor(this.uiThemeColor)
            .enabled(!this.sheetBusy)
            .onClick(() => {
              this.sheetAction = 'edit';
            })
        }
        .width('100%')
        .padding({ top: 14 })
      }

      if (this.sheetAction === 'checkin') {
        Column({ space: 8 }) {
          // 人数不在单独的标签行里，就在这一项的标题右侧（见 `sheetCheckinRandomOption`）
          this.sheetCheckinRandomOption()
          this.sheetMenuOption('全部点名',
            `点名「${this.sheetLesson.class_name}」的全部名单学生`, this.uiThemeColor, 'checkinAll')
          this.sheetMenuOption('查看本节课程情况',
            `只读展开第${this.sheetLesson.week_no}周这一次课的点名结果，不改动任何数据`,
            '#6B7280', 'checkinView')
          this.sheetMenuOption('返回', '', '#6B7280', 'back')
        }
        .width('100%')
        .padding({ top: 14 })
      }

      if (this.sheetAction === 'checkinView') {
        this.checkinViewPanel()
      }

      if (this.sheetAction === 'edit') {
        Column({ space: 8 }) {
          this.sheetMenuOption('编辑此班级', '只编辑该班级分组：班名、人数、颜色、时间段', this.uiThemeColor, 'editGroup')
          this.sheetMenuOption('编辑此课程', '编辑课程信息与该课程的全部班级分组', this.uiThemeColor, 'editCourse')
          this.sheetMenuOption('返回', '', '#6B7280', 'back')
        }
        .width('100%')
        .padding({ top: 14 })
      }

      if (this.sheetAction === 'delete') {
        Column({ space: 8 }) {
          this.sheetMenuOption(`删除本班级本周的课`,
            `仅移除第${this.sheetLesson.week_no}周的这一次课`, '#D97706', 'deleteWeek')
          this.sheetMenuOption('删除本班级的课',
            '删除该班级分组的全部时间段与周次', '#DC2626', 'deleteGroup')
          this.sheetMenuOption('删除本门课程',
            `删除「${this.sheetLesson.course_name}」及其全部班级安排（不可恢复）`, '#DC2626', 'deleteCourse')
          this.sheetMenuOption('返回', '', '#6B7280', 'back')
        }
        .width('100%')
        .padding({ top: 14 })
      }

      Column().height(24)
    }
    .width('100%')
    .padding({ left: 20, right: 20 })
    .backgroundColor('#FFFFFF')
  }

  // ---------------------------------------------------------------- 管理 sheet 视图

  /** 当前学期的“教师 + 课程数”行（供教师管理列表） */
  private teacherCourseRows(): TeacherCourses[] {
    return this.semesterCourses === null ? [] : this.semesterCourses.teacher_courses;
  }

  /**
   * 学生管理：当前名册的学生列表（按学号升序）。
   *
   * 排序放在 UI 层而不是只靠 SQL：学号是字符串，`ORDER BY student_no` 会把
   * "10" 排在 "2" 前面；`compareNo` 按自然序（数字段按数值）比，才是人眼期待的升序。
   * 返回副本，不就地改 `roster.students`（它是 @Trace 状态，就地排序会打乱 ForEach 的 key 对应关系）。
   */
  private rosterStudents(): Student[] {
    if (this.roster === null) {
      return [];
    }
    const list: Student[] = this.roster.students.slice();
    list.sort((a: Student, b: Student) => compareNo(a.student_no, b.student_no));
    return list;
  }

  /** 学生管理：当前名册的班级名 */
  private rosterClassName(): string {
    return this.roster === null ? '' : this.roster.class_name;
  }

  /** 班级管理：当前名册人数 */
  private rosterCount(): number {
    return this.roster === null ? 0 : this.roster.count();
  }

  /** 班级管理：名册里按主键找一个学生（学生详情/删除都从它取值） */
  private rosterStudent(id: number): Student | undefined {
    if (this.roster === null) {
      return undefined;
    }
    const list: Student[] = this.roster.students;
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === id) {
        return list[i];
      }
    }
    return undefined;
  }

  /** 名册列表高度：按人数算并封顶 —— 短名单贴着内容，长名单在列表内部滚动 */
  private rosterListHeight(): number {
    const count: number = this.rosterCount();
    const raw: number = count * ROSTER_ROW_HEIGHT + Math.max(0, count - 1) * 8;
    return clamp(raw, ROSTER_ROW_HEIGHT, ROSTER_LIST_MAX_HEIGHT);
  }

  /** 管理 sheet 头部的返回逻辑：逐层退回（学生详情 → 名册 → 班级列表 → 菜单） */
  private manageBack(): void {
    // 导入说明是从「导入课表」点进来的，所以退回去也是回导入面板，而不是直接回菜单
    if (this.manageView === 'help') {
      this.manageView = 'import';
      return;
    }
    if (this.manageView === 'studentDetail') {
      this.studentEditId = 0;
      this.manageView = 'student';
      return;
    }
    if (this.manageView === 'student' && this.rosterClassId.length > 0) {
      this.rosterClassId = '';
      this.roster = null;
      this.exitRosterSelect();
      return;
    }
    if (this.manageView === 'semester') {
      if (this.semesterEditId > 0) {
        this.semesterEditId = 0;
        return;
      }
      if (this.semesterPageMode === 'create') {
        this.semesterPageMode = 'list';
        return;
      }
      if (this.semesterSelectMode) {
        this.exitSemesterSelect();
        return;
      }
    }
    if (this.manageView === 'teacher') {
      if (this.teacherFormId !== 0) {
        this.closeTeacherForm();
        return;
      }
      if (this.teacherSelectMode) {
        this.exitTeacherSelect();
        return;
      }
    }
    if (this.manageView === 'time') {
      if (this.tplSelectMode) {
        this.exitTplSelect();
        return;
      }
    }
    this.manageView = 'menu';
  }

  @Builder
  manageSheetBuilder() {
    Column({ space: 12 }) {
      // 头部：返回 / 标题 / 关闭（三者同一行同一高度）
      Row() {
        if (this.manageView !== 'menu') {
          Image($r('app.media.ic_return'))
            .width(22)
            .height(22)
            .onClick(() => this.manageBack())
        }
        Text(this.manageTitle())
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#111827')
          .layoutWeight(1)
          .textAlign(TextAlign.Start)
        Image($r('app.media.ic_exit'))
          .width(22)
          .height(22)
          .onClick(() => this.closeManageSheet())
      }
      .width('100%')
      .height(MANAGE_SHEET.headerHeight)
      .alignItems(VerticalAlign.Center)

      // 主体：**只有一个** Scroll 兜住全部子视图 —— 面板高度随内容走（SheetSize.FIT_CONTENT），
      // 只有内容超过 MANAGE_SHEET.bodyMaxHeight 时才在这里内部滚动。
      // 因此子视图里**不能再有** `layoutWeight(1)` / `height('100%')` 这类「靠父高确定」的写法：
      // 面板自适应高度后父高是不确定的，它们会塌成 0，整片内容消失。
      Scroll() {
        Column({ space: 12 }) {
          if (this.manageView === 'menu') {
            this.manageMenuView()
          }
          if (this.manageView === 'time') {
            this.manageTimeView()
          }
          if (this.manageView === 'teacher') {
            this.manageTeacherView()
          }
          if (this.manageView === 'student') {
            this.manageStudentView()
          }
          if (this.manageView === 'studentDetail') {
            this.studentDetailView()
          }
          if (this.manageView === 'course') {
            this.manageCourseView()
          }
          if (this.manageView === 'semester') {
            this.manageSemesterView()
          }
          if (this.manageView === 'checkin') {
            this.manageCheckinView()
          }
          if (this.manageView === 'setting') {
            this.manageSettingView()
          }
          if (this.manageView === 'about') {
            this.manageAboutView()
          }
          if (this.manageView === 'export') {
            this.manageExportView()
          }
          if (this.manageView === 'import') {
            this.manageImportView()
          }
          if (this.manageView === 'help') {
            this.manageHelpView()
          }

          // 末尾只留一点呼吸位：面板贴到内容底部，不做大留白
          Column().height(MANAGE_SHEET.bottomGap)
        }
        .width('100%')
      }
      .width('100%')
      .constraintSize({ maxHeight: MANAGE_SHEET.bodyMaxHeight })
      .scrollBar(BarState.Off)
      // Scroll 默认会把不满一屏的内容垂直居中，TopStart 才能让内容贴着头部排
      .align(Alignment.TopStart)
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 8 })
    .backgroundColor('#FFFFFF')
  }

  /**
   * 管理菜单（首页 ⋯ 打开后的第一屏）：
   *   顶部 —— 周次滑杆
   *   中部 —— 学期横向滚动条（点即切换），最右侧「+」新建学期（默认名称「默认学期」）
   *   底部 —— 各管理入口
   */
  @Builder
  manageMenuView() {
    // 滚动已上提到 manageSheetBuilder 的统一 Scroll，这里只负责内容（自然高度，不撑满）
    Column({ space: 12 }) {
      // 周次滑杆
      Column({ space: 4 }) {
        Row() {
          Text('周次')
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor('#111827')
          Blank()
          Text(`第 ${this.currentWeek} / ${this.weekTotal()} 周`)
            .fontSize(12)
            .fontColor('#6B7280')
        }
        .width('100%')

        Slider({ value: this.weekSlider, min: 1, max: this.weekTotal(), step: 1 })
          .width('100%')
          .selectedColor(this.uiThemeColor)
          .trackColor('#E5E7EB')
          .onChange((value: number, mode: SliderChangeMode) => this.onWeekSlider(value, mode))
      }
      .width('100%')
      .padding(12)
      .backgroundColor('#F9FAFB')
      .borderRadius(10)

      // 学期：横向滚动，最右侧是新增按钮（周次滑杆旁不再放「+」）
      Scroll() {
        Row({ space: 8 }) {
          ForEach(this.semesters, (sem: Semester) => {
            Column({ space: 2 }) {
              Text(sem.name)
                .fontSize(14)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .fontColor(this.currentSemester()?.id === sem.id ? this.uiThemeColor : '#111827')
                .fontWeight(this.currentSemester()?.id === sem.id ? FontWeight.Bold : FontWeight.Normal)
              Text(`${sem.total_weeks}周`)
                .fontSize(11)
                .fontColor('#9CA3AF')
            }
            .alignItems(HorizontalAlign.Start)
            .width(110)
            .height(52)
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .justifyContent(FlexAlign.Center)
            .backgroundColor(this.currentSemester()?.id === sem.id ? '#EFF6FF' : '#F9FAFB')
            .borderRadius(8)
            .onClick(() => this.switchSemester(sem.id))
          }, (sem: Semester) =>
            `${sem.id}-${sem.name}-${sem.total_weeks}-${this.currentSemester()?.id === sem.id}`)

          // 新增学期（默认名「默认学期」）
          Row() {
            Image($r('app.media.ic_add'))
              .width(22)
              .height(22)
              .objectFit(ImageFit.Contain)
              .fillColor(this.uiThemeColor)
          }
          .width(52)
          .height(52)
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
          .backgroundColor('#EFF6FF')
          .borderRadius(8)
          .onClick(() => this.createQuickSemester())
        }
        .padding({ left: 2, right: 2 })
      }
      .width('100%')
      // 高度与卡片等高（52），配合 TopStart 让学期卡片在滚动条里顶部对齐
      .height(52)
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .align(Alignment.TopStart)

      // 管理入口
      Grid() {
        GridItem() { this.manageButton('时间管理', $r('app.media.ic_time'), 'time') }
        GridItem() { this.manageButton('教师管理', $r('app.media.ic_teacher'), 'teacher') }
        GridItem() { this.manageButton('班级管理', $r('app.media.ic_student'), 'student') }
        GridItem() { this.manageButton('课表管理', $r('app.media.ic_course'), 'course') }
        GridItem() { this.manageButton('学期管理', $r('app.media.ic_semester'), 'semester') }
        GridItem() { this.manageButton('签到信息', $r('app.media.ic_checkin'), 'checkin') }
        GridItem() { this.manageButton('全局设置', $r('app.media.ic_setting'), 'setting') }
        GridItem() { this.manageButton('关于', $r('app.media.ic_info'), 'about') }
      }
      .columnsTemplate('1fr 1fr 1fr 1fr')
      .columnsGap(10)
      .rowsGap(10)
      .width('100%')
    }
    .width('100%')
  }

  /**
   * 时间管理：列出全部时间表（作息模板）。全部时间表用 `List` 承载（`ListItem` 才有左滑操作），名册 / 学期同款样式。
   *
   * 普通态：点名称列 = 应用到当前学期，右侧只有「查看」（进全屏编辑页，即编辑入口）；
   * 左滑露「复制 / 删除」（内置模板滑出只有「复制」，无删除）；
   * 长按进入多选（底部左「全选」/ 右「删除(N)」）；普通态底部居中「新建时间表」。
   *
   * 面板是 FIT_CONTENT：List 高度按条数算并封顶（与名册同一策略），普通态与多选态的
   * 底部操作条**等高**（44）—— 面板内容高度一变，内部点击会命中旧布局
   * （docs/04 §12.3.2 第 17 点，名册页同款教训）。
   */
  @Builder
  manageTimeView() {
    Column({ space: 10 }) {
      // 单行提示，两种模式下高度一致（FIT_CONTENT 面板高度不能随模式切换变化）
      Text(this.tplSelectMode ? '点击勾选/取消，用「全选」一次勾完或全取消' : '点时间表应用到当前学期；左滑可复制/删除，长按可批量选择')
        .fontSize(11)
        .fontColor('#9CA3AF')
        .width('100%')

      if (this.templates.length === 0) {
        Text('还没有时间表：点下方「新建时间表」创建')
          .fontSize(12)
          .fontColor('#9CA3AF')
          .width('100%')
          .padding({ top: 12, bottom: 12 })
      } else {
        List({ space: 8 }) {
          ForEach(this.templates, (tpl: ScheduleTemplate) => {
            if (tpl.is_builtin) {
              // 内置模板不可删除：滑出只有「复制 / 编辑」，无「删除」
              ListItem() {
                this.tplRowBody(tpl)
              }
              .swipeAction({ end: this.tplSwipeActions(tpl.id, true) })
            } else {
              ListItem() {
                this.tplRowBody(tpl)
              }
              .swipeAction({ end: this.tplSwipeActions(tpl.id, false) })
            }
          }, (tpl: ScheduleTemplate) =>
            `${tpl.id}-${tpl.name}-${tpl.class_sessions}-${tpl.duration_time}-${tpl.citation_count}`
            + `-${tpl.is_builtin}-${this.isTemplateInUse(tpl.id)}`
            + `-${this.tplSelectMode}-${this.tplSelectedIds.indexOf(tpl.id) >= 0}`)
        }
        .width('100%')
        .height(this.tplListHeight())
        .scrollBar(BarState.Off)
      }

      // 底部操作区（名册 rosterSelectBar 同款两排式）。
      // 两条形态**等高**，模式切换时面板总高度不变。
      // 多选 = 名册同款两排：上排「取消 / 已选 N 个 / 全选」、下排整宽「删除选中时间表」；
      // 普通 = 上排「共 N 张时间表」信息行 + 下排居中「新建时间表」（结构与字号同上排，等高）。
      if (this.tplSelectMode) {
        Column({ space: 10 }) {
          Row({ space: 8 }) {
            Text('取消')
              .fontSize(14)
              .fontColor('#6B7280')
              .padding({ left: 4, right: 4, top: 6, bottom: 6 })
              .onClick(() => this.exitTplSelect())
            Text(`已选 ${this.tplSelectedIds.length} 个`)
              .fontSize(14)
              .fontColor('#111827')
              .layoutWeight(1)
              .textAlign(TextAlign.Center)
            Text(this.tplSelectedIds.length >= this.templates.length ? '取消全选' : '全选')
              .fontSize(14)
              .fontColor(this.uiThemeColor)
              .padding({ left: 4, right: 4, top: 6, bottom: 6 })
              .onClick(() => this.toggleTplSelectAll())
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 11, bottom: 11 })
          .backgroundColor('#F9FAFB')
          .borderRadius(10)

          Button(this.manageBusy ? '删除中…' : '删除选中时间表')
            .fontSize(14)
            .height(44)
            .width('100%')
            .backgroundColor('#EF4444')
            .fontColor('#FFFFFF')
            .enabled(this.tplSelectedIds.length > 0 && !this.manageBusy)
            .onClick(() => this.confirmDeleteSelectedTemplates())
        }
        .width('100%')
      } else {
        Column({ space: 10 }) {
          Row({ space: 8 }) {
            Text(`共 ${this.templates.length} 张时间表`)
              .fontSize(14)
              .fontColor('#6B7280')
              .padding({ left: 4, right: 4, top: 6, bottom: 6 })
            Blank()
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 11, bottom: 11 })
          .backgroundColor('#F9FAFB')
          .borderRadius(10)

          Row() {
            Blank().layoutWeight(1)
            Button(this.manageBusy ? '处理中…' : '新建时间表')
              .fontSize(14)
              .height(44)
              .width(160)
              .backgroundColor('#16A34A')
              .enabled(!this.manageBusy)
              .onClick(() => this.newTemplate())
            Blank().layoutWeight(1)
          }
          .width('100%')
        }
        .width('100%')
      }
    }
    .width('100%')
  }

  /** 时间管理行内容（内置 / 自定义共用一份行体；多选态整行点按 = 切换选中） */
  @Builder
  tplRowBody(tpl: ScheduleTemplate) {
    if (this.tplSelectMode) {
      Row({ space: 10 }) {
        Text(this.tplSelectedIds.indexOf(tpl.id) >= 0 ? '✓' : '')
          .fontSize(13)
          .fontColor('#FFFFFF')
          .textAlign(TextAlign.Center)
          .width(20)
          .height(20)
          .borderRadius(10)
          .backgroundColor(this.tplSelectedIds.indexOf(tpl.id) >= 0 ? this.uiThemeColor : '#FFFFFF')
          .border({ width: 1, color: this.tplSelectedIds.indexOf(tpl.id) >= 0 ? this.uiThemeColor : '#D1D5DB' })
        Column({ space: 2 }) {
          Row({ space: 6 }) {
            Text(tpl.name)
              .fontSize(15)
              .fontColor('#111827')
            if (tpl.is_builtin) {
              Text('内置')
                .fontSize(10)
                .fontColor('#6B7280')
                .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                .backgroundColor('#E5E7EB')
                .borderRadius(4)
            }
          }
          Text(`每天 ${tpl.class_sessions} 节 · 每节 ${tpl.duration_time} 分钟`
            + ` · ${tpl.citation_count} 个学期引用`)
            .fontSize(11)
            .fontColor('#9CA3AF')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .padding(12)
      .backgroundColor(this.tplSelectedIds.indexOf(tpl.id) >= 0 ? '#EFF6FF' : '#F9FAFB')
      .borderRadius(10)
      .onClick(() => this.toggleTplSelect(tpl.id))
      .gesture(LongPressGesture({ repeat: false, duration: 350 })
        .onAction(() => this.enterTplSelect(tpl.id)))
    } else {
      Row({ space: 10 }) {
        Column({ space: 2 }) {
          Row({ space: 6 }) {
            Text(tpl.name)
              .fontSize(15)
              .fontColor(this.isTemplateInUse(tpl.id) ? this.uiThemeColor : '#111827')
              .fontWeight(this.isTemplateInUse(tpl.id) ? FontWeight.Bold : FontWeight.Normal)
            if (tpl.is_builtin) {
              Text('内置')
                .fontSize(10)
                .fontColor('#6B7280')
                .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                .backgroundColor('#E5E7EB')
                .borderRadius(4)
            }
            if (this.isTemplateInUse(tpl.id)) {
              Text('当前使用')
                .fontSize(10)
                .fontColor(this.uiThemeColor)
            }
          }
          Text(`每天 ${tpl.class_sessions} 节 · 每节 ${tpl.duration_time} 分钟`
            + ` · ${tpl.citation_count} 个学期引用`)
            .fontSize(11)
            .fontColor('#9CA3AF')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .onClick(() => this.applyTemplate(tpl.id))

        Text('查看')
          .fontSize(12)
          .fontColor(this.uiThemeColor)
          .padding({ left: 8, right: 8, top: 6, bottom: 6 })
          .onClick(() => this.editTemplate(tpl.id))
      }
      .width('100%')
      .padding(12)
      .backgroundColor('#F9FAFB')
      .borderRadius(10)
      .gesture(LongPressGesture({ repeat: false, duration: 350 })
        .onAction(() => this.enterTplSelect(tpl.id)))
    }
  }

  /** 时间管理：左滑露出的操作块（复制 / 删除；内置模板只有复制——编辑走行右侧「查看」。多选态点击不响应，守卫写法与名册一致） */
  @Builder
  tplSwipeActions(tplId: number, isBuiltin: boolean) {
    Row({ space: 6 }) {
      Text('复制')
        .fontSize(14)
        .fontColor('#FFFFFF')
        .width(60)
        .height('100%')
        .textAlign(TextAlign.Center)
        .backgroundColor('#16A34A')
        .borderRadius(8)
        .onClick(() => {
          if (this.tplSelectMode) {
            return;
          }
          this.duplicateTemplate(tplId);
        })
      if (!isBuiltin) {
        Text('删除')
          .fontSize(14)
          .fontColor('#FFFFFF')
          .width(60)
          .height('100%')
          .textAlign(TextAlign.Center)
          .backgroundColor('#EF4444')
          .borderRadius(8)
          .onClick(() => {
            if (this.tplSelectMode) {
              return;
            }
            this.confirmDeleteTemplate(tplId);
          })
      }
    }
    .height('100%')
  }

  /**
   * 教师管理：教师用 `List` 承载（`ListItem` 才有左滑操作），名册 / 学期同款样式。
   *
   * 普通态：点教师行 = 切换视角；长按进入多选（底部左「全选」/ 右「删除(N)」）；
   * 普通态底部是「新增教师」表单行（与多选操作条**等高 44**——模式切换时面板总高度不变）。
   */
  @Builder
  manageTeacherView() {
    Column({ space: 10 }) {
      // 单行提示，两种模式下高度一致（FIT_CONTENT 面板高度不能随模式切换变化）
      Text(this.teacherSelectMode ? '点击勾选/取消，用「全选」一次勾完或全取消' : '点教师切换视角；左滑可编辑/删除，长按可批量选择')
        .fontSize(11)
        .fontColor('#9CA3AF')
        .width('100%')

      if (this.teacherCourseRows().length === 0) {
        Text('当前学期还没有教师：点下方「添加教师」开始录入')
          .fontSize(12)
          .fontColor('#9CA3AF')
          .width('100%')
          .padding({ top: 12, bottom: 12 })
      } else {
        List({ space: 8 }) {
          ForEach(this.teacherCourseRows(), (holder: TeacherCourses) => {
            ListItem() {
              if (this.teacherSelectMode) {
                Row({ space: 10 }) {
                  Text(this.teacherSelectedIds.indexOf(holder.teacher.id) >= 0 ? '✓' : '')
                    .fontSize(13)
                    .fontColor('#FFFFFF')
                    .textAlign(TextAlign.Center)
                    .width(20)
                    .height(20)
                    .borderRadius(10)
                    .backgroundColor(this.teacherSelectedIds.indexOf(holder.teacher.id) >= 0 ? this.uiThemeColor : '#FFFFFF')
                    .border({ width: 1, color: this.teacherSelectedIds.indexOf(holder.teacher.id) >= 0 ? this.uiThemeColor : '#D1D5DB' })
                  Column({ space: 2 }) {
                    Text(holder.teacher.displayName())
                      .fontSize(15)
                      .fontColor('#111827')
                    Text(`工号 ${holder.teacher.staff_no} · ${holder.courses.length} 门课程`)
                      .fontSize(11)
                      .fontColor('#9CA3AF')
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                }
                .width('100%')
                .padding(12)
                .backgroundColor(this.teacherSelectedIds.indexOf(holder.teacher.id) >= 0 ? '#EFF6FF' : '#F9FAFB')
                .borderRadius(10)
                .onClick(() => this.toggleTeacherSelect(holder.teacher.id))
                .gesture(LongPressGesture({ repeat: false, duration: 350 })
                  .onAction(() => this.enterTeacherSelect(holder.teacher.id)))
              } else {
                Row({ space: 10 }) {
                  Column({ space: 2 }) {
                    Text(holder.teacher.displayName())
                      .fontSize(15)
                      .fontColor(this.currentTeacherId === holder.teacher.id ? this.uiThemeColor : '#111827')
                      .fontWeight(this.currentTeacherId === holder.teacher.id ? FontWeight.Bold : FontWeight.Normal)
                    Text(`工号 ${holder.teacher.staff_no} · ${holder.courses.length} 门课程`)
                      .fontSize(11)
                      .fontColor('#9CA3AF')
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                  .onClick(() => this.switchTeacher(holder.teacher.id))
                  if (this.currentTeacherId === holder.teacher.id) {
                    Text('当前')
                      .fontSize(11)
                      .fontColor(this.uiThemeColor)
                  }
                }
                .width('100%')
                .padding(12)
                .backgroundColor('#F9FAFB')
                .borderRadius(10)
                .gesture(LongPressGesture({ repeat: false, duration: 350 })
                  .onAction(() => this.enterTeacherSelect(holder.teacher.id)))
              }
            }
            .swipeAction({ end: this.teacherSwipeActions(holder.teacher.id) })
          }, (holder: TeacherCourses) =>
            `${holder.teacher.id}-${holder.teacher.name}-${holder.courses.length}`
            + `-${this.currentTeacherId === holder.teacher.id}`
            + `-${this.teacherSelectMode}-${this.teacherSelectedIds.indexOf(holder.teacher.id) >= 0}`)
        }
        .width('100%')
        .height(this.teacherListHeight())
        .scrollBar(BarState.Off)
      }

      // 底部操作区（名册 rosterSelectBar 同款两排式）。
      // 三条形态**等高**，模式切换时面板总高度不变：
      // 多选 = 上排「取消 / 已选 N 人 / 全选」+ 下排整宽「删除选中教师」；
      // 表单态 = 上排姓名/工号输入行 + 下排「取消 / 确认添加（保存修改）」；
      // 收起态 = 上排「共 N 位教师」信息行 + 下排整宽「添加教师」（点按钮才出表单）。
      if (this.teacherSelectMode) {
        Column({ space: 10 }) {
          Row({ space: 8 }) {
            Text('取消')
              .fontSize(14)
              .fontColor('#6B7280')
              .padding({ left: 4, right: 4, top: 6, bottom: 6 })
              .onClick(() => this.exitTeacherSelect())
            Text(`已选 ${this.teacherSelectedIds.length} 人`)
              .fontSize(14)
              .fontColor('#111827')
              .layoutWeight(1)
              .textAlign(TextAlign.Center)
            Text(this.teacherSelectedIds.length >= this.teacherCourseRows().length ? '取消全选' : '全选')
              .fontSize(14)
              .fontColor(this.uiThemeColor)
              .padding({ left: 4, right: 4, top: 6, bottom: 6 })
              .onClick(() => this.toggleTeacherSelectAll())
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 11, bottom: 11 })
          .backgroundColor('#F9FAFB')
          .borderRadius(10)

          Button(this.manageBusy ? '删除中…' : '删除选中教师')
            .fontSize(14)
            .height(44)
            .width('100%')
            .backgroundColor('#EF4444')
            .fontColor('#FFFFFF')
            .enabled(this.teacherSelectedIds.length > 0 && !this.manageBusy)
            .onClick(() => this.confirmDeleteSelectedTeachers())
        }
        .width('100%')
      } else if (this.teacherFormId !== 0) {
        Column({ space: 10 }) {
          Row({ space: 8 }) {
            TextInput({ placeholder: '教师姓名', text: this.teacherDraftName })
              .fontSize(13)
              .height(42)
              .backgroundColor('#F3F4F6')
              .layoutWeight(1)
              .textAlign(TextAlign.Start)
              .padding({ left: 8, right: 8 })
              .onChange((value: string) => {
                this.teacherDraftName = value;
              })
            TextInput({ placeholder: '工号', text: this.teacherDraftStaffNo })
              .fontSize(13)
              .height(42)
              .backgroundColor('#F3F4F6')
              .width(96)
              .textAlign(TextAlign.Start)
              .padding({ left: 8, right: 8 })
              .onChange((value: string) => {
                this.teacherDraftStaffNo = value;
              })
          }
          .width('100%')

          Row({ space: 8 }) {
            Button('取消')
              .fontSize(14)
              .height(44)
              .layoutWeight(1)
              .backgroundColor('#E5E7EB')
              .fontColor('#374151')
              .enabled(!this.manageBusy)
              .onClick(() => this.closeTeacherForm())
            Button(this.manageBusy
              ? (this.teacherFormId > 0 ? '保存中…' : '添加中…')
              : (this.teacherFormId > 0 ? '保存修改' : '确认添加'))
              .fontSize(14)
              .height(44)
              .layoutWeight(1)
              .backgroundColor('#16A34A')
              .enabled(!this.manageBusy)
              .onClick(() => this.saveTeacherForm())
          }
          .width('100%')
        }
        .width('100%')
      } else {
        Column({ space: 10 }) {
          Row({ space: 8 }) {
            Text(`共 ${this.teacherCourseRows().length} 位教师`)
              .fontSize(14)
              .fontColor('#6B7280')
              .layoutWeight(1)
              .textAlign(TextAlign.Center)
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 11, bottom: 11 })
          .backgroundColor('#F9FAFB')
          .borderRadius(10)

          Button('添加教师')
            .fontSize(14)
            .height(44)
            .width('100%')
            .backgroundColor('#16A34A')
            .enabled(!this.manageBusy)
            .onClick(() => this.openTeacherAdd())
        }
        .width('100%')
      }
    }
    .width('100%')
  }

  /** 教师管理：左滑露出的操作块（编辑+删除；多选/表单态点击不响应，守卫写法与名册一致） */
  @Builder
  teacherSwipeActions(teacherId: number) {
    Row({ space: 6 }) {
      Text('编辑')
        .fontSize(14)
        .fontColor('#FFFFFF')
        .width(60)
        .height('100%')
        .textAlign(TextAlign.Center)
        .backgroundColor('#3B82F6')
        .borderRadius(8)
        .onClick(() => {
          if (this.teacherSelectMode || this.teacherFormId !== 0) {
            return;
          }
          this.openTeacherEdit(teacherId);
        })
      Text('删除')
        .fontSize(14)
        .fontColor('#FFFFFF')
        .width(60)
        .height('100%')
        .textAlign(TextAlign.Center)
        .backgroundColor('#EF4444')
        .borderRadius(8)
        .onClick(() => {
          if (this.teacherSelectMode || this.teacherFormId !== 0) {
            return;
          }
          this.confirmDeleteTeacher(teacherId);
        })
    }
    .height('100%')
  }

    /** 班级管理：班级人数列表 → 点击查看名册 */
  @Builder
  manageStudentView() {
    Column({ space: 10 }) {
      if (this.rosterClassId.length === 0) {
        Column({ space: 8 }) {
            ForEach(this.population, (row: ClassPopulationRow) => {
              Row() {
                Text(row.class_name)
                  .fontSize(15)
                  .fontColor('#111827')
                  .layoutWeight(1)
                Text(`名册 ${row.roster_count} 人 / 登记 ${row.population} 人`)
                  .fontSize(11)
                  .fontColor('#9CA3AF')
                Text('›')
                  .fontSize(16)
                  .fontColor('#9CA3AF')
              }
              .width('100%')
              .padding(12)
              .backgroundColor('#F9FAFB')
              .borderRadius(10)
              .onClick(() => this.openRoster(row.class_id))
            }, (row: ClassPopulationRow) =>
              `${row.class_id}-${row.class_name}-${row.population}-${row.roster_count}`)
          }
          .width('100%')
      } else {
        this.rosterView()
      }
    }
    .width('100%')
  }

  /**
   * 班级名册：学生用 `List` 承载（`ListItem` 才有左滑操作），底部是 Excel 导入。
   *
   * 列表高度按人数算但封顶：名单短时面板贴着内容收边，名单长了在列表内部滚动，
   * 不会先把面板撑到上限、再让外层 Scroll 去滚。
   */
  @Builder
  rosterView() {
    Column({ space: 10 }) {
      Row() {
        Text(this.rosterClassName())
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor('#111827')
          .layoutWeight(1)
        Text(`共 ${this.rosterCount()} 人`)
          .fontSize(12)
          .fontColor('#6B7280')
      }
      .width('100%')

      if (this.rosterCount() === 0) {
        Text('这个班还没有学生：点上方「添加学生信息」逐个录入，或用底部「导入班级名单」批量导入')
          .fontSize(12)
          .fontColor('#9CA3AF')
          .width('100%')
          .padding({ top: 12, bottom: 12 })
      } else {
        // 单行提示，两种模式下高度一致（FIT_CONTENT 面板高度不能随模式切换变化）
        Text(this.rosterSelectMode ? '点击学生勾选/取消，用「全选」一次勾完或全取消' : '长按某个学生可批量选择后删除')
          .fontSize(11)
          .fontColor('#9CA3AF')
          .width('100%')
        List({ space: 8 }) {
          ForEach(this.rosterStudents(), (student: Student) => {
            ListItem() {
              Row({ space: 10 }) {
                if (this.rosterSelectMode) {
                  // 多选框：主题色圆底 + 白色对勾（ic_confirm 是对勾矢量图标，fillColor 染色）
                  Stack() {
                    Circle()
                      .width(22)
                      .height(22)
                      .fill(this.isStudentSelected(student.id) ? this.uiThemeColor : '#FFFFFF')
                      .stroke(this.isStudentSelected(student.id) ? this.uiThemeColor : '#C4C8D0')
                      .strokeWidth(1.5)
                    if (this.isStudentSelected(student.id)) {
                      Image($r('app.media.ic_confirm'))
                        .width(14)
                        .height(14)
                        .fillColor('#FFFFFF')
                    }
                  }
                  .width(22)
                  .height(22)
                }

                Column({ space: 2 }) {
                  Text(student.name.length > 0 ? student.name : '（未填姓名）')
                    .fontSize(15)
                    .fontColor('#111827')
                    .width('100%')
                  Text(student.student_no)
                    .fontSize(12)
                    .fontColor('#9CA3AF')
                    .width('100%')
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                Text(student.sex === undefined || student.sex.length === 0 ? '性别未填' : student.sex)
                  .fontSize(12)
                  .fontColor('#6B7280')
              }
              .width('100%')
              .padding({ top: 10, bottom: 10, left: 12, right: 12 })
              .backgroundColor(this.isStudentSelected(student.id) ? '#EEF5FF' : '#F9FAFB')
              .borderRadius(8)
              .onClick(() => {
                if (this.rosterSelectMode) {
                  this.toggleStudentSelected(student.id);
                } else {
                  this.openStudentDetail(student.id);
                }
              })
              .gesture(LongPressGesture({ repeat: false, duration: 500 })
                .onAction(() => {
                  if (!this.rosterSelectMode) {
                    this.enterRosterSelect(student.id);
                  }
                }))
            }
            .swipeAction({ end: this.rosterSwipeActions(student.id) })
          }, (student: Student) =>
            `${student.id}-${student.student_no}-${student.name}-${student.sex}`
            + `-${this.rosterSelectMode}-${this.isStudentSelected(student.id)}`)
        }
        .width('100%')
        .height(this.rosterListHeight())
        .scrollBar(BarState.Off)
      }

      // 底部操作区：多选模式下换成「全选/删除」，两种形态总高度一致 ——
      // 实测 FIT_CONTENT 面板在内容高度变化后内部点击会错乱（命中旧布局），
      // 所以这里不做"展开/收起"，也不放会显隐的结果文案（导入结果一律走 notify 提示）
      if (this.rosterSelectMode) {
        this.rosterSelectBar()
      } else {
        this.rosterAddRow()
        this.rosterBottomBar()
      }
    }
    .width('100%')
  }

  /** 名册左滑露出的操作：`end` = 向左滑动后出现在条目右侧（多选模式下不响应） */
  @Builder
  rosterSwipeActions(id: number) {
    Row() {
      Text('查看')
        .fontSize(14)
        .fontColor('#FFFFFF')
        .width(72)
        .height('100%')
        .textAlign(TextAlign.Center)
        .backgroundColor('#1890FF')
        .borderRadius(8)
        .onClick(() => {
          if (this.rosterSelectMode) {
            return;
          }
          this.openStudentDetail(id);
        })
      Text('删除')
        .fontSize(14)
        .fontColor('#FFFFFF')
        .width(72)
        .height('100%')
        .textAlign(TextAlign.Center)
        .backgroundColor('#EF4444')
        .borderRadius(8)
        .margin({ left: 8 })
        .onClick(() => {
          if (this.rosterSelectMode) {
            return;
          }
          this.confirmDeleteStudent(id);
        })
    }
    .height('100%')
  }

  /** 名册底部操作行**上方**那一行：逐个添加学生（打开空白的学生表单） */
  @Builder
  rosterAddRow() {
    Row({ space: 8 }) {
      Image($r('app.media.ic_add'))
        .width(18)
        .height(18)
        .fillColor(this.uiThemeColor)
      Text('添加学生信息')
        .fontSize(14)
        .fontColor(this.uiThemeColor)
        .layoutWeight(1)
      Text('›')
        .fontSize(16)
        .fontColor('#9CA3AF')
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 11, bottom: 11 })
    .backgroundColor('#F9FAFB')
    .borderRadius(10)
    .enabled(!this.rosterImportBusy && !this.studentBusy)
    .onClick(() => this.openNewStudent())
  }

  /**
   * 名册**最底部**的操作行：左侧「导入班级名单」（点开后二选一：下载模板 / 选文件导入）、
   * 右侧「导出班级名单」（把名册里已有的学生写成 .xls）。
   *
   * 导入/下载的结果统一走 `notify`（弹窗提示），不在面板里放会显隐的文案 ——
   * FIT_CONTENT 面板高度一变，内部点击就会命中旧布局（见 §12.3.2 第 17 点）。
   */
  @Builder
  rosterBottomBar() {
    Row({ space: 10 }) {
      Button(this.rosterImportBusy ? '导入中…' : '导入班级名单')
        .fontSize(14)
        .height(44)
        .layoutWeight(1)
        .backgroundColor(this.uiThemeColor)
        .fontColor(textColorOf(this.uiThemeColor))
        .enabled(!this.rosterImportBusy)
        .onClick(() => this.openRosterImportMenu())
      Button(this.rosterImportBusy ? '处理中…' : '导出班级名单')
        .fontSize(14)
        .height(44)
        .layoutWeight(1)
        .backgroundColor('#E5E7EB')
        .fontColor('#111827')
        .enabled(!this.rosterImportBusy)
        .onClick(() => this.openRosterExportMenu())
    }
    .width('100%')
  }

  /**
   * 多选模式的底部操作条：上排「取消 / 已选 N 人 / 全选」，下排「删除」。
   *
   * 两排高度刻意与常规形态的 rosterAddRow + rosterBottomBar 一一对应（约 40 + 44），
   * 模式切换时面板总高度不变 —— FIT_CONTENT 面板高度一变，内部点击会命中旧布局
   * （见 docs/04 §12.3.2 第 17 点）。
   * 「全选」是二态按钮：未全选时点击勾上全部，已全选时点击全部取消。
   */
  @Builder
  rosterSelectBar() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Text('取消')
          .fontSize(14)
          .fontColor('#6B7280')
          .padding({ left: 4, right: 4, top: 6, bottom: 6 })
          .onClick(() => this.exitRosterSelect())
        Text(`已选 ${this.rosterSelectedIds.length} 人`)
          .fontSize(14)
          .fontColor('#111827')
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
        Text(this.rosterAllSelected() ? '取消全选' : '全选')
          .fontSize(14)
          .fontColor(this.uiThemeColor)
          .padding({ left: 4, right: 4, top: 6, bottom: 6 })
          .onClick(() => this.toggleRosterSelectAll())
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 11, bottom: 11 })
      .backgroundColor('#F9FAFB')
      .borderRadius(10)

      Button(this.manageBusy ? '删除中…' : `删除选中学生`)
        .fontSize(14)
        .height(44)
        .width('100%')
        .backgroundColor('#EF4444')
        .fontColor('#FFFFFF')
        .enabled(this.rosterSelectedIds.length > 0 && !this.manageBusy)
        .onClick(() => this.confirmDeleteSelected())
    }
    .width('100%')
  }

  /**
   * 「导入班级名单」点开后的二选一：下载班级名单模板 / 导入班级名单。
   *
   * 用 `AlertDialog`（双按钮）而不是在面板里展开一块菜单：面板是 `FIT_CONTENT`，
   * 内容高度一变内部点击就会命中旧布局（见 §12.3.2 第 17 点），弹窗是独立窗口，不受影响。
   */
  private openRosterImportMenu(): void {
    if (this.rosterImportBusy || this.rosterClassId.length === 0) {
      return;
    }
    AlertDialog.show({
      title: '导入班级名单',
      message: '先「下载班级名单模板」按格式填好名单，再「导入班级名单」。',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '导入班级名单',
        action: () => {
          this.pickRosterFile();
        }
      },
      secondaryButton: {
        value: '下载班级名单模板',
        action: () => {
          this.downloadRosterTemplate();
        }
      }
    });
  }

  /**
   * 学生详情（修改）。
   *
   * 表单值一律**直接读 `this.draft*`**，不经过 @Builder 的按值参数 ——
   * @Builder 的参数不参与状态观察，把正在编辑的字段当参数传进去会冻在首帧的值上。
   * 本页只改这一名学生，因此**不提供删除入口**：删除只存在于名册的左滑菜单。
   */
  @Builder
  studentDetailView() {
    Column({ space: 10 }) {
      if (this.studentEditId === 0) {
        Text('没有选中的学生')
          .fontSize(13)
          .fontColor('#9CA3AF')
          .width('100%')
      } else {
        Column({ space: 6 }) {
          Text('学号').fontSize(12).fontColor('#6B7280').width('100%')
          TextInput({ text: this.draftStudentNo, placeholder: '请输入学号' })
            .fontSize(14)
            .height(42)
            .backgroundColor('#F3F4F6')
            .width('100%')
            .textAlign(TextAlign.Start)
            .padding({ left: 8, right: 8 })
            .onChange((value: string) => {
              this.draftStudentNo = value;
            })
        }
        .width('100%')

        Column({ space: 6 }) {
          Text('姓名').fontSize(12).fontColor('#6B7280').width('100%')
          TextInput({ text: this.draftStudentName, placeholder: '请输入姓名' })
            .fontSize(14)
            .height(42)
            .backgroundColor('#F3F4F6')
            .width('100%')
            .textAlign(TextAlign.Start)
            .padding({ left: 8, right: 8 })
            .onChange((value: string) => {
              this.draftStudentName = value;
            })
        }
        .width('100%')

        Column({ space: 6 }) {
          Text('性别').fontSize(12).fontColor('#6B7280').width('100%')
          Row({ space: 10 }) {
            Text('男')
              .fontSize(14)
              .fontColor(this.draftStudentSex === '男' ? '#FFFFFF' : '#374151')
              .backgroundColor(this.draftStudentSex === '男' ? '#1890FF' : '#F3F4F6')
              .padding({ left: 20, right: 20, top: 9, bottom: 9 })
              .borderRadius(8)
              .onClick(() => {
                this.draftStudentSex = '男';
              })
            Text('女')
              .fontSize(14)
              .fontColor(this.draftStudentSex === '女' ? '#FFFFFF' : '#374151')
              .backgroundColor(this.draftStudentSex === '女' ? '#1890FF' : '#F3F4F6')
              .padding({ left: 20, right: 20, top: 9, bottom: 9 })
              .borderRadius(8)
              .onClick(() => {
                this.draftStudentSex = '女';
              })
            Text('未填')
              .fontSize(14)
              .fontColor(this.draftStudentSex.length === 0 ? '#FFFFFF' : '#374151')
              .backgroundColor(this.draftStudentSex.length === 0 ? '#1890FF' : '#F3F4F6')
              .padding({ left: 20, right: 20, top: 9, bottom: 9 })
              .borderRadius(8)
              .onClick(() => {
                this.draftStudentSex = '';
              })
          }
          .width('100%')
        }
        .width('100%')

        Column({ space: 6 }) {
          Text('年龄').fontSize(12).fontColor('#6B7280').width('100%')
          TextInput({ text: this.draftStudentAge, placeholder: '选填，如 20' })
            .type(InputType.Number)
            .fontSize(14)
            .height(42)
            .backgroundColor('#F3F4F6')
            .width('100%')
            .textAlign(TextAlign.Start)
            .padding({ left: 8, right: 8 })
            .onChange((value: string) => {
              this.draftStudentAge = value;
            })
        }
        .width('100%')

        Column({ space: 6 }) {
          Text('联系电话').fontSize(12).fontColor('#6B7280').width('100%')
          TextInput({ text: this.draftStudentPhone, placeholder: '选填' })
            .fontSize(14)
            .height(42)
            .backgroundColor('#F3F4F6')
            .width('100%')
            .textAlign(TextAlign.Start)
            .padding({ left: 8, right: 8 })
            .onChange((value: string) => {
              this.draftStudentPhone = value;
            })
        }
        .width('100%')

        Column({ space: 6 }) {
          Text('备注').fontSize(12).fontColor('#6B7280').width('100%')
          TextInput({ text: this.draftStudentRemark, placeholder: '选填' })
            .fontSize(14)
            .height(42)
            .backgroundColor('#F3F4F6')
            .width('100%')
            .textAlign(TextAlign.Start)
            .padding({ left: 8, right: 8 })
            .onChange((value: string) => {
              this.draftStudentRemark = value;
            })
        }
        .width('100%')

        Row({ space: 10 }) {
          Button('取消')
            .fontSize(14)
            .height(44)
            .layoutWeight(1)
            .backgroundColor('#E5E7EB')
            .fontColor('#111827')
            .onClick(() => this.closeStudentDetail())
          Button(this.studentBusy ? '保存中…' : '保存')
            .fontSize(14)
            .height(44)
            .layoutWeight(1)
            .backgroundColor(this.uiThemeColor)
            .enabled(!this.studentBusy)
            .onClick(() => this.saveStudentDetail())
        }
        .width('100%')
        .margin({ top: 4 })
      }
    }
    .width('100%')
  }

  /** 课表管理：统计 + 新增课程入口 */
  @Builder
  manageCourseView() {
    Column({ space: 10 }) {
      Column({ space: 8 }) {
        Row() {
          Text('本学期课程')
            .fontSize(13)
            .fontColor('#6B7280')
            .layoutWeight(1)
          Text(`${this.stats.courses}`)
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor('#111827')
        }
        .width('100%')
        Row() {
          Text('班级分组')
            .fontSize(13)
            .fontColor('#6B7280')
            .layoutWeight(1)
          Text(`${this.stats.classes}`)
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor('#111827')
        }
        .width('100%')
        Row() {
          Text('时间段 / 周次记录')
            .fontSize(13)
            .fontColor('#6B7280')
            .layoutWeight(1)
          Text(`${this.stats.periods} / ${this.stats.weeks}`)
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor('#111827')
        }
        .width('100%')
        Row() {
          Text('任课教师')
            .fontSize(13)
            .fontColor('#6B7280')
            .layoutWeight(1)
          Text(`${this.stats.teachers}`)
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor('#111827')
        }
        .width('100%')
      }
      .width('100%')
      .padding(14)
      .backgroundColor('#F9FAFB')
      .borderRadius(12)

      Button('新增课程')
        .fontSize(15)
        .width('100%')
        .height(44)
        .backgroundColor(this.uiThemeColor)
        .onClick(() => {
          this.closeManageSheet();
          this.navToCourseEdit();
        })

      Text('编辑现有课程：课表页点击课程块，在详情中选择“编辑”')
        .fontSize(11)
        .fontColor('#9CA3AF')
        .width('100%')
        .textAlign(TextAlign.Center)
    }
    .width('100%')
  }

  /**
   * 学期管理（三态）：
   *   list   —— List + 左滑删除（`SwipeAction`）+ 点按选中（切学期）+ 右侧「查看」
   *             + 长按进入多选（底部左「全选」/ 右「删除」）；普通态底部居中「新建学期」。
   *   detail —— 「查看」进来的学期详情（名称 / 周数 / 开始日期 可一起改）。
   *   create —— 「新建学期」进来的新建表单（标题同步变「新建学期」，返回走头部返回键）。
   *
   * 面板是 FIT_CONTENT：List 高度按学期数算并封顶（与名册同一策略），普通态与多选态的
   * 底部操作条**等高**（44）—— 面板内容高度一变，内部点击会命中旧布局
   * （docs/04 §12.3.2 第 17 点，名册页同款教训）。
   */
  @Builder
  manageSemesterView() {
    if (this.semesterPageMode === 'create') {
      // ---- 新建页：整页只剩表单（返回走面板头部 ic_return）----
      Column({ space: 10 }) {
        TextInput({ placeholder: '学期名称', text: this.semesterDraftName })
          .fontSize(14)
          .height(42)
          .backgroundColor('#F3F4F6')
          .width('100%')
          .textAlign(TextAlign.Start)
          .padding({ left: 8, right: 8 })
          .onChange((value: string) => {
            this.semesterDraftName = value;
          })

        Row({ space: 8 }) {
          Text('周数')
            .fontSize(13)
            .fontColor('#374151')
            .width(56)
          TextInput({ text: this.semesterDraftWeeks })
            .type(InputType.Number)
            .fontSize(14)
            .height(42)
            .backgroundColor('#F3F4F6')
            .width(72)
            .textAlign(TextAlign.Start)
            .padding({ left: 8, right: 8 })
            .onChange((value: string) => {
              this.semesterDraftWeeks = value;
            })
          Text('周（1-40）')
            .fontSize(11)
            .fontColor('#9CA3AF')
          Blank()
        }
        .width('100%')

        Row({ space: 8 }) {
          Text('开始日期')
            .fontSize(13)
            .fontColor('#374151')
            .width(56)
          Text(this.semesterDraftStart.length > 0 ? this.semesterDraftStart : '未设置')
            .fontSize(13)
            .fontColor(this.uiThemeColor)
            .layoutWeight(1)
          Text('第1周周一 ›')
            .fontSize(11)
            .fontColor('#9CA3AF')
        }
        .width('100%')
        .height(38)
        .onClick(() => this.pickSemesterDraftStart())

        Button(this.manageBusy ? '创建中…' : '新建学期')
          .fontSize(14)
          .height(44)
          .width(180)
          .backgroundColor(this.uiThemeColor)
          .enabled(!this.manageBusy)
          .onClick(() => this.createSemesterFromDraft())
      }
      .width('100%')
    } else if (this.semesterEditId > 0) {
      // ---- 学期详情：名称 / 周数 / 开始日期 可一起改（「查看」进来）----
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          Text('名称')
            .fontSize(13)
            .fontColor('#374151')
            .width(56)
          TextInput({ text: this.semesterEditName })
            .fontSize(14)
            .height(42)
            .backgroundColor('#F3F4F6')
            .layoutWeight(1)
            .textAlign(TextAlign.Start)
            .padding({ left: 8, right: 8 })
            .onChange((value: string) => {
              this.semesterEditName = value;
            })
        }
        .width('100%')

        Row({ space: 8 }) {
          Text('周数')
            .fontSize(13)
            .fontColor('#374151')
            .width(56)
          TextInput({ text: this.semesterEditWeeks })
            .type(InputType.Number)
            .fontSize(14)
            .height(42)
            .backgroundColor('#F3F4F6')
            .width(72)
            .textAlign(TextAlign.Start)
            .padding({ left: 8, right: 8 })
            .onChange((value: string) => {
              this.semesterEditWeeks = value;
            })
          Text('周（1-40）')
            .fontSize(11)
            .fontColor('#9CA3AF')
          Blank()
        }
        .width('100%')

        Row({ space: 8 }) {
          Text('开始日期')
            .fontSize(13)
            .fontColor('#374151')
            .width(56)
          Text(this.semesterEditStart.length > 0 ? this.semesterEditStart : '未设置')
            .fontSize(13)
            .fontColor(this.uiThemeColor)
            .layoutWeight(1)
          Text('第1周周一 ›')
            .fontSize(11)
            .fontColor('#9CA3AF')
        }
        .width('100%')
        .height(38)
        .onClick(() => this.pickSemesterStart())

        Row({ space: 8 }) {
          Button('取消')
            .fontSize(14)
            .height(44)
            .layoutWeight(1)
            .backgroundColor('#E5E7EB')
            .fontColor('#111827')
            .onClick(() => {
              this.semesterEditId = 0;
            })
          Button(this.manageBusy ? '保存中…' : '保存')
            .fontSize(14)
            .height(44)
            .layoutWeight(1)
            .backgroundColor(this.uiThemeColor)
            .enabled(!this.manageBusy)
            .onClick(() => this.saveSemesterEdit(this.semesterEditId))
        }
        .width('100%')
      }
      .width('100%')
    } else {
      List({ space: 8 }) {
        ForEach(this.semesters, (sem: Semester) => {
          ListItem() {
            if (this.semesterSelectMode) {
              // ---- 多选态：整行点按 = 切换选中 ----
              Row({ space: 10 }) {
                Text(this.semesterSelectedIds.indexOf(sem.id) >= 0 ? '✓' : '')
                  .fontSize(13)
                  .fontColor('#FFFFFF')
                  .textAlign(TextAlign.Center)
                  .width(20)
                  .height(20)
                  .borderRadius(10)
                  .backgroundColor(this.semesterSelectedIds.indexOf(sem.id) >= 0 ? this.uiThemeColor : '#FFFFFF')
                  .border({ width: 1, color: this.semesterSelectedIds.indexOf(sem.id) >= 0 ? this.uiThemeColor : '#D1D5DB' })
                Column({ space: 2 }) {
                  Text(sem.name)
                    .fontSize(15)
                    .fontColor('#111827')
                  Text(`${sem.total_weeks} 周 · ${sem.start_date} 起`)
                    .fontSize(11)
                    .fontColor('#9CA3AF')
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
              }
              .width('100%')
              .padding(12)
              .backgroundColor(this.semesterSelectedIds.indexOf(sem.id) >= 0 ? '#EFF6FF' : '#F9FAFB')
              .borderRadius(10)
              .onClick(() => this.toggleSemesterSelect(sem.id))
              .gesture(LongPressGesture({ repeat: false, duration: 350 })
                .onAction(() => this.enterSemesterSelect(sem.id)))
            } else {
              // ---- 普通态：点名称列 = 选中（切学期）；右侧「查看」= 详情 / 修改 ----
              Row({ space: 10 }) {
                Column({ space: 2 }) {
                  Text(sem.name)
                    .fontSize(15)
                    .fontColor(this.currentSemester()?.id === sem.id ? this.uiThemeColor : '#111827')
                    .fontWeight(this.currentSemester()?.id === sem.id ? FontWeight.Bold : FontWeight.Normal)
                  Text(`${sem.total_weeks} 周 · ${sem.start_date} 起`)
                    .fontSize(11)
                    .fontColor('#9CA3AF')
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                .onClick(() => this.switchSemester(sem.id))
                if (this.currentSemester()?.id === sem.id) {
                  Text('当前')
                    .fontSize(11)
                    .fontColor(this.uiThemeColor)
                }
                Text('查看')
                  .fontSize(12)
                  .fontColor(this.uiThemeColor)
                  .padding({ left: 8, right: 8, top: 6, bottom: 6 })
                  .onClick(() => this.openSemesterEdit(sem.id))
              }
              .width('100%')
              .padding(12)
              .backgroundColor('#F9FAFB')
              .borderRadius(10)
              .gesture(LongPressGesture({ repeat: false, duration: 350 })
                .onAction(() => this.enterSemesterSelect(sem.id)))
            }
          }
          .swipeAction({ end: this.semesterSwipeDelete(sem.id) })
        }, (sem: Semester) =>
          `${sem.id}-${sem.name}-${sem.total_weeks}-${sem.start_date}`
          + `-${this.currentSemester()?.id === sem.id}`
          + `-${this.semesterSelectMode}-${this.semesterSelectedIds.indexOf(sem.id) >= 0}`)
      }
      .width('100%')
      .height(this.semesterListHeight())
      .scrollBar(BarState.Off)

      // ---- 底部操作区（名册 rosterSelectBar 同款两排式）。
      //      两条形态**等高**，模式切换时面板总高度不变。----
      //      多选 = 名册同款两排：上排「取消 / 已选 N 个 / 全选」、下排整宽「删除选中学期」；
      //      普通 = 上排「共 N 个学期」信息行 + 下排居中「新建学期」（结构与字号同上排，等高）。
      if (this.semesterSelectMode) {
        Column({ space: 10 }) {
          Row({ space: 8 }) {
            Text('取消')
              .fontSize(14)
              .fontColor('#6B7280')
              .padding({ left: 4, right: 4, top: 6, bottom: 6 })
              .onClick(() => this.exitSemesterSelect())
            Text(`已选 ${this.semesterSelectedIds.length} 个`)
              .fontSize(14)
              .fontColor('#111827')
              .layoutWeight(1)
              .textAlign(TextAlign.Center)
            Text(this.semesterSelectedIds.length >= this.semesters.length ? '取消全选' : '全选')
              .fontSize(14)
              .fontColor(this.uiThemeColor)
              .padding({ left: 4, right: 4, top: 6, bottom: 6 })
              .onClick(() => this.toggleSemesterSelectAll())
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 11, bottom: 11 })
          .backgroundColor('#F9FAFB')
          .borderRadius(10)

          Button(this.manageBusy ? '删除中…' : '删除选中学期')
            .fontSize(14)
            .height(44)
            .width('100%')
            .backgroundColor('#EF4444')
            .fontColor('#FFFFFF')
            .enabled(this.semesterSelectedIds.length > 0 && !this.manageBusy)
            .onClick(() => this.confirmDeleteSelectedSemesters())
        }
        .width('100%')
      } else {
        Column({ space: 10 }) {
          Row({ space: 8 }) {
            Text(`共 ${this.semesters.length} 个学期`)
              .fontSize(14)
              .fontColor('#6B7280')
              .padding({ left: 4, right: 4, top: 6, bottom: 6 })
            Blank()
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 11, bottom: 11 })
          .backgroundColor('#F9FAFB')
          .borderRadius(10)

          Row() {
            Blank().layoutWeight(1)
            Button(this.manageBusy ? '处理中…' : '新建学期')
              .fontSize(14)
              .height(44)
              .width(160)
              .backgroundColor('#16A34A')
              .enabled(!this.manageBusy)
              .onClick(() => {
                this.semesterDraftName = `学期 ${this.semesters.length + 1}`;
                this.semesterDraftWeeks = '20';
                this.semesterDraftStart = DateUtil.toDateString(DateUtil.weekMonday(DateUtil.today()));
                this.semesterPageMode = 'create';
              })
            Blank().layoutWeight(1)
          }
          .width('100%')
        }
        .width('100%')
      }
    }
  }

  /** 学期管理：左滑露出的删除块（多选 / 详情态点击不响应，守卫写法与名册一致） */
  @Builder
  semesterSwipeDelete(semesterId: number) {
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
          if (this.semesterSelectMode || this.semesterEditId > 0) {
            return;
          }
          this.confirmDeleteSemester(semesterId);
        })
    }
    .height('100%')
  }

  /**
   * 签到信息：**真正的入口在课程块上**（点课后详情面板中间的「签到」），这里只放
   * "怎么进去"的说明与班级人数概览。
   *
   * 为什么不在这里也放一个签到入口：一次点名必须绑定"**哪一次课**"（时间段 × 周次），
   * 而管理面板里没有"当前第几周、点的是哪节课"这个上下文 —— 从这里进去，用户点完名
   * 落库时还得再选一遍课程 / 周次 / 节次，比直接点课程块多三步。
   */
  @Builder
  manageCheckinView() {
    Column({ space: 10 }) {
      Column({ space: 6 }) {
        Text('签到入口在课程块上')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor('#111827')
          .width('100%')
        Text('在课表上点一节课 → 详情面板中间的「签到」→ 选「随机指定人数点名」（人数就在这一项标题的右侧加减）或「全部点名」，'
          + '也可以点「查看本节课程情况」只读地看一眼这一次课的点名结果（不改动数据）。'
          + '名单里左滑记旷课、右滑记请假、长按并拖到圆环上评等级（圆环正上方那块是取消）；'
          + '名单最底下那个「单人视图」按钮进去：上半屏是当前学生，下半屏是一排操作键（切换视图 + 1/2/3 / 4/5/⊕/×），'
          + '最底下左右两端还能翻前后两位。'
          + '点右上角「完成」才落库。'
          + '导出在班级名册的「导出班级名单」里，可选原表口径（×/⊕ + 等级）或算分后口径（√/×/⊕ + 分数）。'
          + '下面的班级人数概览可用于线下点名。')
          .fontSize(12)
          .fontColor('#6B7280')
          .width('100%')
      }
      .width('100%')
      .padding(14)
      .backgroundColor('#F9FAFB')
      .borderRadius(12)

      Column({ space: 6 }) {
          ForEach(this.population, (row: ClassPopulationRow) => {
            Row() {
              Text(row.class_name)
                .fontSize(14)
                .fontColor('#111827')
                .layoutWeight(1)
              Text(`${row.roster_count} 人`)
                .fontSize(12)
                .fontColor('#6B7280')
            }
            .width('100%')
            .padding({ top: 8, bottom: 8, left: 12, right: 12 })
            .backgroundColor('#F9FAFB')
            .borderRadius(8)
          }, (row: ClassPopulationRow) => `${row.class_id}-${row.class_name}-${row.roster_count}`)
        }
        .width('100%')
    }
    .width('100%')
  }

  /** 全局设置：默认教师（机主）信息维护 */
  @Builder
  manageSettingView() {
    Column({ space: 10 }) {
      Column({ space: 8 }) {
        Text('默认教师（机主）')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor('#111827')
          .width('100%')
        Text('新建学期时自动以此为默认教师')
          .fontSize(11)
          .fontColor('#9CA3AF')
          .width('100%')
      }
      .width('100%')

      Column({ space: 8 }) {
        TextInput({ placeholder: '请输入姓名', text: this.inputName })
          .fontSize(14)
          .height(42)
          .backgroundColor('#F3F4F6')
          .width('100%')
          .textAlign(TextAlign.Start)
          .padding({ left: 8, right: 8 })
          .onChange((value: string) => {
            this.inputName = value;
          })
        TextInput({ placeholder: '教师工号，如 2024***25', text: this.inputStaffNo })
          .fontSize(14)
          .height(42)
          .backgroundColor('#F3F4F6')
          .width('100%')
          .textAlign(TextAlign.Start)
          .padding({ left: 8, right: 8 })
          .onChange((value: string) => {
            this.inputStaffNo = value;
          })
        Button(this.busy ? '保存中…' : '保存')
          .fontSize(14)
          .width('100%')
          .height(44)
          .backgroundColor(this.uiThemeColor)
          .enabled(!this.busy)
          .onClick(() => this.saveOwner())
      }
      .width('100%')
      .padding(14)
      .backgroundColor('#F9FAFB')
      .borderRadius(12)
    }
    .width('100%')
  }

  /** 关于：应用与数据概况 */
  @Builder
  manageAboutView() {
    Column({ space: 10 }) {
      Column({ space: 6 }) {
        Text('每日知途 WisdomDaily')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor('#111827')
          .width('100%')
        Text('HarmonyOS ArkTS · 本地关系型数据库驱动')
          .fontSize(12)
          .fontColor('#6B7280')
          .width('100%')
      }
      .width('100%')
      .padding({ top: 8 })
      .alignItems(HorizontalAlign.Center)

      Column({ space: 8 }) {
        this.sheetInfoRow('数据库版本', `v${this.stats.dbVersion}`)
        this.sheetInfoRow('学期数', `${this.stats.semesters}`)
        this.sheetInfoRow('作息模板', `${this.stats.templates}`)
        this.sheetInfoRow('课程数', `${this.stats.courses}`)
        this.sheetInfoRow('学生数', `${this.stats.students}`)
        this.sheetInfoRow('签到记录', `${this.stats.attendances}`)
      }
      .width('100%')
      .padding(14)
      .backgroundColor('#F9FAFB')
      .borderRadius(12)
    }
    .width('100%')
  }

  // ---------------------------------------------------------------- 课表分享 / 导入

  /** 学期 → 它绑定的时间表 id；没绑定（或学期不存在）时回退到第一张时间表 */
  private templateIdOfSemester(semesterId: number): number {
    for (let i = 0; i < this.semesters.length; i++) {
      if (this.semesters[i].id === semesterId && this.semesters[i].schedule_id > 0) {
        return this.semesters[i].schedule_id;
      }
    }
    return this.templates.length > 0 ? this.templates[0].id : 0;
  }

  private semesterById(semesterId: number): Semester | undefined {
    for (let i = 0; i < this.semesters.length; i++) {
      if (this.semesters[i].id === semesterId) {
        return this.semesters[i];
      }
    }
    return undefined;
  }

  /**
   * 面板里可选列表的高度：**必须显式给**。
   *
   * 面板是 `SheetSize.FIT_CONTENT`，`List` 不给高度就会塌成 0（与名册/时间表同一教训），
   * 这里按条数算并封顶 3 行，既够滚动又不至于把面板顶到很远。
   */
  private pkgListHeight(count: number): number {
    const rows: number = Math.min(count, 3);
    return rows * 56 + Math.max(0, rows - 1) * 8;
  }

  /** 交给系统"另存为"的文件名：路径分隔符与 Windows 非法字符一律换下划线 */
  private safeFileName(name: string): string {
    const base: string = name.trim().length === 0 ? '课表' : name.trim();
    const illegal: string[] = ['/', '\\', ':', '*', '?', '"', '<', '>', '|'];
    let out: string = base;
    for (let i = 0; i < illegal.length; i++) {
      out = out.split(illegal[i]).join('_');
    }
    return out;
  }

  /** 读用户选中的沙箱外文件（uri 不能直接给 readTextSync）。超限/空文件直接抛错由上层提示 */
  private readPickedBytes(uri: string, limitBytes: number, limitLabel: string): Uint8Array {
    const file: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
    try {
      const size: number = fileIo.statSync(file.fd).size;
      if (size <= 0) {
        throw new Error('文件是空的');
      }
      if (size > limitBytes) {
        throw new Error(`文件太大（超过 ${limitLabel}）`);
      }
      const buffer: ArrayBuffer = new ArrayBuffer(size);
      const read: number = fileIo.readSync(file.fd, buffer);
      return new Uint8Array(buffer, 0, read);
    } finally {
      fileIo.closeSync(file);
    }
  }

  /**
   * 导出课表分享包：`manifest.json`（权威）+ 课程清单表.xls + 作息节次表.xls + 说明.txt，
   * 压成一个 zip 后走系统"另存为"。
   *
   * 全部临时文件建在 `cacheDir` 下的独立目录里，**无论成败都在 finally 里清掉** ——
   * 这类"导出一次留一堆缓存"的垃圾没人会主动去清。
   */
  private async exportSchedulePackage(): Promise<void> {
    if (this.pkgBusy) {
      return;
    }
    const semester: Semester | undefined = this.semesterById(this.pkgSemesterId);
    if (semester === undefined) {
      this.notify('请先选择要导出的学期');
      return;
    }
    const repo: ScheduleRepository = ScheduleRepository.getInstance();
    this.pkgBusy = true;
    const workDir: string = `${this.context().cacheDir}/schedule_export_${new Date().getTime()}`;
    Logger.info(TAG, `导出课表包：学期=${semester.name}（${semester.id}）时间表=${this.pkgTemplateId}`);
    try {
      const template: ScheduleTemplate | undefined = await repo.loadTemplate(this.pkgTemplateId);
      if (template === undefined) {
        this.notify('选中的时间表已经不存在了，请重新选一张');
        return;
      }
      const courses: SemesterCourses = await repo.loadSemesterCourses(semester.id);

      ZipUtil.ensureDir(workDir);
      const manifestPath: string = `${workDir}/${ENTRY_MANIFEST}`;
      const coursePath: string = `${workDir}/课程清单表.xls`;
      const slotPath: string = `${workDir}/作息节次表.xls`;
      const readmePath: string = `${workDir}/${ENTRY_README}`;
      ZipUtil.writeText(manifestPath,
        SchedulePackage.manifestJson(semester, template, courses.teacher_courses));
      ZipUtil.writeBytes(coursePath, XlsWriter.build(
        SchedulePackage.courseRows(semester, template.name, courses.teacher_courses)));
      ZipUtil.writeBytes(slotPath, XlsWriter.build(SchedulePackage.templateRows(template)));
      ZipUtil.writeText(readmePath, SchedulePackage.readmeText(semester.name, template.name));

      const zipPath: string = `${workDir}/package.zip`;
      await ZipUtil.compress([manifestPath, coursePath, slotPath, readmePath], zipPath);
      const bytes: Uint8Array = ZipUtil.readBytes(zipPath);
      const uri: string = await this.savePickedFile(bytes,
        `知途课表_${this.safeFileName(semester.name)}_${DateUtil.toDateString(new Date())}.zip`);
      if (uri.length === 0) {
        this.notify('已取消导出');
      } else {
        this.notify(`已导出 zip 分享包（时间表：${template.name}）\n`
          + `${courses.countCourses()} 门课程 / ${courses.countPeriods()} 个时间段\n${uri}`);
      }
    } catch (e) {
      Logger.error(TAG, `导出课表包失败：${ScheduleRepository.describeError(e)}`);
      this.notify(`导出失败：${ScheduleRepository.describeError(e)}`);
    } finally {
      ZipUtil.removeTree(workDir);
      this.pkgBusy = false;
    }
  }

  /**
   * 下载一张 Excel 模板（`kind` = `course` / `template`）。
   *
   * 模板行由 `SchedulePackage` 生成 —— 与导入侧**共用同一批表头常量**，
   * 所以"模板里写什么"和"导入认什么"不会各改一半而悄悄漂移。
   */
  private async exportSheetTemplate(kind: string): Promise<void> {
    if (this.pkgBusy) {
      return;
    }
    this.pkgBusy = true;
    try {
      const isCourse: boolean = kind === 'course';
      const rows: string[][] = isCourse
        ? SchedulePackage.courseTemplateRows()
        : SchedulePackage.templateTemplateRows();
      const name: string = isCourse ? '知途_课程清单表_模板.xls' : '知途_作息节次表_模板.xls';
      const uri: string = await this.savePickedFile(XlsWriter.build(rows), name);
      if (uri.length === 0) {
        this.notify('已取消下载');
      } else {
        this.notify(`模板已保存：${uri}`);
      }
    } catch (e) {
      Logger.error(TAG, `导出模板失败：${ScheduleRepository.describeError(e)}`);
      this.notify(`导出模板失败：${ScheduleRepository.describeError(e)}`);
    } finally {
      this.pkgBusy = false;
    }
  }

  /**
   * 从一张 .xls 导入：先按**内容**认类型，再解析入库。
   *
   * 三种表头依次判：课程清单表（课程名称 + 星期）→ 作息节次表（开始时间 + 结束时间）
   * → 教务系统「教师个人课表」网格（≥3 个「星期X」且下方有 `[..]节` 痕迹，判据最宽故放最后）。
   */
  private async importScheduleFromExcel(): Promise<void> {
    if (this.pkgBusy) {
      return;
    }
    this.pkgBusy = true;
    try {
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['.xls'];
      const view: picker.DocumentViewPicker = new picker.DocumentViewPicker(this.context());
      const uris: string[] = await view.select(options);
      if (uris.length === 0) {
        this.notify('已取消选择文件');
        return;
      }
      const bytes: Uint8Array = this.readPickedBytes(uris[0], 8 * 1024 * 1024, '8 MB');
      const parsed: PackageParseResult = SchedulePackage.parseSheet(XlsReader.readFirstSheet(bytes));
      if (!parsed.ok || parsed.pkg === null) {
        this.notify(`导入失败：${parsed.message}`);
        return;
      }
      Logger.info(TAG, `Excel 导入：识别为 ${parsed.kind}（${parsed.pkg.summary()}）`);
      this.confirmImportPackage(parsed.pkg);
    } catch (e) {
      Logger.error(TAG, `Excel 导入失败：${ScheduleRepository.describeError(e)}`);
      this.notify(`导入失败：${ScheduleRepository.describeError(e)}`);
    } finally {
      this.pkgBusy = false;
    }
  }

  /**
   * 从 zip 分享包导入。
   *
   * 先把选中的 zip **拷进沙箱**再解压：文件选择器给的是 `file://docs/...` 这类 URI，
   * 而 `zlib` 要的是真实路径（`fileIo` 反而认得 URI，所以拷贝这一步用 fileIo 做）。
   */
  private async importScheduleFromZip(): Promise<void> {
    if (this.pkgBusy) {
      return;
    }
    this.pkgBusy = true;
    const workDir: string = ZipUtil.uniqueTempDir(this.context().cacheDir, 'schedule_import');
    try {
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['.zip'];
      const view: picker.DocumentViewPicker = new picker.DocumentViewPicker(this.context());
      const uris: string[] = await view.select(options);
      if (uris.length === 0) {
        this.notify('已取消选择文件');
        return;
      }
      ZipUtil.ensureDir(workDir);
      const zipPath: string = `${workDir}/package.zip`;
      ZipUtil.writeBytes(zipPath, this.readPickedBytes(uris[0], 32 * 1024 * 1024, '32 MB'));
      // 解压目标目录**必须先存在**（不然是 900002）：ZipUtil.decompress 会自己建好它
      const outDir: string = `${workDir}/unpacked`;
      await ZipUtil.decompress(zipPath, outDir);
      const names: string[] = ZipUtil.list(outDir);
      Logger.info(TAG, `zip 解压完成，包内条目：${names.join(', ')}`);
      if (names.length === 0) {
        this.notify('这个压缩包里没有文件');
        return;
      }
      const parsed: PackageParseResult = this.parseUnpackedDir(outDir, names);
      if (!parsed.ok || parsed.pkg === null) {
        this.notify(`导入失败：${parsed.message}`);
        return;
      }
      Logger.info(TAG, `zip 导入：识别为 ${parsed.kind}（${parsed.pkg.summary()}）`);
      this.confirmImportPackage(parsed.pkg);
    } catch (e) {
      const raw: string = ScheduleRepository.describeError(e);
      Logger.error(TAG, `zip 导入失败：${raw}`);
      this.notify(`导入失败：${raw}${this.zipErrorHint(raw)}`);
    } finally {
      ZipUtil.removeTree(workDir);
      this.pkgBusy = false;
    }
  }

  /**
   * 把 `zlib` 的原生报错翻成人话。
   *
   * 900002 是「解压目标目录不可用」（如今 `ZipUtil.decompress` 内部会先建目录，理论上不该再出现，
   * 留着是为了把真相写在屏幕上而不是让人猜）；导出、网盘下载、改名之后最可能撞上的是 900003。
   */
  private zipErrorHint(raw: string): string {
    if (raw.indexOf('900003') >= 0) {
      return '\n（这个文件不是完整可用的 zip 包：可能在传输、下载或改名时损坏了）';
    }
    if (raw.indexOf('900002') >= 0) {
      return '\n（解压目标目录不可用，请重试）';
    }
    if (raw.indexOf('900001') >= 0) {
      return '\n（压缩包读不到，请确认文件还在原位置）';
    }
    return '';
  }

  /**
   * 认包：**`manifest.json` 优先**（无损、权威），没有才退回按 .xls 猜。
   *
   * 为什么不让"包里的 xls"覆盖 manifest：两张 xls 只带得走"课程行"和"节次行"，
   * 带不走学期起始日 / 时间表时长这类元信息，混着读会出现"改了课表却把时间表弄丢"
   * 这种没法解释的状态。想在 Excel 里改课表，正确姿势是把那张 xls 单独拿去「Excel 文件导入」。
   */
  private parseUnpackedDir(outDir: string, names: string[]): PackageParseResult {
    const manifestName: string = this.findEntry(names, ENTRY_MANIFEST);
    if (manifestName.length > 0) {
      return SchedulePackage.parseManifest(ZipUtil.readText(`${outDir}/${manifestName}`));
    }
    const sheetName: string = this.pickSheetEntry(names);
    if (sheetName.length === 0) {
      return PackageParseResult.fail('这个压缩包里既没有 manifest.json，也没有 .xls 表格，认不出来。');
    }
    Logger.info(TAG, `包内没有 manifest.json，改按表格解析：${sheetName}`);
    return SchedulePackage.parseSheet(
      XlsReader.readFirstSheet(ZipUtil.readBytes(`${outDir}/${sheetName}`)));
  }

  /** 忽略大小写地在条目名里找目标文件；找不到返回空串 */
  private findEntry(names: string[], target: string): string {
    for (let i = 0; i < names.length; i++) {
      if (names[i].toLowerCase() === target.toLowerCase()) {
        return names[i];
      }
    }
    return '';
  }

  /** 挑一张 xls（优先名字里带"课程/课表"的，否则第一个 .xls） */
  private pickSheetEntry(names: string[]): string {
    let fallback: string = '';
    for (let i = 0; i < names.length; i++) {
      if (!names[i].toLowerCase().endsWith('.xls')) {
        continue;
      }
      if (names[i].indexOf('课程') >= 0 || names[i].indexOf('课表') >= 0) {
        return names[i];
      }
      if (fallback.length === 0) {
        fallback = names[i];
      }
    }
    return fallback;
  }

  /**
   * 导入前二次确认。
   *
   * 用 `AlertDialog`（独立窗口）而不是在面板里展开一块：面板是 `FIT_CONTENT`，
   * 内容高度一变内部点击就会命中旧布局（docs/04 §12.3.2 第 17 点）。
   */
  private confirmImportPackage(pkg: ImportedPackage): void {
    const kindLabel: string = pkg.createSemester ? '整个学期（含时间表）' : '一张时间表';
    AlertDialog.show({
      title: '确认导入',
      message: `即将导入${kindLabel}：\n${pkg.summary()}\n来源：${pkg.source}\n\n`
        + '导入是「新建」，不会覆盖或修改已有学期 / 时间表；同名的会自动加序号。',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '导入',
        action: () => {
          this.runPackageImport(pkg);
        }
      },
      secondaryButton: {
        value: '取消',
        action: () => {
        }
      }
    });
  }

  /** 真正落库：一个事务建时间表 + 学期 + 全部课程，成功后切到新学期并刷新整页 */
  private async runPackageImport(pkg: ImportedPackage): Promise<void> {
    if (this.pkgBusy) {
      return;
    }
    this.pkgBusy = true;
    Logger.info(TAG, `开始导入课表包：${pkg.summary().split('\n').join(' ')}`);
    try {
      const report: PackageImportReport =
        await ScheduleRepository.getInstance().importSchedulePackage(pkg);
      this.closeManageSheet();
      await this.refresh();
      this.notify(`导入完成\n${report.summary()}`);
    } catch (e) {
      Logger.error(TAG, `导入课表包失败：${ScheduleRepository.describeError(e)}`);
      this.notify(`导入失败：${ScheduleRepository.describeError(e)}`);
    } finally {
      this.pkgBusy = false;
    }
  }

  /** 「官网导入」占位：入口与文案先落地，等官网提供数据接口后再接 */
  private notifyOfficialImport(): void {
    this.notify('官网导入还没上线\n\n后续版本会支持用学校官网账号一键拉取课表；\n'
      + '目前可以先用「ZIP 压缩包导入」或「Excel 文件导入」。');
  }

  /** 导出面板：选学期 + 选时间表 → 导出 zip */
  @Builder
  manageExportView() {
    Column({ space: 10 }) {
      Text('选一个学期和它对应的时间表，导成一个 zip 分享包。')
        .fontSize(11)
        .fontColor('#9CA3AF')
        .width('100%')

      Text('学期')
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor('#111827')
        .width('100%')
      if (this.semesters.length === 0) {
        Text('还没有学期，先去「学期管理」新建一个')
          .fontSize(12)
          .fontColor('#9CA3AF')
          .width('100%')
          .padding({ top: 6, bottom: 6 })
      } else {
        List({ space: 8 }) {
          ForEach(this.semesters, (sem: Semester) => {
            ListItem() {
              Row({ space: 8 }) {
                Column({ space: 2 }) {
                  Text(sem.name)
                    .fontSize(14)
                    .fontColor('#111827')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(`${sem.total_weeks} 周 · 起始 ${sem.start_date.length > 0 ? sem.start_date : '未设置'}`
                    + `${sem.schedule_name.length > 0 ? ` · ${sem.schedule_name}` : ''}`)
                    .fontSize(11)
                    .fontColor('#9CA3AF')
                    .maxLines(1)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                Text(this.pkgSemesterId === sem.id ? '✓' : '')
                  .fontSize(13)
                  .fontColor('#FFFFFF')
                  .textAlign(TextAlign.Center)
                  .width(22)
                  .height(22)
                  .borderRadius(11)
                  .backgroundColor(this.pkgSemesterId === sem.id ? this.uiThemeColor : '#FFFFFF')
                  .border({
                    width: 1,
                    color: this.pkgSemesterId === sem.id ? this.uiThemeColor : '#D1D5DB'
                  })
              }
              .width('100%')
              .padding(10)
              .backgroundColor(this.pkgSemesterId === sem.id ? '#EFF6FF' : '#F9FAFB')
              .borderRadius(10)
              .onClick(() => {
                this.pkgSemesterId = sem.id;
                this.pkgTemplateId = this.templateIdOfSemester(sem.id);
              })
            }
          }, (sem: Semester) => `pkg-sem-${sem.id}-${this.pkgSemesterId === sem.id}`)
        }
        .width('100%')
        .height(this.pkgListHeight(this.semesters.length))
      }

      Text('时间表')
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor('#111827')
        .width('100%')
      if (this.templates.length === 0) {
        Text('还没有时间表')
          .fontSize(12)
          .fontColor('#9CA3AF')
          .width('100%')
          .padding({ top: 6, bottom: 6 })
      } else {
        List({ space: 8 }) {
          ForEach(this.templates, (tpl: ScheduleTemplate) => {
            ListItem() {
              Row({ space: 8 }) {
                Column({ space: 2 }) {
                  Text(tpl.name)
                    .fontSize(14)
                    .fontColor('#111827')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(`${tpl.class_sessions} 节 · 每节 ${tpl.duration_time} 分钟`
                    + `${tpl.is_builtin ? ' · 内置' : ''}`)
                    .fontSize(11)
                    .fontColor('#9CA3AF')
                    .maxLines(1)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                Text(this.pkgTemplateId === tpl.id ? '✓' : '')
                  .fontSize(13)
                  .fontColor('#FFFFFF')
                  .textAlign(TextAlign.Center)
                  .width(22)
                  .height(22)
                  .borderRadius(11)
                  .backgroundColor(this.pkgTemplateId === tpl.id ? this.uiThemeColor : '#FFFFFF')
                  .border({
                    width: 1,
                    color: this.pkgTemplateId === tpl.id ? this.uiThemeColor : '#D1D5DB'
                  })
              }
              .width('100%')
              .padding(10)
              .backgroundColor(this.pkgTemplateId === tpl.id ? '#EFF6FF' : '#F9FAFB')
              .borderRadius(10)
              .onClick(() => {
                this.pkgTemplateId = tpl.id;
              })
            }
          }, (tpl: ScheduleTemplate) => `pkg-tpl-${tpl.id}-${this.pkgTemplateId === tpl.id}`)
        }
        .width('100%')
        .height(this.pkgListHeight(this.templates.length))
      }

      Button(this.pkgBusy ? '正在打包…' : '导出为 ZIP 压缩包')
        .width('100%')
        .height(44)
        .fontSize(14)
        .fontColor('#FFFFFF')
        .backgroundColor(this.uiThemeColor)
        .enabled(!this.pkgBusy)
        .onClick(() => {
          this.exportSchedulePackage();
        })
    }
    .width('100%')
  }

  /** 导入面板：Excel / ZIP / 官网（占位）三个入口 */
  @Builder
  manageImportView() {
    Column({ space: 10 }) {
      Text('导入会新建学期 / 时间表，不会覆盖或修改已有数据；同名的会自动加序号。')
        .fontSize(11)
        .fontColor('#9CA3AF')
        .width('100%')

      this.importEntryRow('Excel 文件导入', '课程清单表 / 作息节次表，或教务系统导出的「教师个人课表」',
        '.xls', true, 'excel')
      this.importEntryRow('ZIP 压缩包导入', '本 App 导出的分享包',
        '.zip', true, 'zip')
      this.importEntryRow('从官网导入', '用学校官网账号一键拉取课表', '即将支持', false, 'official')

      Text('分享包里不含学生名单与签到记录：名单属于班级、跨学期共享，不在课表分享范围内。')
        .fontSize(11)
        .fontColor('#9CA3AF')
        .width('100%')
        .padding({ top: 4 })

      // 说明入口（面板最下方）：教务课表怎么导、两张 Excel 模板去哪拿
      Row({ space: 6 }) {
        Image($r('app.media.ic_help'))
          .width(16)
          .height(16)
          .fillColor(this.uiThemeColor)
        Text('导入说明 / 下载 Excel 模板')
          .fontSize(12)
          .fontColor(this.uiThemeColor)
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ top: 6, bottom: 2 })
      .onClick(() => {
        this.manageView = 'help';
      })
    }
    .width('100%')
  }

  /**
   * 导入入口行。
   *
   * 刻意**不把回调当参数传进 @Builder**（按值参数不参与状态观察，传进去的 lambda 不会内联），
   * 改为传一个 `kind` 字符串，在 onClick 里分支。
   */
  @Builder
  importEntryRow(title: string, subtitle: string, badge: string, enabled: boolean, kind: string) {
    Row({ space: 10 }) {
      Column({ space: 3 }) {
        Text(title)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(enabled ? '#111827' : '#9CA3AF')
        Text(subtitle)
          .fontSize(11)
          .fontColor('#9CA3AF')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Text(badge)
        .fontSize(10)
        .fontColor(enabled ? this.uiThemeColor : '#9CA3AF')
        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
        .borderRadius(4)
        .backgroundColor(enabled ? '#EFF6FF' : '#F3F4F6')
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#F9FAFB')
    .borderRadius(10)
    .opacity(enabled ? 1 : 0.7)
    .onClick(() => {
      if (kind === 'excel') {
        this.importScheduleFromExcel();
      } else if (kind === 'zip') {
        this.importScheduleFromZip();
      } else {
        this.notifyOfficialImport();
      }
    })
  }

  /**
   * 导入说明（导入面板最下方的 ⓘ 进来）。
   *
   * 为什么单独做成一个面板视图、而不是弹 AlertDialog：
   *  ① 这里的两个「下载模板」要真的触发系统"另存为"，AlertDialog 放不下动作按钮
   *     （`buttons` 数组不编译，`confirm` 只能有一个）；
   *  ② 面板视图沿用既有的高度模型（`FIT_CONTENT` + 一层 `Scroll`），不引入新的布局风险。
   */
  @Builder
  manageHelpView() {
    Column({ space: 10 }) {
      this.helpSection('① 别人分享的 zip 包',
        '直接选「ZIP 压缩包导入」。包里有学期、时间表、课程，一次全带过来。')

      this.helpSection('② 自己的课表，填 Excel',
        '两张表各管一件事：「作息节次表」说明每节课的起止时间（决定课表每天画几行）；'
          + '「课程清单表」一行一个时间段（课程名 / 星期 / 起止节次 / 教室 / 周次）。'
          + '两张表都能单独导入；与已有时间表重名会自动加序号。')

      this.helpSection('③ 教务系统导出的「教师个人课表」（推荐）',
        '在教务系统里导出教师课表后，直接选「Excel 文件导入」就行：App 会自动认出'
          + '「星期一…星期日」的网格，把每个格子里的 课程名 / 周次 / 教室[节次]节 / 班级:人数 逐项拆开，'
          + '并按大节钟点推出作息节次表 —— 不需要手工整理成模板。'
          + '（只认 .xls 老格式；如果教务导出的是 .xlsx，请先用 Excel / WPS 另存为 .xls。）')

      Button('下载「课程清单表」模板')
        .width('100%')
        .height(44)
        .fontSize(14)
        .fontColor('#FFFFFF')
        .backgroundColor(this.uiThemeColor)
        .onClick(() => {
          this.exportSheetTemplate('course');
        })

      Button('下载「作息节次表」模板')
        .width('100%')
        .height(44)
        .fontSize(14)
        .fontColor('#FFFFFF')
        .backgroundColor(this.uiThemeColor)
        .onClick(() => {
          this.exportSheetTemplate('template');
        })

      Text('模板里带一行示例，照着填即可；列的先后顺序可以随意调整，App 按表头名认列。')
        .fontSize(11)
        .fontColor('#9CA3AF')
        .width('100%')
        .padding({ top: 2 })
    }
    .width('100%')
  }

  /** 说明段落：小标题 + 正文（正文自动换行，不做截断） */
  @Builder
  helpSection(title: string, body: string) {
    Column({ space: 3 }) {
      Text(title)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor('#111827')
        .width('100%')
      Text(body)
        .fontSize(11)
        .fontColor('#6B7280')
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // ---------------------------------------------------------------- 拾色器（界面颜色）

  /**
   * 全屏拾色器：半透明遮罩 + 底部面板。
   *
   * 与课程编辑页的拾色器同一套交互：
   *  方形区域（饱和度 × 明度，点/拖即取色）+ 色相条 + 透明度条 + HEX 输入，
   *  最终落库格式为 8 位 `#AARRGGBB`。
   */
  @Builder
  uiColorPickerOverlay() {
    Column() {
      Column()
        .width('100%')
        .layoutWeight(1)
        .backgroundColor('rgba(0,0,0,0.4)')
        .onClick(() => {
          this.cancelUiColor();
        })

      Column({ space: 16 }) {
        Row() {
          Text(this.pickerTitle())
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor('#111827')
            .layoutWeight(1)
          Text('✕')
            .fontSize(20)
            .fontColor('#6B7280')
            .onClick(() => {
              this.cancelUiColor();
            })
        }
        .width('100%')

        // 当前色预览 + HEX（8 位 ARGB）
        Row({ space: 12 }) {
          Column()
            .width(42)
            .height(42)
            .backgroundColor(this.pickerARGB())
            .borderRadius(21)
            .border({ width: 1, color: '#E5E7EB' })
          TextInput({ text: this.pickerARGB() })
            .fontSize(14)
            .height(42)
            .backgroundColor('#F3F4F6')
            .layoutWeight(1)
            .textAlign(TextAlign.Start)
            .padding({ left: 8, right: 8 })
            .onChange((value: string) => this.onPickerHexInput(value))
        }
        .width('100%')

        // 饱和度 × 明度 方形区域
        Stack() {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(hueColor(this.pickerHue))
          Column()
            .width('100%')
            .height('100%')
            .linearGradient({
              angle: 90,
              colors: [['#FFFFFF', 0], ['rgba(255,255,255,0)', 1]]
            })
          Column()
            .width('100%')
            .height('100%')
            .linearGradient({
              angle: 180,
              colors: [['rgba(0,0,0,0)', 0], ['#000000', 1]]
            })
          // 选择点：同心圆（外黑内白），中心透出底色
          Column() {
            Column() {
            }
            .width(12)
            .height(12)
            .borderRadius(6)
            .border({ width: 2, color: '#FFFFFF' })
          }
          .width(18)
          .height(18)
          .borderRadius(9)
          .border({ width: 2, color: '#000000' })
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .position({
            x: this.pickerSaturation * this.pickerBoxSize - 9,
            y: (1 - this.pickerValue) * this.pickerBoxSize - 9
          })
        }
        .width(this.pickerBoxSize)
        .height(this.pickerBoxSize)
        .clip(true)
        .borderRadius(8)
        .onTouch((event: TouchEvent) => this.onColorBoxTouch(event))

        // 色相条
        Column({ space: 6 }) {
          Text('色相').fontSize(12).fontColor('#6B7280').width('100%')
          Stack() {
            Column()
              .width('100%')
              .height(20)
              .borderRadius(10)
              .linearGradient({
                angle: 90,
                colors: [
                  ['#FF0000', 0],
                  ['#FFFF00', 0.17],
                  ['#00FF00', 0.33],
                  ['#00FFFF', 0.5],
                  ['#0000FF', 0.67],
                  ['#FF00FF', 0.83],
                  ['#FF0000', 1]
                ]
              })
            Column() {
              Column() {
              }
              .width(12)
              .height(12)
              .borderRadius(6)
              .border({ width: 2, color: '#FFFFFF' })
            }
            .width(16)
            .height(16)
            .borderRadius(8)
            .border({ width: 2, color: '#111827' })
            .position({
              x: (this.pickerHue / 360) * this.pickerBoxSize - 8,
              y: 2
            })
          }
          .width(this.pickerBoxSize)
          .height(20)
          .onTouch((event: TouchEvent) => this.onHueTouch(event))
        }

        // 透明度条：只改 A 通道
        Column({ space: 6 }) {
          Text('透明度').fontSize(12).fontColor('#6B7280').width('100%')
          Stack() {
            Column()
              .width('100%')
              .height(20)
              .borderRadius(10)
              .linearGradient({
                angle: 90,
                colors: [['#FFFFFF', 0], [this.pickerHex(), 1]]
              })
            Column() {
              Column() {
              }
              .width(12)
              .height(12)
              .borderRadius(6)
              .border({ width: 2, color: '#FFFFFF' })
            }
            .width(16)
            .height(16)
            .borderRadius(8)
            .backgroundColor(this.pickerARGB())
            .border({ width: 2, color: '#111827' })
            .shadow({ radius: 2, color: 'rgba(0,0,0,0.3)' })
            .position({
              x: this.pickerAlpha * this.pickerBoxSize - 8,
              y: 2
            })
          }
          .width(this.pickerBoxSize)
          .height(20)
          .onTouch((event: TouchEvent) => this.onAlphaTouch(event))
        }

        Button('确定')
          .fontSize(15)
          .width('100%')
          .height(46)
          .backgroundColor(this.uiThemeColor)
          .onClick(() => this.confirmUiColor())
      }
      .width('100%')
      .padding(20)
      .backgroundColor('#FFFFFF')
      .borderRadius({ topLeft: 16, topRight: 16 })
    }
    .width('100%')
    .height('100%')
  }

  build() {
    Stack() {
      Column() {
        if (this.showOwnerSetup) {
          Column({ space: 12 }) {
            // 操作反馈统一走 AlertDialog（notify），此处不再持久展示 message
            this.ownerSetupCard()
          }
          .justifyContent(FlexAlign.Center)
          .layoutWeight(1)
          .width('100%')
          .padding({ left: 20, right: 20 })
          .backgroundColor(PAGE_BG_COLOR)
        } else {
          this.tabContent()
        }
      }
      .width('100%')
      .height('100%')

      // 界面颜色拾色器：盖在整个页面（含底部导航）之上
      if (this.showUiColorPicker) {
        this.uiColorPickerOverlay()
      }
    }
    .width('100%')
    .height('100%')
  }
}
