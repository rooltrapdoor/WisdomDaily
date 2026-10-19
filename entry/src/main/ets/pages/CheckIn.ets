import { common } from '@kit.AbilityKit';
import { display, router } from '@kit.ArkUI';
import { ScheduleRepository } from '../repository/ScheduleRepository';
import { Student } from '../model/Student';
import { AttendanceRow } from '../model/Rows';
import {
  AttendMark,
  AttendStatus,
  DEFAULT_RANDOM_COUNT,
  GRADE_BANDS,
  GradeBand,
  MAX_RANDOM_COUNT,
  MIN_RANDOM_COUNT,
  RING_SECTOR_CANCEL,
  RING_SECTOR_NONE,
  RingPoint,
  SignInMark,
  bandOfGrade,
  isValidGrade,
  ringGradeAngle,
  ringOffsetOf,
  ringSectorOf
} from '../model/Attendance';
import { THEME_COLOR_DEFAULT, WEEKDAY_LABELS, PAGE_BG_COLOR, clamp, colorOr, errText } from '../common/Util';
import { Logger } from '../common/Logger';

const TAG: string = 'CheckInPage';

/** 每行高度（vp）。手势阈值都以它为参照，改版式时一起看 */
const ROW_HEIGHT: number = 62;
/** 左右滑多少算一次标记：太小会与"上下滑动列表"打架，太大手指要拉半个屏幕 */
const SWIPE_MIN: number = 36;
/** 长按触发圆环的时长（ms）。太短会与"按住拖动列表"混淆 */
const LONG_PRESS_MS: number = 320;
/** 圆环半径（vp）：手指从环心滑到环上刚好等于这个距离 */
const RING_RADIUS: number = 96;
/** 等级圆点直径 */
const RING_DOT: number = 56;
/** 「取消」那一格的胶囊尺寸（vp）—— 画成横的，一眼区别于 5 个圆点 */
const RING_CANCEL_W: number = 62;
const RING_CANCEL_H: number = 34;
/** 死区半径（vp）：手指没离开环心这么远就什么都不选（抬手 = 取消，不改动） */
const RING_DEAD_ZONE: number = 30;
/** 单人视图里 7 个操作键的高度（vp）—— 做大一点，手抖也点得准 */
const ONE_KEY_HEIGHT: number = 64;

/**
 * 圆环上的一个等级圆点（位置由环心与半径算出，单位 vp）。
 * ArkTS 严格模式不允许"接口 + 对象字面量"混着来，所以用 class。
 */
class RingSlot {
  grade: number = 0;
  x: number = 0;
  y: number = 0;
  bandText: string = '';

  constructor(grade: number, x: number, y: number, bandText: string) {
    this.grade = grade;
    this.x = x;
    this.y = y;
    this.bandText = bandText;
  }
}

/**
 * 全屏点名页（签到）。
 *
 * ## 为什么是独立全屏页而不是半模态
 * 这一页要装三种手势，还要能滚一整个班的名单。半模态是 `FIT_CONTENT`（高度随内容变，
 * 见 docs/04 §12.3.2 第 17 点），在它里面做"长按 → 手指下滑 → 松手确认"这种连续手势，
 * 面板高度一变命中区就跟着错位；而且手势阈值也需要一块固定的舞台。
 *
 * ## 三种手势（都不弹任何菜单，滑完即生效）
 *  - **左滑** → 旷课（导出 `×`）
 *  - **右滑** → 请假（导出 `⊕`）
 *  - **长按 → 拖到圆环上** → 选等级 1~5：出勤（导出 `√`），同时**当场**在等级对应
 *    区间里随机取一个分落库，写进导出表的"课堂状态"列。圆环是**整圈**：正上方占
 *    1/3 圆的是**取消**（松手不改动），剩下 2/3 均分给 5 档（正左 1 / 正下 3 / 正右 5）。
 *    再滑一次同方向 = 撤销回"未点名"。
 *  - **列表最底下那个「单人视图」按钮** → 进**单人视图**（见下）。
 *    **行本身不再可点**：一行的长按已经用来评档了，再让"轻点"去跳页，
 *    手指在长按判定（320ms）之前抬起来就会跳页 —— 想评档的人反而被送到另一个界面。
 *
 * ## 长按期间只操作被选中的那一个
 * 长按成功后，其余学生的行上会压一层阴影，并**挡住他们的手势**（`HitTestMode.Block`），
 * 列表也临时禁掉滚动 —— 老师的手指就是那一根手指，不该有第二行同时在响应。
 *
 * ## 单人视图（`viewMode === 'one'`）
 * **上半屏** = 当前学生（第 i / N 位、姓名 / 学号 / 状态符号 / 档位分数），
 * **下半屏** = 操作区：顶上一行 切换视图 + 1 / 2 / 3，第二行 4 / 5 / ⊕ / ×，
 * 最底下左右两端是前后两位学生：按钮按内容宽**收小**（不占满半行），靠**两端对齐**
 * （左 `ic_lastUser` 贴左、右 `ic_nextUser` 贴右，点一下就走）；姓名与学号分两行两个 `Text`，
 * **中间不加 `·`**（这一格本来就窄，少一个符号就多一个字的位置）。
 * 列表视图的手势适合"扫着标"，单人视图的按钮适合"对着点名册一条条确认"。
 * 上下各占一半是刻意的：按钮区落在**屏幕下半**，拇指够得到，上半屏只放"现在是谁"。
 *
 * ## 保存时机
 * 沿用本项目的 Save-on-Done：手势只改内存，点右上角「完成」才落库；
 * 有改动时返回会先问一句"放弃修改？"。整次点名是**一次事务整批替换**
 * （`AttendanceDao.replaceSession`），不是逐行 upsert —— 重复点「完成」不会写出重影行。
 */
@Entry
@ComponentV2
struct CheckIn {
  // ---- 路由参数 ----
  @Local periodId: number = 0;
  @Local weekNo: number = 0;
  @Local classId: string = '';
  @Local courseName: string = '';
  @Local className: string = '';
  @Local classRoom: string = '';
  /** 1 = 周一 … 7 = 周日 */
  @Local weekday: number = 1;
  @Local startSession: number = 1;
  @Local endSession: number = 1;
  /** `all` = 全部点名；`random` = 随机抽 N 人 */
  @Local markMode: string = 'all';
  @Local randomCount: number = DEFAULT_RANDOM_COUNT;
  @Local themeColor: string = THEME_COLOR_DEFAULT;

