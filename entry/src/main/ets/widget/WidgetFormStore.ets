import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Logger } from '../common/Logger';
import { errText } from '../common/Util';

const TAG: string = 'WidgetFormStore';
const STORE_NAME: string = 'schedule_widget';
const KEY_IDS: string = 'form_ids';

/** 一张已添加卡片：formId + 它被添加时的尺寸（`formInfo.FormDimension` 的数值） */
export class WidgetFormEntry {
  formId: string = '';
  dimension: number = 0;
}

/**
 * 已添加卡片的 formId 登记簿（preferences）。
 *
 * 为什么需要：`formProvider` 只提供"按 formId 更新"，**没有**"列出本应用所有卡片"的接口，
 * 而应用侧想做到"编辑后立刻刷新卡片"就必须能枚举出这些 id。
 * 于是由卡片进程在 `onAddForm` / `onRemoveForm` 时登记 / 注销，主进程只读。
 *
 * 为什么连尺寸一起记：卡片页跑在独立进程、拿不到自己的尺寸，
 * "这一节课怎么排"（窄卡竖排两行 / 宽卡横排两行）只能在提供方决定。
 * 而尺寸**只有 `onAddForm` 那一次 want 里带着**（`FormParam.DIMENSION_KEY`），
 * 之后的定时刷新（`onUpdateForm`）和应用主动推送都拿不到 —— 所以必须在添加时就存下来。
 *
 * 存成 `formId:dimension` 逗号分隔的字符串而不是数组：ValueType 的联合数组类型在 ArkTS
 * 严格模式下取值后要做类型收敛，formId 本身是纯数字串，用字符串最省事也最不容易出岔子。
 * 老格式（只有 formId、没有 `:dimension`）解析时尺寸按 0 处理，即退化为小卡版式。
 */
export class WidgetFormStore {
  /** 登记 / 更新一张卡片（重复添加同一 formId 只更新尺寸） */
  static async saveForm(context: common.Context, formId: string, dimension: number): Promise<void> {
    if (formId.length === 0) {
      return;
    }
    try {
      const entries: WidgetFormEntry[] = await WidgetFormStore.listForms(context);
      const kept: WidgetFormEntry[] = [];
      for (let i = 0; i < entries.length; i++) {
        if (entries[i].formId !== formId) {
          kept.push(entries[i]);
        }
      }
      const entry: WidgetFormEntry = new WidgetFormEntry();
      entry.formId = formId;
      entry.dimension = dimension;
      kept.push(entry);
      await WidgetFormStore.save(context, kept);
      Logger.info(TAG, `登记卡片 ${formId}（尺寸 ${dimension}），当前共 ${kept.length} 张`);
    } catch (e) {
      Logger.error(TAG, `登记卡片失败：${errText(e)}`);
    }
  }

  static async removeFormId(context: common.Context, formId: string): Promise<void> {
    try {
      const entries: WidgetFormEntry[] = await WidgetFormStore.listForms(context);
      const kept: WidgetFormEntry[] = [];
      for (let i = 0; i < entries.length; i++) {
        if (entries[i].formId !== formId) {
          kept.push(entries[i]);
        }
      }
      if (kept.length === entries.length) {
        return;
      }
      await WidgetFormStore.save(context, kept);
      Logger.info(TAG, `注销卡片 ${formId}，当前共 ${kept.length} 张`);
    } catch (e) {
      Logger.error(TAG, `注销卡片失败：${errText(e)}`);
    }
  }

  static async listFormIds(context: common.Context): Promise<string[]> {
    const entries: WidgetFormEntry[] = await WidgetFormStore.listForms(context);
    const ids: string[] = [];
    for (let i = 0; i < entries.length; i++) {
      ids.push(entries[i].formId);
    }
    return ids;
  }

  static async listForms(context: common.Context): Promise<WidgetFormEntry[]> {
    const pref: preferences.Preferences = await preferences.getPreferences(context, STORE_NAME);
    const raw: preferences.ValueType = await pref.get(KEY_IDS, '');
    const text: string = typeof raw === 'string' ? raw as string : '';
    const entries: WidgetFormEntry[] = [];
    if (text.length === 0) {
      return entries;
    }
    const parts: string[] = text.split(',');
    for (let i = 0; i < parts.length; i++) {
      const part: string = parts[i].trim();
      if (part.length === 0) {
        continue;
      }
      const entry: WidgetFormEntry = new WidgetFormEntry();
      const colon: number = part.indexOf(':');
      if (colon < 0) {
        entry.formId = part;
      } else {
        entry.formId = part.substring(0, colon);
        const n: number = parseInt(part.substring(colon + 1), 10);
        entry.dimension = isNaN(n) ? 0 : n;
      }
      if (entry.formId.length > 0) {
        entries.push(entry);
      }
    }
    return entries;
  }

  /** 某张卡片的尺寸（未登记 / 老格式 → 0，调用方按默认尺寸处理） */
  static async dimensionOf(context: common.Context, formId: string): Promise<number> {
    try {
      const entries: WidgetFormEntry[] = await WidgetFormStore.listForms(context);
      for (let i = 0; i < entries.length; i++) {
        if (entries[i].formId === formId) {
          return entries[i].dimension;
        }
      }
    } catch (e) {
      Logger.warn(TAG, `读取卡片尺寸失败：${errText(e)}`);
    }
    return 0;
  }

  private static async save(context: common.Context, entries: WidgetFormEntry[]): Promise<void> {
    const parts: string[] = [];
    for (let i = 0; i < entries.length; i++) {
      parts.push(`${entries[i].formId}:${entries[i].dimension}`);
    }
    const pref: preferences.Preferences = await preferences.getPreferences(context, STORE_NAME);
    await pref.put(KEY_IDS, parts.join(','));
    await pref.flush();
  }
}
