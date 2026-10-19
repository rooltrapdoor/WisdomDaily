import { relationalStore } from '@kit.ArkData';
import { RsReader } from './DbExecutor';
import { DDL_ATTENDANCE, DDL_TODO_SUBTASK, DDL_TODO_TASK, Tables } from './TableSchema';

/**
 * 数据库版本迁移。
 *
 * 规则：
 *  - 迁移只能"向前"，不允许回头改历史项；
 *  - 每个迁移项必须幂等（可重复执行不报错），因为中途崩溃会重跑；
 *  - 迁移过程中的表结构变更优先使用 `ALTER TABLE ... ADD COLUMN` + 默认值；
 *    唯一例外是必须修改 CHECK / 列类型等无法 ALTER 的约束时，才允许
 *    "建新表 → 拷数据 → 换名"的整表重建（见 v3 的 rebuildClassGroupForArgb，
 *    记得关外键防级联误删、补中断恢复分支）；
 *  - 新增列后记得同步更新 TableSchema 里的建表语句，让"新装"和"升级"最终结构一致。
 *
 * 注意：ArkTS 严格模式禁止"接口 + 对象字面量内联函数"的写法
 * （arkts-no-untyped-obj-literals / arkts-no-noninferrable-arr-literals），
 * 因此这里是 class，迁移项一律用 `new Migration(...)` 生成。
 */
export class Migration {
  /** 迁移完成后应达到的版本号 */
  readonly targetVersion: number;
  /** 人类可读的描述，写进日志便于事后追查 */
  readonly describe: string;
  readonly run: (store: relationalStore.RdbStore) => Promise<void>;

  constructor(targetVersion: number, describe: string,
    run: (store: relationalStore.RdbStore) => Promise<void>) {
    this.targetVersion = targetVersion;
    this.describe = describe;
    this.run = run;
  }
}

/** 表里是否已有某列（PRAGMA table_info 探测，让 ALTER 真正幂等） */
export async function hasColumn(store: relationalStore.RdbStore, table: string,
  column: string): Promise<boolean> {
  const rs: relationalStore.ResultSet = await store.querySql(`PRAGMA table_info(${table})`, []);
  try {
    const reader: RsReader = new RsReader(rs);
    while (rs.goToNextRow()) {
      if (reader.str('name') === column) {
        return true;
      }
    }
    return false;
  } finally {
    rs.close();
  }
}

/** 表是否存在（sqlite_master 探测） */
export async function hasTable(store: relationalStore.RdbStore, table: string): Promise<boolean> {
  const rs: relationalStore.ResultSet =
    await store.querySql(`SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?`, [table]);
  try {
    return rs.rowCount > 0;
  } finally {
    rs.close();
  }
}

/**
 * v3：class_group 颜色格式 6 位 `#RRGGBB` → 8 位 `#AARRGGBB`（ARGB）。
 *
 * CHECK 约束无法用 ALTER 修改，只能整表重建（建新表 → 拷数据 → 换名）。
 * 关键风险：class_group 被 time_period 以 ON DELETE CASCADE 引用，若重建期间
 * 外键处于开启状态，DROP 会级联清空全部时间段数据——因此前后必须显式
 * 关闭/恢复外键（迁移语句经 store.execute 串行执行，写连接一致）。
 *
 * 幂等性：颜色升级用 CASE 只转换 length=7 的行；若上次迁移中断在
 * DROP 与 RENAME 之间（class_group 缺失、class_group_v3 仍在），直接补换名。
 */
async function rebuildClassGroupForArgb(store: relationalStore.RdbStore): Promise<void> {
  const oldExists: boolean = await hasTable(store, Tables.CLASS_GROUP);
  const stagingExists: boolean = await hasTable(store, 'class_group_v3');
  if (!oldExists && stagingExists) {
    // 上次中断在 DROP 之后、RENAME 之前：数据都在暂存表里，补一步换名即可
    await store.execute(`ALTER TABLE class_group_v3 RENAME TO ${Tables.CLASS_GROUP}`);
    return;
  }
  if (!oldExists) {
    // 两张表都不存在（异常状态）：交给迁移后的 DDL 补建 pass 重建空表
    return;
  }

  await store.execute(`PRAGMA foreign_keys = OFF`);
  try {
    // 清掉可能的半成品暂存表（CREATE 后中断的场景）
    await store.execute(`DROP TABLE IF EXISTS class_group_v3`);
    await store.execute(`CREATE TABLE class_group_v3 (
       id         INTEGER PRIMARY KEY AUTOINCREMENT,
       course_id  INTEGER NOT NULL,
       class_id   TEXT    NOT NULL,
       population INTEGER NOT NULL DEFAULT 0 CHECK (population >= 0),
       color      TEXT    NOT NULL DEFAULT '#F0F0F0'
                  CHECK (color GLOB '#[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]'
                      OR color GLOB '#[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]'),
       sort_order INTEGER NOT NULL DEFAULT 0,
       UNIQUE (course_id, class_id),
       FOREIGN KEY (course_id) REFERENCES course(id)     ON DELETE CASCADE,
       FOREIGN KEY (class_id)  REFERENCES class_info(class_id) ON DELETE RESTRICT
     )`);
    // 存量 6 位色补 FF Alpha（幂等：已是 8 位的原样透传）
    await store.execute(`INSERT INTO class_group_v3 (id, course_id, class_id, population, color, sort_order)
       SELECT id, course_id, class_id, population,
              CASE WHEN length(color) = 7 THEN '#FF' || substr(color, 2) ELSE color END,
              sort_order
         FROM ${Tables.CLASS_GROUP}`);
    // 外键已关：DROP 不会级联删除 time_period，子表引用随 RENAME 指回新表
    await store.execute(`DROP TABLE ${Tables.CLASS_GROUP}`);
    await store.execute(`ALTER TABLE class_group_v3 RENAME TO ${Tables.CLASS_GROUP}`);
    // 迁移 pass 之后 ScheduleDb 会重跑 DDL_INDEXES（IF NOT EXISTS），这里无需补索引
  } finally {
    await store.execute(`PRAGMA foreign_keys = ON`);
  }
}

