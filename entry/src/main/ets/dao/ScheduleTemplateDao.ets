import { relationalStore } from '@kit.ArkData';
import { DbExecutor, RsReader } from '../db/DbExecutor';
import { DaoSupport } from './DaoSupport';
import { ScheduleSlotRow, ScheduleTemplateRow } from '../model/Rows';
import { ScheduleSlot, ScheduleTemplate } from '../model/ScheduleTemplate';
import { Tables, Views } from '../db/TableSchema';
import { nowMs } from '../common/Util';

/** schedule_template + schedule_slot 两张表的读写，对外始终以"模板 + 节次表"整体出现 */
export class ScheduleTemplateDao {
  private static mapTemplate(reader: RsReader): ScheduleTemplateRow {
    return {
      id: reader.num('id'),
      name: reader.str('name'),
      class_sessions: reader.num('class_sessions', 12),
      duration_time: reader.num('duration_time', 45),
      is_builtin: reader.bool('is_builtin'),
      citation_count: reader.num('citation_count')
    };
  }

  /** 列表：只查一次 slot 表，再在内存里按 schedule_id 归组，避免 N+1 */
  static async listAll(exec: DbExecutor): Promise<ScheduleTemplateRow[]> {
    const rs = await exec.querySql(
      `SELECT id, name, class_sessions, duration_time, is_builtin, citation_count
         FROM ${Views.V_TEMPLATE_STAT} ORDER BY is_builtin DESC, id ASC`, []);
    const rows: ScheduleTemplateRow[] = [];
    try {
      while (rs.goToNextRow()) {
        rows.push(ScheduleTemplateDao.mapTemplate(new RsReader(rs)));
      }
    } finally {
      rs.close();
    }
    return rows;
  }

  static async listAllSlots(exec: DbExecutor): Promise<ScheduleSlotRow[]> {
    const rs = await exec.querySql(
      `SELECT schedule_id, session_no, start_time, end_time
         FROM ${Tables.SCHEDULE_SLOT} ORDER BY schedule_id ASC, session_no ASC`, []);
    const rows: ScheduleSlotRow[] = [];
    try {
      while (rs.goToNextRow()) {
        const reader: RsReader = new RsReader(rs);
        rows.push({
          schedule_id: reader.num('schedule_id'),
          session_no: reader.num('session_no'),
          start_time: reader.str('start_time'),
          end_time: reader.str('end_time')
        });
      }
    } finally {
      rs.close();
    }
    return rows;
  }

  static async findById(exec: DbExecutor, id: number): Promise<ScheduleTemplateRow | undefined> {
    const rs = await exec.querySql(
      `SELECT id, name, class_sessions, duration_time, is_builtin, citation_count
         FROM ${Views.V_TEMPLATE_STAT} WHERE id = ?`, [id]);
    try {
      if (!rs.goToFirstRow()) {
        return undefined;
      }
      return ScheduleTemplateDao.mapTemplate(new RsReader(rs));
    } finally {
      rs.close();
    }
  }

  static async findByName(exec: DbExecutor, name: string): Promise<ScheduleTemplateRow | undefined> {
    const rs = await exec.querySql(
      `SELECT id, name, class_sessions, duration_time, is_builtin, citation_count
         FROM ${Views.V_TEMPLATE_STAT} WHERE name = ?`, [name]);
    try {
      if (!rs.goToFirstRow()) {
        return undefined;
      }
      return ScheduleTemplateDao.mapTemplate(new RsReader(rs));
    } finally {
      rs.close();
    }
  }

  static async slotsOf(exec: DbExecutor, scheduleId: number): Promise<ScheduleSlot[]> {
    const rs = await exec.querySql(
      `SELECT session_no, start_time, end_time FROM ${Tables.SCHEDULE_SLOT}
        WHERE schedule_id = ? ORDER BY session_no ASC`, [scheduleId]);
    const slots: ScheduleSlot[] = [];
    try {
      while (rs.goToNextRow()) {
        const reader: RsReader = new RsReader(rs);
        slots.push(ScheduleSlot.of(reader.num('session_no'), reader.str('start_time'), reader.str('end_time')));
      }
    } finally {
      rs.close();
    }
    return slots;
  }

  static async insert(exec: DbExecutor, template: ScheduleTemplate): Promise<number> {
    const ts: number = nowMs();
    await exec.executeSql(
      `INSERT INTO ${Tables.SCHEDULE_TEMPLATE}
         (name, class_sessions, duration_time, is_builtin, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?)`,
      [template.name, template.class_sessions, template.duration_time,
        template.is_builtin ? 1 : 0, ts, ts]);
    const newId: number = await DaoSupport.lastRowId(exec);
    await ScheduleTemplateDao.replaceSlots(exec, newId, template.slots);
    return newId;
  }

  static async update(exec: DbExecutor, template: ScheduleTemplate): Promise<void> {
    await exec.executeSql(
      `UPDATE ${Tables.SCHEDULE_TEMPLATE}
          SET name = ?, class_sessions = ?, duration_time = ?, updated_at = ?
        WHERE id = ?`,
      [template.name, template.class_sessions, template.duration_time, nowMs(), template.id]);
  }

  /** 节次表整体替换：先删后插，保证节数与 class_sessions 永远一致（旧二维数组做不到这点） */
  static async replaceSlots(exec: DbExecutor, scheduleId: number, slots: ScheduleSlot[]): Promise<void> {
    await exec.executeSql(`DELETE FROM ${Tables.SCHEDULE_SLOT} WHERE schedule_id = ?`, [scheduleId]);
    if (slots.length === 0) {
      return;
    }
    const buckets: Array<relationalStore.ValuesBucket> = [];
    for (let i = 0; i < slots.length; i++) {
      const slot: ScheduleSlot = slots[i];
      const bucket: relationalStore.ValuesBucket = {};
      bucket['schedule_id'] = scheduleId;
      bucket['session_no'] = i + 1;
      bucket['start_time'] = slot.start_time;
      bucket['end_time'] = slot.end_time;
      buckets.push(bucket);
    }
    await exec.batchInsert(Tables.SCHEDULE_SLOT, buckets);
  }

  static async deleteById(exec: DbExecutor, id: number): Promise<void> {
    await exec.executeSql(`DELETE FROM ${Tables.SCHEDULE_SLOT} WHERE schedule_id = ?`, [id]);
    await exec.executeSql(`DELETE FROM ${Tables.SCHEDULE_TEMPLATE} WHERE id = ?`, [id]);
  }

  static async count(exec: DbExecutor): Promise<number> {
    return DaoSupport.scalarNumber(exec, `SELECT COUNT(*) AS v FROM ${Tables.SCHEDULE_TEMPLATE}`, []);
  }
}
