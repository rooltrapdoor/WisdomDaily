import { DbExecutor, RsReader } from '../db/DbExecutor';
import { DaoSupport } from './DaoSupport';
import { AppSettingRow } from '../model/Rows';
import { Tables } from '../db/TableSchema';
import { nowMs, normalizeColor, clampNotifyMinutes, NOTIFY_AHEAD_DEFAULT_MINUTES } from '../common/Util';

/**
 * app_setting 单行表读写（替代 default_setting.json）。
 *
 * 用真实外键存"当前学期 / 当前教师"，取代旧版的数组下标。
 * 下标方案在学期被删除、重排后就会指错对象，是"切学期看到别人数据"的根因。
 */
export class AppSettingDao {
  /** 读取单行设置；不存在返回 undefined（由上层决定是否初始化） */
  static async load(exec: DbExecutor): Promise<AppSettingRow | undefined> {
    const rs = await exec.querySql(
      `SELECT id, semester_id, teacher_id, theme_mode, theme_color, today_color,
              owner_name, owner_staff_no,
              notify_next_day, notify_ahead, notify_ahead_minutes, updated_at
         FROM ${Tables.APP_SETTING} WHERE id = 1`, []);
    try {
      if (!rs.goToFirstRow()) {
        return undefined;
      }
      const reader: RsReader = new RsReader(rs);
      return {
        id: reader.num('id', 1),
        semester_id: reader.optNum('semester_id'),
        teacher_id: reader.optNum('teacher_id'),
        theme_mode: reader.num('theme_mode'),
        theme_color: reader.optStr('theme_color'),
        today_color: reader.optStr('today_color'),
        owner_name: reader.optStr('owner_name'),
        owner_staff_no: reader.optNum('owner_staff_no'),
        notify_next_day: reader.num('notify_next_day', 0),
        notify_ahead: reader.num('notify_ahead', 0),
        notify_ahead_minutes: reader.num('notify_ahead_minutes', NOTIFY_AHEAD_DEFAULT_MINUTES),
        updated_at: reader.num('updated_at')
      };
    } finally {
      rs.close();
    }
  }

  /** 确保单行存在（幂等），首次调用时创建 */
  static async ensureRow(exec: DbExecutor): Promise<void> {
    await exec.executeSql(
      `INSERT OR IGNORE INTO ${Tables.APP_SETTING} (id, semester_id, teacher_id, theme_mode, updated_at)
       VALUES (1, NULL, NULL, 0, ?)`, [nowMs()]);
  }

  /** 保存"当前指向"——切学期、切教师只需这一条 UPDATE，不用重写整个学期 */
  static async savePointers(exec: DbExecutor, semesterId: number, teacherId: number): Promise<void> {
    await AppSettingDao.ensureRow(exec);
    await exec.executeSql(
      `UPDATE ${Tables.APP_SETTING}
          SET semester_id = ?, teacher_id = ?, updated_at = ?
        WHERE id = 1`,
      [semesterId > 0 ? semesterId : null, teacherId > 0 ? teacherId : null, nowMs()]);
  }

  static async setThemeMode(exec: DbExecutor, themeMode: number): Promise<void> {
    await AppSettingDao.ensureRow(exec);
    await exec.executeSql(
      `UPDATE ${Tables.APP_SETTING} SET theme_mode = ?, updated_at = ? WHERE id = 1`,
      [themeMode, nowMs()]);
  }

  /** 保存界面颜色（主题色 / 今日高亮色）；两者都归一化成 8 位 ARGB 后再落库 */
  static async setUiColors(exec: DbExecutor, themeColor: string, todayColor: string): Promise<void> {
    await AppSettingDao.ensureRow(exec);
    await exec.executeSql(
      `UPDATE ${Tables.APP_SETTING} SET theme_color = ?, today_color = ?, updated_at = ? WHERE id = 1`,
      [normalizeColor(themeColor), normalizeColor(todayColor), nowMs()]);
  }

  /**
   * 保存上课提醒设置（开关 ×2 + 提前量）。
   *
   * 提前量在这里再夹紧一次（`clampNotifyMinutes`）：调用方来自手输输入框，
   * 库层是最后一道关口 —— 写进去的值必须永远落在合法区间，否则提醒调度
   * 会拿着 0 分钟或 100000 分钟去算触发时刻。
   */
  static async setReminders(exec: DbExecutor, nextDay: boolean, ahead: boolean,
    aheadMinutes: number): Promise<void> {
    await AppSettingDao.ensureRow(exec);
    await exec.executeSql(
      `UPDATE ${Tables.APP_SETTING}
          SET notify_next_day = ?, notify_ahead = ?, notify_ahead_minutes = ?, updated_at = ?
        WHERE id = 1`,
      [nextDay ? 1 : 0, ahead ? 1 : 0, clampNotifyMinutes(aheadMinutes), nowMs()]);
  }

