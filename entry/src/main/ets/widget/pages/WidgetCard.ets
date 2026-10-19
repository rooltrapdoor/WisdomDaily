/**
 * 桌面卡片：显示"今天还没上完的课"；**开了「提醒第二天的课」**（我的 → 上课提醒，
 * 即"提前一天晚上十点通知"）时，22 点后改为显示"明天"的课。没开那个开关的卡整天只说今天 ——
 * 切次日这个行为存在的意义就是"今晚提前知道明天有课"，开关关掉了就没有理由再切
 * （判据在提供方 `WidgetData.compute()`，一处定）。
 *
 * 尺寸与版式（官方设计规范：小卡 2\*2 = 150×150 vp，中卡 2\*4 = 316×150 vp，
 * **两者同高、2\*4 两倍宽**）：
 *  - 两种尺寸都只显示**两节课**（`WidgetData.ROW_LIMIT`）；每行信息由提供方按尺寸装好后推过来，
 *    卡片页只管照单渲染 —— 卡片进程拿不到自己的尺寸，也不该在这里做数据加工。
 *  - **顶部一行**：左 `今天 · 周三`（自适应字号；**没开「提醒第二天的课」时只剩 `周三`**）、
 *    右 `第 N 周`（**只有宽卡有**）+ **课程数徽标**（`剩 2 节` / `共 3 节`，吃"今天"高亮色）
 *    + **应用图标** `ic_app`。图标是最右一格，用户一眼看出"这张卡属于哪个应用"；
 *    它由卡片页自己取资源，不进契约。窄卡（150 vp）一行挤不下四样，砍掉周数、
 *    把宽度让给"还剩几节"（用户 2026-09-23 定）。
 *  - **窄卡（2\*2）**：一节课竖排**两行** —— 课程名 / **左右各两行的四宫格**：
 *    左列钟点上下排（上=开始、下=结束）、右列教室上下排（上=`@教室`、下=`N人`）。
 *    宽度只有 150 vp，所以"第N节"与"班级"在提供方就已经去掉；课程名独占一行才可能完整。
 *    合体写成 `10:55-12:35` 再跟 `@教室 · N人`，真机上会被截成 `10:55-1…`（"几点下课"就没了），
 *    拆成两行两列后每格最多 5 个字符。
 *  - **窄卡里不许出现省略号**：所有文本走**自适应字号**（`minFontSize` + `maxFontSize` + `maxLines(1)`；
 *    默认策略 `MAX_LINES_FIRST` 会先缩字号再谈截断，而 `heightAdaptivePolicy` **没有 `@form` 标记、
 *    卡片里不可用**），不再用 `textOverflow(Ellipsis)` —— 卡片上被截断的课名与教室等于没有，
 *    宁可小一号也要让用户读全。
 *  - **宽卡（2\*4）**：一行横排两行 —— `课程名（类型）+ 班级` / `第N-M节 · 钟点 + @教室 · N人`，
 *    与应用里课程块的口径一致（课程名 / 班级 / 教室 / 人数），另加课程类型后缀。
 *  - **点某一行课程 → 拉起应用并直接打开这节课的详情**（`postCardAction` 的 router 事件）；
 *    **一节课都没有时点整张卡 → 拉起应用并停在课表页**（不带 `wsdPeriod`，应用据此区分
 *    "开某节课"与"只看课表"）。空态卡片点不动会被当成卡片坏了，而"今天没课"恰恰是
 *    用户想去应用里看一眼的时候。
 *  - **卡片固定两格**：目标日只剩**一节课**时，第二格**留白**（`blankCell()`，用户 2026-09-23 定）。
 *    那一格**必须占位**（空 Column + `layoutWeight(1)`）：缺了它，课程块会被 `layoutWeight(1)`
 *    拉满整张卡、又高又空 —— 真机上那正是"数据没装配对"的样子。
 *    **一节课都没有**时，`今天没课啦ヽ(*≧ω≦)ﾉ` 才是整张卡的空态 —— 它**只在空态出现**：
 *    卡片上还挂着课时不再出现这句话（"只剩一节就补一句今天没课啦"是 2026-09-22 那一版，
 *    已按用户要求撤掉：卡片上还挂着课，底下写"今天没课啦"本来就自相矛盾）。
 *    空态文案宽卡一行；窄卡 150 vp 放不下，颜文字另起一行（换行由提供方写进 `\n`，不靠自动折行）。
 *
 * 数据来源：`EntryFormAbility` 查库后通过 `formProvider.updateForm` 推过来 ——
 * 卡片页跑在卡片进程里，**不能**访问数据库，所以这里只负责展示，
 * 每个 `@LocalStorageProp` 装饰器的 key 与 `widget/WidgetData.ets` 的 `WidgetBinding` 字段一一对应。
 *
 * 各行课程刻意**不把值传进 `@Builder`**（按值参数不参与状态观察，会把卡片冻在首帧），
 * 而是传恒定行号、在体内经普通方法现读（见 docs/04 §12.3.2 第 10 点）。
 */
