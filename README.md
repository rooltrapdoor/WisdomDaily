# 每日知途（WisdomDaily）· 设计交付包

> 基于 HarmonyOS NEXT **API 20（6.0.0(20)）**、参考 `UI界面参考截图/` 的 6 张真机截图，完成的**需求分析 / 数据库设计 / 概要设计 / 详细设计 / 系统架构图 / 核心数据流图**全套设计交付，并附带一套**已完整落地的应用工程**（55 个 `.ets` / 26 598 行）。
>
> **存储方案：ArkTS 内置关系型数据库 `RelationalStore`（SQLite）。业务数据不使用 JSON 存储。**

---

## 快速开始

| 想看什么 | 打开哪个文件 |
| :--- | :--- |
| **一眼看全貌（推荐）** | [`设计文档总览.html`](设计文档总览.html) —— 单文件 HTML，已内联两张架构图，直接双击打开 |
| 系统架构图 | [`diagrams/系统架构图.svg`](diagrams/系统架构图.svg) |
| 核心数据流图 | [`diagrams/核心数据流图.svg`](diagrams/核心数据流图.svg) |
| 架构分析主文档 | [`docs/05-系统架构与数据流.md`](docs/05-系统架构与数据流.md) |
| 要做什么 | [`docs/01-需求分析.md`](docs/01-需求分析.md) |
| 数据怎么存 | [`docs/02-数据库设计.md`](docs/02-数据库设计.md) |
| 顶层怎么设计 | [`docs/03-概要设计.md`](docs/03-概要设计.md) |
| 具体怎么实现 | [`docs/04-详细设计.md`](docs/04-详细设计.md) |

---

## 交付清单

```
WisdomDaily/
├── README.md                      本文件：交付索引
├── 设计文档总览.html               单文件总览（内联两张 SVG，可直接预览）
├── build_overview.py               总览页面生成脚本（改图后重跑即可）
│
├── docs/
│   ├── 01-需求分析.md              目标 · 角色 · 功能需求（含签到 / 提醒 / 待办）· 非功能需求 · 25 条验收标准 · 追踪矩阵
│   ├── 02-数据库设计.md            存储选型 · 14 表 + 2 视图 + 14 索引 · ER · 约束矩阵 · 迁移（v1→v7）· 备份
│   ├── 03-概要设计.md              七层分层 · 6 条架构铁律 · 模块划分 · 技术选型 · 12 项 ADR
│   ├── 04-详细设计.md              数据库基础设施 · 领域模型 · DAO · Repository · 8 个算法 · 17 项缺陷对照 · 测试设计 · 文件级索引
│   ├── 05-系统架构与数据流.md      架构分析主文档：分层职责 · 核心模块 · 数据流（读 / 写 / 提醒 / 待办）· 现状分析 · 演进路线
│   └── 06-状态管理与桌面卡片方案.md 状态管理落地 · 2*2 / 2*4 桌面卡片（窄/宽两套版式）· 上课提醒（规划 + 实施回执 v5.1）· 课堂签到（§2.9）
│
├── diagrams/
│   ├── 系统架构图.svg              七层分层架构 + 六条铁律 + 依赖约束
│   └── 核心数据流图.svg            读路径（6 条直查 + 内存拼装）/ 写路径（编辑即事务）/ 初始化编排
│
├── entry/src/main/ets/             ★ 全部落地代码（55 个 .ets / 26 598 行）
│   ├── common/     Logger · Util（颜色归一化 / 字色 / UUID / 周次 / 提醒常量 / 页面底色 PAGE_BG_COLOR）· DateUtil
│   │                · XlsReader / XlsWriter（自研 BIFF8 .xls 读写）· ZipUtil（课表分享包）· LessonDoneStore（当天课程完成态）
│   ├── db/         TableSchema（表结构唯一真源，v7）· DbExecutor（连接/事务抽象 + RsReader）
│   │                · DbMigrations（v1→v7）· DbLock（遇锁退避重试）· ScheduleDb（单例连接 / 事务 / 备份）
│   ├── model/      Rows（行类型）· Semester · Teacher · Course · ScheduleTemplate
│   │                · Student · AppSetting · Attendance（签到模型 / 等级分档 / 导出符号）· Todo（任务 / 子任务 / 重复规则）
│   ├── dao/        11 个业务 DAO（单表 SQL + 行映射，首参一律 DbExecutor）
│   ├── service/    ConflictDetector（教师 / 班级双维度冲突检测）· LessonReminder（上课提醒调度：额度清点 + 熔断 + 每条带「关闭」按钮）
│   ├── repository/ ScheduleRepository（唯一课表数据门面）· TodoRepository（待办门面）· SchedulePackage（分享包 / 教务网格表识别）
│   │                · SeedData · LegacyJsonImporter · RosterImporter
│   ├── entryability/ · entrybackupability/ · entryformability/（桌面卡片提供方）
│   ├── widget/     WidgetData · WidgetFormStore · WidgetUpdater · WidgetLaunch · pages/WidgetCard（2*2 / 2*4 今日未上的课 · 课程数徽标 · 点击跳转）
│   └── pages/      Index（课表 + 待办 + 我的 三页签）· CourseEdit · TemplateEdit · CheckIn（全屏点名）
│                    · Todo（待办面板组件）· TodoEdit（待办新建 / 详情）
│
└── UI界面参考截图/                 6 张真机截图（需求来源）
```

