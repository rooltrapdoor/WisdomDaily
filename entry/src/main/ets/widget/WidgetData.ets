import { common } from '@kit.AbilityKit';
import { formBindingData, formInfo } from '@kit.FormKit';
import { DateUtil } from '../common/DateUtil';
import { Logger } from '../common/Logger';
import { TODAY_COLOR_DEFAULT, errText, colorOr, isDbLocked } from '../common/Util';
import { ScheduleDb } from '../db/ScheduleDb';
import { LessonRow } from '../model/Rows';
import { Semester } from '../model/Semester';
import { ScheduleSlot, ScheduleTemplate } from '../model/ScheduleTemplate';
import { ScheduleRepository, Workspace } from '../repository/ScheduleRepository';

const TAG: string = 'WidgetData';
const MS_PER_DAY: number = 24 * 60 * 60 * 1000;
/**
 * 卡片最多显示两节课（两种尺寸都一样）。
 *
 * 尺寸按官方设计规范：**小卡片 2\*2 = 150×150 vp，中卡片 2\*4 = 316×150 vp** ——
 * 两者**同高**，2\*4 只是两倍宽。所以"2\*4 更高、能塞四节"是错的：
 * 早先给 2\*4 排四行，高度没变而行数翻倍，每组课程只剩一半高度，
 * 小字号互相压字、读出来就是错的。收到两行后两种尺寸都从容。
 * 多出来的课去应用里看。
 */
const ROW_LIMIT: number = 2;
/** 22 点之后视为"第二天"，显示次日课程 */
const NEXT_DAY_HOUR: number = 22;
const COLOR_FALLBACK: string = '#FF1890FF';
/**
 * 「今天没课啦」那句话 —— **只在"当天的课一节都不剩"时出现**（2026-09-23 起）：
 *
 *  1. 当天本来就没课；
 *  2. 当天的课全上完了。
 *
 * 两者对用户是同一件事（今天不用上课了），共用这一句，成因只写进 `WSD_WidgetData` 日志。
 * **"只剩最后一节课"不再补这句话**（原先补在第二格）：卡片上还挂着课，
 * 底下写"今天没课啦"本来就自相矛盾；只剩一节课时第二格**留白**即可 ——
 * 那一格在卡片页照样占位，课程块不会被拉满（见 `WidgetCard.blankCell()`）。
 *
 * 窄卡（2\*2）只有 150 vp 宽，一行的 `今天没课啦ヽ(*≧ω≦)ﾉ` 会挤，按需求在颜文字前**换行**
 * （用 `\n` 定死，不靠自动折行 —— 自动折行会按容器宽度随时变位置）。
 */
const NOTE_NO_MORE: string = '今天没课啦ヽ(*≧ω≦)ﾉ';
const NOTE_NO_MORE_NARROW: string = '今天没课啦\nヽ(*≧ω≦)ﾉ';

/**
 * 卡片绑定数据。
 *
 * 字段名**必须**与 `widget/pages/WidgetCard.ets` 里 `@LocalStorageProp('x')` 的 key 逐字一致 ——
 * 动态卡片就是靠 `updateForm` 推过来的这组键值去更新卡片页的 LocalStorage 的。
 * 只用基本类型：卡片与提供方是两个进程，复杂对象过不去。
 *
 * `rowNPeriod` / `weekNo` / `weekday` 是"点卡片跳进应用"的定位键：
 *  - 点**某一行课程** → 带上 `rowNPeriod`，应用侧凭 `时间段 + 周次` 打开这一课次的详情；
 *  - 点**空态卡片** → 不带 `rowNPeriod`（只有 `weekNo`），应用侧把课表切到那一周。
 */
