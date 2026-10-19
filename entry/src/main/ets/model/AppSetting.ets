import { AppSettingRow } from './Rows';
import { THEME_COLOR_DEFAULT, TODAY_COLOR_DEFAULT, NOTIFY_AHEAD_DEFAULT_MINUTES, clampNotifyMinutes,
  colorOr } from '../common/Util';

/**
 * 应用级设置（对应 app_setting 单行表，替代旧的 default_setting.json）。
 *
 * 旧结构里"当前学期 / 当前教师"用数组下标表达，一旦学期被删除或重排，
 * 下标就会指向另一个学期——这正是"切学期后显示错数据"的根因。
 * 现在改为存真实主键，指向永远明确；学期被删时外键 SET NULL 自动兜底。
 */
@ObservedV2
export class AppSetting {
  /** 当前学期 id；0 表示未选（首次启动或学期被删） */
  @Trace semester_id: number = 0;
  /** 当前教师 id；0 表示未选 */
  @Trace teacher_id: number = 0;
  @Trace theme_mode: number = 0;
  /** 界面主题色（ARGB）：导航高亮 / 主按钮 / 滑杆等强调色 */
  @Trace theme_color: string = THEME_COLOR_DEFAULT;
  /** "今天"高亮色（ARGB）：周次栏里今日日期徽标 */
  @Trace today_color: string = TODAY_COLOR_DEFAULT;
  // 机主信息只在冷启动读取 / 设置页写入，不做逐字段响应式，刻意不加 @Trace（见 docs/06 去 V2 方向）
  /** 机主姓名（首启录入）；'' 表示尚未配置 */
  owner_name: string = '';
  /** 机主教师工号；0 表示尚未配置 */
  owner_staff_no: number = 0;
  // 上课提醒设置：与机主信息同理，只在冷启动读取 / 「我的」面板写入，不做逐字段响应式，不加 @Trace
  /** 提醒第二天的课：第二天有课时，当天 22:00 提醒 */
  notify_next_day: boolean = false;
  /** 当天有课时提前提醒 */
  notify_ahead: boolean = false;
  /** 提前提醒的提前量（分钟），默认 20 */
  notify_ahead_minutes: number = NOTIFY_AHEAD_DEFAULT_MINUTES;
  @Trace updated_at: number = 0;

  /** 机主是否已完成首次录入 */
  hasOwner(): boolean {
    return this.owner_name.length > 0 && this.owner_staff_no > 0;
  }

  static fromRow(row: AppSettingRow): AppSetting {
    const setting: AppSetting = new AppSetting();
    setting.semester_id = row.semester_id === undefined ? 0 : row.semester_id;
    setting.teacher_id = row.teacher_id === undefined ? 0 : row.teacher_id;
    setting.theme_mode = row.theme_mode;
    setting.theme_color = colorOr(row.theme_color, THEME_COLOR_DEFAULT);
    setting.today_color = colorOr(row.today_color, TODAY_COLOR_DEFAULT);
    setting.owner_name = row.owner_name === undefined ? '' : row.owner_name;
    setting.owner_staff_no = row.owner_staff_no === undefined ? 0 : row.owner_staff_no;
    setting.notify_next_day = row.notify_next_day === undefined ? false : row.notify_next_day !== 0;
    setting.notify_ahead = row.notify_ahead === undefined ? false : row.notify_ahead !== 0;
    setting.notify_ahead_minutes = clampNotifyMinutes(row.notify_ahead_minutes);
    setting.updated_at = row.updated_at;
    return setting;
  }

  static fresh(): AppSetting {
    const setting: AppSetting = new AppSetting();
    setting.semester_id = 0;
    setting.teacher_id = 0;
    setting.theme_mode = 0;
    setting.theme_color = THEME_COLOR_DEFAULT;
    setting.today_color = TODAY_COLOR_DEFAULT;
    setting.notify_next_day = false;
    setting.notify_ahead = false;
    setting.notify_ahead_minutes = NOTIFY_AHEAD_DEFAULT_MINUTES;
    setting.updated_at = new Date().getTime();
    return setting;
  }
}
