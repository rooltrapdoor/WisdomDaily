/**
 * 数据库表结构唯一真源（Single Source of Truth）。
 *
 * 约定：
 *  - 表名 / 列名一律 snake_case，与旧 JSON 字段名保持一致，便于迁移与对照。
 *  - 所有时间戳为 INTEGER（毫秒，本地时区无歧义的 epoch）。
 *  - 布尔用 INTEGER 0/1 + CHECK 约束。
 *  - 颜色用 TEXT 并强制 `#RRGGBB`（6 位，不透明）或 `#AARRGGBB`（8 位，带透明度）：
 *    把"格式写坏"直接堵在库层；自动字色算法会把 Alpha 合成到白底再判深浅。
 *  - 一个学期内的教师、课程、班级、时间段全部靠外键串起来，删除课程自动级联清理。
 */

export const DB_NAME: string = 'wisdomdaily.db';

/** 当前 schema 版本，每次结构变更 +1，并在 DbMigrations 里补一段迁移 */
export const DB_VERSION: number = 7;

export class Tables {
  static readonly APP_SETTING: string = 'app_setting';
  static readonly SEMESTER: string = 'semester';
  static readonly SCHEDULE_TEMPLATE: string = 'schedule_template';
  static readonly SCHEDULE_SLOT: string = 'schedule_slot';
  static readonly TEACHER: string = 'teacher';
  static readonly COURSE: string = 'course';
  static readonly CLASS_INFO: string = 'class_info';
  static readonly CLASS_GROUP: string = 'class_group';
  static readonly TIME_PERIOD: string = 'time_period';
  static readonly PERIOD_WEEK: string = 'period_week';
  static readonly STUDENT: string = 'student';
  static readonly ATTENDANCE: string = 'attendance';
  static readonly TODO_TASK: string = 'todo_task';
  static readonly TODO_SUBTASK: string = 'todo_subtask';
}

export class Views {
  /** 扁平化的"一节课"视图：课表渲染 / 冲突检测 / 统计全部基于它 */
  static readonly V_LESSON: string = 'v_lesson';
  /** 模板 + 被引用次数（计数由 COUNT 实时算，不再维护冗余计数列） */
  static readonly V_TEMPLATE_STAT: string = 'v_template_stat';
}

/**
 * 签到（点名）记录表。**单独抽成常量是因为它被两处引用**：
 * `DDL_TABLES`（新装与"版本号已是 6 但表被清掉"的自检重建）和
 * `DbMigrations` 的 v6 迁移段 —— 抄两份建表语句迟早会漂移成两种结构。
 *
 * 一行 = **一次具体上课的某个学生**：
 *  - `time_period_id + week_no` 定位"哪一次课"（同一门课第 3 周与第 4 周是两次）；
 *  - `status` 三态：`present` 出勤（导出 √）/ `absent` 旷课（×）/ `leave` 请假（⊕）；
 *  - `grade` = 长按下滑选的等级 1~5（对应 90~95 / 85~90 / 80~85 / 72~80 / 65~72 五个分档）；
 *  - `score` = **选等级时当场算好并落库**的区间随机分，写进导出表的"课堂状态"列。
 *    **不放在导出时现算**：同一份数据导两次分数不一样，老师没法对账。
 *
 * 唯一键压在 (时间段, 周次, 学生) 上：重复点名走"先清本次课、再整批写"，天然幂等。
 */
export const DDL_ATTENDANCE: string =
  `CREATE TABLE IF NOT EXISTS attendance (
     id             INTEGER PRIMARY KEY AUTOINCREMENT,
     time_period_id INTEGER NOT NULL,
     week_no        INTEGER NOT NULL CHECK (week_no BETWEEN 1 AND 60),
     student_id     INTEGER NOT NULL,
     status         TEXT    NOT NULL DEFAULT 'present'
                    CHECK (status IN ('present', 'absent', 'leave')),
     grade          INTEGER CHECK (grade IS NULL OR (grade >= 1 AND grade <= 5)),
     score          INTEGER CHECK (score IS NULL OR (score >= 0 AND score <= 100)),
     created_at     INTEGER NOT NULL DEFAULT 0,
     updated_at     INTEGER NOT NULL DEFAULT 0,
     UNIQUE (time_period_id, week_no, student_id),
     FOREIGN KEY (time_period_id) REFERENCES time_period(id) ON DELETE CASCADE,
     FOREIGN KEY (student_id)     REFERENCES student(id)     ON DELETE CASCADE
   )`;

