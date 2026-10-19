import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { CourseGraphSaveResult, ScheduleRepository } from '../repository/ScheduleRepository';
import { Course, ClassGroup, TimePeriod } from '../model/Course';
import { DateUtil } from '../common/DateUtil';
import {
  COURSE_TYPES,
  DEFAULT_COLOR,
  PAGE_BG_COLOR,
  HSV,
  cleanName,
  clamp,
  normalizeColor,
  errText,
  alphaOf,
  hexToHsv,
  hsvToHex,
  withAlpha,
  hueColor
} from '../common/Util';
import { Logger } from '../common/Logger';

const TAG: string = 'CourseEditPage';

/** 布局常量 */
interface LAYOUT_Interface {
  headerHeight: number;
  inputHeight: number;
  cardRadius: number;
  chipHeight: number;
  periodRowHeight: number;
}

const LAYOUT: LAYOUT_Interface = {
  headerHeight: 56,
  inputHeight: 46,
  cardRadius: 12,
  chipHeight: 34,
  periodRowHeight: 44
};

/**
 * 表单行图标的强调色。
 *
 * 与页面里其余强调文字（「修改」「+ 添加时间段」等）取同一个蓝，保证"图标 + 文字"
 * 看起来是一套。页面本身还不是主题色感知的（全页硬编码 `#1890FF`），所以这里也不读
 * 主题色 —— 避免出现"图标跟主题变、文字不跟"的割裂。若日后整页接入主题色，改这一处即可。
 */
const FORM_ICON_COLOR: string = '#1890FF';

/** 课程卡片备选色板（截图拾色器的平替：预设 + HEX 输入） */
const PRESET_COLORS: string[] = [
  '#FF6B6B', '#FF9F43', '#FDCB6E', '#4CD97B', '#45B7D1',
  '#4D96FF', '#6C5CE7', '#9B59B6', '#E056FD', '#FC5C65',
  '#96CEB4', '#FFEAA7', '#DDA0DD', '#A29BFE', '#74B9FF',
  '#B2BEC3'
];

interface PendingConflict {
  groupIndex: number;
  periodIndex: number;
  message: string;
}

/**
 * 添加课程页。
 *
 * 设计约束（兼容 docs/06 去 V2 方向）：
 *  - 页面只用 `@State` 顶层引用；
 *  - 所有嵌套变更通过 clone 后替换数组引用触发刷新；
 *  - 不依赖 `@ObjectLink` / `@Trace` 的嵌套响应。
 */
@Entry
@Component
struct CourseEdit {
  // 页面基础状态
  @State busy: boolean = false;
  @State message: string = '';
  @State semesterId: number = 0;
  @State teacherId: number = 0;
  @State maxWeek: number = 20;
  @State maxSession: number = 12;
  @State semesterName: string = '';
  @State teacherName: string = '';

  // 课程字段（扁平化，避免嵌套对象突变不刷新）
  @State courseName: string = '';
  @State courseType: string = '理论';
  @State creditText: string = '';
  @State courseRemark: string = '';

  // 班级分组与时间段
  @State groups: ClassGroup[] = [];

  // 对话框状态
  @State showTypePicker: boolean = false;
  @State showColorPicker: boolean = false;
  @State colorPickerGroupIndex: number = -1;
  @State pickerHue: number = 0;
  @State pickerSaturation: number = 1;
  @State pickerValue: number = 1;
  /** 透明度：1 = 不透明。库表颜色为 #RRGGBB 无 Alpha，保存时把透明度合成到白底上 */
  @State pickerAlpha: number = 1;
  @State pickerBoxSize: number = 280;
  @State showWeekPicker: boolean = false;
  @State weekPickerGroupIndex: number = -1;
  @State weekPickerPeriodIndex: number = -1;
  @State weekDraft: number[] = [];
  @State showWeekdayPicker: boolean = false;
  @State weekdayPickerGroupIndex: number = -1;
  @State weekdayPickerPeriodIndex: number = -1;
  @State weekdayDraft: number = 1;
  @State showSessionPicker: boolean = false;
  @State sessionPickerGroupIndex: number = -1;
  @State sessionPickerPeriodIndex: number = -1;
  @State sessionDraftStart: number = 1;
  @State sessionDraftEnd: number = 2;
  @State showConflictDialog: boolean = false;
  @State pendingConflict: PendingConflict = { groupIndex: -1, periodIndex: -1, message: '' };
  @State savedCourseRowId: number = 0;
  @State forceMode: boolean = false;
  /**
   * 页面参数（学期 / 教师）非法：此时**禁止保存**。
   *
   * 之前只判断 `<= 0`，而 `parseInt` 失败得到的是 `NaN`，`NaN <= 0` 恒为 false ——
   * 参数缺失时照样能"保存成功"，但课程会挂到 semester_id = NaN 上，
   * 既不属于任何学期、也永远不出现在课表里（正是"加了课程却看不到"的一种成因）。
   */
  @State badParams: boolean = false;

  // ---- 编辑模式（'add' / 'editCourse' / 'editGroup'） ----
  @State editMode: string = 'add';
  @State focusGroupId: number = 0;
  /** 编辑过程中被用户删除、保存时需从库中清除的分组 / 时间段主键 */
  private removedGroupIds: number[] = [];
  private removedPeriodIds: number[] = [];

  aboutToAppear(): void {
    this.loadParams();
  }

  private context(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }

  private loadParams(): void {
    const params: Record<string, Object> | undefined = router.getParams() as Record<string, Object>;
    if (params === undefined) {
      this.badParams = true;
      this.message = '缺少页面参数';
      return;
    }
    this.semesterId = parseInt('' + params['semesterId']);
    this.teacherId = parseInt('' + params['teacherId']);
    this.maxWeek = parseInt('' + params['maxWeek']);
    this.maxSession = parseInt('' + params['maxSession']);
    this.semesterName = params['semesterName'] as string;
    this.teacherName = params['teacherName'] as string;

    if (isNaN(this.maxWeek) || this.maxWeek <= 0) {
      this.maxWeek = 20;
    }
    if (isNaN(this.maxSession) || this.maxSession <= 0) {
      this.maxSession = 12;
    }

    // NaN 也要拦住（见 badParams 注释）：NaN 与 0 都必须判为非法参数
    if (isNaN(this.semesterId) || this.semesterId <= 0
      || isNaN(this.teacherId) || this.teacherId <= 0) {
      this.badParams = true;
      this.message = '参数异常：学期或教师未指定';
      return;
    }

    const mode: string = params['mode'] === undefined ? 'add' : params['mode'] as string;
    const courseRowId: number =
      params['courseRowId'] === undefined ? 0 : parseInt('' + params['courseRowId']);
    this.focusGroupId =
      params['focusGroupId'] === undefined ? 0 : parseInt('' + params['focusGroupId']);

    if (mode === 'editCourse' || mode === 'editGroup') {
      if (isNaN(courseRowId) || courseRowId <= 0) {
        this.badParams = true;
        this.message = '参数异常：未指定要编辑的课程';
        return;
      }
      if (mode === 'editGroup' && (isNaN(this.focusGroupId) || this.focusGroupId <= 0)) {
        this.badParams = true;
        this.message = '参数异常：未指定要编辑的班级';
        return;
      }
      this.editMode = mode;
      this.loadExistingCourse(courseRowId);
      return;
    }

    // 默认添加一个班级分组和一段全学期时间
    this.addGroup();
    ScheduleRepository.getInstance().init(this.context()).catch((e: Object) => {
      Logger.error(TAG, `初始化仓库失败：${errText(e)}`);
    });
  }

