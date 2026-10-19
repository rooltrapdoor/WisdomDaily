import { Logger } from '../common/Logger';
import { errText } from '../common/Util';

const TAG: string = 'WidgetLaunch';

/**
 * 卡片 `router` 事件携带的键名。
 *
 * 必须与 `widget/pages/WidgetCard.ets` 里 `postCardAction` 的 `params` 键**逐字一致** ——
 * 卡片与应用是两个进程，中间只有这一串键值对。
 * 统一加 `wsd` 前缀，避免与系统注入的保留键（formId / bundleName 等）撞名。
 */
const KEY_WEEK: string = 'wsdWeek';
const KEY_WEEKDAY: string = 'wsdWeekday';
/** 只有"点某节课"才带这个键；**空态点卡片不带** —— 见 `WidgetOpenRequest.periodId` */
const KEY_PERIOD: string = 'wsdPeriod';

/**
 * 一次「在卡片上点了东西」的待办。
 *
 * 两种意图共用一条通道，靠 `periodId` 区分：
 *  - `periodId > 0`：点的是**某一行课程** → 应用里打开这一课次的详情；
 *  - `periodId = 0`：点的是**空态卡片** → 只把课表切到 `weekNo` 那一周，不开详情。
 */
export class WidgetOpenRequest {
  /** 目标周次（卡片可能显示的是"明天"，跨周时这里就是下一周；0 = 没有有效周次） */
  weekNo: number = 0;
  /** 目标星期 1~7（仅用于防御性校验） */
  weekday: number = 0;
  /**
   * `time_period.id`：一节"时间段"，配上周次即可唯一确定一课次。
   *
   * **0 = 只进课表、不开详情**（卡片一节课都没有，用户点卡片只是想看课表）。
   */
  periodId: number = 0;
}

/**
 * 待办的有效期（ms）。
 *
 * 为什么要过期：请求由 EntryAbility 登记、由首页消费，而"点击卡片时首页恰好不在最前面"
 * （用户正停在课程编辑页）会让它一直挂着 —— 等用户几分钟后回到课表时再突然弹出一张
 * 课程详情面板就成了惊吓。过期后静默丢弃，卡片再点一次即可。
 */
const PENDING_TTL_MS: number = 120 * 1000;

/**
 * 卡片点击 → 应用内定位 的交接点。
 *
 * 为什么用模块级静态变量而不是 AppStorage：
 *  ① 主页面是状态管理 V2（`@ComponentV2`），V2 组件不读 AppStorage V1 的键；
 *  ② 这条请求的生命周期很短 —— 由 `EntryAbility.onCreate / onNewWant` 写入，
 *     由首页 `onPageShow` 取走，**取一次即清空**，不需要可观察性。
 *
 * 卡片侧发的是 `postCardAction({ action: 'router', ... })`：
 * 应用没在运行 → 走 `onCreate`；已在后台 → 走 `onNewWant`。两者都把 want 交给这里。
 */
export class WidgetLaunch {
  private static pending: WidgetOpenRequest | undefined = undefined;
  /** 待办登记时刻（配合 `PENDING_TTL_MS` 判断是否已过期） */
  private static pendingAt: number = 0;

  /**
   * 解析 want 参数并登记待办。返回是否登记成功（不是卡片触发的启动就会返回 false）。
   *
   * 参数位置在不同版本上有两种形态，这里都兼容：
   *  ① `want.parameters` 直接就是 params 的键值对（文档示例）；
   *  ② `want.parameters.params` 里放着 params 的 JSON 字符串（部分版本实测如此）。
   */
  static request(parameters: Record<string, Object> | undefined): boolean {
    try {
      const bag: Record<string, Object> | undefined = WidgetLaunch.unwrap(parameters);
      if (bag === undefined) {
        return false;
      }
      const week: number = WidgetLaunch.intOf(bag[KEY_WEEK]);
      const period: number = WidgetLaunch.intOf(bag[KEY_PERIOD]);
      // 两个都没有 = 卡片只是"把应用拉起来"（空态且连周次都算不出的那几种环境空态），
      // 不必登记待办：不写参数启动本来就停在课表页（首页由系统直接加载）。
      if (week <= 0 && period <= 0) {
        return false;
      }
      const req: WidgetOpenRequest = new WidgetOpenRequest();
      req.weekNo = week;
      req.weekday = WidgetLaunch.intOf(bag[KEY_WEEKDAY]);
      req.periodId = period;
      // 连点两次以最后一次为准（用户最后点的那节课才是他想看的）
      WidgetLaunch.pending = req;
      WidgetLaunch.pendingAt = Date.now();
      Logger.info(TAG, period > 0
        ? `收到卡片定位请求：第 ${week} 周 星期${req.weekday} period#${period}`
        : `收到卡片"看课表"请求：第 ${week} 周 星期${req.weekday}（不开某节课）`);
      return true;
    } catch (e) {
      Logger.warn(TAG, `卡片参数解析失败：${errText(e)}`);
      return false;
    }
  }

  /** 是否有"新鲜"的待办（只查看，不消费）：首页据此决定本次 onPageShow 走哪条路径 */
  static hasPending(): boolean {
    return WidgetLaunch.isFresh();
  }

  /** 取走待办（取一次即清空，保证同一个请求只处理一次；过期请求直接丢弃） */
  static take(): WidgetOpenRequest | undefined {
    if (!WidgetLaunch.isFresh()) {
      if (WidgetLaunch.pending !== undefined) {
        Logger.info(TAG, '卡片定位请求已过期，丢弃');
      }
      WidgetLaunch.pending = undefined;
      return undefined;
    }
    const req: WidgetOpenRequest | undefined = WidgetLaunch.pending;
    WidgetLaunch.pending = undefined;
    return req;
  }

  private static isFresh(): boolean {
    return WidgetLaunch.pending !== undefined
      && (Date.now() - WidgetLaunch.pendingAt) <= PENDING_TTL_MS;
  }

  private static unwrap(parameters: Record<string, Object> | undefined): Record<string, Object> | undefined {
    if (parameters === undefined) {
      return undefined;
    }
    const nested: Object | undefined = parameters['params'];
    if (nested === undefined) {
      return parameters;
    }
    if (typeof nested === 'string') {
      const parsed: Object = JSON.parse(nested as string) as Object;
      return parsed as Record<string, Object>;
    }
    return nested as Record<string, Object>;
  }

  /** 卡片与 want 里的数字可能是 number 也可能是字符串，统一收敛成整数（非法值给 0） */
  private static intOf(raw: Object | undefined): number {
    if (raw === undefined) {
      return 0;
    }
    if (typeof raw === 'number') {
      const n: number = raw as number;
      return isNaN(n) ? 0 : Math.floor(n);
    }
    if (typeof raw === 'string') {
      const n: number = parseInt(raw as string, 10);
      return isNaN(n) ? 0 : n;
    }
    return 0;
  }
}
