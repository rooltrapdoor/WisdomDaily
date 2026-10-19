#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成《设计文档总览.html》：把两张 SVG 内联进单页 HTML，便于直接预览。"""
import re
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent


def load_svg(path: pathlib.Path) -> str:
    text = path.read_text(encoding="utf-8")
    text = re.sub(r"<\?xml[^>]*\?>", "", text).strip()
    # 让 SVG 自适应容器宽度
    text = re.sub(
        r'(<svg[^>]*?)\swidth="[^"]*"\s+height="[^"]*"',
        r"\1",
        text,
        count=1,
    )
    text = text.replace(
        "<svg xmlns",
        '<svg style="width:100%;height:auto;display:block" xmlns',
        1,
    )
    return text


arch_svg = load_svg(ROOT / "diagrams" / "系统架构图.svg")
flow_svg = load_svg(ROOT / "diagrams" / "核心数据流图.svg")

HTML = """<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>每日知途（WisdomDaily）· 设计文档总览</title>
<style>
  :root {
    --bg: #F5F6F8;
    --card: #FFFFFF;
    --line: #E3E6EA;
    --ink: #1F2329;
    --ink-2: #5A6270;
    --ink-3: #8A929E;
    --blue: #1B5FA8;
    --orange: #A05A00;
    --green: #1E7A4C;
    --purple: #5B39A8;
    --red: #C0392B;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; background: var(--bg); color: var(--ink);
    font-family: "HarmonyOS Sans SC", "PingFang SC", "Microsoft YaHei", -apple-system, sans-serif;
    font-size: 14px; line-height: 1.7;
  }
  .wrap { max-width: 1240px; margin: 0 auto; padding: 32px 24px 72px; }

  header.hero {
    background: linear-gradient(135deg, #F0F6FF 0%, #FFFFFF 55%, #FFF7EC 100%);
    border: 1px solid var(--line); border-radius: 14px;
    padding: 28px 30px; margin-bottom: 22px;
  }
  header.hero h1 { margin: 0 0 8px; font-size: 25px; letter-spacing: .3px; }
  header.hero p.sub { margin: 0; color: var(--ink-2); font-size: 13.5px; }
  .meta { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 16px; }
  .chip {
    background: #FFFFFF; border: 1px solid var(--line); border-radius: 999px;
    padding: 4px 12px; font-size: 12px; color: var(--ink-2);
  }
  .chip b { color: var(--ink); font-weight: 600; }

  nav.tabs {
    display: flex; flex-wrap: wrap; gap: 8px;
    background: var(--card); border: 1px solid var(--line); border-radius: 12px;
    padding: 10px; margin-bottom: 22px; position: sticky; top: 12px; z-index: 10;
  }
  nav.tabs a {
    text-decoration: none; color: var(--ink-2); font-size: 13px;
    padding: 7px 14px; border-radius: 8px; transition: .15s;
  }
  nav.tabs a:hover { background: #EEF4FC; color: var(--blue); }

  section.card {
    background: var(--card); border: 1px solid var(--line); border-radius: 14px;
    padding: 26px 30px; margin-bottom: 22px;
  }
  section.card > h2 {
    margin: 0 0 4px; font-size: 19px;
    display: flex; align-items: center; gap: 10px;
  }
  section.card > h2 .num {
    display: inline-flex; align-items: center; justify-content: center;
    width: 26px; height: 26px; border-radius: 8px;
    background: var(--blue); color: #fff; font-size: 13px; font-weight: 700;
  }
  section.card > p.lead { color: var(--ink-2); margin: 6px 0 18px; font-size: 13.5px; }
  .filetag {
    display: inline-block; font-family: ui-monospace, Consolas, monospace;
    font-size: 12px; color: var(--purple); background: #F5F1FF;
    border: 1px solid #E4DBFA; border-radius: 6px; padding: 2px 8px;
  }

  h3 { font-size: 15px; margin: 24px 0 10px; }
  h3:first-child { margin-top: 0; }

  table { width: 100%; border-collapse: collapse; font-size: 13px; margin: 10px 0 4px; }
  th, td { border: 1px solid var(--line); padding: 8px 11px; text-align: left; vertical-align: top; }
  th { background: #F7F9FB; font-weight: 600; color: var(--ink); white-space: nowrap; }
  td code { font-family: ui-monospace, Consolas, monospace; font-size: 12px; color: var(--purple); }

  ul { margin: 8px 0 4px; padding-left: 22px; }
  li { margin: 4px 0; }

  .grid2 { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 14px; }
  .mini {
    border: 1px solid var(--line); border-radius: 10px; padding: 14px 16px; background: #FCFDFE;
  }
  .mini h4 { margin: 0 0 8px; font-size: 13.5px; }
  .mini ul { margin: 0; padding-left: 18px; font-size: 12.5px; color: var(--ink-2); }

  .callout {
    border-left: 4px solid var(--blue); background: #F4F9FF;
    border-radius: 0 10px 10px 0; padding: 12px 16px; margin: 14px 0; font-size: 13px;
  }
  .callout.warn { border-left-color: var(--red); background: #FDF4F3; }
  .callout.ok { border-left-color: var(--green); background: #F3FAF6; }
  .callout b { color: inherit; }

  .sev { font-weight: 700; font-size: 12px; padding: 1px 7px; border-radius: 5px; white-space: nowrap; }
  .sev.p0 { background: #FDECEA; color: #B3261E; }
  .sev.p1 { background: #FFF4E5; color: #A05A00; }
  .sev.p2 { background: #EEF4FC; color: #1B5FA8; }
  .sev.fixed { background: #E7F7EF; color: #1E7A4C; }

  .diagram {
    border: 1px solid var(--line); border-radius: 12px;
    background: #FFFFFF; padding: 12px; overflow-x: auto;
  }
  footer { color: var(--ink-3); font-size: 12.5px; text-align: center; padding: 12px 0 0; }
</style>
</head>
<body>
<div class="wrap">

  <header class="hero">
    <h1>每日知途（WisdomDaily）· 设计文档总览</h1>
    <p class="sub">HarmonyOS NEXT · API 20（6.0.0(20)）· ArkTS + ArkUI 声明式 · 单进程离线应用</p>
    <div class="meta">
      <span class="chip">包名 <b>com.wxz.wisdomdaily</b></span>
      <span class="chip">架构风格 <b>七层分层单体</b></span>
      <span class="chip">存储 <b>RelationalStore（SQLite）</b></span>
      <span class="chip">数据模型 <b>14 表 + 2 视图 + 14 索引</b>（v7）</span>
      <span class="chip">文档版本 <b>v2.0</b></span>
      <span class="chip">已落地代码 <b>54 文件 / 26 598 行</b></span>
    </div>
  </header>

  <nav class="tabs">
    <a href="#overview">总览</a>
    <a href="#arch">系统架构图</a>
    <a href="#flow">核心数据流图</a>
    <a href="#req">需求分析</a>
    <a href="#db">数据库设计</a>
    <a href="#hld">概要设计</a>
    <a href="#lld">详细设计</a>
    <a href="#module">核心模块</a>
    <a href="#status">落地状态</a>
  </nav>

  <!-- 总览 -->
  <section class="card" id="overview">
    <h2><span class="num">0</span>文档总览</h2>
    <p class="lead">本套文档基于 <b>UI界面参考截图</b> 的 6 张真机截图编写，存储方案为 <b>ArkTS 内置关系型数据库 RelationalStore</b>（不使用 JSON 存业务数据），并附带一套已通过静态校验的数据层工程骨架。</p>
    <table>
      <thead><tr><th>文档</th><th>文件</th><th>核心内容</th></tr></thead>
      <tbody>
        <tr><td>需求分析</td><td><span class="filetag">docs/01-需求分析.md</span></td><td>项目目标与存储约束（ST-1~5）、3 类角色、12 模块功能需求、12 项非功能需求、25 条验收标准、需求追踪矩阵</td></tr>
        <tr><td>数据库设计</td><td><span class="filetag">docs/02-数据库设计.md</span></td><td>存储选型决策、物理设计、ER 模型、14 张表逐字段定义、2 个视图、14 个索引、事务边界、级联删除双保险、版本迁移、备份恢复</td></tr>
        <tr><td>概要设计</td><td><span class="filetag">docs/03-概要设计.md</span></td><td>七层分层、10 条设计原则、6 条架构铁律、模块划分、技术选型、接口契约（DbExecutor / RsReader / Repository）、12 项 ADR</td></tr>
        <tr><td>详细设计</td><td><span class="filetag">docs/04-详细设计.md</span></td><td>数据库基础设施、领域模型类图、11 个 DAO、Repository 读写路径、8 个算法、17 项缺陷对照、测试设计、文件级索引</td></tr>
        <tr><td>架构与数据流</td><td><span class="filetag">docs/05-系统架构与数据流.md</span></td><td>架构分析主文档：分层职责与铁律、核心模块协作、读/写数据流、相较基线的改进、四阶段演进路线</td></tr>
        <tr><td>状态管理与桌面卡片</td><td><span class="filetag">docs/06-状态管理与桌面卡片方案.md</span></td><td>状态管理 V2 落地约定 · 2*2 / 2*4 桌面卡片（数据通道 / 刷新策略 / 窄宽两套版式 / 加卡姿势与排障）· 上课提醒，v5.1 规划 + 实施回执</td></tr>
        <tr><td>系统架构图</td><td><span class="filetag">diagrams/系统架构图.svg</span></td><td>七层分层 + 9 项横切关注点 + 六条架构铁律 + 依赖方向标注</td></tr>
        <tr><td>核心数据流图</td><td><span class="filetag">diagrams/核心数据流图.svg</span></td><td>读路径（10 条 SQL + 内存拼装）/ 写路径（编辑即事务）/ 初始化编排与四道一致性兜底</td></tr>
      </tbody>
    </table>

    <div class="callout">
      <b>一句话概括</b>：这是一个「五层嵌套数据模型 + 七层单向分层 + 编辑即事务提交 + 内置关系库存储 + 约束由数据库兜底」的单进程离线课表应用。它的架构复杂度不在分布式，而在<b>「编辑体验的顺滑」与「进程随时可能被杀」之间的平衡</b> —— 只是这个平衡点从"生命周期兜底落盘"前移到了"数据库事务"。
    </div>
  </section>

  <!-- 系统架构图 -->
  <section class="card" id="arch">
    <h2><span class="num">1</span>系统架构图</h2>
    <p class="lead">自上而下七层单向依赖；右侧为被多层共用的横切关注点。领域模型层被 ②④⑤ 依赖，属合法复用而非反向依赖。</p>
    <div class="diagram">
__ARCH_SVG__
    </div>

    <h3>分层职责</h3>
    <table>
      <thead><tr><th>层</th><th>组成</th><th>核心职责</th><th>不该做的事</th></tr></thead>
      <tbody>
        <tr><td><b>① 宿主层</b></td><td><code>EntryAbility</code> / <code>EntryBackupAbility</code></td><td>生命周期、发起数据库初始化、销毁时关闭连接</td><td>不承载业务逻辑；不做兜底落盘（已无此必要）</td></tr>
        <tr><td><b>② 表现层</b></td><td><code>pages/*.ets</code>、半模态设置面板、拾色弹窗</td><td>渲染界面、收集输入、触发路由</td><td>不出现 <code>@kit.ArkData</code> / 表名 / SQL 关键字</td></tr>
        <tr><td><b>③ 状态层</b></td><td><code>@ObservedV2</code> / <code>@Trace</code> / <code>@Provider</code> / <code>@Local</code></td><td>状态持有与精准刷新；源状态变更后统一重算派生状态</td><td>不做持久化；不做业务计算</td></tr>
        <tr><td><b>④ 编排层</b></td><td><code>ScheduleRepository</code>、<code>seed</code>、<code>LegacyJsonImporter</code>、<code>ConflictDetector</code></td><td><b>决定事务边界</b>、组装对象图、用例编排、初始化编排</td><td>不写 SQL；不感知 UI</td></tr>
        <tr><td><b>⑤ 数据访问层</b></td><td><code>dao/</code> 11 个 DAO</td><td>单表 SQL 与行映射，只返回 <code>*Row</code></td><td>不判业务规则；不自行开事务；不返回领域对象</td></tr>
        <tr><td><b>⑥ 数据库基础设施</b></td><td><code>ScheduleDb</code> · <code>TableSchema</code> · <code>DbExecutor</code> · <code>DbMigrations</code></td><td>连接与 schema 生命周期、事务、执行器抽象、版本迁移、备份恢复</td><td>不含任何业务语义</td></tr>
        <tr><td><b>⑦ 领域模型层</b></td><td><code>model/</code> 领域类 + 13 个 <code>*Row</code></td><td>业务实体、规则、计算（含完整冲突判定）</td><td>不 import 存储 API；不持有文件路径或句柄</td></tr>
        <tr><td><b>⑧ 存储与系统能力</b></td><td><code>RelationalStore</code> · 沙箱 <code>databaseDir</code> · 系统 Kit</td><td>数据持久化与平台原子能力</td><td>—</td></tr>
      </tbody>
    </table>

    <h3>六条架构铁律（代码评审必查）</h3>
    <div class="grid2">
      <div class="mini"><h4>R1 连接唯一</h4><ul><li>只有 <code>ScheduleDb</code> 能持有 <code>RdbStore</code></li><li>其他层只能拿 <code>DbExecutor</code></li></ul></div>
      <div class="mini"><h4>R2 页面不碰 SQL</h4><ul><li><code>pages/</code> 下 <code>SELECT/INSERT/UPDATE/DELETE</code> 命中数应为 0</li><li>只依赖 <code>ScheduleRepository</code></li></ul></div>
      <div class="mini"><h4>R3 DAO 只返回 Row</h4><ul><li>DAO 输出 <code>model/Rows.ets</code> 的行类型</li><li>不构造领域对象</li></ul></div>
      <div class="mini"><h4>R4 模型不碰存储</h4><ul><li><code>model/</code> 下 <code>relationalStore</code> 命中数应为 0</li><li>保证可独立单测</li></ul></div>
      <div class="mini"><h4>R5 事务只由 Repository 决定</h4><ul><li><code>dao/</code> 下 <code>beginTransaction</code> 命中数应为 0</li><li>DAO 首参一律 <code>DbExecutor</code></li></ul></div>
      <div class="mini"><h4>R6 模型不持有路径</h4><ul><li>没有 <code>getClassPath()</code> 这类方法</li><li>关联一律走主键</li></ul></div>
    </div>

    <div class="callout ok">
      <b>为什么这些铁律能成立</b>：v1.0（JSON 方案）中领域层与 DAO 互相 import，<b>构成循环依赖</b>，铁律 R3/R4/R6 无法成立。改用 <code>DbExecutor</code> 注入 + DAO/Row 分离后，依赖图变成严格的单向 DAG。
    </div>
  </section>

  <!-- 核心数据流图 -->
  <section class="card" id="flow">
    <h2><span class="num">2</span>核心数据流图</h2>
    <p class="lead">蓝色为读路径，橙色为写路径，绿色虚线为事务边界，紫色为初始化编排与一致性兜底。</p>
    <div class="diagram">
__FLOW_SVG__
    </div>

    <h3>三条链路的本质区别</h3>
    <table>
      <thead><tr><th>链路</th><th>触发时机</th><th>涉及层</th><th>关键设计</th></tr></thead>
      <tbody>
        <tr><td><b>读路径</b></td><td>冷启动（仅一次）</td><td>⑧→⑥→⑤→④→③→②</td><td>10 条索引查询（工作区 4 条 + 对象图 6 条）+ 内存逐层拼装；此后切周只走 <code>v_lesson</code> 视图</td></tr>
        <tr><td><b>写路径</b></td><td>用户点保存</td><td>②→④→⑤→⑥→⑧</td><td>归一化 → 冲突预检（事务外）→ <code>runInTransaction</code> 多表写入 → commit → 更新内存</td></tr>
        <tr><td><b>初始化编排</b></td><td>每次启动（幂等）</td><td>①→⑥→④</td><td>建库 → 建表/迁移/自愈 → 探测旧 JSON → 事务导入 → 播种 → 指针自愈 → 归档</td></tr>
      </tbody>
    </table>

    <div class="callout">
      <b>数据流本质</b>：数据只在冷启动时从数据库流入内存（10 条 SQL）；此后每一次编辑都以"用户点保存"为界，<b>当场在事务中提交</b>。不存在"内存脏了但还没落盘"这个状态 —— 所以生命周期回调里不需要任何兜底保存。
    </div>

    <div class="callout ok">
      <b>与 v1.0 的关键差异</b>：v1.0 靠"内存优先 + 四个生命周期时机兜底落盘"保证不丢数据，把安全性押在"四个回调恰好都执行"上。v2.0 让每次保存当场提交事务 —— 进程被杀只可能丢"用户还没点保存的那一步输入"，而这一步本来就该丢。
    </div>
  </section>

  <!-- 需求分析 -->
  <section class="card" id="req">
    <h2><span class="num">3</span>需求分析要点</h2>
    <p class="lead"><span class="filetag">docs/01-需求分析.md</span></p>

    <div class="callout warn">
      <b>硬性存储约束</b>：业务数据一律存入 ArkTS 内置关系型数据库（<code>RelationalStore</code>）；数据模型必须关系化（拆表、外键、用主键而非名称关联）；跨表写入必须事务化；JSON 仅用于导入导出与旧数据一次性兼容，<b>不得作为运行期存储</b>；表结构变更必须有版本迁移机制。
    </div>

    <h3>功能模块（8 个模块）</h3>
    <table>
      <thead><tr><th>模块</th><th>编号前缀</th><th>项数</th><th>代表需求</th></tr></thead>
      <tbody>
        <tr><td>课表视图</td><td><code>FR-VIEW</code></td><td>11</td><td>周次导航、时间轴、跨节课程块、滑动切周、点击编辑</td></tr>
        <tr><td>课程与班级管理</td><td><code>FR-COURSE</code></td><td>13</td><td>课程信息、多班级、多时间段、HSV 拾色、<b>双维度冲突检测</b>、复制派生</td></tr>
        <tr><td>课表时间管理</td><td><code>FR-TIME</code></td><td>7</td><td>节次数与每节时间、模板新建与复用、引用次数实时统计</td></tr>
        <tr><td>学期管理</td><td><code>FR-TERM</code></td><td>7</td><td>学期列表与切换、总周数、起始日期归一化到周一、至少保留 1 个</td></tr>
        <tr><td>教师管理</td><td><code>FR-TEACHER</code></td><td>5</td><td>工号+姓名、按教师切换课表并持久化、重复添加按字段合并</td></tr>
        <tr><td>学生管理</td><td><code>FR-STUDENT</code></td><td>5</td><td>按不可变 <code>class_id</code> 维护名单、人数对账、无引用才可删班级</td></tr>
        <tr><td>数据导入导出</td><td><code>FR-IO</code></td><td>4</td><td>导出到系统文档目录、事务化导入、数据库级备份恢复</td></tr>
        <tr><td>全局设置与关于</td><td><code>FR-SETTING</code></td><td>5</td><td>半模态设置面板、九宫格入口、当前学期/教师持久化</td></tr>
      </tbody>
    </table>

    <h3>核心非功能需求</h3>
    <div class="grid2">
      <div class="mini"><h4>性能 NFR-01</h4><ul><li>冷启动 ≤ 1.5s</li><li>数据读取（10 条 SQL）≤ 100ms</li><li>满课表渲染 ≤ 200ms · 切周 ≥ 55fps</li></ul></div>
      <div class="mini"><h4>容量 NFR-02</h4><ul><li>≥ 8 学期 · 每学期 ≥ 30 教师 / 40 课程</li><li>单课程 ≥ 10 班级 × 10 时间段</li><li>单班名单 ≥ 500 人</li></ul></div>
      <div class="mini"><h4>可靠性 NFR-03</h4><ul><li><b>要么完整生效、要么完全不变</b></li><li>不允许"半个学期"这类半截数据</li></ul></div>
      <div class="mini"><h4>数据完整性 NFR-11</h4><ul><li>人数非负 / 节次区间合法 / 周次 ≥ 1</li><li>颜色 6 位十六进制 / 关联键存在</li><li>规则写入数据库约束，绕过界面也会被拒</li></ul></div>
    </div>
  </section>

  <!-- 数据库设计 -->
  <section class="card" id="db">
    <h2><span class="num">4</span>数据库设计要点</h2>
    <p class="lead"><span class="filetag">docs/02-数据库设计.md</span></p>

    <div class="callout ok">
      <b>选型结论</b>：<b>RelationalStore（ArkTS 内置 SQLite）是唯一持久化方案</b>。课表数据天然强关联、强约束 —— 同一班级被多门课引用、周次与时间段是一对多、学期与教师是层级关系。用文件存储时必须自己维护这些关系（因而产生"按班级名拼文件名""改名就丢名单""冲突判定跨不了文件"等结构性问题），而关系库把关联键、唯一约束、级联删除、事务原子性交还给数据库。
    </div>

    <h3>物理设计</h3>
    <table>
      <thead><tr><th>项</th><th>值</th><th>说明</th></tr></thead>
      <tbody>
        <tr><td>库文件</td><td><code>wisdomdaily.db</code></td><td>位于应用私有沙箱 <code>databaseDir</code></td></tr>
        <tr><td>安全等级</td><td><code>SecurityLevel.S1</code></td><td>沙箱隔离 + 最优性能</td></tr>
        <tr><td>日志模式</td><td><code>journal_mode = WAL</code></td><td>读写不互斥，切周查询不被写事务阻塞</td></tr>
        <tr><td>同步级别</td><td><code>synchronous = FULL</code></td><td>提交即落盘；写入频次低，用性能换"绝不丢"</td></tr>
        <tr><td>外键</td><td><code>foreign_keys = ON</code></td><td>每连接生效，连接池下不保证 → 另有应用层级联双保险</td></tr>
        <tr><td>版本号</td><td><code>user_version = 7</code></td><td>由 <code>store.version</code> 读写，驱动迁移（v1→v7）</td></tr>
      </tbody>
    </table>

    <h3>14 张表 + 2 个视图 + 14 个索引</h3>
    <table>
      <thead><tr><th>分组</th><th>表 / 视图</th><th>关键设计</th></tr></thead>
      <tbody>
        <tr><td rowspan="3">基础配置</td><td><code>schedule_template</code></td><td>作息模板；<code>name</code> UNIQUE</td></tr>
        <tr><td><code>schedule_slot</code></td><td>节次槽（<code>session_no</code> / 起止时间），<code>ON DELETE CASCADE</code></td></tr>
        <tr><td><code>semester</code></td><td>学期；<code>start_date</code> 为 <code>TEXT 'YYYY-MM-DD'</code>；<code>schedule_id</code> 外键</td></tr>
        <tr><td rowspan="3">主体</td><td><code>teacher</code></td><td>教师；<code>(semester_id, staff_no, name)</code> UNIQUE，upsert 用 <code>COALESCE</code> 合并</td></tr>
        <tr><td><code>course</code></td><td>课程；<b>不可变 <code>course_id</code>(UUID)</b> + <code>course_score</code> 可空</td></tr>
        <tr><td><code>class_info</code></td><td>班级（跨学期共享）；<b>不可变 <code>class_id</code>(UUID)</b>，<code>name</code> UNIQUE</td></tr>
        <tr><td rowspan="3">排课</td><td><code>class_group</code></td><td>课程 × 班级；<code>(course_id, class_id)</code> UNIQUE；颜色 <code>CHECK GLOB</code>；<code>class_id</code> 外键为 <b>RESTRICT</b></td></tr>
        <tr><td><code>time_period</code></td><td>时间段；<code>CHECK (end_time &gt;= start_time)</code>、<code>weekday BETWEEN 1 AND 7</code></td></tr>
        <tr><td><code>period_week</code></td><td><b>周次子表</b>：让周次交集能下推 SQL，并让"第 N 周"可索引</td></tr>
        <tr><td rowspan="2">人员与设置</td><td><code>student</code></td><td>学生；<code>telephone</code> 为 TEXT（保留前导 0）；<code>remark</code>（修正旧版拼写 <code>remake</code>）</td></tr>
        <tr><td><code>app_setting</code></td><td>单行设置；存 <b>真实主键指针</b>（<code>semester_id</code> / <code>teacher_id</code>）而非数组下标</td></tr>
        <tr><td rowspan="2">签到与待办</td><td><code>attendance</code>（v6）</td><td>签到；<code>UNIQUE(time_period_id, week_no, student_id)</code>；<code>grade</code> / <code>score</code> 未评写 NULL，不写 0</td></tr>
        <tr><td><code>todo_task</code> · <code>todo_subtask</code>（v7）</td><td><b>无外键</b>：待办与课表完全独立；软删 + 30 天回收站；子任务由 DAO 先删后插</td></tr>
        <tr><td rowspan="2">视图</td><td><code>v_lesson</code></td><td>按周展开的课表读模型，供"取某周课表"使用</td></tr>
        <tr><td><code>v_template_stat</code></td><td>实时 <code>COUNT</code> 模板引用次数，<b>消灭会漂移的冗余计数</b></td></tr>
      </tbody>
    </table>

    <h3>相比 v1.0 的六项结构性改进</h3>
    <div class="grid2">
      <div class="mini"><h4>① 不可变业务主键</h4><ul><li><code>course_id</code> / <code>class_id</code> 为 UUID</li><li>重命名 = 一条 <code>UPDATE</code>，不再需要"改文件名 + 改引用 + 改设置"多步编排</li></ul></div>
      <div class="mini"><h4>② 周次拆表</h4><ul><li><code>period_week(period_id, week_no)</code> + 索引</li><li>冲突检测的周次交集直接下推 SQL</li></ul></div>
      <div class="mini"><h4>③ 引用计数改视图</h4><ul><li>不再手工维护 <code>citation_count</code></li><li>任何绑定/解绑路径漏改都不会漂移</li></ul></div>
      <div class="mini"><h4>④ 学分真可为 NULL</h4><ul><li>修掉旧版 <code>?? 2</code> 把"未填"变成"2 学分"</li><li><code>RsReader.optReal</code> 提供真 NULL 语义</li></ul></div>
      <div class="mini"><h4>⑤ 颜色约束双保险</h4><ul><li><code>normalizeColor()</code> 归一化 8 位/3 位到 6 位</li><li>库层 <code>CHECK (color GLOB '#RRGGBB')</code></li></ul></div>
      <div class="mini"><h4>⑥ 指针用主键而非下标</h4><ul><li>学期排序变化或删除不会让指针"错位指到别的学期"</li><li>启动时 <code>repairPointers()</code> 自愈</li></ul></div>
    </div>
  </section>

  <!-- 概要设计 -->
  <section class="card" id="hld">
    <h2><span class="num">5</span>概要设计要点</h2>
    <p class="lead"><span class="filetag">docs/03-概要设计.md</span></p>

    <h3>10 条设计原则</h3>
    <table>
      <thead><tr><th>编号</th><th>原则</th><th>落地要求</th></tr></thead>
      <tbody>
        <tr><td>P1</td><td>页面不碰 SQL</td><td>页面禁止 import <code>@kit.ArkData</code>，不得出现表名 / 列名 / SQL 片段</td></tr>
        <tr><td>P2</td><td>模型不依赖存储</td><td><code>model/</code> 不 import <code>relationalStore</code>，保证可单测</td></tr>
        <tr><td>P3</td><td>单一数据源</td><td>表结构只在 <code>TableSchema</code> 定义一次；SQL 不复制粘贴</td></tr>
        <tr><td>P4</td><td>显式映射</td><td><code>ResultSet</code> ↔ 对象必经 <code>RsReader</code> 与 <code>fromRow()/toRow()</code></td></tr>
        <tr><td>P5</td><td>失败可降级</td><td>读取失败返回安全默认值 + 记日志，不阻塞进入首页</td></tr>
        <tr><td>P6</td><td>状态驱动视图</td><td>刷新只由响应式状态变更触发</td></tr>
        <tr><td>P7</td><td>写入事务化</td><td>跨表写入必须包在一个事务里，要么全成功要么全回滚</td></tr>
        <tr><td>P8</td><td>主键稳定</td><td>业务主键为不可变 UUID，重命名不改主键</td></tr>
        <tr><td>P9</td><td>资源国际化</td><td>文案走 <code>$string</code>，禁止硬编码中文</td></tr>
        <tr><td>P10</td><td>连接唯一</td><td>只有 <code>ScheduleDb</code> 持有 <code>RdbStore</code>，其余只拿 <code>DbExecutor</code></td></tr>
      </tbody>
    </table>

    <h3>三个核心接口契约</h3>
    <div class="grid2">
      <div class="mini"><h4>DbExecutor（最重要）</h4><ul><li>把 <code>RdbStore</code> 与 <code>Transaction</code> 的同形方法收口</li><li><code>StoreExecutor</code> 自动提交 · <code>TxExecutor</code> 并入事务</li><li>DAO 写一次即服务两种场景</li></ul></div>
      <div class="mini"><h4>RsReader 类型安全读取器</h4><ul><li><code>str/num/real/optStr/optNum/optReal/bool</code></li><li>统一 NULL 与列缺失的语义</li><li><code>optReal</code> 是"学分可为空"的落点</li></ul></div>
      <div class="mini"><h4>领域对象协议</h4><ul><li><code>static fromRow(row)</code> 从数据库行还原</li><li><code>toRow()</code> 转为写入载荷</li><li><code>clone()</code> 深拷贝 · 无 <code>getValue()</code></li></ul></div>
    </div>

    <h3>11 项关键架构决策（ADR）</h3>
    <table>
      <thead><tr><th>编号</th><th>决策</th><th>理由 / 代价</th></tr></thead>
      <tbody>
        <tr><td>ADR-01</td><td>状态管理 V2</td><td>五层嵌套下追踪到具体字段，避免 V1 逐层 <code>@ObjectLink</code></td></tr>
        <tr><td>ADR-02</td><td><b>编辑即事务提交</b></td><td>取代"内存优先 + 兜底落盘"；删掉脏标记；代价：写操作异步化，高频改动需防抖</td></tr>
        <tr><td>ADR-03</td><td><code>DbExecutor</code> 抽象</td><td>DAO 不必为实现"连接/事务"两种场景写两份</td></tr>
        <tr><td>ADR-04</td><td>关系库是唯一持久化方案</td><td>JSON 仅保留"旧数据一次性导入"一个用途</td></tr>
        <tr><td>ADR-05</td><td>级联删除双保险</td><td>PRAGMA 外键 + 应用层显式级联；<code>class_group→class_info</code> 用 RESTRICT</td></tr>
        <tr><td>ADR-06</td><td>冷启动用直查，按周取数才用视图</td><td>视图按周展开会让行数膨胀数十倍，不适合组装对象图</td></tr>
        <tr><td>ADR-07</td><td><code>period_week</code> 拆表</td><td>周次语义下推到 SQL，候选集在库层收敛</td></tr>
        <tr><td>ADR-08</td><td>引用计数改视图实时统计</td><td>不漂移比省一次聚合更重要</td></tr>
        <tr><td>ADR-09</td><td>不可变业务主键取代按名关联</td><td>重命名变一次 UPDATE；代价：不能再用名称做联表捷径</td></tr>
        <tr><td>ADR-10</td><td>路由用 router，不引入 Navigation/NavPathStack</td><td>5 个全屏页且无分栏诉求；pushUrl/getParams/back + main_pages.json 注册即可，半模态不进路由栈</td></tr>
        <tr><td>ADR-11</td><td>时间轴与网格共用节次数据源</td><td>绝对定位 + 固定行高，避免弹性布局像素累积误差</td></tr>
      </tbody>
    </table>
  </section>

  <!-- 详细设计 -->
  <section class="card" id="lld">
    <h2><span class="num">6</span>详细设计要点</h2>
    <p class="lead"><span class="filetag">docs/04-详细设计.md</span></p>

    <h3>数据层的四层结构</h3>
    <table>
      <thead><tr><th>层</th><th>回答的问题</th><th>规模</th></tr></thead>
      <tbody>
        <tr><td><code>db/</code></td><td>连接从哪来、表怎么建、事务怎么开、游标怎么读</td><td>4 文件 / 约 600 行</td></tr>
        <tr><td><code>model/</code></td><td>领域对象长什么样、行列怎么映射、冲突怎么算</td><td>7 文件 / 约 1 300 行</td></tr>
        <tr><td><code>dao/</code></td><td>每张表的 SQL 与行映射</td><td>10 文件 / 约 1 600 行</td></tr>
        <tr><td><code>repository/</code></td><td>事务边界、对象图组装、初始化编排、旧数据导入</td><td>3 文件 / 约 1 250 行</td></tr>
      </tbody>
    </table>

    <h3>8 个关键算法</h3>
    <table>
      <thead><tr><th>算法</th><th>复杂度</th><th>要点</th></tr></thead>
      <tbody>
        <tr><td>周次计算 <code>getWeekNumber</code></td><td>O(1)</td><td>以"起始日所在周周一"为锚 + <code>+1</code> + 夹紧 <code>[1, totalWeeks]</code>；<b>已修正旧版第 0 周问题</b></td></tr>
        <tr><td>日期解析 <code>parseDate</code></td><td>O(1)</td><td>手工正则解析，避免 <code>new Date('YYYY-MM-DD')</code> 的 UTC 偏移</td></tr>
        <tr><td>周次文本化 <code>formatWeeks</code></td><td>O(n log n)</td><td>贪心分段：<code>[1,3,5,7]</code> → <code>1-7周(单周)</code></td></tr>
        <tr><td>周次归一化 <code>normalizeWeeks</code></td><td>O(n²)</td><td>去重 + 夹紧；<b>用数组而非 Set</b>（ArkTS 对 Set 支持有限）</td></tr>
        <tr><td>颜色归一化 <code>normalizeColor</code></td><td>O(1)</td><td><code>#RGB</code> / <code>#RRGGBB</code> / <code>#AARRGGBB</code> / 非法值 → 统一 6 位</td></tr>
        <tr><td>自动字色 <code>textColorOf</code></td><td>O(1)</td><td>BT.601 亮度 &gt; 128 取黑，否则白</td></tr>
        <tr><td>唯一命名 <code>getNewOrAddOneName</code></td><td>O(1)</td><td>正则匹配末尾 <code>(N)</code> 递增；<b>改为查库判重</b>并加循环上限</td></tr>
        <tr><td>网格坐标计算</td><td>O(1)</td><td>绝对定位：<code>left=(weekday-1)×列宽</code>，<code>top=(start_time-1)×行高</code></td></tr>
      </tbody>
    </table>

    <h3>冲突检测：双维度 + 周次下推 SQL</h3>
    <table>
      <thead><tr><th>维度</th><th>定义</th><th>v1.0</th></tr></thead>
      <tbody>
        <tr><td>教师维度</td><td>同一教师在同一周、同一天、同一节次出现在两个地方</td><td><span class="sev p0">缺失</span></td></tr>
        <tr><td>班级维度</td><td>同一班级在同一时间被两门课占用（可能来自不同教师）</td><td><span class="sev p0">缺失</span></td></tr>
        <tr><td>课程自身</td><td>同天 + 节次区间相交 + 周次有交集，三者同时成立</td><td><span class="sev p1">只判"完整包含"</span></td></tr>
      </tbody>
    </table>
    <div class="callout warn">
      <b>最严重的旧行为</b>：冲突时<b>静默丢弃</b> —— 用户以为保存成功，实际课表少了一节。v2.0 把冲突详情（课程、班级、教室、重叠周次）返回给调用方，由用户选择「替换 / 仍然保存 / 返回修改」，<b>绝不允许静默处理</b>。
    </div>

    <h3>17 项缺陷的处置结果</h3>
    <table>
      <thead><tr><th>编号</th><th>缺陷</th><th>v2.0 状态</th></tr></thead>
      <tbody>
        <tr><td>DEF-02</td><td>学期重命名只改文件不改设置</td><td><span class="sev fixed">从根上消失</span> 改名 = 一条 UPDATE</td></tr>
        <tr><td>DEF-05</td><td>落盘失败仍清零脏标记</td><td><span class="sev fixed">从根上消失</span> 没有脏标记了</td></tr>
        <tr><td>DEF-07</td><td>写入非原子（TRUNC 后直写）</td><td><span class="sev fixed">从根上消失</span> SQLite 事务 + FULL</td></tr>
        <tr><td>DEF-11</td><td>领域层与 DAO 循环依赖</td><td><span class="sev fixed">从根上消失</span> DbExecutor 注入</td></tr>
        <tr><td>DEF-03</td><td>起始日非周一时首周算出第 0 周</td><td><span class="sev fixed">已修正</span> 归一化到周一 + 公式 +1</td></tr>
        <tr><td>DEF-04</td><td>颜色 8 位 / 6 位不统一</td><td><span class="sev fixed">已修正</span> 归一化两道 + 库层 CHECK</td></tr>
        <tr><td>DEF-06</td><td>冲突检测不完整且静默丢弃</td><td><span class="sev fixed">已重写</span> 双维度 + 区间相交 + 周次下推</td></tr>
        <tr><td>DEF-08</td><td><code>course_score</code> 空值默认补 2</td><td><span class="sev fixed">已修正</span> <code>RsReader.optReal</code> 真 NULL</td></tr>
        <tr><td>DEF-15</td><td>空文件被判定为存在而跳过初始化</td><td><span class="sev fixed">从根上消失</span> 判据是"库里有学期"</td></tr>
        <tr><td>DEF-01</td><td>派生状态不随源状态刷新</td><td><span class="sev p1">转化为页面层约定</span> <code>reloadDerivedState()</code></td></tr>
        <tr><td>DEF-10</td><td>布局常量散落</td><td><span class="sev p2">待 UI 实现</span> 抽 <code>LayoutConstants</code></td></tr>
        <tr><td>DEF-16</td><td>生命周期监听未注销</td><td><span class="sev p2">待 UI 实现</span> <code>aboutToDisappear</code> 中 <code>off</code></td></tr>
      </tbody>
    </table>
    <p style="color:var(--ink-2);font-size:13px;margin-top:8px">逐条对照见 <span class="filetag">docs/04-详细设计.md §10</span>。16 项中 <b>12 项因架构变更从根上消失或已修正</b>，3 项为纯页面层问题且与存储方案无关。本轮另发现并修正 DEF-17（<code>ConflictDetector</code> 的 <code>GROUP BY</code> 与多周合并逻辑矛盾）。</p>
  </section>

  <!-- 核心模块 -->
  <section class="card" id="module">
    <h2><span class="num">7</span>核心模块与协作</h2>
    <p class="lead">全工程 44 个 <code>.ets</code> 文件围绕 <code>ScheduleRepository</code> 一个门面协作；页面层只需认识它一个类。</p>

    <h3>模块职责</h3>
    <table>
      <thead><tr><th>模块</th><th>关键入口</th><th>职责</th></tr></thead>
      <tbody>
        <tr><td>M1 应用入口</td><td><code>EntryAbility</code></td><td>创建窗口、发起 <code>ScheduleRepository.init()</code>、销毁时关闭数据库</td></tr>
        <tr><td>M2 课表视图</td><td><code>Index</code></td><td>周次导航、滑动切周、设置面板、<code>reloadDerivedState()</code></td></tr>
        <tr><td>M3 网格渲染</td><td>课程网格组件</td><td>按「教师 + 周次 + 作息模板」渲染星期 × 节次网格</td></tr>
        <tr><td>M4 业务编排</td><td><code>ScheduleRepository</code></td><td><b>事务边界</b>、对象图组装、用例编排、初始化与备份</td></tr>
        <tr><td>M5 冲突检测</td><td><code>ConflictDetector</code></td><td>教师维度 + 班级维度两条 JOIN，周次 <code>IN</code> 下推</td></tr>
        <tr><td>M6 数据访问</td><td><code>dao/</code> 11 个 DAO</td><td>单表 SQL 与行映射，首参一律 <code>DbExecutor</code></td></tr>
        <tr><td>M7 数据库基础设施</td><td><code>ScheduleDb</code> / <code>TableSchema</code></td><td>连接、PRAGMA、建表、迁移、事务、备份恢复</td></tr>
        <tr><td>M8 执行器抽象</td><td><code>DbExecutor</code> / <code>RsReader</code></td><td>统一"连接/事务"两种场景；类型安全读列</td></tr>
        <tr><td>M9 领域模型</td><td><code>model/</code> 7 文件</td><td>实体与业务规则，含 <code>TimePeriod.overlaps()</code></td></tr>
        <tr><td>M10 旧数据导入</td><td><code>LegacyJsonImporter</code></td><td>旧 JSON 事务化一次性导入 + 归档（434 行）</td></tr>
        <tr><td>M11 首启种子</td><td><code>SeedData</code></td><td>库内无学期时播种默认模板 / 学期 / 教师 / 课程 / 班级</td></tr>
        <tr><td>M12 日期与工具</td><td><code>DateUtil</code> / <code>Util</code> / <code>Logger</code></td><td>周次与周矩阵、UUID 与颜色归一化、hilog 统一出口</td></tr>
        <tr><td>M13 上课提醒</td><td><code>LessonReminder</code></td><td>按课表重算提醒快照（次日 22:00 / 课前 N 分钟），登记到系统后台代理提醒；连排课不打扰；<b>额度 30 条</b>：每条带「关闭」按钮 + 每次重建清点 + 额度满熔断</td></tr>
      </tbody>
    </table>

    <h3>三个最值得记住的设计</h3>
    <div class="grid2">
      <div class="mini">
        <h4>① DbExecutor（30 行接口）</h4>
        <ul><li>把 <code>RdbStore</code> 与 <code>Transaction</code> 的同形方法收口为一个接口</li><li>DAO 写一次即同时服务"连接（自动提交）"与"事务（可回滚）"</li><li>没有它，每个 DAO 方法都要写两份，逻辑必然漂移</li></ul>
      </div>
      <div class="mini">
        <h4>② RsReader 类型安全读取器</h4>
        <ul><li>把 <code>ResultSet</code> 的 NULL / 列缺失 / 类型陷阱收口到 10 个方法</li><li><code>optReal</code> 一个方法就修掉"未填学分变成 2 学分"</li><li>所有 DAO 的游标 <code>try/finally</code> 关闭，全局 0 处遗漏</li></ul>
      </div>
      <div class="mini">
        <h4>③ 级联删除双保险</h4>
        <ul><li>SQLite 外键按连接生效、连接池下不可靠 → 应用层显式级联（顺序不可颠倒）</li><li><code>class_group → class_info</code> 刻意用 <b>RESTRICT</b>：宁可报错也不静默删数据</li><li>删学期涉及 8 张表，全在一个事务内</li></ul>
      </div>
    </div>
  </section>

  <!-- 落地状态 -->
  <section class="card" id="status">
    <h2><span class="num">8</span>落地状态与下一步</h2>
    <p class="lead">工程位于 <span class="filetag">WisdomDaily/</span>，API 20，包名 <code>com.wxz.wisdomdaily</code>。</p>

    <h3>完成情况</h3>
    <table>
      <thead><tr><th>部分</th><th>状态</th><th>说明</th></tr></thead>
      <tbody>
        <tr><td>设计文档（6 份 Markdown）</td><td><span class="sev fixed">完成</span></td><td>需求 / 数据库 / 概要 / 详细 / 架构与数据流 / 状态管理与桌面卡片，全部为 v2.0 关系库方案</td></tr>
        <tr><td>图纸（2 张 SVG）</td><td><span class="sev fixed">完成</span></td><td>七层架构图 · 核心数据流图（读 / 写 / 初始化编排）</td></tr>
        <tr><td>工程骨架与配置</td><td><span class="sev fixed">完成</span></td><td>AppScope / entry 模块 / hvigor / 资源 / 权限（仅 WRITE_MEDIA）</td></tr>
        <tr><td>数据层 + 页面层</td><td><span class="sev fixed">完成</span></td><td>全工程 55 个 <code>.ets</code> / 26 598 行：课表视图（滑动切周 + 空表自证诊断）、课程编辑（多班级 / 多时间段 / HSV 拾色 / 冲突确认）、时间表编辑（内容比对判脏）、管理面板（FIT_CONTENT 半模态）、名册 / 时间管理 / 教师管理（名册另有 .xls 导入导出 / 合并单元格与边框；三个列表视图统一为 List + 左滑编辑/删除 + 长按多选 + 名册两排式底栏的同款交互（教师添加改为点击展开表单））、桌面卡片（2*2 与 2*4 **同高不同宽** → 窄卡竖排 / 宽卡横排两套版式，只显示未上完的两节，点击课程跳转详情）、上课提醒（次日 22:00 + 课前 N 分钟，系统代理提醒）、待办（任务 + 子任务 + 回收站 30 天 + 应用内到点提醒 + 「学习」清单展示当天课程，schema v7）、<b>课表分享包</b>（顶栏分享图标导出 zip：manifest.json + 课程清单表 + 作息节次表 + 说明；顶栏下载图标导入：Excel / zip / 官网〔占位〕，导入为「新建学期」，不覆盖已有数据；<b>并认出教务系统导出的「教师个人课表」网格</b>：自动拆出课程名 / 周次 / 教室[节次]节 / 班级:人数，按大节钟点反推作息节次表，导入面板底部另有说明与两张 Excel 模板下载）</td></tr>
        <tr><td>课堂签到（点名）</td><td><span class="sev fixed">完成</span></td><td>课程详情中间「签到」→ <b>全屏点名页</b>（<code>pages/CheckIn.ets</code>）：学生纵向列表，<b>左滑旷课（导出 ×）/ 右滑请假（导出 ⊕）/ 长按并拖到圆环上选等级 1~5（正上方 1/3 是取消）</b>（等级换算随机分当场落库，导两次一致）；结果点「完成」才落库（Save-on-Done + 快照判脏）；名册导出支持<b>原表 / 算分后</b>两种口径，一次点名占一列（最多 5 列）；<code>attendance</code> 表 schema v6；详见 <span class="filetag">docs/04</span> §12.3.2 (27) 与 <span class="filetag">docs/06</span> §2.9；签到面板里还可<b>只读展开「查看本节课程情况」</b>（出勤 / 旷课 / 请假 / 未点名 四格计数 + 已点名进度 + 已评级平均分 + 逐人列表，全程不落库）；<b>长按期间其余学生压阴影、只有被选中的那一行可操作</b>，<b>列表最底下的「单人视图」按钮</b>进去（<b>上半屏</b>当前学生 / <b>下半屏</b>切换视图 + 1/2/3 + 4/5/⊕/× / 底部两端前后两位学生，见 <span class="filetag">docs/04</span> §12.3.2 (29)、(30)）</td></tr>
        <tr><td>桌面卡片（2*2 / 2*4 今日课程）</td><td><span class="sev fixed">完成</span></td><td><code>EntryFormAbility</code> + <code>widget/</code>：<b>两种尺寸都只显示两节、每节都是两行</b>（2*2 与 2*4 同高、只差宽度 → 窄卡每节竖排两行「课程名 / 第二行四宫格：<b>左钟点上下排（贴左）+ 右教室与人数上下排（贴右）</b>」/ 宽卡每节横排两行）、顶部右上角 <code>ic_app</code> 图标、<b>钟点/教室/人数不出现省略号</b>（超长文字改缩字号；<b>仅窄卡课程名固定 12pt、超长末尾截断</b>）、只显示当天还没上完的课（<code>今天没课啦ヽ(*≧ω≦)ﾉ</code> <b>只在真没课时出现</b>；<b>只剩一节时第二格留白、固定两格</b>）、<b>顶栏课程数徽标</b>（今天"剩 N 节" / 明天"共 N 节"，吃应用里"今天"日期徽标的同一个高亮色；<b>窄卡不显示周数，只留这一格</b>）、<b>22 点切次日与标题的"今天/明天"跟随「提醒第二天的课」开关</b>（关掉后整天只说今天）、30 分钟定时刷新 + 前后台主动推送、宽卡行内显示 <code>@教室 · N人</code> 与课程类型 <code>（理论/实验）</code>、点某行拉起应用打开该课详情、<b>没课时点整张卡进应用看课表</b>（只携周次、切回「首页」页签）；详见 <span class="filetag">docs/06</span></td></tr>
        <tr><td>上课提醒</td><td><span class="sev fixed">完成</span></td><td><code>service/LessonReminder.ets</code> + <code>app_setting</code> 三列（schema v5）：「我的 → 上课提醒」两个开关 + 提前量输入框；提醒条目每次按课表**全清重建**，走系统后台代理提醒（应用不运行也能弹）；每条提醒带「关闭」按钮、每次重建清点系统额度（30 条）、额度满即熔断 10 分钟不刷屏；详见 <span class="filetag">docs/06</span> §2.8</td></tr>
        <tr><td>系统栏与页面底色同源</td><td><span class="sev fixed">完成</span></td><td>页面底色 / 窗口底色 / 状态栏 / 导航栏统一取 <code>PAGE_BG_COLOR</code>（<code>common/Util.ets</code> 唯一定义，四个页面页根共 7 处 + <code>EntryAbility</code> 三处）：手势导航下底部那块<b>没有背景色 API</b>、透传的是<b>窗口底色</b>，只设 <code>navigationBarColor</code> 挡不住那条 33 vp 白边，要补 <code>setWindowBackgroundColor()</code>；详见 <span class="filetag">docs/04</span> §12.3.2 (32)</td></tr>
      </tbody>
    </table>

    <h3>页面层推进顺序</h3>
    <table>
      <thead><tr><th>阶段</th><th>内容</th><th>目标</th></tr></thead>
      <tbody>
        <tr><td>第 1 步</td><td>页面骨架 + <code>LayoutConstants</code> + <code>reloadDerivedState()</code></td><td>把派生状态刷新做对（DEF-01）</td></tr>
        <tr><td>第 2 步</td><td>课表视图页（网格 + 时间轴 + 周次条 + 滑动切周）</td><td>只读渲染跑通，对照截图</td></tr>
        <tr><td>第 3 步</td><td>课程编辑页（含 HSV 拾色器 + 冲突确认交互）</td><td>走通带 <code>force</code> 的冲突处理</td></tr>
        <tr><td>第 4 步</td><td>作息模板页 / 学期页 / 教师页 / 学生名单页</td><td>补齐功能矩阵</td></tr>
        <tr><td>第 5 步</td><td>导出导入（课表 zip 分享包 + Excel / zip / 官网导入 + 教务教师课表识别 + Excel 模板下载）+ 关于页 + 折叠屏适配</td><td>收尾</td></tr>
      </tbody>
    </table>

    <div class="callout ok">
      <b>页面层与数据层的契约</b>：页面层只需认识 <code>ScheduleRepository</code> 一个类 —— 它提供 <code>loadWorkspace</code> / <code>loadSemesterCourses</code> / <code>loadWeekLessons</code> / <code>saveCourseGraph</code>（整门课单事务：课程 + 班级 + 时间段，冲突整体回滚）/ <code>createSemester</code> / <code>backup</code> 等 30 余个语义化方法，页面上不需要出现一行 SQL。
    </div>

    <h3>遗留风险</h3>
    <ul>
      <li><b>L-1</b> 版本迁移机制已有 v2~v7 六段真实迁移，但尚未在真机做过"逐版本连续升级"验证</li>
      <li><b>L-2</b> <code>syncSemesterCourses</code> 的差量比对逻辑较复杂，缺少单测覆盖</li>
      <li><b>L-4</b> 冲突检测未覆盖"同一教师跨学期"，也未做"教室冲突"维度（数据基础已具备）</li>
      <li><b>L-5</b> <code>describeError</code> 的文案映射按经验列出，未覆盖全部 SQLite 错误码</li>
      <li><b>L-7</b> 大名单（&gt;1000 学生）的 <code>replaceRoster</code> 需分批写入以避开单条语句变量上限</li>
    </ul>
  </section>

  <footer>每日知途（WisdomDaily）设计文档 v2.0（RelationalStore 方案）· 生成于 2026-10-19 · 6 份 Markdown 文档 + 2 张 SVG 图纸 + 全工程 55 个 .ets / 26 598 行（数据层 + 页面层 + 桌面卡片 + 上课提醒 + 课堂签到 + 待办 + 课表分享包）</footer>
</div>
</body>
</html>
"""

HTML = HTML.replace("__ARCH_SVG__", arch_svg).replace("__FLOW_SVG__", flow_svg)

out = ROOT / "设计文档总览.html"
out.write_text(HTML, encoding="utf-8")
print(f"OK -> {out}  ({out.stat().st_size} bytes)")
print(f"   内联 系统架构图.svg {len(arch_svg)} chars / 核心数据流图.svg {len(flow_svg)} chars")