  // ---- 数据 ----
  @Local busy: boolean = true;
  @Local saving: boolean = false;
  @Local badParams: boolean = false;
  @Local message: string = '';
  /** 全班名单（学号升序）—— 手势改的是 `marks` 里的对应项 */
  @Local students: Student[] = [];
  /** 与 `students` 同下标的标记数组 */
  @Local marks: SignInMark[] = [];
  /** 本次点名要显示哪些学生（`students` 的下标）。随机抽人时只放抽中的那些 */
  @Local targetIndexes: number[] = [];

  // ---- 圆环选择器（长按一个学生时出现）----
  @Local ringVisible: boolean = false;
  /** 正在被长按的那一行（`students` 下标），-1 = 无 */
  @Local ringIndex: number = -1;
  /**
   * 手指当前落在哪一格：`RING_SECTOR_CANCEL`(0) = 取消，1~5 = 等级，
   * `RING_SECTOR_NONE`(-1) = 还没离开死区（抬手等于什么都没做）。
   * 直接复用 `ringSectorOf()` 的返回值，页面不再另存一套"选中了什么"。
   */
  @Local ringPick: number = RING_SECTOR_NONE;
  @Local ringCenterX: number = 0;
  @Local ringCenterY: number = 0;
  /** 窗口尺寸（vp）—— 用来把环心夹在屏幕内，别让圆环被裁掉 */
  @Local screenW: number = 360;
  @Local screenH: number = 780;

  // ---- 单人视图（一个学生一屏，按钮记分）----
  /** `list` = 名单列表（手势标记）；`one` = 单人视图（按钮标记） */
  @Local viewMode: string = 'list';
  /** 单人视图看的是**点名对象里的第几个**（随机抽人时只在抽中的那几个里走） */
  @Local onePos: number = 0;

  /** 有未保存改动（判定方式与 TemplateEdit 一致：内容 ≠ 基线，改回原样 = 没改） */
  @Local dirty: boolean = false;
  private baseline: string = '';

  aboutToAppear(): void {
    const screen = display.getDefaultDisplaySync();
    this.screenW = px2vp(screen.width);
    this.screenH = px2vp(screen.height);
    this.load();
  }

  onBackPress(): boolean {
    if (this.dirty) {
      this.confirmDiscard();
      return true;
    }
    return false;
  }

  private context(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }

  // ---------------------------------------------------------------- 加载

  private async load(): Promise<void> {
    const params: Record<string, Object> | undefined = router.getParams() as Record<string, Object>;
    if (params === undefined) {
      this.badParams = true;
      this.message = '缺少页面参数';
      this.busy = false;
      return;
    }
    this.periodId = parseInt('' + params['periodId']);
    this.weekNo = parseInt('' + params['weekNo']);
    this.classId = params['classId'] === undefined ? '' : `${params['classId']}`;
    this.courseName = params['courseName'] === undefined ? '' : `${params['courseName']}`;
    this.className = params['className'] === undefined ? '' : `${params['className']}`;
    this.classRoom = params['classRoom'] === undefined ? '' : `${params['classRoom']}`;
    this.weekday = params['weekday'] === undefined ? 1 : parseInt('' + params['weekday']);
    this.startSession = params['startSession'] === undefined ? 1 : parseInt('' + params['startSession']);
    this.endSession = params['endSession'] === undefined ? this.startSession : parseInt('' + params['endSession']);
    this.markMode = params['mode'] === undefined ? 'all' : `${params['mode']}`;
    this.randomCount = params['randomCount'] === undefined
      ? DEFAULT_RANDOM_COUNT
      : this.clampCount(parseInt('' + params['randomCount']));
    // 强调色由调用方带过来（Index 已经读好了设置），省一次 workspace 查询
    this.themeColor = colorOr(params['themeColor'] === undefined ? '' : `${params['themeColor']}`,
      THEME_COLOR_DEFAULT);

    // NaN 与 0 都要拦住：NaN 会让后面的 SQL 参数变成非法值
    if (isNaN(this.periodId) || this.periodId <= 0
      || isNaN(this.weekNo) || this.weekNo <= 0
      || this.classId.length === 0) {
      this.badParams = true;
      this.message = '参数异常：未指定要点的这节课';
      this.busy = false;
      return;
    }

    try {
      const repo: ScheduleRepository = ScheduleRepository.getInstance();
      await repo.init(this.context());
      const roster = await repo.loadRoster(this.classId);
      this.students = roster.students;
      const marks: SignInMark[] = [];
      for (let i = 0; i < this.students.length; i++) {
        marks.push(SignInMark.of(this.students[i].id));
      }
      // 回填这次课已经点过的结果：老师中途退出再进来，进度不能丢
      const existing: AttendanceRow[] = await repo.loadAttendance(this.periodId, this.weekNo);
      for (let i = 0; i < existing.length; i++) {
        const at: AttendanceRow = existing[i];
        for (let j = 0; j < marks.length; j++) {
          if (marks[j].student_id === at.student_id) {
            marks[j].status = at.status;
            marks[j].grade = at.grade;
            marks[j].score = at.score;
            break;
          }
        }
      }
      this.marks = marks;
      this.rollTargets();
      Logger.info(TAG, `载入完成：${this.students.length} 名学生，已有 ${existing.length} 条签到记录`);
    } catch (e) {
      this.message = `加载失败：${errText(e)}`;
      Logger.error(TAG, this.message);
    }
    this.baseline = this.snapshot();
    this.dirty = false;
    this.busy = false;
  }

  private clampCount(value: number): number {
    if (isNaN(value)) {
      return DEFAULT_RANDOM_COUNT;
    }
    return clamp(Math.round(value), MIN_RANDOM_COUNT, MAX_RANDOM_COUNT);
  }

  // ---------------------------------------------------------------- 点名对象

  /**
   * 决定这一次要显示哪些人。
   *
   * 「随机抽 N 人」抽出的是**点名对象**（抽到谁就点谁），不是"抽到的自动算出勤" ——
   * 出勤与否仍然由老师逐个滑出来，工具不该替老师下结论。
   */
  private rollTargets(): void {
    const count: number = this.students.length;
    const indexes: number[] = [];
    for (let i = 0; i < count; i++) {
      indexes.push(i);
    }
    if (this.markMode !== 'random') {
      this.targetIndexes = indexes;
      return;
    }
    // Fisher–Yates：从后往前逐个与前方的随机位置交换，保证每种排列等概率
    for (let i = count - 1; i > 0; i--) {
      const j: number = Math.floor(Math.random() * (i + 1));
      const tmp: number = indexes[i];
      indexes[i] = indexes[j];
      indexes[j] = tmp;
    }
    const take: number = clamp(this.randomCount, MIN_RANDOM_COUNT, count === 0 ? 1 : count);
    this.targetIndexes = indexes.slice(0, take);
  }