export interface WidgetBinding {
  /**
   * 顶部左：`今天 · 周三` / `明天 · 周四`；**没开「提醒第二天的课」时只有 `周三`**。
   *
   * 这个"今天/明天"与卡片"22 点切次日"是同一件事：用户没要"提前知道明天"，
   * 卡片就整天只说今天，标题里也不必写"今天"（永远都是今天的卡，标"今天"是废话）。
   * 判据在提供方一处算好：`app_setting.notify_next_day && 当前钟点 >= 22`。
   */
  titleText: string;
  /** 顶部右：`第 3 周`（学期外为空；**窄卡 2\*2 不渲染这一格** —— 150 vp 挤不下，见 `WidgetCard.build()`） */
  weekText: string;
  /**
   * 课程数徽标：`剩 2 节`（今天 —— **还没上完**的）/ `共 3 节`（明天 —— 当天**全部**）；
   * 当天一节都不剩时给空串（空态那句《今天没课啦》已经说清了，再写"剩 0 节"是啰嗦）。
   *
   * 与 `rowCount`（卡片实际渲染几格）**不是一回事**：卡片固定最多两格，
   * "后面还有几节"只有这个数字说得清。两种尺寸都渲染它 —— 窄卡砍掉周数、独留这一格。
   * 口径只由 `WidgetData.countLabel()` 一处定，写反了页面上只是数字小一点、不会报错。
   */
  countText: string;
  /**
   * 课程数徽标的颜色（ARGB 字符串）：与应用里"今天"日期徽标**同一个高亮色**
   * （`app_setting.today_color`，默认 `TODAY_COLOR_DEFAULT`）。
   *
   * 卡片进程读不到 `app_setting`，所以颜色必须随数据一起推过来 ——
   * 与 `rowNColor` 同一个道理，卡片页只管用它染色。
   */
  countColor: string;
  /**
   * 空态文案（一节课都没有时显示在中间）。
   *
   * "今天已无课"给 `今天没课啦ヽ(*≧ω≦)ﾉ`（窄卡换行版）；而**环境类**空态 ——
   * `还没有学期` / `学期还没开始|已结束` / `还没选择教师` / `数据忙，稍后自动刷新` /
   * `打开应用后可用` / `数据读取失败` —— 仍逐条分开：那是"配置没到位"，
   * 用户要据此去改设置，合并成一句就等于把故障藏起来。
   */
  emptyText: string;
  /** 有课的条数（0 ~ 2，卡片最多两行） */
  rowCount: number;
  /**
   * 是不是**宽卡**（2\*4）：1 = 宽卡，0 = 小卡（2\*2）。
   *
   * 两种尺寸同高（150 vp）但宽度差一倍（316 vs 150），能塞下的信息量不同，
   * 而卡片页跑在独立进程、拿不到自己的尺寸，所以由提供方按登记簿里的尺寸算好后推过来。
   * 卡片页据此选"窄卡竖排两行"还是"宽卡横排两行"两套版式。
   */
  cardWide: number;
  /** 目标日所在周次（点卡片跳转时用于定位；0 = 算不出周次，如"还没有学期""学期已结束"） */
  weekNo: number;
  /** 目标日星期 1~7（0 = 无） */
  weekday: number;
  /** 课程名；宽卡（2\*4）在名字后接课程类型，如 `数字信号处理（理论）` */
  row1Course: string;
  /**
   * 上课**开始**钟点，如 `08:00`（窄卡第二行的上半行）。
   *
   * 窄卡只有 150 vp 宽，`08:00-09:40` 再加 `@教室` 一行放不下（钟点会被截成 `10:55-1…`），
   * 所以窄卡把钟点**拆成上下两行**：上面开始、下面结束，右边才是教室。
   * 作息模板缺失时退回节次（`第1-2节`），不留空串。
   */
  row1Start: string;
  /** 上课**结束**钟点，如 `09:40`（窄卡第二行的下半行；模板缺失时为空串，那一行不渲染） */
  row1End: string;
  /**
   * 上课时间（**合体写法，只有宽卡渲染**）。
   *
   * 窄卡（2\*2）给钟点 `08:00-09:40`，但窄卡改用 `rowNStart` / `rowNEnd` 分两行渲染，
   * 这一格它不引用；宽卡（2\*4）给全 `第1-2节 · 08:00-09:40`。
   * 作息模板缺失时退回节次，不留空串。
   */
  row1Meta: string;
  /**
   * 第二行右段的**上半**（**不收缩**）：教室。
   *
   * 窄卡（2\*2）只给 `@教室` —— 人数不再挤在它后面（窄了会被省略号吃掉半截），
   * 而是另占 `rowNPeople`，挂在教室**下面一行**，与左边"开始/结束"两行对称；
   * 宽卡（2\*4）给 `@教室 · N人`，与应用里的课程块口径一致，N 为 0 时只剩教室。
   */
  row1Place: string;
  /**
   * 班级登记人数，如 `45人`（**窄卡渲染在教室下面一行**）。
   *
   * 宽卡也装着这一格，但它的第二行右段已把人数并进 `rowNPlace`（`@教室 · 45人`），故不单独渲染 ——
   * 与 `rowNClass` 同一条规矩：**数据装全、按版式决定渲染哪几格**，卡片页不做字符串拼接。
   * 口径与课表页格子、课程详情一致（`class_group.population`）；为 0 时给空串，不显示光秃秃的"0人"。
   */
  row1People: string;
  /** 班级名（**只有宽卡渲染**：与课程名同行靠右、不收缩；窄卡两行放不下，只留给宽卡） */
  row1Class: string;
  row1Color: string;
  row1Period: string;
  row2Course: string;
  /** 第二节课的开始钟点（窄卡第二行上半行；语义同 `row1Start`） */
  row2Start: string;
  /** 第二节课的结束钟点（窄卡第二行下半行；语义同 `row1End`） */
  row2End: string;
  row2Meta: string;
  row2Place: string;
  /** 第二节课的班级人数（窄卡渲染在教室下面一行；语义同 `row1People`） */
  row2People: string;
  row2Class: string;
  row2Color: string;
  row2Period: string;
}

