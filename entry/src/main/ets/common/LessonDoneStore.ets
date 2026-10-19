/**
 * 当天课程「已完成」登记簿（preferences）。
 *
 * 为什么不进数据库：课程完成态只是待办页的一次性勾划（当天有效，次日自然重置），
 * 不值得为它建表迁库 —— 按天一个 key 存逗号拼接的课程 key 最省事。
 * 课程 key = `${course_row_id}-${time_period_id}`（与列表 ForEach key 同源）。
 * 历史日期的登记留着不清理（每条几十字节，量级可忽略）。
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const STORE_NAME: string = 'lesson_done_store';

export class LessonDoneStore {
  /** 某天的存储 key：done_yyyyMMdd */
  private static dayKey(dayMs: number): string {
    const d: Date = new Date(dayMs);
    const mm: string = d.getMonth() < 9 ? `0${d.getMonth() + 1}` : `${d.getMonth() + 1}`;
    const dd: string = d.getDate() < 10 ? `0${d.getDate()}` : `${d.getDate()}`;
    return `done_${d.getFullYear()}${mm}${dd}`;
  }

  /** 读某天已完成的课程 key 列表（无 / 解析失败返回空数组） */
  static async load(context: common.Context, dayMs: number): Promise<string[]> {
    try {
      const pref: preferences.Preferences = await preferences.getPreferences(context, STORE_NAME);
      const raw: preferences.ValueType = await pref.get(LessonDoneStore.dayKey(dayMs), '');
      if (typeof raw !== 'string' || raw.length === 0) {
        return [];
      }
      const out: string[] = [];
      const parts: string[] = raw.split(',');
      for (let i = 0; i < parts.length; i++) {
        const key: string = parts[i].trim();
        if (key.length > 0 && out.indexOf(key) < 0) {
          out.push(key);
        }
      }
      return out;
    } catch (e) {
      return [];
    }
  }

  /** 整体覆写某天的完成登记；失败静默 —— 丢了只影响划线显示，不影响课表数据 */
  static async save(context: common.Context, dayMs: number, keys: string[]): Promise<void> {
    try {
      const pref: preferences.Preferences = await preferences.getPreferences(context, STORE_NAME);
      await pref.put(LessonDoneStore.dayKey(dayMs), keys.join(','));
      await pref.flush();
    } catch (e) {
      // 静默：登记失败只影响"重启后还在"，不影响本次会话
    }
  }
}