  /** 编辑模式：从库中加载课程（editGroup 只保留聚焦的班级分组）填充表单 */
  private async loadExistingCourse(courseRowId: number): Promise<void> {
    try {
      const repo: ScheduleRepository = ScheduleRepository.getInstance();
      await repo.init(this.context());
      const course: Course | undefined = await repo.loadCourseForEdit(courseRowId);
      if (course === undefined) {
        this.message = '课程不存在或已被删除';
        return;
      }
      this.courseName = course.course_name;
      this.courseType = course.course_type;
      this.creditText = course.course_score === null ? '' : `${course.course_score}`;
      this.courseRemark = course.course_remark;
      this.savedCourseRowId = course.id;

      if (this.editMode === 'editGroup') {
        const focused: ClassGroup[] = [];
        for (let i = 0; i < course.class_groups.length; i++) {
          if (course.class_groups[i].id === this.focusGroupId) {
            focused.push(course.class_groups[i]);
          }
        }
        if (focused.length === 0) {
          this.message = '该班级分组不存在或已被删除';
          return;
        }
        this.groups = focused;
      } else {
        this.groups = course.class_groups;
      }
      Logger.info(TAG, `编辑模式加载课程 #${courseRowId}：${this.groups.length} 个班级分组`);
    } catch (e) {
      this.message = `加载课程失败：${errText(e)}`;
      Logger.error(TAG, this.message);
    }
  }

  // ---------------------------------------------------------------- 课程字段

  private setCourseType(type: string): void {
    this.courseType = type;
    this.showTypePicker = false;
  }

  /** 页头标题：添加 / 编辑课程 / 编辑班级 */
  private pageTitle(): string {
    if (this.editMode === 'editCourse') {
      return '编辑课程';
    }
    if (this.editMode === 'editGroup') {
      return '编辑班级';
    }
    return '添加课程';
  }

  // ---------------------------------------------------------------- 班级分组操作

  private addGroup(): void {
    const group: ClassGroup = new ClassGroup();
    group.class_name = '';
    group.population = 0;
    // 预设色板是 6 位写法，这里归一化成 8 位 ARGB（补 FF Alpha），与库表格式一致
    group.color = normalizeColor(PRESET_COLORS[this.groups.length % PRESET_COLORS.length]);
    group.time_periods = [TimePeriod.empty(this.maxWeek)];

    const next: ClassGroup[] = this.groups.slice();
    next.push(group);
    this.groups = next;
  }

  private removeGroup(index: number): void {
    // 「编辑班级」页不提供删除能力：界面上已隐藏复制/删除入口，这里再兜一层，
    // 保证"编辑班级页里永远删不掉这个班级"（删除统一走课表详情菜单的「删除本班级的课」）。
    if (this.editMode === 'editGroup') {
      Logger.info(TAG, '编辑班级模式：本页不允许删除该班级，已忽略');
      return;
    }
    if (index < 0 || index >= this.groups.length) {
      return;
    }
    const group: ClassGroup = this.groups[index];
    if (group.id > 0) {
      this.removedGroupIds.push(group.id);
    }
    const next: ClassGroup[] = this.groups.slice();
    next.splice(index, 1);
    this.groups = next;
  }

  private duplicateGroup(index: number): void {
    if (index < 0 || index >= this.groups.length) {
      return;
    }
    const copy: ClassGroup = this.groups[index].clone();
    copy.id = 0;
    // 时间段也视为新增
    for (let i = 0; i < copy.time_periods.length; i++) {
      copy.time_periods[i].id = 0;
    }
    // 复制的是"时间段安排"，不是班级身份：class_id / class_name / population 都是
    // 班级自己的属性，带着走会让副本在保存时命中同一个 class_id —— 走 rename 分支
    // 把源班的档案改了名、两个分组在库里合并成一行（多班合并缺陷的根因）。
    // 名称留空由用户重填，漏填会被 validate() 拦住。
    copy.class_id = '';
    copy.class_name = '';
    copy.population = 0;
    const next: ClassGroup[] = this.groups.slice();
    next.splice(index + 1, 0, copy);
    this.groups = next;
  }

  private replaceGroup(index: number, updater: (g: ClassGroup) => ClassGroup): void {
    if (index < 0 || index >= this.groups.length) {
      return;
    }
    const next: ClassGroup[] = this.groups.slice();
    next[index] = updater(next[index].clone());
    this.groups = next;
  }

  private setGroupName(index: number, value: string): void {
    this.replaceGroup(index, (g: ClassGroup) => {
      g.class_name = cleanName(value, '');
      return g;
    });
  }

  private setGroupPopulation(index: number, value: string): void {
    const n: number = parseInt(value.trim());
    this.replaceGroup(index, (g: ClassGroup) => {
      g.population = isNaN(n) || n < 0 ? 0 : n;
      return g;
    });
  }

  private setGroupColor(index: number, color: string): void {
    this.replaceGroup(index, (g: ClassGroup) => {
      g.color = normalizeColor(color);
      return g;
    });
  }

  // ---------------------------------------------------------------- 时间段操作

  private replacePeriod(groupIndex: number, periodIndex: number,
    updater: (p: TimePeriod) => TimePeriod): void {
    this.replaceGroup(groupIndex, (g: ClassGroup) => {
      if (periodIndex < 0 || periodIndex >= g.time_periods.length) {
        return g;
      }
      const periods: TimePeriod[] = g.time_periods.slice();
      periods[periodIndex] = updater(periods[periodIndex].clone());
      g.time_periods = periods;
      return g;
    });
  }

  private addPeriodToGroup(groupIndex: number): void {
    this.replaceGroup(groupIndex, (g: ClassGroup) => {
      const periods: TimePeriod[] = g.time_periods.slice();
      periods.push(TimePeriod.empty(this.maxWeek));
      g.time_periods = periods;
      return g;
    });
  }

  private removePeriodFromGroup(groupIndex: number, periodIndex: number): void {
    if (groupIndex < 0 || groupIndex >= this.groups.length) {
      return;
    }
    // 编辑模式：记录被删时间段的库内主键，保存时同步删除
    if (periodIndex >= 0 && periodIndex < this.groups[groupIndex].time_periods.length) {
      const periodId: number = this.groups[groupIndex].time_periods[periodIndex].id;
      if (periodId > 0) {
        this.removedPeriodIds.push(periodId);
      }
    }
    this.replaceGroup(groupIndex, (g: ClassGroup) => {
      if (periodIndex < 0 || periodIndex >= g.time_periods.length) {
        return g;
      }
      const periods: TimePeriod[] = g.time_periods.slice();
      periods.splice(periodIndex, 1);
      g.time_periods = periods;
      return g;
    });
  }

