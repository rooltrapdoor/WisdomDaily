import { common } from '@kit.AbilityKit';
import { reminderAgentManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { notificationManager } from '@kit.NotificationKit';
import { DateUtil } from '../common/DateUtil';
import { Logger } from '../common/Logger';
import { errText, errDetail, NOTIFY_NEXT_DAY_HOUR } from '../common/Util';
import { LessonRow } from '../model/Rows';
import { Semester } from '../model/Semester';
import { ScheduleSlot, ScheduleTemplate } from '../model/ScheduleTemplate';
import { ScheduleRepository, Workspace } from '../repository/ScheduleRepository';

const TAG: string = 'LessonReminder';
const MS_PER_DAY: number = 24 * 60 * 60 * 1000;

/**
 * 向未来扫描几天。
 *
 * 4 而不是 3：22 点提醒的触发日是"今天/明天/后天"，但它要判断的是**次日**有没有课，
 * 所以"后天 22 点那条"必须能看到第 4 天的课表。少算一天，"后天晚上"这一档就永远不提醒。
 */
const SCAN_DAYS: number = 4;
/** 提前提醒只登记"今天 + 明天"。后天及以后的课，等明天的同步再登记 */
const AHEAD_DAYS: number = 2;

/** 同一个进程内两次重建的最小间隔（刷新很频繁，避免反复清空 / 重发几十条提醒） */
const SYNC_THROTTLE_MS: number = 20000;

/** 通知 id 分段：22 点提醒 2200+，提前提醒 3000+（同一批内不重复即可） */
const ID_NEXT_DAY_BASE: number = 2200;
const ID_AHEAD_BASE: number = 3000;

/**
 * 系统错误码：提醒数量超出上限。
 *
 * 官方口径：**有效/未过期**的提醒，单个普通应用 API ≤ 25 为 30 条、API ≥ 26 为 64 条。
 * 关键在"有效"怎么算 —— **到点弹出后，只要用户没点提醒上的「关闭/CLOSE」按钮，
 * 它就一直算有效**。所以关闭按钮不是锦上添花，是额度唯一的出口（见 `publish`）。
 */
const CODE_REMINDER_LIMIT: number = 1700002;

/**
 * 撞上额度上限后的静默期。
 *
 * 额度满了之后**每一条登记都必然失败**，而重建是"每次刷新都跑"的 ——
 * 2026-09-22 真机日志里，三分钟内同一个错刷了十几条。
 * 额度只能靠"人去通知中心点掉旧提醒"释放，所以这里给一个够长但不长的窗口：
 * 期间不登记、也不清理（清了也登记不回来，只会把用户仅剩的提醒弄没）。
 */
const QUOTA_COOLDOWN_MS: number = 10 * 60 * 1000;

/**
 * 一条待登记的提醒。
 *
 * 先收集、后登记（而不是边算边发）是为了**按触发时刻排队**：
 * 额度不够时先保住"马上就要响"的那几条，而不是按"先把后天的算完"的顺序把额度用光。
 */
interface PendingReminder {
  fire: Date;
  title: string;
  content: string;
  notificationId: number;
}

/**
 * 上课提醒。
 *
 * 用系统级"后台代理提醒"（`reminderAgentManager`）而不是应用内定时器：
 * 代理提醒由系统闹钟托管，**应用没运行、被清理、甚至没联网都能准时弹**，
 * 而应用内 `setTimeout` 一退出后台就没了 —— 上课提醒恰恰是那种"应用一定不在前台"的场景。
 *
 * ## 为什么每次都"全清重建"
 *
 * 课表随时可能被编辑（改时间、删课、换教室），提醒内容里带着这些信息。
 * 增量维护（记住 id、只改变化的那几条）一旦哪一步出错，就会留下一条**永远不会消失**的旧提醒，
 * 而用户没有任何办法看到它、更没法删掉 —— 只能卸载重装。
 * 所以这里每次同步都是"按当前课表算一份完整快照 → 清掉旧的全部 → 重新登记"，
 * 状态只存在于课表里，不存在于提醒表里。
 *
 * 代价是 `cancelAllReminders()` 会取消**本应用的全部提醒**：以后若再加别的提醒功能，
 * 要么共用一个调度器，要么换用 `groupId` 分组清理。
 *
 * ## 额度（30 条）与「关闭」按钮
 *
 * 系统只允许单个应用同时存在 30 条**有效/未过期**的提醒，而"有效"的口径很反直觉：
 * **到点弹出之后，只要用户没点提醒上的「关闭」按钮，它就一直算有效**。
 * 额度只进不出的唯一出口就是那个按钮 —— 这就是每条提醒都必须配 `actionButton` 的原因，
 * 也是每次重建都要清点额度的原因（2026-09-22 真机日志：所有登记全撞 1700002）。
 *
 * ## 触发规则
 *
 *  1. 「提醒第二天的课」：次日有课时，当天 22:00 提醒一次。
 *  2. 「提前提醒」：当天/次日的每节课，在上课前 N 分钟（默认 20）提醒一次。
 *  3. 例外：如果**这节课开始前 N 分钟内还有另一节课没下课**，这一条就不提醒 ——
 *     提醒时刻正好落在别人的课堂上，弹出来只会打扰正在上课的人。
 *     判据即"课间间隔 ≤ N 分钟"，与用户的描述一致（默认 20 分钟时就是"课间只有 20 分钟就不提醒"）。
 */
export class LessonReminder {
  /** 上次成功重建的时刻（毫秒）；0 = 还没成功过 */
  private static lastSyncMs: number = 0;
  /** 额度熔断到期时刻（毫秒）：额度满了以后到点之前不再登记（见 `QUOTA_COOLDOWN_MS`） */
  private static quotaBlockedUntilMs: number = 0;

  /**
   * 按当前课表重建全部提醒。
   *
   * 调用点：应用每次刷新课表之后（`Index.refresh`）、以及提醒开关变更时（`force = true`）。
   *
   * @param force 忽略节流强制重建。开关一拨就要立刻生效，不能被 20 秒节流挡住。
   */
  static async sync(context: common.Context, force: boolean = false): Promise<void> {
    const nowMs: number = new Date().getTime();
    if (!force && nowMs - LessonReminder.lastSyncMs < SYNC_THROTTLE_MS) {
      return;
    }
    LessonReminder.lastSyncMs = nowMs;
    if (!force && LessonReminder.quotaBlockedUntilMs > nowMs) {
      // 额度熔断期：**连清理都不做** —— 清了也登记不回来，只会把用户仅剩的提醒弄没。
      // 这里刻意不打日志：进入熔断时已经报过原因与时长，每次刷新再报一次就是刷屏。
      return;
    }
    try {
      const repo: ScheduleRepository = ScheduleRepository.getInstance();
      await repo.init(context, true);
      const space: Workspace = await repo.loadWorkspace();
      const nextDayOn: boolean = space.setting.notify_next_day;
      const aheadOn: boolean = space.setting.notify_ahead;
      const aheadMinutes: number = space.setting.notify_ahead_minutes;

      // 先清空：这一批是"完整快照"，不做增量（见类注释）。
      // 顺手清点"清空前 / 清空后"的条数 —— 这是**唯一能看出额度被谁占着**的地方：
      // 系统把"已弹出、但用户没点关闭"的提醒仍然算作有效，那种额度 cancelAll 清不掉，
      // 是 1700002 唯一的可能来源。清空后仍 > 0 就说明额度正是这么没的。
      const heldBefore: number = await LessonReminder.validCount();
      await LessonReminder.cancelAll();
      const heldAfter: number = await LessonReminder.validCount();
      // 无条件打：-1 = getValidReminders 本身失败了，这个值同样是线索（查询都不可用时
      // "额度去向"就成了盲区）。每轮 sync 最多一行（20 秒节流挡着），不构成刷屏；
      // 反过来，"明明撞了额度却连清点行都没有"才是最难排查的静默。
      Logger.info(TAG, `提醒额度清点：清理前 ${heldBefore} 条 / 清理后 ${heldAfter} 条`
        + (heldAfter < 0 ? '（getValidReminders 查询失败）' : '')
        + (heldAfter > 0 ? '（未释放：已弹出但没点「关闭」的提醒）' : ''));
      if (!nextDayOn && !aheadOn) {
        Logger.info(TAG, '上课提醒均已关闭，只做了旧提醒清理');
        return;
      }

      const semester: Semester | undefined =
        LessonReminder.findSemester(space, space.setting.semester_id);
      const teacherId: number = space.setting.teacher_id;
      if (semester === undefined || teacherId <= 0) {
        // 没有学期 / 没选教师时课表本身就是空的，没什么可提醒
        return;
      }

      const slots: ScheduleSlot[] = LessonReminder.slotsOf(space, semester);
      const now: Date = new Date();
      const days: Date[] = [];
      const ofDays: LessonRow[][] = [];
      const cache: Map<number, LessonRow[]> = new Map<number, LessonRow[]>();
      for (let i = 0; i < SCAN_DAYS; i++) {
        const date: Date = new Date(now.getFullYear(), now.getMonth(), now.getDate() + i);
        days.push(date);
        ofDays.push(await LessonReminder.lessonsOnDay(repo, semester, teacherId, date, cache));
      }

      const pending: PendingReminder[] = [];
      LessonReminder.collectNextDayReminders(now, days, ofDays, slots, nextDayOn, pending);
      LessonReminder.collectAheadReminders(now, days, ofDays, slots, aheadOn, aheadMinutes, pending);
      await LessonReminder.ensureSlot();
      await LessonReminder.publishAll(pending);
    } catch (e) {
      // 失败不被节流挡住：否则一次偶发失败会让提醒停摆 20 秒以上
      LessonReminder.lastSyncMs = 0;
      Logger.error(TAG, `重建上课提醒失败：${errDetail(e)}`);
    }
  }

  /**
   * 确认通知可用：没开就弹一次系统授权框。
   *
   * 用户第一次拨开提醒开关时调用。返回 false 说明用户拒绝了 —— 此时提醒**仍然会登记**，
   * 只是弹不出来；界面上要给出提示，让用户知道去哪儿开。
   */
  static async ensureNotificationEnabled(context: common.UIAbilityContext): Promise<boolean> {
    try {
      if (await notificationManager.isNotificationEnabled()) {
        return true;
      }
      await notificationManager.requestEnableNotification(context);
      return await notificationManager.isNotificationEnabled();
    } catch (e) {
      Logger.warn(TAG, `申请通知授权失败：${errText(e)}`);
      return false;
    }
  }

  // ------------------------------------------------------------ 内部

  /**
   * 收集"次日有课"的 22 点提醒（只收集，登记统一走 `publishAll`）。
   *
   * 注意判断的是 `ofDays[i + 1]`（**次日**有没有课），触发时刻却是 `days[i]` 的 22:00 ——
   * 用户要的是"今晚十点告诉我明天有课"，不是"明晚十点告诉我明天有课"。
   */
  private static collectNextDayReminders(now: Date, days: Date[], ofDays: LessonRow[][],
    slots: ScheduleSlot[], enabled: boolean, out: PendingReminder[]): void {
    if (!enabled) {
      return;
    }
    for (let i = 0; i + 1 < days.length; i++) {
      const tomorrowLessons: LessonRow[] = ofDays[i + 1];
      if (tomorrowLessons.length === 0) {
        continue;
      }
      const date: Date = days[i];
      const fire: Date = new Date(date.getFullYear(), date.getMonth(), date.getDate(),
        NOTIFY_NEXT_DAY_HOUR, 0, 0);
      if (fire.getTime() <= now.getTime()) {
        // 今天已经过了 22 点：这一档跳过（明天那次同步会补上"明晚提醒后天"）
        continue;
      }
      const first: LessonRow = tomorrowLessons[0];
      const clock: string = LessonReminder.startClockOf(first, slots);
      const head: string = clock.length > 0 ? `${clock} ${LessonReminder.nameOf(first)}` : LessonReminder.nameOf(first);
      const item: PendingReminder = {
        fire: fire,
        title: '明天有课',
        content: `明天 ${tomorrowLessons.length} 节课，第一节 ${head}`,
        notificationId: ID_NEXT_DAY_BASE + i
      };
      out.push(item);
    }
  }

  /** 收集每节课的"提前 N 分钟"提醒（只做今天与明天；登记统一走 `publishAll`） */
  private static collectAheadReminders(now: Date, days: Date[], ofDays: LessonRow[][],
    slots: ScheduleSlot[], enabled: boolean, aheadMinutes: number, out: PendingReminder[]): void {
    if (!enabled) {
      return;
    }
    const nowMinutes: number = now.getHours() * 60 + now.getMinutes();
    for (let i = 0; i < days.length && i < AHEAD_DAYS; i++) {
      const lessons: LessonRow[] = ofDays[i];
      const date: Date = days[i];
      for (let j = 0; j < lessons.length; j++) {
        const lesson: LessonRow = lessons[j];
        const startMinutes: number = LessonReminder.startMinutesOf(lesson, slots);
        if (startMinutes < 0) {
          // 作息模板里查不到节次钟点：算不出触发时刻，跳过（宁可漏提醒，也不能定错时间）
          continue;
        }
        const remindMinutes: number = startMinutes - aheadMinutes;
        if (remindMinutes < 0) {
          continue;
        }
        if (i === 0 && remindMinutes <= nowMinutes) {
          // 今天的课，提醒时刻已经过去了
          continue;
        }
        if (LessonReminder.blockedByEarlier(lesson, lessons, slots, remindMinutes)) {
          Logger.info(TAG, `"${LessonReminder.nameOf(lesson)}" 提前 ${aheadMinutes} 分钟时上一节还没下课，跳过提醒`);
          continue;
        }
        const fire: Date = new Date(date.getFullYear(), date.getMonth(), date.getDate(),
          Math.floor(remindMinutes / 60), remindMinutes % 60, 0);
        const item: PendingReminder = {
          fire: fire,
          title: '即将上课',
          content: LessonReminder.aheadContent(lesson, slots),
          notificationId: ID_AHEAD_BASE + i * 10 + j
        };
        out.push(item);
      }
    }
  }

  /** 提前提醒的正文：`08:00 高等数学 @A101`（没教室就只剩前两段） */
  private static aheadContent(lesson: LessonRow, slots: ScheduleSlot[]): string {
    const parts: string[] = [];
    const clock: string = LessonReminder.startClockOf(lesson, slots);
    if (clock.length > 0) {
      parts.push(clock);
    }
    parts.push(LessonReminder.nameOf(lesson));
    if (lesson.class_room.length > 0) {
      parts.push(`@${lesson.class_room}`);
    }
    return parts.join(' ');
  }

  /**
   * 这节课的提醒时刻，是否还落在"另一节课"里。
   *
   * 判据：同一天存在另一节课，其**结束钟点 ≥ 提醒时刻**。
   * 等价说法是"两节课之间的间隔 ≤ 提前量"—— 默认 20 分钟时，
   * 就是用户描述的"这节课之前 20 分钟另一节课才结束，就不提醒"。
   */
  private static blockedByEarlier(lesson: LessonRow, lessons: LessonRow[], slots: ScheduleSlot[],
    remindMinutes: number): boolean {
    for (let i = 0; i < lessons.length; i++) {
      const other: LessonRow = lessons[i];
      if (other.time_period_id === lesson.time_period_id) {
        continue;
      }
      const endMinutes: number = LessonReminder.endMinutesOf(other, slots);
      if (endMinutes >= 0 && endMinutes >= remindMinutes) {
        return true;
      }
    }
    return false;
  }

  /**
   * 按触发时刻排队登记。
   *
   * 顺序即优先级：**越早触发的越先登记**。额度紧张时先保住"马上就要响"的那几条，
   * 而不是按"先把后天的算完"的顺序把额度用光。
   *
   * 撞上额度上限就**立刻收手**：后面的必然也失败，继续发只是把日志刷成一片红。
   * 错误码由 `publish` 识别并置上熔断时刻，这里只负责停。
   */
  private static async publishAll(list: PendingReminder[]): Promise<void> {
    if (list.length === 0) {
      return;
    }
    list.sort((a: PendingReminder, b: PendingReminder) => a.fire.getTime() - b.fire.getTime());
    for (let i = 0; i < list.length; i++) {
      const item: PendingReminder = list[i];
      const ok: boolean = await LessonReminder.publish(item.fire, item.title, item.content,
        item.notificationId);
      if (ok) {
        continue;
      }
      // 判"刚刚撞的额度"要用**当前时刻**比：熔断到期后这个戳仍然 > 0，
      // 拿它当"已满"会把之后任何一条**别的**原因的失败也误判成额度满、白白中止整批。
      if (LessonReminder.quotaBlockedUntilMs > new Date().getTime()) {
        const left: number = list.length - 1 - i;
        if (left > 0) {
          Logger.warn(TAG, `提醒额度已满，本轮放弃剩余 ${left} 条登记`);
        }
        return;
      }
    }
  }

  /**
   * 当前应用"有效/未过期"的提醒条数。
   *
   * 只用于日志与定位：额度是被"已弹出但没点关闭"的提醒占着，还是本应用压根没登记上，
   * 全看这一个数。查询失败返回 -1（不参与任何判断，绝不影响主流程）。
   */
  private static async validCount(): Promise<number> {
    try {
      const list: Array<reminderAgentManager.ReminderRequest> =
        await reminderAgentManager.getValidReminders();
      return list.length;
    } catch (e) {
      return -1;
    }
  }

  /**
   * 登记一条日历型代理提醒。返回是否成功。
   *
   * 单条失败**只记账、不抛出**：这批提醒里后面几条往往比刚刚失败的那条更重要
   * （用户更在意"明天第一节课"而不是"后天最后一节"），一条登记不上不该让整批停摆。
   * 系统接口（`publishReminder`）在部分机型 / 权限状态下会直接抛，
   * 所以这里必须自己兜住，并留下 `errDetail`（带调用栈首行）供定位。
   *
   * **必须带 `actionButton`**：系统把"已弹出、但用户没点关闭按钮"的提醒仍然算作有效，
   * 一直占着 30 条的额度。不配这个按钮，用户连能点的地方都没有 —— 额度只进不出，
   * 最后每条登记都撞 1700002（2026-09-22 真机日志实证）。按钮语义由系统给，
   * 文案随便写（`ACTION_BUTTON_TYPE_CLOSE` 才是关键）。
   */
  private static async publish(fire: Date, title: string, content: string,
    notificationId: number): Promise<boolean> {
    try {
      const request: reminderAgentManager.ReminderRequestCalendar = {
        reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_CALENDAR,
        dateTime: {
          year: fire.getFullYear(),
          month: fire.getMonth() + 1,
          day: fire.getDate(),
          hour: fire.getHours(),
          minute: fire.getMinutes(),
          second: 0
        },
        actionButton: [
          { title: '知道了', type: reminderAgentManager.ActionButtonType.ACTION_BUTTON_TYPE_CLOSE }
        ],
        title: title,
        content: content,
        notificationId: notificationId,
        slotType: notificationManager.SlotType.SOCIAL_COMMUNICATION
      };
      await reminderAgentManager.publishReminder(request);
      Logger.info(TAG, `提醒 #${notificationId} → ${fire.getMonth() + 1}/${fire.getDate()} `
        + `${DateUtil.hmFromMinutes(fire.getHours() * 60 + fire.getMinutes())}「${title}」${content}`);
      return true;
    } catch (e) {
      if (LessonReminder.codeOf(e) === CODE_REMINDER_LIMIT) {
        // 额度满了：熔断 + 只报一次。剩下的交给"用户去通知中心点掉旧提醒"来解。
        LessonReminder.quotaBlockedUntilMs = new Date().getTime() + QUOTA_COOLDOWN_MS;
        Logger.warn(TAG, `提醒额度已用满（1700002），${QUOTA_COOLDOWN_MS / 60000} 分钟内不再尝试登记`);
      } else {
        Logger.error(TAG, `登记提醒 #${notificationId} 失败：${errDetail(e)}`);
      }
      return false;
    }
  }

  /**
   * 取错误的数字码；取不到时返回 0（与任何系统错误码都不等）。
   *
   * **不能用 `instanceof Error` 拦**：真机上系统接口抛出的 `BusinessError` 跨了 native
   * 边界，**不是 `Error` 实例** —— `errText` 里那个 `JSON.stringify` 兜底分支就是为它
   * 留的（2026-09-23 真机实证：`登记提醒 #3000 失败：{"data":1700002,...}` 这个 JSON
   * 形态只能出自 stringify 分支；若它是 `Error`，errText 会打 `code=1700002, ...`）。
   * 所以这里按鸭子判断直接读 `code` 属性：是有限数字就认。
   */
  private static codeOf(e: Object): number {
    const code: number | undefined = (e as BusinessError).code;
    return typeof code === 'number' && Number.isFinite(code) ? code : 0;
  }

  private static async cancelAll(): Promise<void> {
    try {
      await reminderAgentManager.cancelAllReminders();
    } catch (e) {
      Logger.warn(TAG, `清理旧提醒失败（已忽略）：${errText(e)}`);
    }
  }

  /**
   * 建"社交通信"渠道并抬到高优先级。
   *
   * 不建的话提醒会走系统默认渠道，可能既不响铃也不横幅 —— 那就失去提醒的意义了。
   * 建失败不阻断（系统自带的同名渠道照样能用）。
   *
   * **字段名必须用带 `notification` 前缀的那两个**（`notificationType` / `notificationLevel`）：
   * `NotificationSlot` 上还留着老字段 `type` / `level`，其中 `type` 的类型来自**旧模块**
   * `@ohos.notification` 的 `SlotType`（API 11 起废弃），与本文件的 `notificationManager.SlotType`
   * **同名但不同源**，赋过去会报 `Type 'SlotType.SOCIAL_COMMUNICATION' is not assignable to type 'SlotType'`
   * —— 这种"同名枚举不可赋值"的报错，先去 SDK 看该字段是不是留了个指向旧模块的老写法。
   */
  private static async ensureSlot(): Promise<void> {
    try {
      const slot: notificationManager.NotificationSlot = {
        notificationType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
        notificationLevel: notificationManager.SlotLevel.LEVEL_HIGH
      };
      await reminderAgentManager.addNotificationSlot(slot);
    } catch (e) {
      Logger.warn(TAG, `创建通知渠道失败（改用系统默认）：${errText(e)}`);
    }
  }

  /** 某一天的课（按开始时间排序）。学期外、模板缺失一律返回空数组，不抛 */
  private static async lessonsOnDay(repo: ScheduleRepository, semester: Semester, teacherId: number,
    date: Date, cache: Map<number, LessonRow[]>): Promise<LessonRow[]> {
    const startDate: Date = semester.startDate();
    const firstMonday: number = DateUtil.weekMonday(startDate).getTime();
    const lastDay: number = firstMonday + semester.total_weeks * 7 * MS_PER_DAY - MS_PER_DAY;
    const at: number = date.getTime();
    if (at < firstMonday || at > lastDay) {
      return [];
    }
    const week: number = DateUtil.getWeekNumber(startDate, date, semester.total_weeks);
    let rows: LessonRow[] | undefined = cache.get(week);
    if (rows === undefined) {
      rows = await repo.loadWeekLessons(semester.id, teacherId, week);
      cache.set(week, rows);
    }
    const weekday: number = DateUtil.toDbWeekday(date.getDay());
    const out: LessonRow[] = [];
    for (let i = 0; i < rows.length; i++) {
      if (rows[i].weekday === weekday) {
        out.push(rows[i]);
      }
    }
    out.sort((a: LessonRow, b: LessonRow) => {
      if (a.start_time !== b.start_time) {
        return a.start_time - b.start_time;
      }
      return a.end_time - b.end_time;
    });
    return out;
  }

  /** 节次 → 上课钟点（从零点起的分钟数）；作息模板缺失返回 -1 */
  private static startMinutesOf(lesson: LessonRow, slots: ScheduleSlot[]): number {
    for (let i = 0; i < slots.length; i++) {
      if (slots[i].session_no === lesson.start_time) {
        const minutes: number = DateUtil.hmToMinutes(slots[i].start_time);
        return minutes > 0 ? minutes : -1;
      }
    }
    return -1;
  }

  /** 节次 → 下课钟点（从零点起的分钟数）；作息模板缺失返回 -1 */
  private static endMinutesOf(lesson: LessonRow, slots: ScheduleSlot[]): number {
    for (let i = 0; i < slots.length; i++) {
      if (slots[i].session_no === lesson.end_time) {
        const minutes: number = DateUtil.hmToMinutes(slots[i].end_time);
        return minutes > 0 ? minutes : -1;
      }
    }
    return -1;
  }

  /** 节次 → `HH:mm` 上课钟点；作息模板缺失返回空串 */
  private static startClockOf(lesson: LessonRow, slots: ScheduleSlot[]): string {
    for (let i = 0; i < slots.length; i++) {
      if (slots[i].session_no === lesson.start_time) {
        return slots[i].start_time;
      }
    }
    return '';
  }

  private static nameOf(lesson: LessonRow): string {
    return lesson.course_name.length > 0 ? lesson.course_name : '未命名课程';
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