/**
 * 卡片数据装配。
 *
 * 为什么放在提供方（Extension）算：卡片页跑在卡片进程，不能读数据库；
 * 提供方在 `onAddForm` / `onUpdateForm` 时查库，把结果压成一组字符串推给卡片。
 *
 * 取数口径与课表页一致：**当前学期 + 当前教师**（都取自 app_setting 的指针），
 * 目标日落在学期外时不做周次夹紧（`getWeekNumber` 会夹到首/末周，会把"假期"显示成有课），
 * 而是直接给空态。
 */
export class WidgetData {
  /**
   * 卡片尺寸 → 显示几节课。
   *
   * 两种尺寸现在都显示两节（见 `ROW_LIMIT` 的说明），保留这个函数是因为
   * "行数由提供方算好推给卡片页"这条链路要留着：卡片页跑在独立进程里、
   * 拿不到自己的尺寸，将来若再按尺寸分化，只改这里即可。
   */
  static rowsOfDimension(dimension: number): number {
    return ROW_LIMIT;
  }

  /**
   * 卡片尺寸 → 是不是宽卡（2\*4）。
   *
   * `FormDimension` 里 `Dimension_2_2 = 2`、`Dimension_2_4 = 3`；
   * 老格式登记（尺寸为 0）按小卡处理，即退化成最保守的版式。
   */
  static isWideDimension(dimension: number): boolean {
    return dimension === formInfo.FormDimension.Dimension_2_4;
  }

  /**
   * 「今天没课啦」按尺寸取一句话：窄卡给换行版（150 vp 挤不下一行），宽卡给一行版。
   *
   * 只有**空态**走这里（当天本来就没课 / 当天的课全上完了）—— 同一件事必须是同一句话，
   * 所以宁可多一个方法，也不在两处各写一次三元表达式（那样迟早只改一处）。
   */
  private static noMoreText(wide: boolean): string {
    return wide ? NOTE_NO_MORE : NOTE_NO_MORE_NARROW;
  }