  private setPeriodWeeks(groupIndex: number, periodIndex: number, weeks: number[]): void {
    this.replacePeriod(groupIndex, periodIndex, (p: TimePeriod) => {
      p.week_nums = weeks.slice();
      return p;
    });
  }

  private setPeriodWeekday(groupIndex: number, periodIndex: number, weekday: number): void {
    this.replacePeriod(groupIndex, periodIndex, (p: TimePeriod) => {
      p.weekday = clamp(weekday, 1, 7);
      return p;
    });
  }

  private setPeriodSessions(groupIndex: number, periodIndex: number, start: number, end: number): void {
    const s: number = clamp(start, 1, this.maxSession);
    let e: number = clamp(end, 1, this.maxSession);
    if (e < s) {
      e = s;
    }
    this.replacePeriod(groupIndex, periodIndex, (p: TimePeriod) => {
      p.start_time = s;
      p.end_time = e;
      return p;
    });
  }

  private setPeriodRoom(groupIndex: number, periodIndex: number, value: string): void {
    this.replacePeriod(groupIndex, periodIndex, (p: TimePeriod) => {
      p.class_room = value.trim();
      return p;
    });
  }

  private setPeriodRemark(groupIndex: number, periodIndex: number, value: string): void {
    this.replacePeriod(groupIndex, periodIndex, (p: TimePeriod) => {
      p.remark = value.trim();
      return p;
    });
  }

  // ---------------------------------------------------------------- 保存

  private validate(): string {
    if (this.badParams) {
      return '参数异常：学期或教师未指定，无法保存';
    }
    if (cleanName(this.courseName, '').length === 0) {
      return '请输入课程名称';
    }
    if (this.groups.length === 0) {
      return '请至少添加一个班级分组';
    }
    // 同一门课里班名必须互不相同：同名会让两个分组解析到同一个 class_id，
    // 保存时在库里合并成一个班级（多班合并缺陷的同名路径）。空名交给下面原有检查。
    const seenNames: string[] = [];
    for (let i = 0; i < this.groups.length; i++) {
      const name: string = cleanName(this.groups[i].class_name, '');
      if (name.length === 0) {
        continue;
      }
      if (seenNames.indexOf(name) >= 0) {
        return `班级名称「${name}」在本课程里重复了，同一门课的每个班级要用不同的名称`;
      }
      seenNames.push(name);
    }
    for (let i = 0; i < this.groups.length; i++) {
      const g: ClassGroup = this.groups[i];
      if (cleanName(g.class_name, '').length === 0) {
        return `班级 ${i + 1} 名称不能为空`;
      }
      // 时间段一个都没有的课程 = 永远不在课表上出现（课表按 v_lesson 渲染，没有周次就没有行），
      // 必须在这里拦住：否则用户会得到一门"保存成功却找不到"的课
      if (g.time_periods.length === 0) {
        return `班级 ${i + 1} 至少需要一个时间段（周次 / 星期 / 节次）`;
      }
      for (let j = 0; j < g.time_periods.length; j++) {
        const p: TimePeriod = g.time_periods[j];
        if (p.week_nums.length === 0) {
          return `班级 ${i + 1} 时间段 ${j + 1} 未设置周次`;
        }
        if (p.start_time > p.end_time) {
          return `班级 ${i + 1} 时间段 ${j + 1} 起始节次不能大于结束节次`;
        }
      }
    }
    return '';
  }

  /**
   * 保存课程。
   *
   * 走 Repository 的 `saveCourseGraph`：课程 + 班级分组 + 时间段 + 周次在**一个事务**里写完。
   * 冲突时不写任何一行（整体回滚），把冲突交回界面由用户决定 —— 绝不留下
   * "课程有了、时间段没有"的空壳（那种课程在课表里永远不显示，是"新增课程看不到"的根因）。
   */
  private async saveCourse(): Promise<void> {
    const error: string = this.validate();
    if (error.length > 0) {
      this.message = error;
      return;
    }

    this.busy = true;
    this.message = '';
    try {
      const course: Course = Course.create(cleanName(this.courseName, '未命名课程'), this.courseType);
      const credit: number = parseFloat(this.creditText.trim());
      course.course_score = isNaN(credit) || this.creditText.trim().length === 0 ? null : credit;
      course.course_remark = this.courseRemark.trim();
      course.id = this.savedCourseRowId;
      course.class_groups = this.groups;

      const result: CourseGraphSaveResult = await ScheduleRepository.getInstance().saveCourseGraph(
        this.semesterId, this.teacherId, course, this.groups,
        this.removedGroupIds, this.removedPeriodIds, this.maxWeek, this.forceMode);

      if (!result.saved) {
        if (result.conflicts.length > 0 && !this.forceMode) {
          this.pendingConflict = {
            groupIndex: -1,
            periodIndex: -1,
            message: result.message.length > 0 ? result.message : '与现有课程时间冲突'
          };
          this.showConflictDialog = true;
          this.busy = false;
          return;
        }
        this.message = result.message.length > 0 ? result.message : '保存失败';
        this.busy = false;
        return;
      }

      this.savedCourseRowId = result.courseRowId;
      this.removedGroupIds = [];
      this.removedPeriodIds = [];
      this.message = '保存成功';
      Logger.info(TAG, `课程「${course.course_name}」保存完成，courseRowId=${result.courseRowId}`);
      router.back();
    } catch (e) {
      this.message = `保存失败：${errText(e)}`;
      Logger.error(TAG, this.message);
    }
    this.busy = false;
  }

  private async forceSaveConflict(): Promise<void> {
    this.forceMode = true;
    this.showConflictDialog = false;
    await this.saveCourse();
  }

  private cancelConflict(): void {
    // 冲突时整次保存已回滚：库里没有留下任何半截数据，界面保持原样等用户改时间
    this.showConflictDialog = false;
    this.message = '已取消保存：本次改动没有写入数据库，请调整时间后重试';
  }

  // ---------------------------------------------------------------- 格式化

  private sessionRange(): number[] {
    const result: number[] = [];
    for (let i: number = 1; i <= this.maxSession; i++) {
      result.push(i);
    }
    return result;
  }

  /** 节次芯片按每行 4 个分组，配合 layoutWeight 实现等宽 + 横向均匀分布 */
  private sessionRows(): number[][] {
    const all: number[] = this.sessionRange();
    const rows: number[][] = [];
    for (let i: number = 0; i < all.length; i += 4) {
      const row: number[] = [];
      for (let j: number = i; j < i + 4 && j < all.length; j++) {
        row.push(all[j]);
      }
      rows.push(row);
    }
    return rows;
  }

  private formatPeriodSummary(p: TimePeriod): string {
    return `${DateUtil.formatWeeks(p.week_nums)} · ${DateUtil.weekdayLabel(p.weekday)} · 第${p.start_time}-${p.end_time}节`;
  }