/** 待办任务（待办页主数据；与课表数据完全独立，不带学期外键） */
export const DDL_TODO_TASK: string =
  `CREATE TABLE IF NOT EXISTS todo_task (
     id                INTEGER PRIMARY KEY AUTOINCREMENT,
     title             TEXT    NOT NULL,
     description       TEXT    NOT NULL DEFAULT '',
     due_at            INTEGER,
     remind_at         INTEGER,
     remind_offset_min INTEGER,
     priority          INTEGER NOT NULL DEFAULT 0 CHECK (priority BETWEEN 0 AND 3),
     tag               TEXT,
     list_name         TEXT    NOT NULL DEFAULT '个人',
     repeat_rule       TEXT    NOT NULL DEFAULT 'none'
                       CHECK (repeat_rule IN ('none', 'daily', 'weekly', 'monthly')),
     done              INTEGER NOT NULL DEFAULT 0 CHECK (done IN (0, 1)),
     done_at           INTEGER,
     remind_fired      INTEGER NOT NULL DEFAULT 0 CHECK (remind_fired IN (0, 1)),
     deleted           INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0, 1)),
     deleted_at        INTEGER,
     archived          INTEGER NOT NULL DEFAULT 0 CHECK (archived IN (0, 1)),
     created_at        INTEGER NOT NULL,
     updated_at        INTEGER NOT NULL
   )`;

/** 待办子任务（任务下可拆子项，独立完成；随任务整体重写） */
export const DDL_TODO_SUBTASK: string =
  `CREATE TABLE IF NOT EXISTS todo_subtask (
     id         INTEGER PRIMARY KEY AUTOINCREMENT,
     task_id    INTEGER NOT NULL,
     title      TEXT    NOT NULL,
     done       INTEGER NOT NULL DEFAULT 0 CHECK (done IN (0, 1)),
     sort_order INTEGER NOT NULL DEFAULT 0
   )`;

