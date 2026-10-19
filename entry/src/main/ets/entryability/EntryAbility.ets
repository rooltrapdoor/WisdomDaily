import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../common/Logger';
import { PAGE_BG_COLOR, errText } from '../common/Util';
import { ScheduleRepository } from '../repository/ScheduleRepository';
import { WidgetLaunch } from '../widget/WidgetLaunch';
import { WidgetUpdater } from '../widget/WidgetUpdater';

const TAG: string = 'EntryAbility';

/**
 * 应用入口。
 *
 * 与旧实现的对比（这是改造后最直接的一处简化）：
 *  - 旧版：onCreate 里把 rawfile 种子拷进沙箱、读 default_setting.json、
 *    在 onBackground / onWindowStageDestroy / onAbilityDestroy **三处**都挂上"保存全部数据"，
 *    因为数据只在内存里，进程随时可能被系统回收。
 *  - 现在：冷启动只做一次"打开数据库 + 首启初始化"，此后每次编辑都在自己的事务里落库。
 *    三个生命周期回调里的兜底保存全部删掉——留一个空实现只是为了日志上能看清这一点。
 */
export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);

    // 冷启动即打开数据库并完成首启初始化（老用户走一次性旧数据导入）。
    // 页面侧 await 同一个 Promise，不会重复初始化。
    ScheduleRepository.getInstance().init(this.context)
      .then(() => {
        Logger.info(TAG, '数据库初始化完成，后续编辑将实时落库');
      })
      .catch((e: Object) => {
        Logger.error(TAG, `数据库初始化失败：${ScheduleRepository.describeError(e)}`);
      });

    // 卡片点课拉起应用：先把"要看哪一节课"记下来，首页 onPageShow 会取走并打开详情
    this.acceptCardLaunch(want);
  }

  /**
   * 应用已在后台时，卡片再次点击（router 事件）走这里而不是 onCreate。
   *
   * `launchType` 是单实例（默认），所以热启动不会重走 onCreate，必须单独接一次，
   * 否则"应用没被杀掉时点卡片没反应"。
   */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    Logger.info(TAG, 'onNewWant：来自卡片的再次拉起');
    this.acceptCardLaunch(want);
  }

  private acceptCardLaunch(want: Want): void {
    if (WidgetLaunch.request(want.parameters)) {
      Logger.info(TAG, '已记录卡片定位请求，等待首页消费');
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code) {
        Logger.error(TAG, `首页加载失败：code=${err.code}, message=${err.message}`);
        return;
      }
      Logger.info(TAG, '首页加载完成');
      this.applySystemBarColors(windowStage);
    });
  }

  /**
   * 窗口底色与系统栏同色 —— 屏幕上下两条边一起对齐页面底色。
   *
   * 两处要分清（踩过坑才写下来）：
   *  - **状态栏**：`statusBarColor` 真能上色，顶部那条就是它。
   *  - **底部手势导航条区域**：**没有背景色 API**。`navigationBarColor` 只对传统三键
   *    导航生效；手势导航下这块是系统区域、**透传窗口底色**，不设时是白色，
   *    页面是浅灰，于是底部多出一条 33vp 的白边（真机截图取色量出来的）。
   *
   * 正解是官方「沉浸式」指南里的同色方案：把**窗口底色**设成页面底色，导航条区域
   * 自己就跟着一致了 —— 不必开 layoutFullScreen 去动页面布局。
   *
   * 颜色一律取 `PAGE_BG_COLOR`（`common/Util.ets` 里的唯一定义），不许在这里写裸字面量：
   * 窗口底色与页面底色漂开，屏幕上就是一条白边。
   */
  private applySystemBarColors(windowStage: window.WindowStage): void {
    windowStage.getMainWindow((err: BusinessError, win: window.Window) => {
      if (err.code) {
        Logger.error(TAG, `获取主窗口失败：code=${err.code}, message=${err.message}`);
        return;
      }
      // 底部手势导航条区域透传的就是它 —— 与页面底色同源，下方那条白边才会消失
      try {
        win.setWindowBackgroundColor(PAGE_BG_COLOR);
      } catch (e) {
        // 窗口未就绪时会抛 1300002 —— 不该阻断启动，记一条日志即可
        Logger.error(TAG, `设置窗口背景色失败（已忽略）：${errText(e)}`);
      }
      const props: window.SystemBarProperties = {
        statusBarColor: PAGE_BG_COLOR,
        statusBarContentColor: '#111827',
        navigationBarColor: PAGE_BG_COLOR,
        navigationBarContentColor: '#111827'
      };
      win.setWindowSystemBarProperties(props).then(() => {
        Logger.info(TAG, `窗口底色与系统栏已设为 ${PAGE_BG_COLOR}`);
      }).catch((e: BusinessError) => {
        Logger.error(TAG, `设置系统栏颜色失败：code=${e.code}, message=${e.message}`);
      });
    });
  }

  onBackground(): void {
    // 数据已在每次编辑时提交事务，这里不再需要"保存全部数据"
    Logger.info(TAG, 'onBackground：无待落库数据（实时事务提交）');
    // 用户改完课表离开应用（回桌面）时把卡片刷成最新，避免"卡片还是旧课"
    WidgetUpdater.refreshAll(this.context);
  }

  onWindowStageDestroy(): void {
    Logger.info(TAG, 'onWindowStageDestroy：无待落库数据');
  }

  onForeground(): void {
    Logger.debug(TAG, 'onForeground');
    // 打开应用时顺带把桌面卡片刷一次（换天 / 跨 22 点后第一次进应用也能立刻正确）
    WidgetUpdater.refreshAll(this.context);
  }

  onDestroy(): void {
    ScheduleRepository.getInstance().close()
      .then(() => Logger.info(TAG, 'onDestroy：数据库连接已释放'))
      .catch((e: Object) => Logger.error(TAG, `关闭数据库异常：${ScheduleRepository.describeError(e)}`));
  }
}