  /**
   * 班级分组的内容签名：覆盖时间段所有"非文本输入"的展示字段（id/节次/星期/周次集合）。
   *
   * 为什么需要：班级卡片的 ForEach key 必须能感知时间段变化，否则通过弹窗修改
   * 节次/星期/周次后卡片不重建、显示停留在旧值。而 class_name / population /
   * class_room / remark 是 TextInput 直接绑定的字段，纳入 key 会导致每敲一个
   * 字符就整卡重建、输入框丢焦点，因此刻意排除。
   */
  private groupSignature(group: ClassGroup): string {
    let sig: string = '';
    for (let i = 0; i < group.time_periods.length; i++) {
      const p: TimePeriod = group.time_periods[i];
      sig += `${p.id}:${p.start_time}-${p.end_time}-${p.weekday}-${p.week_nums.join(',')};`;
    }
    return sig;
  }

  // ---------------------------------------------------------------- 弹窗操作

  private openColorPicker(groupIndex: number): void {
    this.colorPickerGroupIndex = groupIndex;
    const hsv: HSV = hexToHsv(this.groups[groupIndex].color);
    this.pickerHue = hsv.h;
    this.pickerSaturation = hsv.s;
    this.pickerValue = hsv.v;
    this.pickerAlpha = alphaOf(this.groups[groupIndex].color);
    this.showColorPicker = true;
  }

  /** 当前 HSV 的纯色 HEX（不含透明度，用于方形底色 / 色相与透明度条的渐变端点） */
  private pickerHex(): string {
    return hsvToHex(this.pickerHue, this.pickerSaturation, this.pickerValue);
  }

  /** 展示/落库颜色：8 位 ARGB `#AARRGGBB`，透明度真实生效 */
  private pickerARGB(): string {
    return withAlpha(this.pickerHex(), this.pickerAlpha);
  }