let storage: LocalStorage = new LocalStorage();

@Entry(storage)
@Component
struct WidgetCard {
  /** 顶部左：`今天 · 周三` / `明天 · 周四`；**没开「提醒第二天的课」时只剩 `周三`** */
  @LocalStorageProp('titleText') titleText: string = '每日知途';
  /** 顶部右：`第 3 周`（**只有宽卡渲染**，窄卡 150 vp 挤不下，让位给课程数） */
  @LocalStorageProp('weekText') weekText: string = '';
  /** 课程数徽标：`剩 2 节`（今天还剩几节）/ `共 3 节`（明天共几节）；当天一节都不剩时为空串 */
  @LocalStorageProp('countText') countText: string = '';
  /**
   * 课程数徽标的颜色（ARGB）：与应用里"今天"日期徽标**同一个高亮色**
   * （提供方从 `app_setting.today_color` 带来 —— 卡片进程读不到设置）。
   */
  @LocalStorageProp('countColor') countColor: string = '#FF1890FF';
  /** 空态：一节课都没有时的话（`今天没课啦ヽ(*≧ω≦)ﾉ` / `正在加载…` / 环境类提示） */
  @LocalStorageProp('emptyText') emptyText: string = '正在加载…';
  @LocalStorageProp('rowCount') rowCount: number = 0;
  /** 1 = 宽卡（2\*4），0 = 窄卡（2\*2）—— 两套版式的开关 */
  @LocalStorageProp('cardWide') cardWide: number = 0;
  /** 点课跳转的定位键：目标周次 + 星期（与 `WidgetData` 的 weekNo / weekday 对应） */
  @LocalStorageProp('weekNo') weekNo: number = 0;
  @LocalStorageProp('weekday') weekday: number = 0;
  @LocalStorageProp('row1Course') row1Course: string = '';
  /** 窄卡第二行的**上半行**：开始钟点 `08:00`（宽卡不引用这一格，它用 `row1Meta`） */
  @LocalStorageProp('row1Start') row1Start: string = '';
  /** 窄卡第二行的**下半行**：结束钟点 `09:40`；空串时（作息模板缺失）那一行不渲染 */
  @LocalStorageProp('row1End') row1End: string = '';
  @LocalStorageProp('row1Meta') row1Meta: string = '';
  @LocalStorageProp('row1Place') row1Place: string = '';
  /** 窄卡第二行**右下**：`45人`（宽卡把人数并进了 `row1Place`，不渲染这一格） */
  @LocalStorageProp('row1People') row1People: string = '';
  @LocalStorageProp('row1Class') row1Class: string = '';
  @LocalStorageProp('row1Color') row1Color: string = '#FF1890FF';
  @LocalStorageProp('row1Period') row1Period: string = '';
  @LocalStorageProp('row2Course') row2Course: string = '';
  /** 第二节课的开始钟点（窄卡第二行上半行；语义同 `row1Start`） */
  @LocalStorageProp('row2Start') row2Start: string = '';
  /** 第二节课的结束钟点（窄卡第二行下半行；语义同 `row1End`） */
  @LocalStorageProp('row2End') row2End: string = '';
  @LocalStorageProp('row2Meta') row2Meta: string = '';
  @LocalStorageProp('row2Place') row2Place: string = '';
  /** 第二节课的班级人数（窄卡第二行右下；语义同 `row1People`） */
  @LocalStorageProp('row2People') row2People: string = '';
  @LocalStorageProp('row2Class') row2Class: string = '';
  @LocalStorageProp('row2Color') row2Color: string = '#FF1890FF';
  @LocalStorageProp('row2Period') row2Period: string = '';

  // ---- 以下九个方法只做"按行号现读"，不参与任何状态缓存 ----