  /**
   * 课程数徽标的文本 —— **口径只在这里定**：今天报"还剩几节"，明天报"当天一共几节"。
   *
   * 两个数字来自**不同集合**，不能混用：
   *  - 今天（`ofDay`）只算**还没上完**的课 —— 上午上完的那两节不该再算进"还剩几节"；
   *  - 明天（`allOfDay`）整天都还没到，报"当天全部"才是用户要的（提前知道要上几节）。
   *
   * 写反了页面上只是数字小一点 / 大一点，**编译器一句都不会说**，所以单独成一个纯函数，
   * 由 `widgetcheck.py` 钉住这三行。
   *
   * 当天一节都不剩时给**空串**（不是"剩 0 节"）：那时候卡片上已经写着《今天没课啦》，
   * 再标一个 0 是重复；这与课表里"人数为 0 就不显示光秃秃的 0人"是同一条规矩。
   */
  private static countLabel(toTomorrow: boolean, allOfDay: number, ofDay: number): string {
    const n: number = toTomorrow ? allOfDay : ofDay;
    return n > 0 ? (toTomorrow ? `共 ${n} 节` : `剩 ${n} 节`) : '';
  }

  /**
   * 卡片首次创建 / 定时刷新 / 应用主动推送都走它。
   *
   * @param dimension   这张卡片的尺寸（`FormDimension`）。行数由 `rowsOfDimension` 算，
   *                    "窄卡 / 宽卡"两套版式由 `isWideDimension` 定。
   * @param allowWrites 这次装配需不需要写权限。
   *                    `EntryFormAbility`（卡片进程）传 `false` —— 卡片只读数据，
   *                    绝不去写库：应用与卡片是两个进程，两边都写就是跨进程抢写锁
   *                    （`14800024` database file is locked），会把应用界面打成"课表加载失败"。
   *                    `WidgetUpdater`（应用进程）传 `true`。
   */
  static async build(context: common.Context, dimension: number,
    allowWrites: boolean = true): Promise<formBindingData.FormBindingData> {
    try {
      const binding: WidgetBinding = await WidgetData.compute(context, dimension, allowWrites);
      return formBindingData.createFormBindingData(binding);
    } catch (e) {
      Logger.error(TAG, `卡片数据装配失败：${errText(e)}`);
      const failed: WidgetBinding = WidgetData.empty();
      failed.titleText = '每日知途';
      failed.cardWide = WidgetData.isWideDimension(dimension) ? 1 : 0;
      // 三种失败分开说话：卡片上写清原因，用户知道是"等一下"还是"去应用里看看"，
      // 而不是面对一句无解的"数据读取失败"
      if (isDbLocked(e)) {
        failed.emptyText = '数据忙，稍后自动刷新';
      } else if (ScheduleDb.isNotReady(e)) {
        failed.emptyText = '打开应用后可用';
      } else {
        failed.emptyText = '数据读取失败';
      }
      return formBindingData.createFormBindingData(failed);
    }
  }

  /** 卡片刚创建时先给一张"正在加载"，查库完成后由 updateForm 覆盖 */
  static placeholder(dimension: number): WidgetBinding {
    const binding: WidgetBinding = WidgetData.empty();
    binding.titleText = '每日知途';
    binding.cardWide = WidgetData.isWideDimension(dimension) ? 1 : 0;
    binding.emptyText = '正在加载…';
    return binding;
  }

