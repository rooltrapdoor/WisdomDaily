/**
 * 签到（点名）领域模型与全局口径。
 *
 * 这个文件是**签到所有"魔法值"的唯一真源**：状态取值、导出符号、等级分档、列数上限。
 * 为什么单列一个文件：这些常量同时被"点名页（手势）"和"导出（Index.ets）"两侧引用，
 * 各写一份迟早漂移 —— 比如导出侧把等级 4 的区间写成 72~80、点名页写成 72~79，
 * 同一份数据两次导出分数不一样，而且**编译期一句报错都不会有**。
 */

/** `attendance.status` 的取值（与建表语句里的 CHECK 一一对应） */
export class AttendStatus {
  /** 本次课尚未点名 —— **只存在于页面内存**，"没点过名"在库里是不存在这一行 */
  static readonly NONE: string = 'none';
  /** 出勤：长按下滑选了 1~5 里的某一档 */
  static readonly PRESENT: string = 'present';
  /** 旷课（左滑）：导出 `×` */
  static readonly ABSENT: string = 'absent';
  /** 请假（右滑）：导出 `⊕` */
  static readonly LEAVE: string = 'leave';
}

/** 导出表里那三个符号（老师手工填表时的记法，不要改成汉字） */
export class AttendMark {
  static readonly PRESENT: string = '√';
  static readonly ABSENT: string = '×';
  static readonly LEAVE: string = '⊕';
}

/**
 * 等级 → 分数区间。
 *
 * 区间**上端取开**（除最高一档），于是五档彼此不重叠：
 * 1 → 90~95、2 → 85~89、3 → 80~84、4 → 72~79、5 → 65~71。
 * 老师说的"2 对应 85~90"里那个 90 归给 1 档，否则同一个 90 分既算 1 也算 2，
 * 导出后反查不出学生到底是哪一档。
 */
export class GradeBand {
  readonly grade: number;
  readonly low: number;
  readonly high: number;

  constructor(grade: number, low: number, high: number) {
    this.grade = grade;
    this.low = low;
    this.high = high;
  }
}

/** 五档，索引 0 = 等级 1（与半圆上从左到右的排列顺序一致） */
export const GRADE_BANDS: GradeBand[] = [
  new GradeBand(1, 90, 95),
  new GradeBand(2, 85, 89),
  new GradeBand(3, 80, 84),
  new GradeBand(4, 72, 79),
  new GradeBand(5, 65, 71)
];

/** 导出表里「考勤」「课堂状态」各只有 5 个子列 —— 一门课最多导出前 5 次点名 */
export const MAX_SIGNIN_COLUMNS: number = 5;

/** 随机抽取点名的默认人数 */
export const DEFAULT_RANDOM_COUNT: number = 10;

/** 随机抽取人数的上下限（人数输入框据此校验，避免 0 人或整班 200 人） */
export const MIN_RANDOM_COUNT: number = 1;
export const MAX_RANDOM_COUNT: number = 200;

/** 等级是否合法（1~5） */
export function isValidGrade(grade: number): boolean {
  return grade >= 1 && grade <= 5;
}

/** 等级对应的分档；等级非法时返回 undefined，调用方据此拒绝落库 */
export function bandOfGrade(grade: number): GradeBand | undefined {
  for (let i = 0; i < GRADE_BANDS.length; i++) {
    if (GRADE_BANDS[i].grade === grade) {
      return GRADE_BANDS[i];
    }
  }
  return undefined;
}

/**
 * 等级换算出的分数：在区间内**随机取一个整数**（含上下端）。
 *
 * 在"选等级的那一刻"算好并落库，而不是导出时现算 —— 否则同一份点名记录
 * 导两次分数不同，老师没法拿它对账，学生来问也说不清。
 */
export function randomScoreOfGrade(grade: number): number {
  const band: GradeBand | undefined = bandOfGrade(grade);
  if (band === undefined) {
    return 0;
  }
  const span: number = band.high - band.low + 1;
  return band.low + Math.floor(Math.random() * span);
}

// ---------------------------------------------------------------- 圆环选择器几何

/**
 * 圆环里「取消」那一格的张角（度）—— **1/3 圆**。
 *
 * 为什么给取消留这么大一块：老师长按一个学生，多半是"想改口"或"手滑按住"，
 * 抬手方向里"往上"最不像是在选档（档位都在环的中下段）。把正上方那 120°
 * 整块留给取消，误触就落不到任何等级上。
 */
export const RING_CANCEL_SPAN: number = 120;

/**
 * 圆环里每个等级格的张角（度）：剩下的 **2/3 圆均分给 5 档** → 48°。
 *
 * `RING_CANCEL_SPAN + RING_GRADE_SPAN × 5` 必须正好等于 360 —— 只改一个数就会
 * 多出或漏掉一个角。这条等式由 `.workbuddy/tools/ringcheck.py` 守着。
 */
export const RING_GRADE_SPAN: number = 48;

/** 手指落在「取消」格里 */
export const RING_SECTOR_CANCEL: number = 0;
/** 手指还没离开环心（死区内）—— 抬手等于什么都没做 */
export const RING_SECTOR_NONE: number = -1;