  private courseOf(row: number): string {
    return row === 1 ? this.row1Course : this.row2Course;
  }

  /** 开始钟点（窄卡第二行的上半行） */
  private startOf(row: number): string {
    return row === 1 ? this.row1Start : this.row2Start;
  }

  /** 结束钟点（窄卡第二行的下半行；为空串时那一行整行不渲染） */
  private endOf(row: number): string {
    return row === 1 ? this.row1End : this.row2End;
  }

  private metaOf(row: number): string {
    return row === 1 ? this.row1Meta : this.row2Meta;
  }

  /** 教室（宽卡里是 `@教室 · N人`）；空串时这一格不渲染 */
  private placeOf(row: number): string {
    return row === 1 ? this.row1Place : this.row2Place;
  }

  /** 班级人数 `45人`（**窄卡挂在教室下面一行**；宽卡人数已并进 `placeOf`，不读这一格） */
  private peopleOf(row: number): string {
    return row === 1 ? this.row1People : this.row2People;
  }

  private classOf(row: number): string {
    return row === 1 ? this.row1Class : this.row2Class;
  }

  private colorOf(row: number): string {
    return row === 1 ? this.row1Color : this.row2Color;
  }

  private periodOf(row: number): string {
    return row === 1 ? this.row1Period : this.row2Period;
  }

  /**
   * 点击某一行 → 拉起应用并打开这节课的详情。
   *
   * `postCardAction` 的 router 事件只允许在点击回调里触发；params 会被系统塞进
   * 目标 UIAbility 的 `want.parameters`（应用没运行走 onCreate，在后台走 onNewWant），
   * 由 `widget/WidgetLaunch.ets` 解析成"定位到第几周的第几个时间段"。
   *
   * 刻意**不写 bundleName**：不写默认就是本应用，省掉一处与 `AppScope/app.json5` 重复的包名
   * （历史教训：硬编码的旧名是改名时最容易漏掉的地方）。
   */
  private openInApp(row: number): void {
    const period: string = this.periodOf(row);
    if (period.length === 0 || this.weekNo <= 0) {
      // 这一行没有定位信息（空态 / 数据还没到），不做跳转
      return;
    }
    postCardAction(this, {
      action: 'router',
      abilityName: 'EntryAbility',
      params: {
        wsdWeek: `${this.weekNo}`,
        wsdWeekday: `${this.weekday}`,
        wsdPeriod: period
      }
    });
  }

  /**
   * 点击**空态卡片** → 拉起应用、停在课表页；没有具体某节课要打开。
   *
   * 与 `openInApp` 的唯一区别是**不带 `wsdPeriod`** —— 应用侧就靠"有没有时间段 id"
   * 区分「打开某节课详情」与「只是看课表」（见 `WidgetLaunch.request` 与
   * `Index.openTimetableFromCard`）。
   *
   * 周次照旧带上（`weekNo` 在数据侧一算出来就写，不再"有课才写"）：
   * 卡片显示的是哪一周（22 点后是明天，跨周时就是下一周），点进去看到的就该是哪一周。
   * 环境类空态（还没有学期 / 学期还没开始 / 还没选择教师）没有有效周次，`weekNo` 为 0，
   * 应用收到 0 就只是把应用拉起来 —— 那几种情况本来也没有"正确的周"可言。
   */
  private openHome(): void {
    postCardAction(this, {
      action: 'router',
      abilityName: 'EntryAbility',
      params: {
        wsdWeek: `${this.weekNo}`,
        wsdWeekday: `${this.weekday}`
      }
    });
  }