  /**
   * 保存机主信息（首启录入的"默认教师"）。
   * 只写 owner 两列；往哪个学期登记教师、是否切换当前指向，由 Repository 在同一事务里决策。
   */
  static async setOwnerProfile(exec: DbExecutor, name: string, staffNo: number): Promise<void> {
    await AppSettingDao.ensureRow(exec);
    await exec.executeSql(
      `UPDATE ${Tables.APP_SETTING} SET owner_name = ?, owner_staff_no = ?, updated_at = ? WHERE id = 1`,
      [name, staffNo, nowMs()]);
  }

  /** 当前指向的学期被删除后，外键会置 NULL，这里给出一个安全的"第一个学期"兜底 */
  static async repairPointers(exec: DbExecutor): Promise<void> {
    const semesterCount: number = await DaoSupport.scalarNumber(exec,
      `SELECT COUNT(*) AS v FROM ${Tables.SEMESTER}`, []);
    if (semesterCount === 0) {
      return;
    }
    await exec.executeSql(
      `UPDATE ${Tables.APP_SETTING}
          SET semester_id = (SELECT id FROM ${Tables.SEMESTER} ORDER BY sort_order ASC, id ASC LIMIT 1)
        WHERE id = 1 AND (semester_id IS NULL
                          OR semester_id NOT IN (SELECT id FROM ${Tables.SEMESTER}))`, []);
    await exec.executeSql(
      `UPDATE ${Tables.APP_SETTING}
          SET teacher_id = (
                SELECT t.id FROM ${Tables.TEACHER} t
                 WHERE t.semester_id = (SELECT semester_id FROM ${Tables.APP_SETTING} WHERE id = 1)
                 ORDER BY t.sort_order ASC, t.id ASC LIMIT 1)
        WHERE id = 1
          AND (teacher_id IS NULL
               OR teacher_id NOT IN (
                    SELECT t.id FROM ${Tables.TEACHER} t
                     WHERE t.semester_id = (SELECT semester_id FROM ${Tables.APP_SETTING} WHERE id = 1)))`, []);
  }

  /**
   * `ensureRow` + `repairPointers` 会不会真的改成什么东西 —— **纯读**判断。
   *
   * 存在的理由：这两件事原本在每次启动（以及卡片每 30 分钟刷新一次）都无条件跑，
   * 而且被包在一个写事务里 —— 哪怕一行都不用改，也要先拿一次写锁。
   * 应用与卡片是两个进程时，这就是 `14800024`（database file is locked）的来源。
   * 先只读探一遍、确认"确实有坏行"再开写事务，稳态下启动路径就是**零写**。
   *
   * 判据必须与 `repairPointers` 的 WHERE 子句一一对应，否则会出现
   * "探针说不用修，于是永远不修"的静默漏修。
   */
  static async needsRepair(exec: DbExecutor): Promise<boolean> {
    const missingRow: number = await DaoSupport.scalarNumber(exec,
      `SELECT COUNT(*) AS v FROM ${Tables.APP_SETTING} WHERE id = 1`, []);
    if (missingRow === 0) {
      return true;
    }
    const semesterCount: number = await DaoSupport.scalarNumber(exec,
      `SELECT COUNT(*) AS v FROM ${Tables.SEMESTER}`, []);
    if (semesterCount === 0) {
      // 一个学期都没有时 repairPointers 也是空操作，不必为它写库
      return false;
    }
    const badSemester: number = await DaoSupport.scalarNumber(exec,
      `SELECT COUNT(*) AS v FROM ${Tables.APP_SETTING}
        WHERE id = 1 AND (semester_id IS NULL
                          OR semester_id NOT IN (SELECT id FROM ${Tables.SEMESTER}))`, []);
    if (badSemester > 0) {
      return true;
    }
    const badTeacher: number = await DaoSupport.scalarNumber(exec,
      `SELECT COUNT(*) AS v FROM ${Tables.APP_SETTING}
        WHERE id = 1
          AND (teacher_id IS NULL
               OR teacher_id NOT IN (
                    SELECT t.id FROM ${Tables.TEACHER} t
                     WHERE t.semester_id = (SELECT semester_id FROM ${Tables.APP_SETTING} WHERE id = 1)))`, []);
    return badTeacher > 0;
  }
}