/** 建表顺序 = 外键依赖顺序，不要随意调整 */
export const DDL_TABLES: string[] = [
  // 1. 课表时间模板（作息表）
  `CREATE TABLE IF NOT EXISTS schedule_template (
     id             INTEGER PRIMARY KEY AUTOINCREMENT,
     name           TEXT    NOT NULL UNIQUE,
     class_sessions INTEGER NOT NULL DEFAULT 12 CHECK (class_sessions BETWEEN 1 AND 24),
     duration_time  INTEGER NOT NULL DEFAULT 45 CHECK (duration_time BETWEEN 1 AND 300),
     is_builtin     INTEGER NOT NULL DEFAULT 0  CHECK (is_builtin IN (0, 1)),
     created_at     INTEGER NOT NULL DEFAULT 0,
     updated_at     INTEGER NOT NULL DEFAULT 0
   )`,

  // 2. 每节课的起止时间（替代原 class_time 二维数组，可被 SQL 直接查询与校验）
  `CREATE TABLE IF NOT EXISTS schedule_slot (
     schedule_id INTEGER NOT NULL,
     session_no  INTEGER NOT NULL CHECK (session_no BETWEEN 1 AND 24),
     start_time  TEXT    NOT NULL,
     end_time    TEXT    NOT NULL,
     PRIMARY KEY (schedule_id, session_no),
     FOREIGN KEY (schedule_id) REFERENCES schedule_template(id) ON DELETE CASCADE
   )`,

  // 3. 学期
  `CREATE TABLE IF NOT EXISTS semester (
     id          INTEGER PRIMARY KEY AUTOINCREMENT,
     name        TEXT    NOT NULL UNIQUE,
     total_weeks INTEGER NOT NULL DEFAULT 20 CHECK (total_weeks BETWEEN 1 AND 60),
     start_date  TEXT    NOT NULL DEFAULT '',      -- 第 1 周周一，'YYYY-MM-DD'
     schedule_id INTEGER,                          -- 引用的作息模板
     sort_order  INTEGER NOT NULL DEFAULT 0,       -- 保持用户看到的学期顺序
     created_at  INTEGER NOT NULL DEFAULT 0,
     updated_at  INTEGER NOT NULL DEFAULT 0,
     FOREIGN KEY (schedule_id) REFERENCES schedule_template(id) ON DELETE SET NULL
   )`,

  // 4. 教师（归属学期，与旧结构"教师内联在学期里"一致）
  `CREATE TABLE IF NOT EXISTS teacher (
     id          INTEGER PRIMARY KEY AUTOINCREMENT,
     semester_id INTEGER NOT NULL,
     staff_no    INTEGER NOT NULL,                 -- 原 Teacher.id（工号）
     name        TEXT    NOT NULL,
     department  TEXT,
     age         INTEGER,
     sex         TEXT,
     telephone   TEXT,
     sort_order  INTEGER NOT NULL DEFAULT 0,
     created_at  INTEGER NOT NULL DEFAULT 0,
     updated_at  INTEGER NOT NULL DEFAULT 0,
     UNIQUE (semester_id, staff_no, name),
     FOREIGN KEY (semester_id) REFERENCES semester(id) ON DELETE CASCADE
   )`,

  // 5. 单行应用设置（替代 default_setting.json，用 CHECK 保证只有一行）
  `CREATE TABLE IF NOT EXISTS app_setting (
     id          INTEGER PRIMARY KEY CHECK (id = 1),
     semester_id INTEGER,
     teacher_id  INTEGER,
     theme_mode  INTEGER NOT NULL DEFAULT 0 CHECK (theme_mode IN (0, 1, 2)),
     -- 界面颜色（ARGB）：写在 app_setting 而不是另建表，因为它是"全局唯一一份"的配置。
     -- 刻意不加 CHECK：列由 ALTER TABLE 迁移补上，为了"新装 = 升级"结构完全一致，
     -- 这里也不引入 CHECK；写入路径由 normalizeColor()/colorOr() 兜底格式。
     theme_color TEXT    NOT NULL DEFAULT '#FF1890FF',
     today_color TEXT    NOT NULL DEFAULT '#FF1890FF',
     owner_name      TEXT,                           -- 机主姓名（首启录入，作为默认教师）
     owner_staff_no  INTEGER,                        -- 机主教师工号
     -- 上课提醒（"我的 → 上课提醒"）。同样是"全局唯一一份"的配置，跟界面颜色放在一起。
     -- 与 theme_color 一样刻意不加 CHECK（列由 ALTER TABLE 迁移补上，
     -- "新装 = 升级"的结构必须完全一致），取值合法性由写入路径兜底。
     notify_next_day      INTEGER NOT NULL DEFAULT 0,   -- 提醒第二天的课（当天 22:00 提醒）
     notify_ahead         INTEGER NOT NULL DEFAULT 0,   -- 当天有课时提前提醒
     notify_ahead_minutes INTEGER NOT NULL DEFAULT 20,  -- 提前量（分钟）
     updated_at  INTEGER NOT NULL DEFAULT 0,
     FOREIGN KEY (semester_id) REFERENCES semester(id) ON DELETE SET NULL,
     FOREIGN KEY (teacher_id)  REFERENCES teacher(id)  ON DELETE SET NULL
   )`,

  // 6. 课程（教师 1:N 课程）
  `CREATE TABLE IF NOT EXISTS course (
     id            INTEGER PRIMARY KEY AUTOINCREMENT,
     course_id     TEXT    NOT NULL UNIQUE,        -- 不可变业务主键（UUID）
     semester_id   INTEGER NOT NULL,
     teacher_id    INTEGER NOT NULL,
     course_name   TEXT    NOT NULL,
     course_type   TEXT    NOT NULL DEFAULT '理论' CHECK (course_type IN ('理论', '实验', '实践')),
     course_score  REAL    CHECK (course_score IS NULL OR (course_score > 0 AND course_score <= 30)),
     course_remark TEXT    NOT NULL DEFAULT '',
     sort_order    INTEGER NOT NULL DEFAULT 0,
     created_at    INTEGER NOT NULL DEFAULT 0,
     updated_at    INTEGER NOT NULL DEFAULT 0,
     UNIQUE (teacher_id, semester_id, course_name, course_type),
     FOREIGN KEY (semester_id) REFERENCES semester(id) ON DELETE CASCADE,
     FOREIGN KEY (teacher_id)  REFERENCES teacher(id)  ON DELETE CASCADE
   )`,

  // 7. 班级档案（全局唯一，一个班级一条记录，被多个课程共享）
  `CREATE TABLE IF NOT EXISTS class_info (
     class_id   TEXT    PRIMARY KEY,               -- 不可变业务主键（UUID）
     class_name TEXT    NOT NULL UNIQUE,
     created_at INTEGER NOT NULL DEFAULT 0,
     updated_at INTEGER NOT NULL DEFAULT 0
   )`,

  // 8. 课程 × 班级（= 旧 CourseInformation：这门课教这个班，用这个颜色）
  `CREATE TABLE IF NOT EXISTS class_group (
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
   )`,

  // 9. 上课时间段（= 旧 TimePeriod）
  `CREATE TABLE IF NOT EXISTS time_period (
     id             INTEGER PRIMARY KEY AUTOINCREMENT,
     class_group_id INTEGER NOT NULL,
     weekday        INTEGER NOT NULL CHECK (weekday BETWEEN 1 AND 7),   -- 1 = 周一 … 7 = 周日
     start_time     INTEGER NOT NULL CHECK (start_time BETWEEN 1 AND 24), -- 节次，1-based
     end_time       INTEGER NOT NULL CHECK (end_time  BETWEEN 1 AND 24),
     class_room     TEXT    NOT NULL DEFAULT '',
     remark         TEXT    NOT NULL DEFAULT '',
     CHECK (start_time <= end_time),
     FOREIGN KEY (class_group_id) REFERENCES class_group(id) ON DELETE CASCADE
   )`,

  // 10. 生效周次（替代 week_nums 数组：能被 SQL 按周过滤、能被索引）
  `CREATE TABLE IF NOT EXISTS period_week (
     time_period_id INTEGER NOT NULL,
     week_no        INTEGER NOT NULL CHECK (week_no BETWEEN 1 AND 60),
     PRIMARY KEY (time_period_id, week_no),
     FOREIGN KEY (time_period_id) REFERENCES time_period(id) ON DELETE CASCADE
   )`,

  // 11. 学生名单（按 class_id 稳定关联，班级重命名不再丢名单）
  `CREATE TABLE IF NOT EXISTS student (
     id         INTEGER PRIMARY KEY AUTOINCREMENT,
     student_no TEXT    NOT NULL,
     class_id   TEXT    NOT NULL,
     name       TEXT    NOT NULL DEFAULT '',
     age        INTEGER,
     sex        TEXT,
     telephone  TEXT,                              -- TEXT：保留前导 0 与国际格式
     remark     TEXT,                              -- 修正旧字段拼写 remake
     is_builtin INTEGER NOT NULL DEFAULT 0 CHECK (is_builtin IN (0, 1)),
     sort_order INTEGER NOT NULL DEFAULT 0,
     created_at INTEGER NOT NULL DEFAULT 0,
     updated_at INTEGER NOT NULL DEFAULT 0,
     UNIQUE (class_id, student_no),
     FOREIGN KEY (class_id) REFERENCES class_info(class_id) ON DELETE CASCADE
   )`,

  // 12. 签到（点名）记录（定义见上方 DDL_ATTENDANCE —— 迁移段要与它共用同一份语句）
  DDL_ATTENDANCE,
  // 13. 待办（任务 + 子任务；定义见上方 DDL_TODO_TASK / DDL_TODO_SUBTASK）
  DDL_TODO_TASK,
  DDL_TODO_SUBTASK
];