export const MIGRATIONS: Migration[] = [
  new Migration(2,
    'app_setting 增加机主信息 owner_name / owner_staff_no（首启录入，作为默认教师）',
    async (store: relationalStore.RdbStore): Promise<void> => {
      const hasName: boolean = await hasColumn(store, Tables.APP_SETTING, 'owner_name');
      if (!hasName) {
        await store.execute(`ALTER TABLE ${Tables.APP_SETTING} ADD COLUMN owner_name TEXT`);
      }
      const hasStaffNo: boolean = await hasColumn(store, Tables.APP_SETTING, 'owner_staff_no');
      if (!hasStaffNo) {
        await store.execute(`ALTER TABLE ${Tables.APP_SETTING} ADD COLUMN owner_staff_no INTEGER`);
      }
    }),
  new Migration(3,
    'class_group.color 升级为 8 位 ARGB #AARRGGBB（重建表放宽 CHECK，存量色补 FF Alpha）',
    async (store: relationalStore.RdbStore): Promise<void> => {
      await rebuildClassGroupForArgb(store);
    }),
  new Migration(4,
    'app_setting 增加界面颜色 theme_color / today_color（主题色与今日高亮色，ARGB）',
    async (store: relationalStore.RdbStore): Promise<void> => {
      const hasTheme: boolean = await hasColumn(store, Tables.APP_SETTING, 'theme_color');
      if (!hasTheme) {
        await store.execute(
          `ALTER TABLE ${Tables.APP_SETTING} ADD COLUMN theme_color TEXT NOT NULL DEFAULT '#FF1890FF'`);
      }
      const hasToday: boolean = await hasColumn(store, Tables.APP_SETTING, 'today_color');
      if (!hasToday) {
        await store.execute(
          `ALTER TABLE ${Tables.APP_SETTING} ADD COLUMN today_color TEXT NOT NULL DEFAULT '#FF1890FF'`);
      }
    }),
  new Migration(5,
    'app_setting 增加上课提醒设置 notify_next_day / notify_ahead / notify_ahead_minutes',
    async (store: relationalStore.RdbStore): Promise<void> => {
      // 三个开关型列一律 NOT NULL + DEFAULT：存量行升级后自动拿到"关闭 + 20 分钟"，
      // 不需要再写一遍 UPDATE，也就不会有"半升级"的中间态。
      const hasNextDay: boolean = await hasColumn(store, Tables.APP_SETTING, 'notify_next_day');
      if (!hasNextDay) {
        await store.execute(
          `ALTER TABLE ${Tables.APP_SETTING} ADD COLUMN notify_next_day INTEGER NOT NULL DEFAULT 0`);
      }
      const hasAhead: boolean = await hasColumn(store, Tables.APP_SETTING, 'notify_ahead');
      if (!hasAhead) {
        await store.execute(
          `ALTER TABLE ${Tables.APP_SETTING} ADD COLUMN notify_ahead INTEGER NOT NULL DEFAULT 0`);
      }
      const hasMinutes: boolean = await hasColumn(store, Tables.APP_SETTING, 'notify_ahead_minutes');
      if (!hasMinutes) {
        await store.execute(
          `ALTER TABLE ${Tables.APP_SETTING} ADD COLUMN notify_ahead_minutes INTEGER NOT NULL DEFAULT 20`);
      }
    }),
  new Migration(6,
    '新增 attendance 表（签到记录：时间段 × 周次 × 学生 → 出勤状态 + 等级 + 分数）',
    async (store: relationalStore.RdbStore): Promise<void> => {
      // 整表新建、没有存量数据要搬，所以建表语句直接执行即可（IF NOT EXISTS，天然幂等）。
      // 建表语句与 DDL_TABLES 共用同一个常量（DDL_ATTENDANCE），不抄第二份。
      // 索引不在这一步做：migrate() 末尾会整体重跑 DDL_INDEXES（全部 IF NOT EXISTS）。
      await store.execute(DDL_ATTENDANCE);
    }),
  new Migration(7,
    '新增 todo_task / todo_subtask 两表（待办：任务 + 子任务，含回收站与提醒列）',
    async (store: relationalStore.RdbStore): Promise<void> => {
      // 整表新建、没有存量数据要搬，建表语句与 DDL_TABLES 共用同一份常量（幂等）。
      // 索引不在这一步做：migrate() 末尾会整体重跑 DDL_INDEXES（全部 IF NOT EXISTS）。
      await store.execute(DDL_TODO_TASK);
      await store.execute(DDL_TODO_SUBTASK);
    })
];