  /** 切回全班（随机抽完想再看看别人） */
  private showAll(): void {
    this.markMode = 'all';
    this.rollTargets();
  }

  // ---------------------------------------------------------------- 手势落点

  private markOf(index: number): SignInMark {
    return this.marks[index];
  }

  /** 本次水平滑动起点（窗口全局 X）—— 与 `updateRing` 同一套坐标，避开 px/vp 的单位赌注 */
  private swipeStartX: number = 0;
  /**
   * 这一次触摸是否已经进入"长按选档"。
   *
   * 拦的是**同一个触摸**里的左右滑：圆环是整圈、任意方向都能选档，长按之后往右拖到
   * 5 档，行上那个水平 PanGesture 会同时把它看成"请假"。
   *
   * 在 `TouchType.Down` 清零，而**不是**在抬手时清：抬手时"圆环的 Pan"与"水平的 Pan"
   * 谁先回调 `onActionEnd` 不由我们决定，靠执行顺序去判就是赌运气。
   */
  private ringTouch: boolean = false;

  private beginSwipe(event: GestureEvent): void {
    if (this.ringTouch) {
      return;
    }
    this.swipeStartX = event.fingerList.length > 0 ? event.fingerList[0].globalX : 0;
  }

  /**
   * 左右滑落点：**用"终点 − 起点"算位移，不用 `GestureEvent.offsetX`**。
   *
   * 原因同 `updateRing`：`offsetX` 的单位在文档里有 vp / px 两种说法，
   * 而阈值（36）是按 vp 定的 —— 赌错一次就是"轻轻一碰就记旷课"或"怎么滑都不生效"。
   * 起点取不到时（`fingerList` 为空）退回 `offsetX`，宁可退化成旧行为也不要漏掉整次滑动。
   */
  private endSwipe(index: number, event: GestureEvent): void {
    // 这一次触摸长按过 → 它整体归圆环，不当左右滑（见 `ringTouch`）
    if (this.ringTouch) {
      return;
    }
    let dx: number = event.offsetX;
    if (this.swipeStartX !== 0 && event.fingerList.length > 0) {
      dx = event.fingerList[0].globalX - this.swipeStartX;
    }
    if (dx <= -SWIPE_MIN) {
      this.applyAbsent(index);
    } else if (dx >= SWIPE_MIN) {
      this.applyLeave(index);
    }
  }

  /**
   * 左滑：旷课。**再滑一次同方向 = 撤销** —— 手势没有二次确认，误触总得有退路。
   */
  private applyAbsent(index: number): void {
    const mark: SignInMark = this.marks[index];
    if (mark.status === AttendStatus.ABSENT) {
      mark.reset();
    } else {
      mark.markAbsent();
    }
    this.refreshDirty();
  }

  /** 右滑：请假。同样支持"再滑一次撤销" */
  private applyLeave(index: number): void {
    const mark: SignInMark = this.marks[index];
    if (mark.status === AttendStatus.LEAVE) {
      mark.reset();
    } else {
      mark.markLeave();
    }
    this.refreshDirty();
  }

  /** 长按下滑选定等级：出勤 + 等级 + 当场算好的随机分 */
  private applyGrade(index: number, grade: number): void {
    if (!isValidGrade(grade)) {
      return;
    }
    this.marks[index].markGrade(grade);
    this.refreshDirty();
  }

  /** 一键把这次课还没点名的都记为最高档（课上得顺、没人缺席时的省事入口） */
  private markAllPresent(): void {
    for (let i = 0; i < this.targetIndexes.length; i++) {
      const idx: number = this.targetIndexes[i];
      if (!this.marks[idx].marked()) {
        this.marks[idx].markGrade(1);
      }
    }
    this.refreshDirty();
  }

  private clearAll(): void {
    for (let i = 0; i < this.marks.length; i++) {
      this.marks[i].reset();
    }
    this.refreshDirty();
  }

  // ---------------------------------------------------------------- 圆环选择器

  /**
   * 长按命中：开环，并进入"只操作这一个学生"的模式。
   *
   * 环心取**长按点**并整体夹进屏幕内（圆环半径 + 圆点半径），别让它被裁掉一半。
   * 同时点亮 `ringTouch`：这一次触摸里只要长按成功过，左右滑的落点判定就让路。
   */
  private beginRing(index: number, event: GestureEvent): void {
    if (event.fingerList.length === 0) {
      return;
    }
    const finger = event.fingerList[0];
    this.ringIndex = index;
    this.ringPick = RING_SECTOR_NONE;
    this.ringTouch = true;
    const margin: number = RING_RADIUS + RING_DOT / 2 + 8;
    this.ringCenterX = clamp(finger.globalX, margin, this.screenW - margin);
    this.ringCenterY = clamp(finger.globalY, margin, this.screenH - margin);
    this.ringVisible = true;
  }

  /**
   * 手指位置 → 圆环上的哪一格。
   *
   * 用**窗口全局坐标**而不是 `GestureEvent.offsetX/offsetY`：后者的单位在文档里
   * 一直有 vp / px 两种说法，而 `beginRing` 记的环心来自 `fingerList[].globalX/globalY`，
   * 两边都取全局坐标，单位天然一致，不必赌一次换算。
   *
   * 角度判定本身在 `Attendance.ringSectorOf()`（纯函数，能被 ringcheck.py 单测）：
   * 正上方 = 取消、正下 = 3 档、正左 = 1 档、正右 = 5 档。
   */
  private updateRing(gx: number, gy: number): void {
    this.ringPick = ringSectorOf(gx - this.ringCenterX, gy - this.ringCenterY, RING_DEAD_ZONE);
  }

  /**
   * 松手：落在等级格就记档；落在「取消」或死区就**什么都不改**。
   *
   * 「取消」是"这次长按作废"，**不是**"清掉这个学生原有的标记"：长按本来就是
   * 想改口、或者手滑按住时的入口，误触撤不回来比误记一档更糟。
   */
  private commitRing(): void {
    const index: number = this.ringIndex;
    const pick: number = this.ringPick;
    this.closeRing();
    if (index >= 0 && isValidGrade(pick)) {
      this.applyGrade(index, pick);
    }
  }