/**
 * 手指相对环心的偏移 → 选中哪一格。
 *
 * 返回 `RING_SECTOR_CANCEL`(0) = 取消，1~5 = 等级，`RING_SECTOR_NONE`(-1) = 还在死区里。
 *
 * 角度以**正上方为 0°、顺时针为正**（`atan2(向右的分量, 向上的分量)`），于是
 * **正上是取消、正下是 3 档、正左是 1 档、正右是 5 档** —— 与上一版半圆扇面
 * （1 最左 / 3 正下 / 5 最右）是同一套手感，老师换版式不用重新学。
 *
 * 纯函数（不碰任何状态），所以能直接在 Node 里跑：`ringcheck.py` 会拿它反查
 * "圆点画在哪、手指滑到那就选哪"这条一致性，以及取消格是否真的占 1/3。
 */
export function ringSectorOf(dx: number, dy: number, deadZone: number): number {
  if (dx * dx + dy * dy < deadZone * deadZone) {
    return RING_SECTOR_NONE;
  }
  let psi: number = Math.atan2(dx, -dy) * 180 / Math.PI;
  if (psi < 0) {
    psi += 360;
  }
  const half: number = RING_CANCEL_SPAN / 2;
  if (psi < half || psi >= 360 - half) {
    return RING_SECTOR_CANCEL;
  }
  // 顺时针第几格：0 号格紧贴取消格的右侧（也就是等级 5），依次往左下排到等级 1
  const sector: number = Math.floor((psi - half) / RING_GRADE_SPAN);
  const rank: number = sector > 4 ? 4 : sector;
  return 5 - rank;
}

/**
 * 等级格的**中心角**（度，正上起顺时针）—— 画圆点用。
 *
 * 必须与 `ringSectorOf()` 共用 `RING_CANCEL_SPAN` / `RING_GRADE_SPAN`：
 * 画出来的点落在哪一格，手指滑到那点就必须选中哪一格。两边各写一份角度，迟早
 * 会出现"看着对准了、实际选偏了"，而且编译期一句报错都没有。
 */
export function ringGradeAngle(grade: number): number {
  const sector: number = 5 - grade;
  return RING_CANCEL_SPAN / 2 + RING_GRADE_SPAN * (sector + 0.5);
}

/** 圆环上的一点：**相对环心的偏移**（单位与传入半径一致） */
export interface RingPoint {
  x: number;
  y: number;
}

/**
 * 角度 → 圆环上的偏移量。
 *
 * `angleDeg` 与 `ringSectorOf()` / `ringGradeAngle()` 同一套基准：**正上方 0°、顺时针为正**，
 * 于是 `x = R·sinψ`、`y = −R·cosψ`（屏幕坐标 y 朝下）。
 *
 * 页面**只做"环心 + 这里的偏移"**，不再自己写三角函数：画点的公式和判定的公式必须出自
 * 同一处，否则会出现"看着对准了、实际选偏了"，而且编译期一句话都不会说。
 */
export function ringOffsetOf(angleDeg: number, radius: number): RingPoint {
  const rad: number = angleDeg * Math.PI / 180;
  return { x: radius * Math.sin(rad), y: -radius * Math.cos(rad) };
}

/**
 * 一个学生在**一次课**上的签到结果（页面内存态）。
 *
 * `@ObservedV2` + `@Trace`：点名页把整个班的标记放在一个数组里，
 * 手势改的是某一个学生的 `status` —— 靠 `@Trace` 逐字段观察，
 * 只有那一行重绘，不必每次改动都整体重建数组。
 */
@ObservedV2
export class SignInMark {
  @Trace student_id: number = 0;
  /** `AttendStatus.NONE` 表示这次课还没点到他 */
  @Trace status: string = AttendStatus.NONE;
  /** 等级 1~5；0 = 未评 */
  @Trace grade: number = 0;
  /** 等级算出的随机分；0 = 未算 */
  @Trace score: number = 0;

  static of(studentId: number): SignInMark {
    const mark: SignInMark = new SignInMark();
    mark.student_id = studentId;
    return mark;
  }

  /** 是否已经被点过（三种状态之一）—— 落库时只写点过的，没点的不产生行 */
  marked(): boolean {
    return this.status !== AttendStatus.NONE;
  }

  /** 左滑：旷课 */
  markAbsent(): void {
    this.status = AttendStatus.ABSENT;
    this.grade = 0;
    this.score = 0;
  }

  /** 右滑：请假 */
  markLeave(): void {
    this.status = AttendStatus.LEAVE;
    this.grade = 0;
    this.score = 0;
  }

  /** 长按下滑选等级：出勤 + 等级 + 当场算好的随机分 */
  markGrade(grade: number): void {
    if (!isValidGrade(grade)) {
      return;
    }
    this.status = AttendStatus.PRESENT;
    this.grade = grade;
    this.score = randomScoreOfGrade(grade);
  }

  /** 再滑一次同方向 = 撤销回到未点名（手势误触的退路） */
  reset(): void {
    this.status = AttendStatus.NONE;
    this.grade = 0;
    this.score = 0;
  }
}