---

## 技术基线

| 项 | 值 |
| :--- | :--- |
| 平台 | HarmonyOS NEXT（`runtimeOS: HarmonyOS`） |
| API 版本 | API 20，`6.0.0(20)`（目标与最低兼容一致） |
| 语言 / UI | ArkTS + ArkUI 声明式 |
| 状态管理 | 状态管理 V2（`@ObservedV2` / `@Trace` / `@Provider` / `@ComponentV2`） |
| 路由 | `router` 页面路由（`@kit.ArkUI` 的 `pushUrl` / `getParams` / `back`，页面在 `main_pages.json` 注册）；**不使用 `Navigation` + `NavPathStack`** |
| **存储** | **`RelationalStore`（`@kit.ArkData`）单库 `wisdomdaily.db`，`SecurityLevel.S1`，WAL + `synchronous=FULL`** |
| 数据模型 | **14 张表 + 2 个视图 + 14 个索引**（`DB_VERSION = 7`）；不可变业务主键 `course_id` / `class_id`（UUID） |
| 三方依赖 | **无**（`oh-package.json5` 的 `dependencies` 为空） |
| 包名 | `com.wxz.wisdomdaily`（`versionName: 2.0.0`） |
| 权限 | 仅 `ohos.permission.WRITE_MEDIA`，**无网络权限** |

---

## 架构一句话

> **这是一个「五层嵌套数据模型 + 七层单向分层 + 编辑即事务提交 + 内置关系库存储 + 约束由数据库兜底」的单进程离线课表应用。它的架构复杂度不在分布式，而在「编辑体验的顺滑」与「进程随时可能被杀」之间的平衡 —— 只是这个平衡点从"生命周期兜底落盘"前移到了"数据库事务"。**

```
① 宿主层      EntryAbility（生命周期 · 数据库初始化）· EntryBackupAbility
② 表现层      ArkUI 页面 / 组件 / 半模态 / 弹窗
③ 状态层      V2 响应式（字段级精准刷新）
④ 编排层      ScheduleRepository：事务边界 · 对象图组装 · 用例编排
⑤ 数据访问层  11 个业务 DAO：单表 SQL + 行映射，只返回 *Row
⑥ 基础设施层  ScheduleDb · TableSchema · DbExecutor · DbMigrations
⑦ 领域模型层  SemesterCourses → Teacher / Course → ClassGroup → TimePeriod
              （被 ②③④ 依赖，自身不依赖任何存储或 UI）
⑧ 存储/系统   RelationalStore（SQLite）· Preferences · AbilityKit …
```

**六条架构铁律**

| 编号 | 铁律 |
| :--- | :--- |
| R1 | 只有 `ScheduleDb` 能持有 `RdbStore`，其他层只能拿 `DbExecutor` |
| R2 | 页面层不出现 `@kit.ArkData`、表名常量、SQL 关键字 |
| R3 | DAO 只返回 `*Row`，不返回领域对象 |
| R4 | 领域模型不 import 任何存储 API |
| R5 | 事务边界只能由 Repository 决定，DAO 不自行开事务 |
| R6 | 领域模型不持有文件路径或存储句柄 |

---

## 核心结论速览

### 数据流本质

> **冷启动时 10 条 SQL 把数据读进内存（4 条工作区 + 6 条对象图）；此后每一次编辑都以"用户点保存"为界，当场在事务中提交。不存在"内存脏了但还没落盘"这个状态 —— 所以生命周期里不需要兜底保存。**

### 做对的四件事

1. **`DbExecutor` 抽象**（30 行接口）—— 把 `RdbStore` 与 `Transaction` 的同形方法收口，DAO 写一次即同时服务"连接"与"事务"两种场景。
2. **`RsReader` 类型安全读取器** —— `ResultSet` 的 NULL / 列缺失 / 类型陷阱集中在 10 个方法里。`optReal` 让"未填学分"保持为 `NULL`，而不是 v1.0 的"变成 2 学分"。
3. **级联删除双保险** —— SQLite 外键按连接生效、连接池下不可靠，故应用层显式级联 + `PRAGMA foreign_keys = ON`。其中 `class_group → class_info` 刻意用 `RESTRICT`：宁可报错也不静默删数据。
4. **不可变业务主键** —— `course_id` / `class_id` 为 UUID，"重命名"变成一条 `UPDATE`，从根上消灭了 v1.0"改名丢名单/改名后读不到数据"这一类结构性缺陷。

### 相比 v1.0（JSON 文档）的变化