  private confirmColor(): void {
    if (this.colorPickerGroupIndex >= 0 && this.colorPickerGroupIndex < this.groups.length) {
      this.setGroupColor(this.colorPickerGroupIndex, this.pickerARGB());
    }
    this.showColorPicker = false;
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
    }
  }

  private onHueTouch(event: TouchEvent): void {
    if (event.touches.length === 0) {
      return;
    }
    if (event.type === TouchType.Down || event.type === TouchType.Move) {
      const x: number = event.touches[0].x;
      this.pickerHue = clamp(Math.round((x / this.pickerBoxSize) * 360), 0, 360);
    }
  }

  private onAlphaTouch(event: TouchEvent): void {
    if (event.touches.length === 0) {
      return;
    }
    if (event.type === TouchType.Down || event.type === TouchType.Move) {
      const x: number = event.touches[0].x;
      this.pickerAlpha = clamp(x / this.pickerBoxSize, 0, 1);
    }
  }

  private onHexInput(value: string): void {
    const hsv: HSV = hexToHsv(value);
    this.pickerHue = hsv.h;
    this.pickerSaturation = hsv.s;
    this.pickerValue = hsv.v;
    this.pickerAlpha = alphaOf(value);
  }

  private openWeekPicker(groupIndex: number, periodIndex: number): void {
    this.weekPickerGroupIndex = groupIndex;
    this.weekPickerPeriodIndex = periodIndex;
    this.weekDraft = this.groups[groupIndex].time_periods[periodIndex].week_nums.slice();
    this.showWeekPicker = true;
  }

  private toggleWeekChip(week: number): void {
    const idx: number = this.weekDraft.indexOf(week);
    const next: number[] = this.weekDraft.slice();
    if (idx >= 0) {
      next.splice(idx, 1);
    } else {
      next.push(week);
      next.sort((a: number, b: number) => a - b);
    }
    this.weekDraft = next;
  }

  private applyWeekPattern(pattern: 'all' | 'odd' | 'even' | 'clear'): void {
    const next: number[] = [];
    if (pattern === 'all') {
      for (let i: number = 1; i <= this.maxWeek; i++) {
        next.push(i);
      }
    } else if (pattern === 'odd') {
      for (let i: number = 1; i <= this.maxWeek; i += 2) {
        next.push(i);
      }
    } else if (pattern === 'even') {
      for (let i: number = 2; i <= this.maxWeek; i += 2) {
        next.push(i);
      }
    }
    this.weekDraft = next;
  }

  private confirmWeekPicker(): void {
    if (this.weekPickerGroupIndex >= 0 && this.weekPickerPeriodIndex >= 0) {
      this.setPeriodWeeks(this.weekPickerGroupIndex, this.weekPickerPeriodIndex, this.weekDraft);
    }
    this.showWeekPicker = false;
  }

  private openWeekdayPicker(groupIndex: number, periodIndex: number): void {
    this.weekdayPickerGroupIndex = groupIndex;
    this.weekdayPickerPeriodIndex = periodIndex;
    this.weekdayDraft = this.groups[groupIndex].time_periods[periodIndex].weekday;
    this.showWeekdayPicker = true;
  }

  private confirmWeekdayPicker(): void {
    if (this.weekdayPickerGroupIndex >= 0 && this.weekdayPickerPeriodIndex >= 0) {
      this.setPeriodWeekday(this.weekdayPickerGroupIndex, this.weekdayPickerPeriodIndex, this.weekdayDraft);
    }
    this.showWeekdayPicker = false;
  }

  private openSessionPicker(groupIndex: number, periodIndex: number): void {
    this.sessionPickerGroupIndex = groupIndex;
    this.sessionPickerPeriodIndex = periodIndex;
    this.sessionDraftStart = this.groups[groupIndex].time_periods[periodIndex].start_time;
    this.sessionDraftEnd = this.groups[groupIndex].time_periods[periodIndex].end_time;
    this.showSessionPicker = true;
  }

  private confirmSessionPicker(): void {
    if (this.sessionPickerGroupIndex >= 0 && this.sessionPickerPeriodIndex >= 0) {
      this.setPeriodSessions(this.sessionPickerGroupIndex, this.sessionPickerPeriodIndex,
        this.sessionDraftStart, this.sessionDraftEnd);
    }
    this.showSessionPicker = false;
  }

  // ---------------------------------------------------------------- Builder

  /**
   * 表单行左侧图标：统一 20vp、强调色，外观占位恒为 28vp（与原字符字形的占位一致），
   * 这样每一行的文字左边缘都严格对齐。
   *
   * `icon` 是 `$r(...)` 常量资源，**不随状态变化** —— 按值传参在这里是安全的。
   * （`@Builder` 的按值参数不参与状态观察，只有"会变的 `@Local` 状态"才不能按值传进去，
   * 见 `Index.weekPage` 那次的教训。）
   *
   * 换图原因：早先每行用的是 `☰` / `▣` / `★` / `✎` / `⬜` / `☼` / `◷` / `◎` / `☺` 这类
   * 字符字形，依赖系统字体回退，不同设备上的字形、字重、基线都不一致，且无法上色统一。
   */
  @Builder
  formIcon(icon: Resource) {
    Row() {
      Image(icon)
        .width(20)
        .height(20)
        .fillColor(FORM_ICON_COLOR)
    }
    .width(28)
    .height(20)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  header() {
    Row() {
      Row() {
        Text('‹')
          .fontSize(28)
          .fontColor('#111827')
          .onClick(() => router.back())
      }
      .width(40)
      .height(LAYOUT.headerHeight)
      .justifyContent(FlexAlign.Center)

      Text(this.pageTitle())
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor('#111827')

      Row() {
        Text('✓')
          .fontSize(22)
          .fontColor(this.busy || this.badParams ? '#9CA3AF' : '#111827')
          .onClick(() => {
            // 参数非法时禁止保存：否则会写出一门挂不到任何学期的"隐形课程"
            if (!this.busy && !this.badParams) {
              this.saveCourse();
            }
          })
      }
      .width(40)
      .height(LAYOUT.headerHeight)
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .height(LAYOUT.headerHeight)
    .padding({ left: 8, right: 8 })
    .backgroundColor('#F3F4F6')
    .justifyContent(FlexAlign.SpaceBetween)
  }

  /**
   * 只读课程信息的取值。
   *
   * 值一律**现读状态**再返回，配合 `courseInfoRow(icon, field)` 使用 ——
   * 见 `courseInfoRow` 上的说明：绝不能把值本身按值传给 @Builder。
   */
  private courseInfoValue(field: string): string {
    if (field === 'name') {
      return cleanName(this.courseName, '').length > 0 ? this.courseName : '未填写';
    }
    if (field === 'type') {
      return this.courseType.length > 0 ? this.courseType : '未设置';
    }
    if (field === 'score') {
      return this.creditText.trim().length > 0 ? this.creditText.trim() : '未设置';
    }
    return this.courseRemark.trim().length > 0 ? this.courseRemark.trim() : '无';
  }

  @Builder
  courseSection() {
    if (this.editMode === 'editGroup') {
      // 编辑班级：课程字段不可改，避免"只想改班名、手滑改掉了课程名/学分"
      this.courseInfoReadonly()
    } else {
      Column({ space: 12 }) {
        Row({ space: 12 }) {
          this.formIcon($r('app.media.ic_courseName'))
          TextInput({ placeholder: '课程名称', text: this.courseName })
            .fontSize(15)
            .height(LAYOUT.inputHeight)
            .backgroundColor('transparent')
            .layoutWeight(1)
            .textAlign(TextAlign.Start)
            .padding({ left: 0, right: 0 })
            .onChange((value: string) => {
              this.courseName = value;
            })
        }
        .width('100%')
        .height(LAYOUT.inputHeight)
        .alignItems(VerticalAlign.Center)

        Row({ space: 12 }) {
          this.formIcon($r('app.media.ic_courseType'))
          Row() {
            Text(this.courseType.length > 0 ? this.courseType : '选择类型')
              .fontSize(15)
              .fontColor(this.courseType.length > 0 ? '#111827' : '#9CA3AF')
              .layoutWeight(1)
            Text('›')
              .fontSize(18)
              .fontColor('#9CA3AF')
          }
          .width('100%')
          .height(LAYOUT.inputHeight)
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.showTypePicker = true;
          })
        }
        .width('100%')
        .height(LAYOUT.inputHeight)
        .alignItems(VerticalAlign.Center)

        Row({ space: 12 }) {
          this.formIcon($r('app.media.ic_score'))
          TextInput({ placeholder: '学分（可不填）', text: this.creditText })
            .type(InputType.Number)
            .fontSize(15)
            .height(LAYOUT.inputHeight)
            .backgroundColor('transparent')
            .layoutWeight(1)
            .textAlign(TextAlign.Start)
            .padding({ left: 0, right: 0 })
            .onChange((value: string) => {
              this.creditText = value;
            })
        }
        .width('100%')
        .height(LAYOUT.inputHeight)
        .alignItems(VerticalAlign.Center)

        Row({ space: 12 }) {
          this.formIcon($r('app.media.ic_remark'))
          TextInput({ placeholder: '备注（可不填）', text: this.courseRemark })
            .fontSize(15)
            .height(LAYOUT.inputHeight)
            .backgroundColor('transparent')
            .layoutWeight(1)
            .textAlign(TextAlign.Start)
            .padding({ left: 0, right: 0 })
            .onChange((value: string) => {
              this.courseRemark = value;
            })
        }
        .width('100%')
        .height(LAYOUT.inputHeight)
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .padding(16)
      .backgroundColor('#FFFFFF')
      .borderRadius(LAYOUT.cardRadius)
    }
  }

  /** 「编辑班级」模式下的课程信息只读卡（灰底 + 「只读」角标，不提供任何输入入口） */
  @Builder
  courseInfoReadonly() {
    Column({ space: 12 }) {
      Row() {
        Text('课程信息')
          .fontSize(13)
          .fontColor('#6B7280')
          .layoutWeight(1)
        Text('只读')
          .fontSize(11)
          .fontColor('#6B7280')
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .backgroundColor('#E5E7EB')
          .borderRadius(4)
      }
      .width('100%')

      this.courseInfoRow($r('app.media.ic_courseName'), 'name')
      this.courseInfoRow($r('app.media.ic_courseType'), 'type')
      this.courseInfoRow($r('app.media.ic_score'), 'score')
      this.courseInfoRow($r('app.media.ic_remark'), 'remark')
    }
    .width('100%')
    .padding(16)
    .backgroundColor('#F9FAFB')
    .borderRadius(LAYOUT.cardRadius)
  }

  /**
   * 只读信息行。
   *
   * **`field` 是编译期字面量**（'name' / 'type' / 'score' / 'remark'），不随状态变化，
   * 按值传进来是安全的；真正的值由 `courseInfoValue(field)` 在渲染时现读 `this.*`。
   * 反过来做（`courseInfoRow(icon, this.courseName)`）会把这一整块冻在首帧的空值上 ——
   * 本页课程字段由 `loadExistingCourse()` 异步回填，首帧必然是空串，正是
   * `Index.weekPage` 那次"@Builder 按值传参冻结整页"的同类陷阱。
   */
  @Builder
  courseInfoRow(icon: Resource, field: string) {
    Row({ space: 12 }) {
      this.formIcon(icon)
      Text(this.courseInfoValue(field))
        .fontSize(15)
        .fontColor('#4B5563')
        .layoutWeight(1)
        .textAlign(TextAlign.Start)
    }
    .width('100%')
    .height(LAYOUT.inputHeight)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  periodRow(groupIndex: number, periodIndex: number, period: TimePeriod) {
    Column({ space: 8 }) {
      // 周次
      Row({ space: 12 }) {
        this.formIcon($r('app.media.ic_week'))
        Text(DateUtil.formatWeeks(period.week_nums))
          .fontSize(14)
          .fontColor('#111827')
          .layoutWeight(1)
          .textAlign(TextAlign.Start)
        Text('修改')
          .fontSize(12)
          .fontColor('#1890FF')
      }
      .width('100%')
      .height(LAYOUT.periodRowHeight)
      .alignItems(VerticalAlign.Center)
      .onClick(() => this.openWeekPicker(groupIndex, periodIndex))

      // 星期 + 节次
      Row({ space: 12 }) {
        this.formIcon($r('app.media.ic_time'))
        Text(DateUtil.weekdayLabel(period.weekday))
          .fontSize(14)
          .fontColor('#111827')
          .layoutWeight(1)
          .textAlign(TextAlign.Start)
        Text('修改')
          .fontSize(12)
          .fontColor('#1890FF')
      }
      .width('100%')
      .height(LAYOUT.periodRowHeight)
      .alignItems(VerticalAlign.Center)
      .onClick(() => this.openWeekdayPicker(groupIndex, periodIndex))

      Row({ space: 12 }) {
        this.formIcon($r('app.media.ic_time'))
        Text(`第${period.start_time} - ${period.end_time}节`)
          .fontSize(14)
          .fontColor('#111827')
          .layoutWeight(1)
          .textAlign(TextAlign.Start)
        Text('修改')
          .fontSize(12)
          .fontColor('#1890FF')
      }
      .width('100%')
      .height(LAYOUT.periodRowHeight)
      .alignItems(VerticalAlign.Center)
      .onClick(() => this.openSessionPicker(groupIndex, periodIndex))

      // 教室
      Row({ space: 12 }) {
        this.formIcon($r('app.media.ic_classRoom'))
        TextInput({ placeholder: '教室', text: period.class_room })
          .fontSize(14)
          .height(LAYOUT.inputHeight)
          .backgroundColor('transparent')
          .layoutWeight(1)
          .textAlign(TextAlign.Start)
          .padding({ left: 0, right: 0 })
          .onChange((value: string) => {
            this.setPeriodRoom(groupIndex, periodIndex, value);
          })
      }
      .width('100%')
      .height(LAYOUT.inputHeight)
      .alignItems(VerticalAlign.Center)

      // 备注
      Row({ space: 12 }) {
        this.formIcon($r('app.media.ic_remark'))
        TextInput({ placeholder: '备注', text: period.remark })
          .fontSize(14)
          .height(LAYOUT.inputHeight)
          .backgroundColor('transparent')
          .layoutWeight(1)
          .textAlign(TextAlign.Start)
          .padding({ left: 0, right: 0 })
          .onChange((value: string) => {
            this.setPeriodRemark(groupIndex, periodIndex, value);
          })
      }
      .width('100%')
      .height(LAYOUT.inputHeight)
      .alignItems(VerticalAlign.Center)

      Row() {
        Text('复制')
          .fontSize(13)
          .fontColor('#1890FF')
          .onClick(() => this.duplicatePeriod(groupIndex, periodIndex))
        Blank()
        Text('删除')
          .fontSize(13)
          .fontColor('#EF4444')
          .onClick(() => this.removePeriodFromGroup(groupIndex, periodIndex))
      }
      .width('100%')
      .padding({ top: 4 })
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#F9FAFB')
    .borderRadius(8)
  }

  private duplicatePeriod(groupIndex: number, periodIndex: number): void {
    this.replaceGroup(groupIndex, (g: ClassGroup) => {
      if (periodIndex < 0 || periodIndex >= g.time_periods.length) {
        return g;
      }
      const periods: TimePeriod[] = g.time_periods.slice();
      const copy: TimePeriod = periods[periodIndex].clone();
      copy.id = 0;
      periods.splice(periodIndex + 1, 0, copy);
      g.time_periods = periods;
      return g;
    });
  }

  @Builder
  classGroupCard(group: ClassGroup, index: number) {
    Column({ space: 12 }) {
      // 班级头部
      Row() {
        Text(this.editMode === 'editGroup' ? '本班级' : `班级 ${index + 1}`)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#111827')
          .layoutWeight(1)
        // 「编辑班级」页不提供删除入口：本页只负责改这一个班级，删除统一走课表详情菜单
        if (this.editMode !== 'editGroup') {
          Text('删除')
            .fontSize(13)
            .fontColor('#EF4444')
            .onClick(() => this.removeGroup(index))
        }
      }
      .width('100%')

      // 班名
      Row({ space: 12 }) {
        this.formIcon($r('app.media.ic_class'))
        TextInput({ placeholder: '请输入班级名称', text: group.class_name })
          .fontSize(15)
          .height(LAYOUT.inputHeight)
          .backgroundColor('transparent')
          .layoutWeight(1)
          .textAlign(TextAlign.Start)
          .padding({ left: 0, right: 0 })
          .onChange((value: string) => {
            this.setGroupName(index, value);
          })
      }
      .width('100%')
      .height(LAYOUT.inputHeight)
      .alignItems(VerticalAlign.Center)

      // 人数 + 颜色
      Row({ space: 12 }) {
        this.formIcon($r('app.media.ic_student'))
        TextInput({ placeholder: '0', text: group.population > 0 ? `${group.population}` : '' })
          .type(InputType.Number)
          .fontSize(15)
          .height(LAYOUT.inputHeight)
          .backgroundColor('transparent')
          .width(60)
          .textAlign(TextAlign.Start)
          .padding({ left: 0, right: 0 })
          .onChange((value: string) => {
            this.setGroupPopulation(index, value);
          })
        Blank()
        Row({ space: 6 }) {
          Column()
            .width(18)
            .height(18)
            .backgroundColor(normalizeColor(group.color))
            .borderRadius(9)
          Text('点击修改颜色')
            .fontSize(13)
            .fontColor('#111827')
        }
        .onClick(() => this.openColorPicker(index))
      }
      .width('100%')
      .height(LAYOUT.inputHeight)
      .alignItems(VerticalAlign.Center)

      // 时间段
      ForEach(group.time_periods, (period: TimePeriod, pi: number) => {
        this.periodRow(index, pi, period)
      }, (period: TimePeriod, pi: number) =>
        `${index}-${pi}-${period.id}-${period.start_time}-${period.end_time}-${period.weekday}`
        + `-${period.class_room}-${period.remark}-${period.week_nums.length}`)

      // 新增时间段
      Text('+ 添加时间段')
        .fontSize(14)
        .fontColor('#1890FF')
        .width('100%')
        .height(40)
        .textAlign(TextAlign.Center)
        .onClick(() => this.addPeriodToGroup(index))

      // 复制 / 删除本班（「编辑班级」页整行隐藏：既不复制也不删除）
      if (this.editMode !== 'editGroup') {
        Row() {
          Text('复制')
            .fontSize(14)
            .fontColor('#1890FF')
            .onClick(() => this.duplicateGroup(index))
          Blank()
          Text('删除')
            .fontSize(14)
            .fontColor('#EF4444')
            .onClick(() => this.removeGroup(index))
        }
        .width('100%')
        .padding({ top: 4 })
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor('#FFFFFF')
    .borderRadius(LAYOUT.cardRadius)
  }

  @Builder
  typePickerOverlay() {
    Column() {
      Column()
        .width('100%')
        .layoutWeight(1)
        .backgroundColor('rgba(0,0,0,0.4)')
        .onClick(() => {
          this.showTypePicker = false;
        })

      Column({ space: 12 }) {
        Text('选择课程类型')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#111827')
          .width('100%')
          .textAlign(TextAlign.Center)

        Column() {
          ForEach(COURSE_TYPES, (type: string) => {
            Row() {
              Text(type)
                .fontSize(15)
                .fontColor(this.courseType === type ? '#1890FF' : '#111827')
                .layoutWeight(1)
              if (this.courseType === type) {
                Text('✓')
                  .fontSize(14)
                  .fontColor('#1890FF')
              }
            }
            .width('100%')
            .height(48)
            .padding({ left: 16, right: 16 })
            .backgroundColor(this.courseType === type ? '#EFF6FF' : '#FFFFFF')
            .onClick(() => this.setCourseType(type))
          }, (type: string) => type)
        }
        .width('100%')
        .backgroundColor('#FFFFFF')
        .borderRadius(10)

        Button('取消')
          .fontSize(15)
          .width('100%')
          .height(46)
          .backgroundColor('#F3F4F6')
          .fontColor('#111827')
          .onClick(() => {
            this.showTypePicker = false;
          })
      }
      .width('100%')
      .padding(16)
      .backgroundColor('#F3F4F6')
      .borderRadius({ topLeft: 16, topRight: 16 })
    }
    .width('100%')
    .height('100%')
    .position({ x: 0, y: 0 })
  }

  @Builder
  colorPickerOverlay() {
    Column() {
      Column()
        .width('100%')
        .layoutWeight(1)
        .backgroundColor('rgba(0,0,0,0.4)')
        .onClick(() => {
          this.showColorPicker = false;
        })

      Column({ space: 16 }) {
        Row() {
          Text('颜色')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor('#111827')
            .layoutWeight(1)
          Text('✕')
            .fontSize(20)
            .fontColor('#6B7280')
            .onClick(() => {
              this.showColorPicker = false;
            })
        }
        .width('100%')

        // 当前色预览 + HEX（8 位 ARGB，真实透明度）
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
            .onChange((value: string) => this.onHexInput(value))
        }
        .width('100%')

        // 饱和度/明度方形区域
        Stack() {
          // 纯色底色 = 当前色相
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(hueColor(this.pickerHue))
          // 从左到右 白→透明（饱和度）
          Column()
            .width('100%')
            .height('100%')
            .linearGradient({
              angle: 90,
              colors: [['#FFFFFF', 0], ['rgba(255,255,255,0)', 1]]
            })
          // 从上到下 透明→黑（明度）
          Column()
            .width('100%')
            .height('100%')
            .linearGradient({
              angle: 180,
              colors: [['rgba(0,0,0,0)', 0], ['#000000', 1]]
            })
          // 选择点：同心圆，外层黑色边框、内层白色边框，中心透出底色
          Column() {
            Column() {
            }
            .width(12)
            .height(12)
            .borderRadius(6)
            .border({ width: 2, color: '#FFFFFF' })
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
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
        // onTouch（Down + Move）：点击矩形内任意一点立即取该处颜色，按住拖动连续取色
        .onTouch((event: TouchEvent) => this.onColorBoxTouch(event))

        // 色相条（上）
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
            Column(){
              Column(){}
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

        // 透明度条（下）：左端全透明（A=00）→ 右端不透明（A=FF）；
        // 只改变 A 通道，RGB 保持不动；颜色以 8 位 #AARRGGBB 落库。
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
            Column(){
              Column(){}
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
          .backgroundColor('#FF8C00')
          .onClick(() => this.confirmColor())
      }
      .width('100%')
      .padding(20)
      .backgroundColor('#FFFFFF')
      .borderRadius({ topLeft: 16, topRight: 16 })
    }
    .width('100%')
    .height('100%')
    .position({ x: 0, y: 0 })
  }

  @Builder
  weekPickerOverlay() {
    Column() {
      Column()
        .width('100%')
        .layoutWeight(1)
        .backgroundColor('rgba(0,0,0,0.4)')
        .onClick(() => {
          this.showWeekPicker = false;
        })

      Column({ space: 12 }) {
        Text('选择上课周次')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#111827')
          .width('100%')
          .textAlign(TextAlign.Center)

        Row({ space: 8 }) {
          Button('全选')
            .fontSize(12)
            .height(30)
            .backgroundColor('#E5E7EB')
            .fontColor('#111827')
            .onClick(() => this.applyWeekPattern('all'))
          Button('单周')
            .fontSize(12)
            .height(30)
            .backgroundColor('#E5E7EB')
            .fontColor('#111827')
            .onClick(() => this.applyWeekPattern('odd'))
          Button('双周')
            .fontSize(12)
            .height(30)
            .backgroundColor('#E5E7EB')
            .fontColor('#111827')
            .onClick(() => this.applyWeekPattern('even'))
          Button('清空')
            .fontSize(12)
            .height(30)
            .backgroundColor('#E5E7EB')
            .fontColor('#111827')
            .onClick(() => this.applyWeekPattern('clear'))
        }
        .width('100%')
        .justifyContent(FlexAlign.Start)

        Scroll() {
          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
            ForEach(this.weekRange(), (week: number) => {
              Text(`${week}`)
                .fontSize(13)
                .fontColor(this.weekDraft.indexOf(week) >= 0 ? '#FFFFFF' : '#111827')
                .width(44)
                .height(34)
                .textAlign(TextAlign.Center)
                .backgroundColor(this.weekDraft.indexOf(week) >= 0 ? '#1890FF' : '#F3F4F6')
                .borderRadius(6)
                .margin(4)
                .onClick(() => this.toggleWeekChip(week))
            }, (week: number) => `${week}`)
          }
          .width('100%')
        }
        .width('100%')
        .height(220)

        Row({ space: 12 }) {
          Button('取消')
            .fontSize(14)
            .layoutWeight(1)
            .height(44)
            .backgroundColor('#E5E7EB')
            .fontColor('#111827')
            .onClick(() => {
              this.showWeekPicker = false;
            })
          Button('确定')
            .fontSize(14)
            .layoutWeight(1)
            .height(44)
            .backgroundColor('#1890FF')
            .onClick(() => this.confirmWeekPicker())
        }
        .width('100%')
      }
      .width('100%')
      .padding(16)
      .backgroundColor('#FFFFFF')
      .borderRadius({ topLeft: 16, topRight: 16 })
    }
    .width('100%')
    .height('100%')
    .position({ x: 0, y: 0 })
  }

  private weekRange(): number[] {
    const result: number[] = [];
    for (let i: number = 1; i <= this.maxWeek; i++) {
      result.push(i);
    }
    return result;
  }

  @Builder
  weekdayPickerOverlay() {
    Column() {
      Column()
        .width('100%')
        .layoutWeight(1)
        .backgroundColor('rgba(0,0,0,0.4)')
        .onClick(() => {
          this.showWeekdayPicker = false;
        })

      Column({ space: 12 }) {
        Text('选择星期')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#111827')
          .width('100%')
          .textAlign(TextAlign.Center)

        Column() {
          ForEach(this.weekdayRange(), (wd: number) => {
            Row() {
              Text(DateUtil.weekdayLabel(wd))
                .fontSize(15)
                .fontColor(this.weekdayDraft === wd ? '#1890FF' : '#111827')
                .layoutWeight(1)
              if (this.weekdayDraft === wd) {
                Text('✓')
                  .fontSize(14)
                  .fontColor('#1890FF')
              }
            }
            .width('100%')
            .height(48)
            .padding({ left: 16, right: 16 })
            .backgroundColor(this.weekdayDraft === wd ? '#EFF6FF' : '#FFFFFF')
            .onClick(() => {
              this.weekdayDraft = wd;
              this.confirmWeekdayPicker();
            })
          }, (wd: number) => `${wd}`)
        }
        .width('100%')
        .backgroundColor('#FFFFFF')
        .borderRadius(10)

        Button('取消')
          .fontSize(15)
          .width('100%')
          .height(46)
          .backgroundColor('#F3F4F6')
          .fontColor('#111827')
          .onClick(() => {
            this.showWeekdayPicker = false;
          })
      }
      .width('100%')
      .padding(16)
      .backgroundColor('#F3F4F6')
      .borderRadius({ topLeft: 16, topRight: 16 })
    }
    .width('100%')
    .height('100%')
    .position({ x: 0, y: 0 })
  }

  private weekdayRange(): number[] {
    return [1, 2, 3, 4, 5, 6, 7];
  }

  @Builder
  sessionPickerOverlay() {
    Column() {
      Column()
        .width('100%')
        .layoutWeight(1)
        .backgroundColor('rgba(0,0,0,0.4)')
        .onClick(() => {
          this.showSessionPicker = false;
        })

      Column({ space: 14 }) {
        Text('选择上课节次')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#111827')
          .width('100%')
          .textAlign(TextAlign.Center)

        Column({ space: 6 }) {
          Text('起始节').fontSize(13).fontColor('#6B7280').width('100%')
          ForEach(this.sessionRows(), (row: number[], rowIndex: number) => {
            Row({ space: 8 }) {
              ForEach(row, (s: number) => {
                Text(`第${s}节`)
                  .fontSize(12)
                  .textAlign(TextAlign.Center)
                  .height(32)
                  .layoutWeight(1)
                  .fontColor(this.sessionDraftStart === s ? '#FFFFFF' : '#111827')
                  .backgroundColor(this.sessionDraftStart === s ? '#1890FF' : '#F3F4F6')
                  .borderRadius(6)
                  .onClick(() => {
                    this.sessionDraftStart = s;
                    if (this.sessionDraftEnd < s) {
                      this.sessionDraftEnd = s;
                    }
                  })
              }, (s: number) => `${s}`)
            }
            .width('100%')
          }, (row: number[], rowIndex: number) => `r${rowIndex}`)
        }

        Column({ space: 6 }) {
          Text('结束节').fontSize(13).fontColor('#6B7280').width('100%')
          ForEach(this.sessionRows(), (row: number[], rowIndex: number) => {
            Row({ space: 8 }) {
              ForEach(row, (s: number) => {
                Text(`第${s}节`)
                  .fontSize(12)
                  .textAlign(TextAlign.Center)
                  .height(32)
                  .layoutWeight(1)
                  .fontColor(this.sessionDraftEnd === s ? '#FFFFFF' : (s < this.sessionDraftStart ? '#9CA3AF' : '#111827'))
                  .backgroundColor(this.sessionDraftEnd === s ? '#1890FF' : '#F3F4F6')
                  .borderRadius(6)
                  .onClick(() => {
                    if (s >= this.sessionDraftStart) {
                      this.sessionDraftEnd = s;
                    }
                  })
              }, (s: number) => `${s}`)
            }
            .width('100%')
          }, (row: number[], rowIndex: number) => `r${rowIndex}`)
        }

        Row({ space: 12 }) {
          Button('取消')
            .fontSize(14)
            .layoutWeight(1)
            .height(44)
            .backgroundColor('#E5E7EB')
            .fontColor('#111827')
            .onClick(() => {
              this.showSessionPicker = false;
            })
          Button('确定')
            .fontSize(14)
            .layoutWeight(1)
            .height(44)
            .backgroundColor('#1890FF')
            .onClick(() => this.confirmSessionPicker())
        }
        .width('100%')
      }
      .width('100%')
      .padding(16)
      .backgroundColor('#FFFFFF')
      .borderRadius({ topLeft: 16, topRight: 16 })
    }
    .width('100%')
    .height('100%')
    .position({ x: 0, y: 0 })
  }

  @Builder
  conflictOverlay() {
    Column() {
      Column()
        .width('100%')
        .layoutWeight(1)
        .backgroundColor('rgba(0,0,0,0.4)')
        .onClick(() => {
          // 点击空白不关闭，必须点按钮
        })

      Column({ space: 14 }) {
        Text('时间冲突')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor('#111827')
          .width('100%')
          .textAlign(TextAlign.Center)

        Text(this.pendingConflict.message)
          .fontSize(14)
          .fontColor('#374151')
          .width('100%')

        Text('仍要保存这段课程安排吗？')
          .fontSize(13)
          .fontColor('#6B7280')
          .width('100%')

        Row({ space: 12 }) {
          Button('取消')
            .fontSize(14)
            .layoutWeight(1)
            .height(44)
            .backgroundColor('#E5E7EB')
            .fontColor('#111827')
            .onClick(() => this.cancelConflict())
          Button('强制保存')
            .fontSize(14)
            .layoutWeight(1)
            .height(44)
            .backgroundColor('#EF4444')
            .onClick(() => this.forceSaveConflict())
        }
        .width('100%')
      }
      .width('100%')
      .padding(20)
      .backgroundColor('#FFFFFF')
      .borderRadius({ topLeft: 16, topRight: 16 })
    }
    .width('100%')
    .height('100%')
    .position({ x: 0, y: 0 })
  }

  build() {
    Column({ space: 0 }) {
      this.header()

      if (this.message.length > 0) {
        Text(this.message)
          .fontSize(12)
          .fontColor(this.message.startsWith('保存成功') ? '#16A34A' : '#D97706')
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .textAlign(TextAlign.Center)
          .backgroundColor(this.message.startsWith('保存成功') ? '#ECFDF5' : '#FFFBEB')
      }

      Scroll() {
        Column({ space: 14 }) {
          this.courseSection()

          // key 说明：groupSignature 覆盖时间段展示字段，保证弹窗修改节次/星期/周次
          // 后卡片立即重建刷新；class_name / population 是 TextInput 直绑字段，
          // 纳入 key 会导致输入时整卡重建丢焦点，因此刻意排除。
          ForEach(this.groups, (group: ClassGroup, index: number) => {
            this.classGroupCard(group, index)
          }, (group: ClassGroup, index: number) =>
            `${index}-${group.id}-${group.color}-${group.class_id}-${this.groupSignature(group)}`)

          // 「编辑班级」页不加班级：本页只显示并编辑被点中的那一个班级
          if (this.editMode !== 'editGroup') {
            Text('+ 添加班级')
              .fontSize(15)
              .fontColor('#1890FF')
              .width('100%')
              .height(48)
              .textAlign(TextAlign.Center)
              .backgroundColor('#FFFFFF')
              .borderRadius(LAYOUT.cardRadius)
              .onClick(() => this.addGroup())
          }

          // 底部占位
          Column().height(32)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      // Scroll 默认把不满一屏的内容垂直居中，显式 TopStart 让页面信息贴顶
      .align(Alignment.TopStart)

      if (this.showTypePicker) {
        this.typePickerOverlay()
      }
      if (this.showColorPicker) {
        this.colorPickerOverlay()
      }
      if (this.showWeekPicker) {
        this.weekPickerOverlay()
      }
      if (this.showWeekdayPicker) {
        this.weekdayPickerOverlay()
      }
      if (this.showSessionPicker) {
        this.sessionPickerOverlay()
      }
      if (this.showConflictDialog) {
        this.conflictOverlay()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(PAGE_BG_COLOR)
  }
}
