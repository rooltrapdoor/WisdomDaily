import { formBindingData, FormExtensionAbility, formInfo, formProvider } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { Logger } from '../common/Logger';
import { errText } from '../common/Util';
import { WidgetData } from '../widget/WidgetData';
import { WidgetFormStore } from '../widget/WidgetFormStore';

const TAG: string = 'EntryFormAbility';

/**
 * 课表卡片的能力入口。
 *
 * 卡片页跑在独立的卡片进程里、不能访问数据库，所以数据统一在这里查好再推：
 *  - `onAddForm`：卡片刚被添加到桌面（**必须同步返回**，先给"正在加载…"，随后异步覆盖）；
 *    这一次的 want 里带着卡片尺寸（`FormParam.DIMENSION_KEY`），要顺手登记下来 ——
 *    后续的定时刷新拿不到尺寸，只能靠这次记下的值。
 *  - `onUpdateForm`：系统按 `form_config.json` 的定时策略回调（30 分钟一次），
 *    也是卡片按当前时间重算"还没上的课"与"22 点后切次日"的触发点；
 *  - `onRemoveForm`：卡片被删掉，注销 formId 登记。
 *
 * 注意：**卡片尺寸不影响行数**（2*2 / 2*4 都显示两节，见 `WidgetData.ROW_LIMIT`），
 * 但**影响每行放什么、怎么排**：小卡 2*2 是 150×150 vp（窄），一节课竖排两行"课程名 / 钟点 + 教室"；
 * 中卡 2*4 是 316×150 vp（宽，与 2*2 **同高**），一节课横排两行"名称（类型）+ 班级 / 节次·钟点 + 教室·人数"。
 * 卡片页拿不到自己的尺寸，所以尺寸在这里登记、在这里算成版式标记推过去。
 */
export default class EntryFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    const formId: string = EntryFormAbility.formIdOf(want);
    const dimension: number = EntryFormAbility.dimensionOf(want);
    // 先登记（含尺寸）再查库：刷新时要按尺寸算行数与版式，顺序不能反
    this.register(formId, dimension);
    return formBindingData.createFormBindingData(WidgetData.placeholder(dimension));
  }

  onUpdateForm(formId: string): void {
    this.refresh(formId);
  }

  onRemoveForm(formId: string): void {
    WidgetFormStore.removeFormId(this.context, formId);
  }

  onAcquireFormState(want: Want): formInfo.FormState {
    return formInfo.FormState.READY;
  }

  /** 登记 formId 与尺寸，登记完立刻推一次数据（onAddForm 里不能同步等，所以单独开一条链） */
  private async register(formId: string, dimension: number): Promise<void> {
    if (formId.length === 0) {
      return;
    }
    await WidgetFormStore.saveForm(this.context, formId, dimension);
    await this.refresh(formId);
  }

  /** 查库 → 推给指定卡片（失败只记日志：卡片会被系统按定时策略重试） */
  private async refresh(formId: string): Promise<void> {
    try {
      if (formId.length === 0) {
        return;
      }
      const dimension: number = await WidgetFormStore.dimensionOf(this.context, formId);
      const rows: number = WidgetData.rowsOfDimension(dimension);
      // allowWrites = false：卡片进程**只读**。
      // 应用界面与卡片是两个进程、共用同一个库文件，卡片这边只要一开写事务，
      // 应用那边就可能拿到 SQLite 的"database file is locked"（14800024）
      // 而把整个课表页显示成加载失败。卡片只需要看数据，那就一点写权限都不要。
      const data: formBindingData.FormBindingData = await WidgetData.build(this.context, dimension, false);
      await formProvider.updateForm(formId, data);
      Logger.info(TAG, `卡片 ${formId} 已刷新（尺寸 ${dimension}，最多 ${rows} 节，`
        + `${WidgetData.isWideDimension(dimension) ? '宽卡版式' : '小卡版式'}）`);
    } catch (e) {
      Logger.error(TAG, `刷新卡片失败：${errText(e)}`);
    }
  }

  /** formId 藏在 want.parameters 里，键是 formInfo.FormParam.IDENTITY_KEY */
  private static formIdOf(want: Want): string {
    const params: Record<string, Object> | undefined = want.parameters;
    if (params === undefined) {
      return '';
    }
    const raw: Object = params[formInfo.FormParam.IDENTITY_KEY];
    return typeof raw === 'string' ? raw as string : '';
  }

  /** 卡片尺寸也藏在 want.parameters 里（`FormParam.DIMENSION_KEY`），只在 onAddForm 这一次可用 */
  private static dimensionOf(want: Want): number {
    const params: Record<string, Object> | undefined = want.parameters;
    if (params === undefined) {
      return 0;
    }
    const raw: Object | undefined = params[formInfo.FormParam.DIMENSION_KEY];
    if (raw === undefined) {
      return 0;
    }
    if (typeof raw === 'number') {
      return raw as number;
    }
    if (typeof raw === 'string') {
      const n: number = parseInt(raw as string, 10);
      return isNaN(n) ? 0 : n;
    }
    return 0;
  }
}