  /**
   * 卡片骨架：顶部"今天 · 周三 / 第 N 周 / 剩 2 节"，下面是两节课或一句空态。
   *
   * 纵向预算（150 vp 高的卡）：上下内边距取 8（规范建议 12）而左右仍是 12，头部与内容间距 5、
   * 两格之间 4、格内边距上下 4 —— 抠掉的是空白，不是内容。
   * 卡片**固定两格**，每格约 53 vp：装得下"课程名 12pt + 两行 10pt 钟点"（≈44）。
   * **若真机上出现纵向裁切，先继续调这几个内边距，不要动字号**（字号再小就读不清了）。
   */
  build() {
    Column({ space: 5 }) {
      // 顶部：左 `今天 · 周三`（开着"提醒第二天的课"才有今天/明天）、
      // 右 `第 N 周`（只有宽卡）+ `剩 2 节` + 应用图标。
      // 标题吃剩余宽度（`layoutWeight(1)`）并配**自适应字号**（13 → 10）：窄卡一行只剩
      // ~126 vp，自适应字号能让标题自己收一点，而不是被截成 `今天 · 周…`（窄卡里不许出现省略号）。
      Row({ space: 3 }) {
        Text(this.titleText)
          .fontWeight(FontWeight.Bold)
          .fontColor('#111827')
          .maxLines(1)
          .minFontSize(10)
          .maxFontSize(13)
          .layoutWeight(1)
        // 周数**只有宽卡渲染**：窄卡 150 vp 里"标题 + 周数 + 课程数 + 图标"四样挤一行，
        // 每个文本都得缩到最小字号；而"第几周"远不如"今天还剩几节"要紧 ——
        // 砍掉它、把宽度让给课程数（用户 2026-09-23 定）。
        if (this.cardWide === 1) {
          Text(this.weekText)
            .fontSize(10)
            .fontColor('#6B7280')
            .maxLines(1)
            .flexShrink(0)
        }
        // 课程数徽标：吃"今天"日期徽标那个高亮色（色值由提供方从 app_setting 带来），
        // 是这一行唯一的强调元素 —— 扫一眼就知道"今天还剩几节 / 明天一共几节"。
        // 当天一节都不剩时是空串，这一格自然消失，不会留下空位。
        if (this.countText.length > 0) {
          Text(this.countText)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.countColor)
            .maxLines(1)
            .minFontSize(9)
            .maxFontSize(11)
            .flexShrink(0)
        }
        // 应用图标：这张卡片上唯一的"身份标识"，也正好是这一行的收尾。
        // `flexShrink(0)` —— 图标被压小就失去识别度了，宁可让标题缩字号。
        Image($r('app.media.ic_app'))
          .width(14)
          .height(14)
          .objectFit(ImageFit.Contain)
          .flexShrink(0)
      }
      .width('100%')

      // 空态（一句友好文案或环境类提示）占满内容区；点它 = 进应用看课表（见 `openHome`）
      if (this.rowCount === 0) {
        Column() {
          Text(this.emptyText)
            .fontSize(13)
            .fontColor('#9CA3AF')
            .maxLines(2)
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        // **固定两格**：只剩一节课时第二格留白（`blankCell()`），但那一格**必须占位** ——
        // 格数由版式定死、不随"还剩几节"变；否则单独一个课程块会被 `layoutWeight(1)`
        // 拉满整张卡，看着像数据没装配对。
        Column({ space: 4 }) {
          if (this.rowCount >= 1) {
            this.courseRow(1)
          }
          if (this.rowCount >= 2) {
            this.courseRow(2)
          }
          if (this.rowCount === 1) {
            this.blankCell()
          }
        }
        .width('100%')
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .backgroundColor('#FFFFFF')
    // 一节课都没有时**整张卡**可点（不只是那句文案）：一张点了没反应的卡会被当成坏掉了，
    // 而"今天没课"正是用户想去应用里看一眼课表的时候。挂在外层是为了"点哪儿都算"；
    // 有课时这里直接跳过，各行的跳转仍归 courseRowNarrow / courseRowWide 自己的 onClick。
    .onClick(() => {
      if (this.rowCount === 0) {
        this.openHome();
      }
    })
  }

  /** 一行 = 一节课；版式由 `cardWide` 决定（窄卡竖排两行 / 宽卡横排两行） */
  @Builder
  courseRow(row: number) {
    if (this.cardWide === 1) {
      this.courseRowWide(row)
    } else {
      this.courseRowNarrow(row)
    }
  }

  /**
   * 目标日只剩一节课时，**第二格留白**（用户 2026-09-23 定："如果只有一节课，底下一行留白即可"）。
   *
   * 它**只占位、不写任何字**，但这一格**必须存在**：它跟课程块一样是 `layoutWeight(1)`，
   * 两格均分高度；缺了它，那唯一一节课的课程块会独占整张卡、被拉得又高又空 ——
   * 真机上那正是"信息没装配对"的样子（2026-09-22 踩过一次）。
   *
   * 2026-09-22 那一版在这里写的是一句 `今天没课啦ヽ(*≧ω≦)ﾉ`，现在撤掉：
   * 卡片上还挂着课、底下却说"今天没课啦"，本来就自相矛盾；这句话现在**只出现在空态**。
   */
  @Builder
  blankCell() {
    Column() {
    }
    .width('100%')
    .layoutWeight(1)
  }

  /**
   * 窄卡（2\*2，150 vp 宽）的一节课，竖排两行 —— 第二行再分成左右两列、各两行：
   *
   * ```
   * ▏软件需求工程
   * ▏10:55      @1107
   * ▏12:35       45人
   * ```
   *
   * 两行是**信息取舍**的结果，不是省地方：150 vp 宽横着一行最多放得下两样，
   * 而桌面场景真正要回答的问题只有"**这节课几点上、在哪上、多少人**"。所以：
   *  - 课程名**独占一行** —— 早先它和班级挤同一行，两样都放不下、各被截去半截；
   *    独占一行后能完整放下十几个字，再长才在末尾截（且只有它允许截）；
   *  - 第二行是**四宫格**：左列钟点上下排（上=开始、下=结束）、右列教室上下排（上=教室、下=人数）。
   *    合体写成 `08:00-09:40` 再跟 `@教室 · N人` 在同一行放不下，真机上会被截成 `10:55-1…`，
   *    "几点下课"与人数一起丢；拆成两行两列后每格最多 5 个字符，宽度绰绰有余；
   *  - **人数为什么不跟教室挤一行**：150 vp 里挤进去必被省略号吃掉半截，而"几个人"正是
   *    教室后面最容易被截掉的那个信息；挂在教室**下面**一行，与左边"开始/结束"两行正好对称；
   *  - 班级、节次不渲染（在提供方就没装进来，或装了也不在这里渲染）—— 它们能从课名推出，
   *    占了宽度反而把教室顶掉；
   *  - 第二行**两端对齐**：钟点贴左（左列 `alignItems(Start)`），教室与人数贴右（右列
   *    `alignItems(End)`）。左列吃剩余宽度（`layoutWeight(1)`）、右列不收缩（`flexShrink(0)`），
   *    右列于是被顶到卡片右缘 —— 与宽卡第二行同一个排法，两张卡片看上去才是同一个设计；
   *  - **只有课名允许省略，且只在末尾**：课名固定 12pt + `maxLines(1)` + `textOverflow(Ellipsis)`，
   *    长了就在末尾收一个 `…`（课名有班级、有课表可对照，截了还能猜）；
   *    而钟点、教室、人数是**读了才知道**的硬信息，一律 `maxLines(1)` + `minFontSize`/`maxFontSize`
   *    自适应字号（默认策略 `MAX_LINES_FIRST`：先缩字号，缩到下限仍放不下才截断）——
   *    被截成 `@综合实验…` 的教室等于没有，宁可小一号也要读全。
   */
  @Builder
  courseRowNarrow(row: number) {
    Column({ space: 1 }) {
      // 课名：固定 12pt、**一行、末尾截断** —— 窄卡里唯一允许出现 `…` 的地方。
      // 不用自适应字号：长课名把字号一路缩到 9pt 会让同一张卡上两个课名一大一小，
      // 排在一起像是两个层级的标题；统一 12pt 再截尾，反而整齐。课名有班级与课表可对照，
      // 截掉半句仍能认出是哪门课 —— 这是全卡唯一"猜得出来"的信息。
      Text(this.courseOf(row))
        .fontWeight(FontWeight.Medium)
        .fontSize(12)
        .fontColor('#111827')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      // `VerticalAlign.Top`：左右两列都是两行，顶端对齐才是"表格式"的读法；
      // 若用默认的居中，右列会整体下移半行、与左列错位。
      Row({ space: 8 }) {
        // 左列：钟点**上下排** —— 上面开始、下面结束。
        // 合体写成 `08:00-09:40` 再加右边的教室与人数，150 vp 一格真放不下：真机上被截成
        // `10:55-1…`，"几点下课"直接没了；拆成上下两行后每行只有 5 个字符，绰绰有余。
        // `lineHeight` 定死 13：两行共 26 vp，卡片纵向预算才好算（缩字号不改行高）。
        Column() {
          Text(this.startOf(row))
            .lineHeight(13)
            .fontColor('#6B7280')
            .maxLines(1)
            .minFontSize(8)
            .maxFontSize(10)
          if (this.endOf(row).length > 0) {
            Text(this.endOf(row))
              .lineHeight(13)
              .fontColor('#6B7280')
              .maxLines(1)
              .minFontSize(8)
              .maxFontSize(10)
          }
        }
        // 钟点**贴左**：`Start` 对齐，并吃下剩余宽度（`layoutWeight(1)`）—— 右列才可能被顶到最右。
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        // 右列：教室在上、**班级人数在下**，两者**贴右**（`End`）。
        // 不收缩（`flexShrink(0)`）：教室无从推断，先牺牲的应该是钟点；
        // 人数为 0 时提供方给空串，那一行整行不渲染，不会留下半格空白。
        if (this.placeOf(row).length > 0 || this.peopleOf(row).length > 0) {
          Column() {
            if (this.placeOf(row).length > 0) {
              Text(this.placeOf(row))
                .lineHeight(13)
                .fontColor('#6B7280')
                .maxLines(1)
                .minFontSize(8)
                .maxFontSize(10)
            }
            if (this.peopleOf(row).length > 0) {
              Text(this.peopleOf(row))
                .lineHeight(13)
                .fontColor('#6B7280')
                .maxLines(1)
                .minFontSize(8)
                .maxFontSize(10)
            }
          }
          .alignItems(HorizontalAlign.End)
          .flexShrink(0)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
    }
    .width('100%')
    .layoutWeight(1)
    // 上下 4：第二行是"左右各两行 10pt"（`lineHeight` 定死 13 → 共 26），加上课程名（固定 12pt，
    // ≈17）与 1vp 间距，内容 ≈ 44；而卡片固定两格时每格可用高度 ≈ 45 —— 正好站得住，别再加回来。
    // **自适应字号只降不升**，所以纵向预算按各文本的上限算即可，不必留额外余量；课名固定 12pt
    // 与原来的上限同值，多出来的那几行字是**横向**截断换来的，不占纵向。
    .padding({ left: 9, right: 6, top: 4, bottom: 4 })
    .backgroundColor('#F9FAFB')
    .borderRadius(8)
    .border({ width: { left: 3 }, color: this.colorOf(row) })
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.openInApp(row);
    })
  }

  /**
   * 宽卡（2\*4，316 vp 宽）的一节课，横排两行：
   *
   * ```
   * ▏数字信号处理（理论）        计科2201
   * ▏第1-2节 · 08:00-09:40    @A101 · 45人
   * ```
   *
   * 信息与应用里的课程块一致（课程名 / 班级 / 教室 / 人数），课程类型并进课程名；
   * 卡片比课程块多一项"节次 · 钟点"—— 桌面上看不到课表，知道几点上课才有用。
   *
   * **同样不许出现省略号**：316 vp 宽虽然宽松，但课名（含类型后缀）与班级都可能很长，
   * 所以这里的文本也一律 `maxLines(1)` + `minFontSize`/`maxFontSize` 自适应字号，
   * 而不是 `textOverflow(Ellipsis)` —— 两种尺寸同一条规矩，省得"小卡修好了、大卡还截着"。
   */
  @Builder
  courseRowWide(row: number) {
    Column({ space: 2 }) {
      Row({ space: 6 }) {
        Text(this.courseOf(row))
          .fontWeight(FontWeight.Medium)
          .fontColor('#111827')
          .maxLines(1)
          .minFontSize(10)
          .maxFontSize(13)
          .layoutWeight(1)
        Text(this.classOf(row))
          .fontColor('#9CA3AF')
          .maxLines(1)
          .minFontSize(8)
          .maxFontSize(10)
          .flexShrink(0)
      }
      .width('100%')

      Row({ space: 6 }) {
        Text(this.metaOf(row))
          .fontColor('#6B7280')
          .maxLines(1)
          .minFontSize(8)
          .maxFontSize(10)
          .layoutWeight(1)
        if (this.placeOf(row).length > 0) {
          Text(this.placeOf(row))
            .fontColor('#6B7280')
            .maxLines(1)
            .minFontSize(8)
            .maxFontSize(10)
            .flexShrink(0)
        }
      }
      .width('100%')
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 10, right: 8, top: 6, bottom: 6 })
    .backgroundColor('#F9FAFB')
    .borderRadius(8)
    .border({ width: { left: 3 }, color: this.colorOf(row) })
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.openInApp(row);
    })
  }
}