export const DDL_VIEWS: string[] = [
  `CREATE VIEW IF NOT EXISTS v_lesson AS
   SELECT c.id       AS course_row_id,
          c.course_id,
          c.course_name,
          c.course_type,
          c.course_score,
          c.course_remark,
          c.semester_id,
          c.teacher_id,
          t.staff_no,
          t.name     AS teacher_name,
          cg.id      AS class_group_id,
          cg.class_id,
          ci.class_name,
          cg.population,
          cg.color,
          tp.id      AS time_period_id,
          tp.weekday,
          tp.start_time,
          tp.end_time,
          tp.class_room,
          tp.remark,
          pw.week_no
     FROM course      c
     JOIN teacher     t  ON t.id  = c.teacher_id
     JOIN class_group cg ON cg.course_id = c.id
     JOIN class_info  ci ON ci.class_id  = cg.class_id
     JOIN time_period tp ON tp.class_group_id = cg.id
     JOIN period_week pw ON pw.time_period_id = tp.id`,

  `CREATE VIEW IF NOT EXISTS v_template_stat AS
   SELECT st.id, st.name, st.class_sessions, st.duration_time, st.is_builtin,
          (SELECT COUNT(*) FROM semester s WHERE s.schedule_id = st.id) AS citation_count
     FROM schedule_template st`
];