| v1.0 问题 | v2.0 状态 |
| :--- | :--- |
| 写入非原子（`TRUNC` 后直写），中断即损坏 | ✅ 消失 —— SQLite 事务 + `synchronous=FULL` |
| 时间冲突静默丢弃、只判"完整包含"、不看周次 | ✅ 重写 —— 教师/班级双维度 + 标准区间相交 + 周次 `IN` 下推 + 冲突详情返回给用户 |
| 派生状态不随源状态刷新（切学期看到别的学期） | 🟡 转化为页面层约定：`reloadDerivedState()` |
| 领域层与 DAO 循环依赖 | ✅ 消失 —— `DbExecutor` 注入；依赖图为严格单向 DAG |
| 学期重命名需六步编排，漏一步就读不到数据 | ✅ 消失 —— 没有"文件名"这个第二真源 |
| 班级按名称关联，改名丢名单 | ✅ 消失 —— `class_id` 不可变主键 |
| `course_score` 未填被补成 2 | ✅ 修正 —— 列可空 + `RsReader.optReal` |
| 颜色 8 位 / 6 位混用导致字色判错 | ✅ 修正 —— 归一化两道 + 数据库 `CHECK` 第三道 |
| 未生效的三方依赖（`class-transformer` 等） | ✅ 移除 —— `dependencies` 为空 |

v1.0 识别的 16 项缺陷中，**12 项因架构变更从根上消失或已修正**，3 项（派生状态刷新、布局常量、监听注销）是纯页面层问题、与存储方案无关。逐条对照见 [详细设计 §10](docs/04-详细设计.md)。

### 落地状态与下一步

| 部分 | 状态 |
| :--- | :--- |
| 设计文档（6 份 + 2 图 + 总览页） | ✅ 完成 |
| 工程与数据层 | ✅ 完成（55 个 `.ets` / 26 598 行，schema v7） |
| 页面层 UI（课表视图 / 课程编辑 / 时间表编辑 / 管理面板 / 名册导入导出） | ✅ 已落地 |
| 桌面卡片（2\*2 / 2\*4，只显示当天还没上完的两节课，22 点后显示次日；窄卡每节竖排两行「课程名 / 左钟点上下排 + 右教室与人数上下排」、宽卡每节横排两行并带课程类型与人数；顶部右上角带应用图标、**钟点/教室/人数不出现省略号**（超长文字改为缩字号；**仅窄卡课程名固定字号、超长末尾截断**）、窄卡第二行**钟点贴左 / 教室与人数贴右**；**固定两格**：当天只剩一节课时第二格留白；点课程跳转详情，**没课时点卡片进应用看课表**；顶栏带今天「剩 N 节」/ 明天「共 N 节」徽标） | ✅ 已落地（`docs/06` 规划 + 实施回执） |
| 上课提醒（「我的 → 上课提醒」：次日 22:00 提醒 + 课前 N 分钟提醒，连排课不打扰；系统代理提醒，应用不运行也能弹） | ✅ 已落地（`docs/06` §2.8） |
| 课堂签到与考勤（课程块「签到」→ 全屏点名页：左滑旷课 `×`、右滑请假 `⊕`、**长按并拖到圆环上**选等级 1~5（**圆环正上方 1/3 是取消**）；长按期间其余学生压阴影、**只有被选中那一行可操作**；**列表最底下的「单人视图」按钮**进去（上半屏当前学生 / 下半屏切换视图 + 1/2/3、4/5/⊕/× / 底部两端前后两位学生）；等级换算的随机分当场落库；名册导出支持「原表 / 算分后」两种口径，一次点名占一列、最多 5 列） | ✅ 已落地（`docs/04` §12.3.2 (27)、(29) 、`docs/04` §12.3.2 (30) · `docs/06` §2.9） |
| 待办（第二页签：问候 + 今日进度环 + 逾期/今日/即将/无截止/已完成 分组；右下角 + 进全屏新建，点任务行进详情；重复任务完成后自动生成下一条；回收站 30 天；「学习」清单展示当天课程并可左滑标完成） | ✅ 已落地（`docs/04` §12.3.2 (36)~(38) · schema v7） |
| 课表分享包（导出 zip：manifest + 课程清单表 + 作息节次表；导入**新建学期、不改已有数据**，支持教务「教师个人课表」网格表识别） | ✅ 已落地（`docs/04` §12.3.2 (39)、(40)） |

页面层只需认识两个仓库入口：课表侧 `ScheduleRepository`、待办侧 `TodoRepository`；功能演进与缺陷修复记录见 [详细设计 §12](docs/04-详细设计.md)。

---

## 关于参考实现

设计中的字段名、方法名、算法与业务语义均与参考工程 `F:\Codes\harmony\kechengbiao` 对齐，便于对照理解"改了什么、为什么改"：

- 标注 ✅ 的为已实现且经静态校验通过的部分（工程位于 `entry/src/main/ets/`）；
- 标注 🔁 的为相对 v1.0（JSON 方案）发生实质变化的点。

---

## 重新生成总览页面

修改 `diagrams/` 下的 SVG 或 `docs/` 下的文档后，重跑脚本即可刷新 `设计文档总览.html`：

```bash
python build_overview.py
```

## 开源许可

本项目采用 [MIT License](LICENSE) 开源协议。

Copyright (c) 2026 rooltrapdoor