  static empty(): WidgetBinding {
    const binding: WidgetBinding = {
      titleText: '', weekText: '', countText: '', countColor: TODAY_COLOR_DEFAULT,
      emptyText: '', rowCount: 0, cardWide: 0, weekNo: 0, weekday: 0,
      row1Course: '', row1Start: '', row1End: '', row1Meta: '', row1Place: '', row1People: '', row1Class: '',
      row1Color: COLOR_FALLBACK, row1Period: '',
      row2Course: '', row2Start: '', row2End: '', row2Meta: '', row2Place: '', row2People: '', row2Class: '',
      row2Color: COLOR_FALLBACK, row2Period: ''
    };
    return binding;
  }

  private static async compute(context: common.Context, dimension: number,
    allowWrites: boolean): Promise<WidgetBinding> {
    const wide: boolean = WidgetData.isWideDimension(dimension);
    const repo: ScheduleRepository = ScheduleRepository.getInstance();
    // 卡片进程传 allowWrites=false：只打开连接读数据，播种 / 自愈等写路径一概不走
    await repo.init(context, allowWrites);
    const space: Workspace = await repo.loadWorkspace();

    const now: Date = new Date();
    // 「22 点切次日」只在用户开了「提醒第二天的课」时才有意义 —— 那个开关要的正是
    // "今晚提前知道明天有课"，卡片跟着它切；关掉之后卡片**整天只说今天**：
    // 标题不写"今天/明天"（永远都是今天的卡，标"今天"是废话），晚上没课就照实说"今天没课啦"。
    // 提醒设置与卡片口径必须一致，否则会出现"22 点后卡片列着明天的课、标题却只剩星期"。
    const notifyNextDay: boolean = space.setting.notify_next_day;
    const toTomorrow: boolean = notifyNextDay && now.getHours() >= NEXT_DAY_HOUR;
    const target: Date = new Date(now.getFullYear(), now.getMonth(),
      now.getDate() + (toTomorrow ? 1 : 0));
    const dayLabel: string = toTomorrow ? '明天' : '今天';
    const weekdayName: string = DateUtil.weekdayLabel(DateUtil.toDbWeekday(target.getDay()));

    const binding: WidgetBinding = WidgetData.empty();
    binding.cardWide = wide ? 1 : 0;
    // 课程数徽标吃用户配置的"今天"高亮色（卡片进程读不到 app_setting，颜色得随数据过来）
    binding.countColor = colorOr(space.setting.today_color, TODAY_COLOR_DEFAULT);
    binding.titleText = notifyNextDay ? `${dayLabel} · ${weekdayName}` : weekdayName;

    const semester: Semester | undefined = WidgetData.findSemester(space, space.setting.semester_id);
    if (semester === undefined) {
      binding.emptyText = '还没有学期';
      return binding;
    }

    // 目标日是否落在学期内：以"第 1 周周一"为锚点，最后一天 = 第 totalWeeks 周的周日
    const startDate: Date = semester.startDate();
    const firstMonday: number = DateUtil.weekMonday(startDate).getTime();
    const lastDay: number = firstMonday + semester.total_weeks * 7 * MS_PER_DAY - MS_PER_DAY;
    if (target.getTime() < firstMonday) {
      binding.emptyText = '学期还没开始';
      return binding;
    }
    if (target.getTime() > lastDay) {
      binding.emptyText = '学期已结束';
      return binding;
    }

    const week: number = DateUtil.getWeekNumber(startDate, target, semester.total_weeks);
    binding.weekText = `第 ${week} 周`;

    // 目标日在这一周里的两个坐标（周次 + 星期），**一算出来就写进契约**，
    // 不再是"有课才写"：空态下点卡片虽然不打开某节课，但要让应用里的课表落到
    // **卡片显示的那一周**（见 `WidgetCard.openHome()` / `Index.openTimetableFromCard`）。
    // 22 点后卡片说的是明天，跨周时这里自然就是下一周。
    binding.weekNo = week;
    const weekday: number = DateUtil.toDbWeekday(target.getDay());
    binding.weekday = weekday;

    const teacherId: number = space.setting.teacher_id;
    if (teacherId <= 0) {
      binding.emptyText = '还没选择教师';
      return binding;
    }

    const lessonRows: LessonRow[] = await repo.loadWeekLessons(semester.id, teacherId, week);
    const allOfDay: LessonRow[] = [];
    for (let i = 0; i < lessonRows.length; i++) {
      if (lessonRows[i].weekday === weekday) {
        allOfDay.push(lessonRows[i]);
      }
    }
    if (allOfDay.length === 0) {
      // 空态对用户只说一句友好的话，到底是"本来就没课"还是"全都上完了"只在日志里区分
      // （同一件事在卡片上不该有两种说法）。窄卡放不下一行，用换行版。
      binding.emptyText = toTomorrow ? '明天没有课^-^' : WidgetData.noMoreText(wide);
      Logger.info(TAG, `卡片空态：${dayLabel}${dayLabel === '今天' ? '本来就无课' : '无课'}`);
      return binding;
    }
    allOfDay.sort((a: LessonRow, b: LessonRow) => {
      if (a.start_time !== b.start_time) {
        return a.start_time - b.start_time;
      }
      return a.end_time - b.end_time;
    });

    const slots: ScheduleSlot[] = WidgetData.slotsOf(space, semester);
    // 「今天」只留**还没上完**的课。
    // 22 点前卡片常年显示"今天"，如果把上午已经上完的课也摊在上面，
    // 卡片就成了一份过期课表 —— 用户扫一眼看到的是"已经不存在的安排"。
    // 判据取**课程结束钟点 > 当前钟点**（不是开始钟点）：正在上的那节要留着，
    // 用户恰恰在这时候最需要确认"这节课在哪间教室"。
    // 作息模板缺失时 `endMinutesOf` 返回 -1，此时一律保留：宁可多显示一节，也不算错。
    const nowMinutes: number = now.getHours() * 60 + now.getMinutes();
    const ofDay: LessonRow[] = [];
    for (let i = 0; i < allOfDay.length; i++) {
      const endMinutes: number = WidgetData.endMinutesOf(allOfDay[i], slots);
      if (toTomorrow || endMinutes < 0 || endMinutes > nowMinutes) {
        ofDay.push(allOfDay[i]);
      }
    }
    if (ofDay.length === 0) {
      binding.emptyText = WidgetData.noMoreText(wide);
      Logger.info(TAG, `卡片空态：今天 ${allOfDay.length} 节课全部已上完（当前 ${nowMinutes} 分）`);
      return binding;
    }

    // 课程数徽标：今天报"还剩几节"、明天报"当天一共几节"。口径只在 `countLabel()` 一处定，
    // 两个数字来自不同集合（`allOfDay` / `ofDay`），写反了页面上只是数字小一点、不会报错。
    binding.countText = WidgetData.countLabel(toTomorrow, allOfDay.length, ofDay.length);

    const limit: number = WidgetData.rowsOfDimension(dimension);
    const count: number = ofDay.length < limit ? ofDay.length : limit;
    for (let i = 0; i < count; i++) {
      WidgetData.fillRow(binding, i, ofDay[i], slots, wide);
    }
    binding.rowCount = count;
    // 只剩一节课时**不再补文案**（用户 2026-09-23 定）：第二格留白。
    // 那一格在卡片页照样占位（`WidgetCard.blankCell()` 是空 Column + layoutWeight(1)），
    // 缺了它课程块会被拉满整张卡、又高又空 —— 那是真机上"数据没装配对"的样子。
    Logger.info(TAG, `卡片数据：${binding.titleText} ${binding.weekText} ${binding.countText}，${count} 节`
      + `（上限 ${limit}，当天未上 ${ofDay.length} 节 / 共 ${allOfDay.length} 节，`
      + `${wide ? '宽卡 2*4' : '小卡 2*2'}）`);
    return binding;
  }