  private closeRing(): void {
    this.ringVisible = false;
    this.ringIndex = -1;
    this.ringPick = RING_SECTOR_NONE;
  }

  /** 环心那句提示：环上六格都占着，中间这块正好空出来 */
  private ringHint(): string {
    if (this.ringPick === RING_SECTOR_NONE) {
      return '拖到环上选档\n正上方 = 取消';
    }
    if (this.ringPick === RING_SECTOR_CANCEL) {
      return '取消\n松手不改动';
    }
    return `${this.ringPick} 档 · 松手确认`;
  }

  /**
   * 圆环上 5 个等级圆点的位置（「取消」那一格是胶囊，单独摆，见 `ringLayer`）。
   *
   * 角度由 `Attendance.ringGradeAngle()` 给出、偏移由 `Attendance.ringOffsetOf()` 换算，
   * 两者与 `ringSectorOf()` **共用同一组常量、同一套基准**（正上方 0°、顺时针为正）——
   * 画出来的点落在哪一格，手指滑到那个点就必须选中哪一格。两边各算一份角度，迟早会
   * "看着对准了、实际选偏了"，编译期还一句报错都没有；`ringcheck.py` 拿画出来的偏移
   * 反查判定函数，把这条钉死。
   */
  private ringSlots(): RingSlot[] {
    const slots: RingSlot[] = [];
    for (let i = 0; i < GRADE_BANDS.length; i++) {
      const band: GradeBand = GRADE_BANDS[i];
      // 环心 + 模型给的偏移；页面这里一行三角函数都不出现
      const off: RingPoint = ringOffsetOf(ringGradeAngle(band.grade), RING_RADIUS);
      slots.push(new RingSlot(band.grade,
        this.ringCenterX + off.x, this.ringCenterY + off.y, `${band.low}~${band.high}`));
    }
    return slots;
  }

  // ---------------------------------------------------------------- 脏标记

  /**
   * 内容快照：与基线比较得出脏标记。
   *
   * 不用"手势被触发过"判定 —— 滑错了再滑回来（撤销）其实等于没改，
   * 用回调计数会误报"有未保存的修改"，退出时白弹一次确认框。
   */
  private snapshot(): string {
    const parts: string[] = [];
    for (let i = 0; i < this.marks.length; i++) {
      const mark: SignInMark = this.marks[i];
      parts.push(`${mark.student_id}:${mark.status}:${mark.grade}:${mark.score}`);
    }
    return parts.join('|');
  }

  private refreshDirty(): void {
    this.dirty = this.snapshot() !== this.baseline;
  }

  // ---------------------------------------------------------------- 保存

  private async save(): Promise<void> {
    if (this.saving || this.badParams) {
      return;
    }
    this.saving = true;
    try {
      const rows: AttendanceRow[] = [];
      for (let i = 0; i < this.marks.length; i++) {
        const mark: SignInMark = this.marks[i];
        // 只有点过的才产生行：没点过 = 库里没有这一行（下次进来仍是"未点名"）
        if (!mark.marked()) {
          continue;
        }
        rows.push({
          id: 0,
          time_period_id: this.periodId,
          week_no: this.weekNo,
          student_id: mark.student_id,
          status: mark.status,
          grade: mark.grade,
          score: mark.score
        });
      }
      const written: number = await ScheduleRepository.getInstance()
        .saveAttendance(this.periodId, this.weekNo, rows);
      this.baseline = this.snapshot();
      this.dirty = false;
      Logger.info(TAG, `点名已保存：第${this.weekNo}周 ${written} 人`);
      router.back();
    } catch (e) {
      this.message = `保存失败：${errText(e)}`;
      Logger.error(TAG, this.message);
    }
    this.saving = false;
  }

