import { formBindingData, formProvider } from '@kit.FormKit';
import { common } from '@kit.AbilityKit';
import { Logger } from '../common/Logger';
import { errText } from '../common/Util';
import { ScheduleRepository } from '../repository/ScheduleRepository';
import { WidgetData } from './WidgetData';
import { WidgetFormEntry, WidgetFormStore } from './WidgetFormStore';

const TAG: string = 'WidgetUpdater';

/**
 * 应用侧主动推卡片数据。
 *
 * 卡片虽然配了定时刷新（30 分钟一次），但"刚改完课表、回到桌面却还是旧课"的观感很差，
 * 所以在应用切前台 / 切后台时各推一次：改完课退出应用（触发 onBackground）时，
 * 桌面上的卡片已经是新数据了。
 *
 * 桌面上可能同时存在 2*2 与 2*4 两种尺寸。两种尺寸现在都显示两节（行数相同），
 * 但装配结果仍按"行数"缓存：同尺寸的卡片共用一份数据，避免为每张卡片重复查库。
 *
 * 单张卡片更新失败（通常是已被用户删掉）就把它的登记清掉，避免每次启动都白试一遍。
 */
export class WidgetUpdater {
  static async refreshAll(context: common.Context): Promise<void> {
    try {
      const entries: WidgetFormEntry[] = await WidgetFormStore.listForms(context);
      if (entries.length === 0) {
        return;
      }
      // 这里跑在**应用进程**里：正常初始化（该播种就播种、该自愈就自愈），所以 allowWrites = true
      await ScheduleRepository.getInstance().init(context, true);
      // 按"版式"缓存（只有窄卡 / 宽卡两种，用两个平行数组即可，无需 Map）
      const cachedWide: number[] = [];
      const cachedData: formBindingData.FormBindingData[] = [];
      for (let i = 0; i < entries.length; i++) {
        const entry: WidgetFormEntry = entries[i];
        const wide: number = WidgetData.isWideDimension(entry.dimension) ? 1 : 0;
        let slot: number = cachedWide.indexOf(wide);
        if (slot < 0) {
          cachedData.push(await WidgetData.build(context, entry.dimension, true));
          cachedWide.push(wide);
          slot = cachedWide.length - 1;
        }
        try {
          await formProvider.updateForm(entry.formId, cachedData[slot]);
        } catch (e) {
          Logger.warn(TAG, `卡片 ${entry.formId} 更新失败，注销登记：${errText(e)}`);
          await WidgetFormStore.removeFormId(context, entry.formId);
        }
      }
    } catch (e) {
      Logger.error(TAG, `推送卡片数据失败：${errText(e)}`);
    }
  }
}