  /**
   * 第 0 行 → row1*，第 1 行 → row2*（卡片固定两行）。
   *
   * 同一份课程数据在这里按**卡片宽度**装成两种内容，卡片页只管照单渲染：
   *
   * | 字段 | 小卡 2\*2（150 vp 宽） | 宽卡 2\*4（316 vp 宽） |
   * |---|---|---|
   * | `rowNCourse` | 课程名 | 课程名**（课程类型）**，如 `数字信号处理（理论）` |
   * | `rowNStart`  | `08:00`（第二行**上半行**） | 同左（宽卡不引用这一格） |
   * | `rowNEnd`    | `09:40`（第二行**下半行**） | 同左（宽卡不引用这一格） |
   * | `rowNMeta`   | `08:00-09:40`（窄卡也不引用这一格） | `第1-2节 · 08:00-09:40` |
   * | `rowNPlace`  | `@A101`（第二行**右上**） | `@A101 · 45人`（人数已并进来） |
   * | `rowNPeople` | `45人`（第二行**右下**，挂在教室下面） | 同左，但宽卡不渲染（人数已并进 `rowNPlace`） |
   * | `rowNClass`  | 装上但**窄卡不渲染**（两行放不下） | 与课程名同行 |
   *
   * 窄卡的"第二行"其实是**左右各两行的四宫格**：左边钟点上下排（上=开始 / 下=结束）、
   * 右边教室上下排（上 `@教室` / 下 `N人`）。把钟点合体写成一行 `08:00-09:40`
   * 再加 `@教室 · N人`，150 vp 一格真放不下（真机上被截成 `10:55-1…`，"几点下课"就没了）；
   * 拆成两行两列后每格最多 5 个字符，宽度绰绰有余，**一个省略号都用不上**。
   * 宽卡的口径与应用里的课程块一致（课程名 / 班级 / 教室 / 人数），只是多了节次与钟点。
   */
  private static fillRow(binding: WidgetBinding, index: number, lesson: LessonRow,
    slots: ScheduleSlot[], wide: boolean): void {
    const sessionText: string = lesson.start_time === lesson.end_time
      ? `第${lesson.start_time}节` : `第${lesson.start_time}-${lesson.end_time}节`;
    const clock: string = WidgetData.clockRange(lesson, slots);
    // 窄卡只留钟点：150 vp 宽的一行里"第1-2节 · "这 7 个字就吃掉近一半宽度，
    // 而用户扫卡片想知道的是"几点上"。作息模板缺失（clock 为空）时退回节次，不留空串。
    let meta: string = clock;
    if (wide) {
      meta = clock.length > 0 ? `${sessionText} · ${clock}` : sessionText;
    } else if (meta.length === 0) {
      meta = sessionText;
    }

    // 窄卡的第二行还要再拆成上下两行：上面开始钟点、下面结束钟点。
    // `08:00-09:40` 后面还得跟一个 `@教室`，150 vp 一行真放不下 —— 真机上钟点会被
    // 截成 `10:55-1…`，"几点下课"等于丢了，而"几点下课"正是桌面场景要看的第二件事。
    // 竖排两行后每行只有 5 个字符，宽度绰绰有余。
    // 作息模板缺失（clock 为空 → 拆不出两段）时上半行退回节次、下半行留空（不渲染）。
    const clockParts: string[] = clock.length > 0 ? clock.split('-') : [];
    const startText: string = clockParts.length === 2 ? clockParts[0] : sessionText;
    const endText: string = clockParts.length === 2 ? clockParts[1] : '';

    // 教室 / 人数：口径与课表页格子（`Index.ets` 的 `${lesson.population}人`）、
    // 课程详情（`${class_name} · ${population}人`）一致，都取 `class_group.population`（登记人数）；
    // 为 0 时不给值，避免出现光秃秃的"0人"。
    // 两者**分成两格**（`rowNPlace` / `rowNPeople`），而不是在卡片页拼字符串：
    // 窄卡把人数放在教室**下面一行**（150 vp 宽里挤进同一行必被省略号吃掉半截，
    // 而"几个人"恰是教室后面最容易丢的那个信息），宽卡两倍宽、人数并进 `rowNPlace`。
    // 拼接属于"装配"，装配只在这一个函数里做 —— 卡片页拿到的都是可以直接显示的字面量。
    let place: string = lesson.class_room.length > 0 ? `@${lesson.class_room}` : '';
    const people: string = lesson.population > 0 ? `${lesson.population}人` : '';
    if (wide && people.length > 0) {
      place = place.length > 0 ? `${place} · ${people}` : people;
    }

    const color: string = colorOr(lesson.color, COLOR_FALLBACK);
    const name: string = lesson.course_name.length > 0 ? lesson.course_name : '未命名课程';
    // 宽卡把课程类型并进课程名（"数字信号处理（理论）"）：课程块里课程名与类型是分开两处
    // 展示的，卡片没有那个空间，就按最省地方的方式合并 —— 用全角括号，与中文课名连读不夹生。
    const course: string = wide && lesson.course_type.length > 0
      ? `${name}（${lesson.course_type}）` : name;
    // period id 转字符串：卡片 → 应用只有 JSON 键值对这条通道，统一按字符串传更稳
    const period: string = `${lesson.time_period_id}`;
    if (index === 0) {
      binding.row1Course = course;
      binding.row1Start = startText;
      binding.row1End = endText;
      binding.row1Meta = meta;
      binding.row1Place = place;
      binding.row1People = people;
      binding.row1Class = lesson.class_name;
      binding.row1Color = color;
      binding.row1Period = period;
    } else {
      binding.row2Course = course;
      binding.row2Start = startText;
      binding.row2End = endText;
      binding.row2Meta = meta;
      binding.row2Place = place;
      binding.row2People = people;
      binding.row2Class = lesson.class_name;
      binding.row2Color = color;
      binding.row2Period = period;
    }
  }