export const DDL_INDEXES: string[] = [
  `CREATE INDEX IF NOT EXISTS idx_semester_sort       ON semester(sort_order, id)`,
  `CREATE INDEX IF NOT EXISTS idx_teacher_semester    ON teacher(semester_id, sort_order)`,
  `CREATE INDEX IF NOT EXISTS idx_course_teacher      ON course(teacher_id, semester_id, sort_order)`,
  `CREATE INDEX IF NOT EXISTS idx_course_semester     ON course(semester_id)`,
  `CREATE INDEX IF NOT EXISTS idx_class_group_course  ON class_group(course_id, sort_order)`,
  `CREATE INDEX IF NOT EXISTS idx_class_group_class   ON class_group(class_id)`,
  `CREATE INDEX IF NOT EXISTS idx_period_group        ON time_period(class_group_id, weekday, start_time)`,
  `CREATE INDEX IF NOT EXISTS idx_period_week_week    ON period_week(week_no)`,
  `CREATE INDEX IF NOT EXISTS idx_student_class       ON student(class_id, sort_order)`,
  `CREATE INDEX IF NOT EXISTS idx_slot_schedule       ON schedule_slot(schedule_id)`,
  // 签到：按"这一次课"取（点名页）与按学生反查（删学生时的级联兜底）各一条
  `CREATE INDEX IF NOT EXISTS idx_attendance_session   ON attendance(time_period_id, week_no)`,
  `CREATE INDEX IF NOT EXISTS idx_attendance_student   ON attendance(student_id)`,
  // 待办：按状态取列表 / 按任务取子任务
  `CREATE INDEX IF NOT EXISTS idx_todo_task_state      ON todo_task(deleted, done, due_at)`,
  `CREATE INDEX IF NOT EXISTS idx_todo_subtask_task    ON todo_subtask(task_id)`
];

/**
 * 连接建立后需要执行的 PRAGMA。
 *
 * 注意：SQLite 的外键约束是"每连接"生效的开关。RelationalStore 内部的连接池
 * 不保证每条连接都吃到这个 PRAGMA，因此 DAO 层同时实现了显式级联删除
 * （见 CourseDao.deleteCourse / SemesterDao.deleteSemester 等），
 * 数据库约束与应用逻辑双保险，绝不产生孤儿行。
 */
export const PRAGMA_SETUP: string[] = [
  `PRAGMA foreign_keys = ON`,
  `PRAGMA journal_mode = WAL`,
  `PRAGMA synchronous = FULL`
];
