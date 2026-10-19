/**
 * 数据库行对象（Row）。
 *
 * 这一层是"关系表"与"领域对象"之间的隔离带：
 *  - DAO 只负责 `ResultSet → Row`，不构造领域对象，也不带业务判断；
 *  - Repository 只负责 `Row[] → 领域对象图`，决定聚合与缓存；
 *  - 于是列名变动只影响 DAO，聚合结构变动只影响 Repository，两边互不牵连。
 *
 * 可选字段一律 `| undefined`：undefined 表示"库里是 NULL"，与空串语义不同。
 */

export interface SemesterRow {
  id: number;
  name: string;
  total_weeks: number;
  start_date: string;
  schedule_id?: number;
  schedule_name?: string;
  sort_order: number;
  created_at: number;
  updated_at: number;
}

export interface ScheduleTemplateRow {
  id: number;
  name: string;
  class_sessions: number;
  duration_time: number;
  is_builtin: boolean;
  citation_count: number;
}

export interface ScheduleSlotRow {
  schedule_id: number;
  session_no: number;
  start_time: string;
  end_time: string;
}

export interface TeacherRow {
  id: number;
  semester_id: number;
  staff_no: number;
  name: string;
  department?: string;
  age?: number;
  sex?: string;
  telephone?: string;
  sort_order: number;
}

export interface CourseRow {
  id: number;
  course_id: string;
  semester_id: number;
  teacher_id: number;
  course_name: string;
  course_type: string;
  course_score: number | null;
  course_remark: string;
  sort_order: number;
}

export interface ClassGroupRow {
  id: number;
  course_id: number;
  class_id: string;
  class_name: string;
  population: number;
  color: string;
  sort_order: number;
}

export interface ClassInfoRow {
  class_id: string;
  class_name: string;
}

/**
 * 启动自愈用：`class_group` 里 `class_id` 指向不存在班级档案的"悬空"分组行
 * （含 `class_id` 为空串的）。`course_created_at` 用来和候选班级档案配对 ——
 * 悬空行与它丢失的档案是同一次保存写进去的，时间戳只差几毫秒。
 */
export interface DanglingGroupRow {
  id: number;
  course_id: number;
  class_id: string;
  course_created_at: number;
}

/** 启动自愈用：没有被任何班级分组引用的"孤儿"班级档案 */
export interface OrphanClassRow {
  class_id: string;
  class_name: string;
  created_at: number;
}

export interface TimePeriodRow {
  id: number;
  class_group_id: number;
  weekday: number;
  start_time: number;
  end_time: number;
  class_room: string;
  remark: string;
}

export interface PeriodWeekRow {
  time_period_id: number;
  week_no: number;
}

export interface StudentRow {
  id: number;
  student_no: string;
  class_id: string;
  class_name: string;
  name: string;
  age?: number;
  sex?: string;
  telephone?: string;
  remark?: string;
  is_builtin: boolean;
  sort_order: number;
}

export interface AppSettingRow {
  id: number;
  semester_id?: number;
  teacher_id?: number;
  theme_mode: number;
  /** 界面主题色（ARGB `#AARRGGBB`）；undefined = 尚未配置，上层用默认值兜底 */
  theme_color?: string;
  /** "今天"高亮色（ARGB `#AARRGGBB`）；undefined = 尚未配置 */
  today_color?: string;
  /** 机主姓名（首启录入的默认教师名）；undefined = 尚未配置 */
  owner_name?: string;
  /** 机主教师工号；undefined = 尚未配置 */
  owner_staff_no?: number;
  /** 提醒第二天的课（1 = 开）；undefined = 尚未配置，按关闭处理 */
  notify_next_day?: number;
  /** 当天有课时提前提醒（1 = 开）；undefined = 尚未配置，按关闭处理 */
  notify_ahead?: number;
  /** 提前量（分钟）；undefined = 用默认 20 */
  notify_ahead_minutes?: number;
  updated_at: number;
}

/** `v_lesson` 视图的一行 = 一次具体的上课（课程 × 班级 × 时间段 × 某个周次） */
export interface LessonRow {
  course_row_id: number;
  course_id: string;
  course_name: string;
  course_type: string;
  course_score: number | null;
  course_remark: string;
  semester_id: number;
  teacher_id: number;
  staff_no: number;
  teacher_name: string;
  class_group_id: number;
  class_id: string;
  class_name: string;
  population: number;
  color: string;
  time_period_id: number;
  weekday: number;
  start_time: number;
  end_time: number;
  class_room: string;
  remark: string;
  week_no: number;
}

/** 统计类聚合行：如"每个班的登记人数 vs 名单人数" */
export interface ClassPopulationRow {
  class_id: string;
  class_name: string;
  population: number;
  roster_count: number;
}

/**
 * `attendance` 表的一行 = **某个学生在某一次课上的签到结果**。
 *
 * "哪一次课"由 `time_period_id + week_no` 定位：同一门课第 3 周周三与第 4 周周三
 * 是两个独立的课次，各自的点名互不影响。
 */
export interface AttendanceRow {
  id: number;
  time_period_id: number;
  week_no: number;
  student_id: number;
  /** `present` 出勤（导出 √）/ `absent` 旷课（×）/ `leave` 请假（⊕） */
  status: string;
  /** 等级 1~5；`0` = 未评（不落库的"未点名"在库里根本没有这一行） */
  grade: number;
  /** 等级换算出的分数；`0` = 未算 */
  score: number;
}

/**
 * 导出用的签到行：比 `AttendanceRow` 多带"这次课排在第几"的排序键。
 *
 * 导出表的「考勤 1~5 / 课堂状态 1~5」是**按课次时间顺序**排的（第 1 次点名 → 第 1 列），
 * 所以必须 JOIN `time_period` 拿到 `weekday` 与 `start_time` 才能定列号 ——
 * 只按 `week_no` 排会在同一周有多节课时把顺序定成随机的。
 */
export interface AttendanceExportRow {
  time_period_id: number;
  week_no: number;
  weekday: number;
  start_time: number;
  student_id: number;
  status: string;
  grade: number;
  score: number;
}