  private confirmDiscard(): void {
    AlertDialog.show({
      title: '放弃修改？',
      message: '本次点名结果尚未保存，退出后将丢失。',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '放弃',
        fontColor: '#DC2626',
        action: () => {
          router.back();
        }
      }
    });
  }

  // ---------------------------------------------------------------- 展示辅助

  private weekText(): string {
    const day: string = this.weekday >= 1 && this.weekday <= 7
      ? WEEKDAY_LABELS[this.weekday - 1]
      : '';
    const range: string = this.endSession > this.startSession
      ? `第${this.startSession}-${this.endSession}节`
      : `第${this.startSession}节`;
    return `${day} ${range} · 第${this.weekNo}周`;
  }

  private dotCount(status: string): number {
    let n: number = 0;
    for (let i = 0; i < this.marks.length; i++) {
      if (this.marks[i].status === status) {
        n++;
      }
    }
    return n;
  }

  private progressText(): string {
    const total: number = this.targetIndexes.length;
    let done: number = 0;
    for (let i = 0; i < this.targetIndexes.length; i++) {
      if (this.marks[this.targetIndexes[i]].marked()) {
        done++;
      }
    }
    return `已点名 ${done} / ${total}`;
  }

  private symbolOf(mark: SignInMark): string {
    if (mark.status === AttendStatus.PRESENT) {
      return AttendMark.PRESENT;
    }
    if (mark.status === AttendStatus.ABSENT) {
      return AttendMark.ABSENT;
    }
    if (mark.status === AttendStatus.LEAVE) {
      return AttendMark.LEAVE;
    }
    return '·';
  }

  private symbolColor(mark: SignInMark): string {
    if (mark.status === AttendStatus.PRESENT) {
      return '#16A34A';
    }
    if (mark.status === AttendStatus.ABSENT) {
      return '#DC2626';
    }
    if (mark.status === AttendStatus.LEAVE) {
      return '#D97706';
    }
    return '#D1D5DB';
  }

  private detailOf(mark: SignInMark): string {
    if (mark.status === AttendStatus.PRESENT) {
      return `${mark.grade}档 · ${mark.score}分`;
    }
    if (mark.status === AttendStatus.ABSENT) {
      return '旷课';
    }
    if (mark.status === AttendStatus.LEAVE) {
      return '请假';
    }
    return '未点';
  }

  private rowBackground(mark: SignInMark): string {
    if (mark.status === AttendStatus.PRESENT) {
      return '#F0FDF4';
    }
    if (mark.status === AttendStatus.ABSENT) {
      return '#FEF2F2';
    }
    if (mark.status === AttendStatus.LEAVE) {
      return '#FFFBEB';
    }
    return '#FFFFFF';
  }

  // ---------------------------------------------------------------- 视图

  // ---------------------------------------------------------------- 单人视图

  /** 单人视图当前看的学生在 `students` 里的下标（名单为空时 -1） */
  private oneIndex(): number {
    if (this.targetIndexes.length === 0) {
      return -1;
    }
    return this.targetIndexes[clamp(this.onePos, 0, this.targetIndexes.length - 1)];
  }

  /**
   * 当前学生的标记。
   *
   * 名单为空时给一个"未点名"的空标记，而不是 `undefined` —— 否则 `symbolOf()` /
   * `symbolColor()` / `detailOf()` / `rowBackground()` 这一串展示辅助全都要多一层判空，
   * 铺满判空的代码更容易漏。
   */
  private oneMark(): SignInMark {
    const index: number = this.oneIndex();
    return index < 0 ? SignInMark.of(0) : this.marks[index];
  }

  /**
   * 从列表底部那个按钮进来时停在哪一位：**第一位还没点名的**。
   *
   * 这一页的用途是"对着点名册一条条确认"，所以进来就落到下一条待办上，
   * 而不是每次都从第一位重新翻；全都点过了才回第一位（那时是回头复查）。
   */
  private oneEntryPos(): number {
    for (let i = 0; i < this.targetIndexes.length; i++) {
      if (!this.marks[this.targetIndexes[i]].marked()) {
        return i;
      }
    }
    return 0;
  }

  private enterOne(pos: number): void {
    this.closeRing();
    const last: number = this.targetIndexes.length === 0 ? 0 : this.targetIndexes.length - 1;
    this.onePos = clamp(pos, 0, last);
    this.viewMode = 'one';
  }

  private backToList(): void {
    this.viewMode = 'list';
  }

  /** 上一位 / 下一位。到头就停在原地 —— 首尾环绕时"最后一位"和"第一位"分不清 */
  private oneMove(delta: number): void {
    if (!this.oneHasNeighbor(delta)) {
      return;
    }
    this.onePos = this.onePos + delta;
  }

  private oneHasNeighbor(delta: number): boolean {
    const pos: number = this.onePos + delta;
    return pos >= 0 && pos < this.targetIndexes.length;
  }

  /**
   * 前后两位学生的**姓名**（到头时给一句说明，不留空 —— 空着看不出"到头了"还是"没加载出来"）。
   *
   * 姓名与学号**分成两行两个 Text**，不把它们拼成一句话：
   * 拼成一句就得在中间塞一个分隔符，而这一格本来就窄（只占屏幕一半），
   * 少一个符号就多一个字的位置；分成两行之后学号还能小一号、淡一点。
   */
  private oneNeighborName(delta: number): string {
    if (!this.oneHasNeighbor(delta)) {
      return delta < 0 ? '已经是第一位' : '已经是最后一位';
    }
    const name: string = this.students[this.targetIndexes[this.onePos + delta]].name;
    return name.length > 0 ? name : '（未填姓名）';
  }

  /** 前后两位学生的**学号**（到头时为空，那一行的高度由上面那句说明撑着） */
  private oneNeighborNo(delta: number): string {
    if (!this.oneHasNeighbor(delta)) {
      return '';
    }
    return this.students[this.targetIndexes[this.onePos + delta]].student_no;
  }

  private oneName(): string {
    const index: number = this.oneIndex();
    if (index < 0) {
      return '';
    }
    const name: string = this.students[index].name;
    return name.length > 0 ? name : '（未填姓名）';
  }

  private oneNo(): string {
    const index: number = this.oneIndex();
    return index < 0 ? '' : this.students[index].student_no;
  }

  private oneBandText(grade: number): string {
    const band: GradeBand | undefined = bandOfGrade(grade);
    return band === undefined ? '' : `${band.low}~${band.high}`;
  }

  /** 这个等级是不是当前学生已经选中的那一档（用来点亮按钮） */
  private oneGradeActive(grade: number): boolean {
    const mark: SignInMark = this.oneMark();
    return mark.status === AttendStatus.PRESENT && mark.grade === grade;
  }

  private oneKindActive(kind: string): boolean {
    const mark: SignInMark = this.oneMark();
    return mark.status === (kind === 'absent' ? AttendStatus.ABSENT : AttendStatus.LEAVE);
  }

  private oneKindColor(kind: string): string {
    return kind === 'absent' ? '#DC2626' : '#D97706';
  }

  /** 点等级：与手势同一套退路 —— **再点一次同档 = 撤销** */
  private oneGrade(grade: number): void {
    const index: number = this.oneIndex();
    if (index < 0) {
      return;
    }
    const mark: SignInMark = this.marks[index];
    if (mark.status === AttendStatus.PRESENT && mark.grade === grade) {
      mark.reset();
    } else {
      mark.markGrade(grade);
    }
    this.refreshDirty();
  }

  /** 点 ⊕ / × ：请假 / 旷课；复用列表视图那两个"再点一次撤销"的方法 */
  private oneTapKind(kind: string): void {
    const index: number = this.oneIndex();
    if (index < 0) {
      return;
    }
    if (kind === 'absent') {
      this.applyAbsent(index);
    } else {
      this.applyLeave(index);
    }
  }

  /** 当前学生那张卡 */
  @Builder
  oneCurrentCard() {
    Column({ space: 8 }) {
      Row() {
        Text(`第 ${this.onePos + 1} / ${this.targetIndexes.length} 位`)
          .fontSize(11)
          .fontColor('#9CA3AF')
        Blank()
        Text(this.markMode === 'random' ? `随机 ${this.targetIndexes.length} 人` : '全部点名')
          .fontSize(11)
          .fontColor(this.themeColor)
      }
      .width('100%')

      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Text(this.oneName())
            .fontSize(26)
            .fontWeight(FontWeight.Bold)
            .fontColor('#111827')
            .maxLines(1)
          Text(this.oneNo())
            .fontSize(13)
            .fontColor('#6B7280')
            .maxLines(1)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Column({ space: 2 }) {
          Text(this.symbolOf(this.oneMark()))
            .fontSize(40)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.symbolColor(this.oneMark()))
          Text(this.detailOf(this.oneMark()))
            .fontSize(11)
            .fontColor('#9CA3AF')
        }
        .alignItems(HorizontalAlign.End)
        .flexShrink(0)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .backgroundColor(this.rowBackground(this.oneMark()))
    .borderRadius(12)
    .border({ width: 0.5, color: '#E5E7EB' })
  }

  /** 等级键：点一次记档，再点一次撤销（与手势同一套手感） */
  @Builder
  oneGradeKey(grade: number) {
    Column({ space: 2 }) {
      Text(`${grade}`)
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.oneGradeActive(grade) ? '#FFFFFF' : '#374151')
      Text(this.oneBandText(grade))
        .fontSize(9)
        .fontColor(this.oneGradeActive(grade) ? '#FFFFFF' : '#9CA3AF')
    }
    .layoutWeight(1)
    .height(ONE_KEY_HEIGHT)
    .justifyContent(FlexAlign.Center)
    .borderRadius(12)
    .backgroundColor(this.oneGradeActive(grade) ? this.themeColor : '#FFFFFF')
    .border({ width: 1, color: this.oneGradeActive(grade) ? this.themeColor : '#E5E7EB' })
    .onClick(() => this.oneGrade(grade))
  }

  /** ⊕ 请假 / × 旷课 */
  @Builder
  oneKindKey(kind: string) {
    Column({ space: 2 }) {
      Text(kind === 'absent' ? AttendMark.ABSENT : AttendMark.LEAVE)
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.oneKindActive(kind) ? '#FFFFFF' : this.oneKindColor(kind))
      Text(kind === 'absent' ? '旷课' : '请假')
        .fontSize(10)
        .fontColor(this.oneKindActive(kind) ? '#FFFFFF' : '#9CA3AF')
    }
    .layoutWeight(1)
    .height(ONE_KEY_HEIGHT)
    .justifyContent(FlexAlign.Center)
    .borderRadius(12)
    .backgroundColor(this.oneKindActive(kind) ? this.oneKindColor(kind) : '#FFFFFF')
    .border({ width: 1, color: this.oneKindActive(kind) ? this.oneKindColor(kind) : '#E5E7EB' })
    .onClick(() => this.oneTapKind(kind))
  }

  /** 切换视图（图标是"两半对调"的意思，配两个字说明切回哪里） */
  @Builder
  oneSwitchKey() {
    Column({ space: 2 }) {
      Image($r('app.media.ic_switch'))
        .width(22)
        .height(22)
        .fillColor(this.themeColor)
      Text('名单')
        .fontSize(10)
        .fontColor('#9CA3AF')
    }
    .layoutWeight(1)
    .height(ONE_KEY_HEIGHT)
    .justifyContent(FlexAlign.Center)
    .borderRadius(12)
    .backgroundColor('#FFFFFF')
    .border({ width: 1, color: '#E5E7EB' })
    .onClick(() => this.backToList())
  }

  /** 底部左右两端：前后两个学生的信息与按钮（delta = -1 上一位 / +1 下一位） */
  @Builder
  oneNeighbor(delta: number) {
    Row({ space: 6 }) {
      if (delta < 0) {
        Image($r('app.media.ic_lastUser'))
          .width(16)
          .height(16)
          .fillColor(this.oneHasNeighbor(delta) ? '#6B7280' : '#C0C4CC')
      }
      Column({ space: 1 }) {
        Text(this.oneNeighborName(delta))
          .fontSize(13)
          .fontColor(this.oneHasNeighbor(delta) ? '#111827' : '#C0C4CC')
          .maxLines(1)
        Text(this.oneNeighborNo(delta))
          .fontSize(10)
          .fontColor('#9CA3AF')
          .maxLines(1)
      }
      // 姓名与学号各自贴**外侧**：左边那个贴左、右边那个贴右（与外层两端对齐同一方向）
      .alignItems(delta < 0 ? HorizontalAlign.Start : HorizontalAlign.End)
      .constraintSize({ maxWidth: 116 })
      if (delta > 0) {
        Image($r('app.media.ic_nextUser'))
          .width(16)
          .height(16)
          .fillColor(this.oneHasNeighbor(delta) ? '#6B7280' : '#C0C4CC')
      }
    }
    .padding({ left: 10, right: 10, top: 6, bottom: 6 })
    .borderRadius(10)
    .backgroundColor('#FFFFFF')
    .border({ width: 0.5, color: '#E5E7EB' })
    // 不写 `layoutWeight(1)`：让它按内容宽（**缩小**），两端对齐交给外层那个 Row
    .flexShrink(1)
    // 到头了就变淡（点了也不动，不如先让人看出来）
    .opacity(this.oneHasNeighbor(delta) ? 1 : 0.55)
    .onClick(() => this.oneMove(delta))
  }

  /** 单人视图：**上半屏** = 当前学生，**下半屏** = 8 个键（切换视图 + 1~5 + ⊕ + ×）+ 前后两位 */
  @Builder
  onePanel() {
    Column() {
      // ---- 上半屏：只回答"现在是谁" ----
      Column() {
        this.oneCurrentCard()
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .padding({ left: 12, right: 12 })

      // ---- 下半屏：拇指区 ----
      // 按钮落在**屏幕下半**（不是紧贴学生卡），单手握持时拇指正好够得到；
      // 键区贴着下半屏的顶、前后两位贴着底，中间那片留白把两组操作分开。
      Column({ space: 10 }) {
        Column({ space: 10 }) {
          Row({ space: 10 }) {
            this.oneSwitchKey()
            this.oneGradeKey(1)
            this.oneGradeKey(2)
            this.oneGradeKey(3)
          }
          .width('100%')

          Row({ space: 10 }) {
            this.oneGradeKey(4)
            this.oneGradeKey(5)
            this.oneKindKey('leave')
            this.oneKindKey('absent')
          }
          .width('100%')
        }
        .width('100%')

        // 前后两位：各按内容宽（缩小），一个贴左一个贴右
        Row() {
          this.oneNeighbor(-1)
          Blank()
          this.oneNeighbor(1)
        }
        .width('100%')
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 12, right: 12, bottom: 12 })
      .justifyContent(FlexAlign.SpaceBetween)
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  header() {
    Row() {
      Row() {
        Text('‹')
          .fontSize(28)
          .fontColor('#111827')
          .onClick(() => {
            if (this.dirty) {
              this.confirmDiscard();
            } else {
              router.back();
            }
          })
      }
      .width(40)
      .height(56)
      .justifyContent(FlexAlign.Center)

      Column({ space: 2 }) {
        Text(this.courseName.length > 0 ? this.courseName : '点名')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor('#111827')
          .maxLines(1)
        Text(`${this.className} · ${this.weekText()}`)
          .fontSize(11)
          .fontColor('#6B7280')
          .maxLines(1)
      }
      .alignItems(HorizontalAlign.Center)
      .layoutWeight(1)

      Row() {
        Text(this.saving ? '…' : '✓')
          .fontSize(22)
          .fontColor(this.saving || this.badParams ? '#9CA3AF' : '#111827')
          .onClick(() => this.save())
      }
      .width(40)
      .height(56)
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .height(56)
    .padding({ left: 8, right: 8 })
    .backgroundColor('#F3F4F6')
  }

  /**
   * 进度条与两个省事入口。
   *
   * 「本次未点的都记 1 档」是刻意只作用于**当前点名对象**（随机抽人时就是抽中那几个），
   * 而不是全班 —— 抽了 10 个人却把全班都标成出勤，那是伪造考勤。
   */
  @Builder
  progressBar() {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        Text(this.progressText())
          .fontSize(13)
          .fontColor('#374151')
          .layoutWeight(1)
        Text('未点都记 1 档')
          .fontSize(12)
          .fontColor(this.themeColor)
          .padding({ left: 6, right: 6, top: 4, bottom: 4 })
          .onClick(() => this.markAllPresent())
        Text('清空')
          .fontSize(12)
          .fontColor('#6B7280')
          .padding({ left: 6, right: 6, top: 4, bottom: 4 })
          .onClick(() => this.clearAll())
      }
      .width('100%')

      Row({ space: 12 }) {
        Text(`出勤 ${this.dotCount(AttendStatus.PRESENT)}`)
          .fontSize(11)
          .fontColor('#16A34A')
        Text(`旷课 ${this.dotCount(AttendStatus.ABSENT)}`)
          .fontSize(11)
          .fontColor('#DC2626')
        Text(`请假 ${this.dotCount(AttendStatus.LEAVE)}`)
          .fontSize(11)
          .fontColor('#D97706')
        Blank()
        if (this.markMode === 'random') {
          Text(`随机 ${this.targetIndexes.length} 人`)
            .fontSize(11)
            .fontColor(this.themeColor)
          Text('换一批')
            .fontSize(11)
            .fontColor(this.themeColor)
            .padding({ left: 4, right: 4 })
            .onClick(() => this.rollTargets())
        }
        Text('看全班')
          .fontSize(11)
          .fontColor(this.themeColor)
          .padding({ left: 4, right: 4 })
          .onClick(() => this.showAll())
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    .backgroundColor('#FFFFFF')
  }

  /**
   * 一行 = 一个学生。三种手势都挂在这一行上；**行本身不可点**（进单人视图走列表底部的按钮）。
   *
   * **两个手势组并列（`GestureMode.Parallel`）而不是嵌套**：
   *  - 左/右滑是"只认水平方向"的 `PanGesture`，与 `List` 的垂直滚动天然不冲突；
   *  - 等级是"长按 → 继续拖动"的连续动作，用 `GestureMode.Sequence` 串起来：
   *    `LongPressGesture` 满足时才轮到 `PanGesture`，所以**没长按的垂直滑动仍然归列表滚动**。
   *    若把自由方向的 PanGesture 直接挂在行上，列表就滚不动了。
   *    长按之后改成**任意方向**都能选档（圆环是整圈），代价是这次触摸里"往右拖"也会被
   *    水平 PanGesture 看见 —— 由 `ringTouch` 拦掉。
   */
  @Builder
  studentRow(index: number) {
    Row({ space: 12 }) {
      Column({ space: 3 }) {
        Text(this.students[index].name.length > 0 ? this.students[index].name : '（未填姓名）')
          .fontSize(16)
          .fontColor('#111827')
          .maxLines(1)
        Text(this.students[index].student_no)
          .fontSize(11)
          .fontColor('#9CA3AF')
          .maxLines(1)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Column({ space: 3 }) {
        Text(this.symbolOf(this.markOf(index)))
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.symbolColor(this.markOf(index)))
        Text(this.detailOf(this.markOf(index)))
          .fontSize(10)
          .fontColor('#9CA3AF')
      }
      .alignItems(HorizontalAlign.End)
      .flexShrink(0)
    }
    .width('100%')
    .height(ROW_HEIGHT)
    .padding({ left: 16, right: 16 })
    .backgroundColor(this.rowBackground(this.markOf(index)))
    .borderRadius(10)
    .border({ width: this.ringIndex === index ? 1.5 : 0.5, color: this.ringIndex === index ? this.themeColor : '#EEF0F2' })
    // 被长按的那一行**浮起来**：其余行压了阴影，它得看得出还是"能操作的那一个"
    .shadow(this.ringIndex === index
      ? { radius: 16, color: '#33000000', offsetX: 0, offsetY: 3 }
      : { radius: 0, color: '#00000000', offsetX: 0, offsetY: 0 })
    // 每次按下先"解锁"：这一次触摸还没长按过（不能在抬手时清，理由见 `ringTouch`）
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.ringTouch = false;
      }
    })
    // 行本身**不挂 onClick**：这一行已经有一个 320ms 的长按用来就地评档，
    // 再让"轻点"去跳页，手指在长按判定之前抬起来就会跳走 —— 想评档的人被送到另一个界面。
    // 进单人视图统一走列表**最底下那个按钮**。
    .gesture(
      GestureGroup(GestureMode.Parallel,
        PanGesture({ direction: PanDirection.Horizontal, distance: 20 })
          .onActionStart((event: GestureEvent) => this.beginSwipe(event))
          .onActionEnd((event: GestureEvent) => this.endSwipe(index, event)),
        GestureGroup(GestureMode.Sequence,
          LongPressGesture({ repeat: false, duration: LONG_PRESS_MS })
            .onAction((event: GestureEvent) => this.beginRing(index, event)),
          PanGesture({ direction: PanDirection.All, distance: 6 })
            .onActionUpdate((event: GestureEvent) => {
              if (event.fingerList.length > 0) {
                this.updateRing(event.fingerList[0].globalX, event.fingerList[0].globalY);
              }
            })
            .onActionEnd(() => this.commitRing())
            .onActionCancel(() => this.closeRing())
        )
      )
    )
  }

  /**
   * 圆环选择器：只画，不吃触摸（`HitTestMode.None`）—— 手指还在原手势里，别被它截断。
   *
   * 整圈 = 「取消」(1/3 圆，正上方，画成横胶囊) + 5 个等级 (各 48°，均分剩下的 2/3)。
   * 环本体也画出来：它是"区域"的可见证据 —— 取消那一格离两端的等级点明显更远，
   * 一眼看得出它占了更大的一块，而不是"多了一个按钮"。
   */
  @Builder
  ringLayer() {
    Stack() {
      // 环本体（只描边）：六格都落在这条环上
      Circle()
        .width(RING_RADIUS * 2)
        .height(RING_RADIUS * 2)
        .fillOpacity(0)
        .stroke('#D1D5DB')
        .strokeWidth(1)
        .position({ x: this.ringCenterX - RING_RADIUS, y: this.ringCenterY - RING_RADIUS })

      // 取消格：正上方
      Column() {
        Text('取消')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.ringPick === RING_SECTOR_CANCEL ? '#FFFFFF' : '#6B7280')
      }
      .width(RING_CANCEL_W)
      .height(RING_CANCEL_H)
      .borderRadius(RING_CANCEL_H / 2)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(this.ringPick === RING_SECTOR_CANCEL ? '#9CA3AF' : '#FFFFFF')
      .border({ width: 1, color: this.ringPick === RING_SECTOR_CANCEL ? '#9CA3AF' : '#E5E7EB' })
      .position({
        x: this.ringCenterX - RING_CANCEL_W / 2,
        y: this.ringCenterY - RING_RADIUS - RING_CANCEL_H / 2
      })

      ForEach(this.ringSlots(), (slot: RingSlot) => {
        Column({ space: 1 }) {
          Text(`${slot.grade}`)
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(slot.grade === this.ringPick ? '#FFFFFF' : '#374151')
          Text(slot.bandText)
            .fontSize(9)
            .fontColor(slot.grade === this.ringPick ? '#FFFFFF' : '#9CA3AF')
        }
        .width(RING_DOT)
        .height(RING_DOT)
        .borderRadius(RING_DOT / 2)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(slot.grade === this.ringPick ? this.themeColor : '#FFFFFF')
        .border({ width: 1, color: slot.grade === this.ringPick ? this.themeColor : '#E5E7EB' })
        .position({ x: slot.x - RING_DOT / 2, y: slot.y - RING_DOT / 2 })
      }, (slot: RingSlot) => `${slot.grade}`)

      // 环心那一句提示（环上六格都占着，中间这块正好空出来）
      Text(this.ringHint())
        .fontSize(12)
        .fontColor('#374151')
        .textAlign(TextAlign.Center)
        .width(RING_RADIUS * 2 - RING_DOT)
        .position({ x: this.ringCenterX - (RING_RADIUS - RING_DOT / 2), y: this.ringCenterY - 18 })
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  hintBar() {
    Column({ space: 4 }) {
      Text('左滑 旷课 ×　·　右滑 请假 ⊕　·　长按并拖到圆环上 评等级（√）')
        .fontSize(11)
        .fontColor('#6B7280')
        .textAlign(TextAlign.Center)
      Text('圆环正上方 = 取消；再滑一次同方向可撤销回"未点名"')
        .fontSize(10)
        .fontColor('#9CA3AF')
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 4 })
    .backgroundColor('#F3F4F6')
  }

  /**
   * 列表视图**最底下**那个按钮：切到单人视图。
   *
   * 入口放在这里，而不挂在"轻点某一行"上：一行已经挂了三种手势（左右滑 + 长按），
   * 再加一个"轻点"就要和长按的 320ms 判定抢同一根手指 —— 想评档的人在判定之前
   * 抬起来，就被送到另一个界面。放到这儿还顺带能把"这是干什么的"写清楚。
   */
  @Builder
  listSwitchBar() {
    Column() {
      Row({ space: 8 }) {
        Image($r('app.media.ic_switch'))
          .width(18)
          .height(18)
          .fillColor(this.themeColor)
        Text('单人视图')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.themeColor)
        Text('一个学生一屏，按钮记分')
          .fontSize(11)
          .fontColor('#9CA3AF')
          .maxLines(1)
      }
      .width('100%')
      .height(46)
      .justifyContent(FlexAlign.Center)
      .borderRadius(12)
      .backgroundColor('#FFFFFF')
      .border({ width: 1, color: this.themeColor })
      .onClick(() => this.enterOne(this.oneEntryPos()))
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 14 })
    .backgroundColor('#F3F4F6')
  }

  @Builder
  centerNote(text: string) {
    Column() {
      Text(text)
        .fontSize(14)
        .fontColor('#6B7280')
        .textAlign(TextAlign.Center)
        .padding({ left: 32, right: 32 })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  build() {
    Stack() {
      Column() {
        this.header()
        if (this.badParams) {
          this.centerNote(this.message)
        } else if (this.busy) {
          this.centerNote('正在载入名单…')
        } else if (this.students.length === 0) {
          this.centerNote(`「${this.className}」还没有学生名单\n先到「管理 → 班级管理」里导入名册`)
        } else {
          this.progressBar()
          if (this.message.length > 0) {
            Text(this.message)
              .fontSize(12)
              .fontColor('#DC2626')
              .width('100%')
              .padding({ left: 16, right: 16, top: 6, bottom: 6 })
          }
          if (this.viewMode === 'one') {
            this.onePanel()
          } else {
            List({ space: 8 }) {
              ForEach(this.targetIndexes, (index: number) => {
                ListItem() {
                  Stack() {
                    this.studentRow(index)
                    // 长按期间：**其他**学生压一层阴影，顺带挡住他们的手势
                    //（只剩被长按的那一行能操作，见页头注释）
                    if (this.ringVisible && this.ringIndex !== index) {
                      Column()
                        .width('100%')
                        .height(ROW_HEIGHT)
                        .borderRadius(10)
                        .backgroundColor('#00000059')
                        .hitTestBehavior(HitTestMode.Block)
                    }
                  }
                  .width('100%')
                  .height(ROW_HEIGHT)
                }
              }, (index: number) => {
                const mark: SignInMark = this.marks[index];
                return `${index}-${mark.status}-${mark.grade}-${mark.score}`;
              })
            }
            .width('100%')
            .layoutWeight(1)
            .padding({ left: 12, right: 12, top: 10, bottom: 10 })
            .scrollBar(BarState.Auto)
            // 开环期间禁掉列表滚动：那一下拖动是"选档"，不是"翻名单"
            .enableScrollInteraction(!this.ringVisible)
            // 最底下：手势提示 + **切到单人视图**的按钮（列表视图的唯一入口）
            this.hintBar()
            this.listSwitchBar()
          }
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(PAGE_BG_COLOR)

      if (this.ringVisible) {
        this.ringLayer()
      }
    }
    .width('100%')
    .height('100%')
  }
}