  /**
   * 这节课的**结束钟点**换算成"从零点起的分钟数"；作息模板里查不到返回 -1（未知）。
   *
   * 返回 -1 而不是 0：0 点（午夜）是一个合法的钟点，用它表达"查不到"会让
   * "夜里 0 点上完的课"被误判成"模板缺失"，两种情形必须能分开。
   */
  private static endMinutesOf(lesson: LessonRow, slots: ScheduleSlot[]): number {
    for (let i = 0; i < slots.length; i++) {
      if (slots[i].session_no === lesson.end_time) {
        const minutes: number = DateUtil.hmToMinutes(slots[i].end_time);
        return minutes > 0 ? minutes : -1;
      }
    }
    return -1;
  }

  /** 用当前学期绑定的作息模板把"第几节"换算成钟点，如 `08:00-09:40`；模板缺失返回空串 */
  private static clockRange(lesson: LessonRow, slots: ScheduleSlot[]): string {
    let start: string = '';
    let end: string = '';
    for (let i = 0; i < slots.length; i++) {
      if (slots[i].session_no === lesson.start_time) {
        start = slots[i].start_time;
      }
      if (slots[i].session_no === lesson.end_time) {
        end = slots[i].end_time;
      }
    }
    return start.length > 0 && end.length > 0 ? `${start}-${end}` : '';
  }

  private static slotsOf(space: Workspace, semester: Semester): ScheduleSlot[] {
    for (let i = 0; i < space.templates.length; i++) {
      const tpl: ScheduleTemplate = space.templates[i];
      if (tpl.id === semester.schedule_id) {
        return tpl.slots;
      }
    }
    return [];
  }

  private static findSemester(space: Workspace, semesterId: number): Semester | undefined {
    for (let i = 0; i < space.semesters.length; i++) {
      if (space.semesters[i].id === semesterId) {
        return space.semesters[i];
      }
    }
    return undefined;
  }
}
