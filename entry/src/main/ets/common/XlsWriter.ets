/**
 * 极简 `.xls`（Excel 97-2003，OLE2/CFB + BIFF8）**写入器**。
 *
 * 为什么需要它：HarmonyOS 没有生成 Excel 的能力，而「导出班级名单」要出的正是
 * `XlsReader` 认得的老式二进制格式 —— 只有两边同格式，导出的文件才能再导回来。
 *
 * 职责刻意压到最小：**把一个字符串二维表写成一个只有一个工作表的工作簿**。
 * 不做样式、不做列宽、不做公式、不写数字类型（名册里学号/姓名/性别全是文本，
 * 学号有前导零更不能当数字写）。
 *
 * 三处刻意的简化，都是规范允许的：
 *   1. Workbook 流末尾补零到不小于 4096 字节 —— CFB 规定「流大小 ≥ miniStreamCutoff
 *      走常规 FAT」，于是**完全不需要 miniFAT / mini stream**，容器只剩
 *      头 + FAT + 目录 + 数据扇区。
 *   2. 字符串统一以 UTF-16LE 写进 SST（flags=0x01），避免同一段里混压缩/Unicode 编码。
 *   3. SST 只在**字符串边界**切 `CONTINUE`，从不把一条字符串拆到两条记录里 ——
 *      规范里 CONTINUE 段首那个重发编码的 grbit 字节只在「上一条记录停在字符串中间」
 *      时才出现，不拆串就永远不需要它。
 *
 * 算法先在 Python 原型上用 `olefile`（CFB 层）+ `xlrd`（BIFF 层）双向校验通过，
 * 再用 `XlsReader` 读回验证「导出 → 再导入」闭环。
 */

const SECTOR_SIZE: number = 512;
/** CFB 的小流阈值：流小于它必须走 mini stream，所以生成时补到它以上就能绕开 miniFAT */
const MINI_CUTOFF: number = 4096;
/** BIFF 单条记录载荷上限 */
const MAX_PAYLOAD: number = 8224;

const FREE_SECTOR: number = 0xFFFFFFFF;
const END_OF_CHAIN: number = 0xFFFFFFFE;
const FAT_SECTOR: number = 0xFFFFFFFD;

const REC_BOF: number = 0x0809;
const REC_EOF: number = 0x000A;
const REC_SST: number = 0x00FC;
const REC_CONTINUE: number = 0x003C;
const REC_LABELSST: number = 0x00FD;
const REC_CODEPAGE: number = 0x0042;
const REC_BOUNDSHEET: number = 0x0085;
const REC_DIMENSIONS: number = 0x0200;
const REC_WINDOW1: number = 0x003D;
const REC_WINDOW2: number = 0x023E;
const REC_ROW: number = 0x0208;
const REC_FONT: number = 0x0031;
const REC_XF: number = 0x00E0;
const REC_MERGEDCELLS: number = 0x00E5;
const REC_BLANK: number = 0x0201;

/** BOF 的 dt 字段：工作簿全局段 / 工作表段 */
const DT_GLOBALS: number = 0x0005;
const DT_SHEET: number = 0x0010;

/**
 * 一个矩形区（行列都**含端点**），同时用于「合并单元格」与「边框范围」。
 * 参数顺序与 BIFF 合并记录一致：(行首, 行尾, 列首, 列尾)。行列号 0 起。
 */
export class XlsRect {
  readonly r1: number;
  readonly r2: number;
  readonly c1: number;
  readonly c2: number;

  constructor(r1: number, r2: number, c1: number, c2: number) {
    this.r1 = r1;
    this.r2 = r2;
    this.c1 = c1;
    this.c2 = c2;
  }
}

export class XlsWriter {
  /**
   * 把二维表写成一个 `.xls` 文件的字节。
   * 空字符串单元格会被跳过（写成空白格）；行/列数取表的最大范围。
   */
  static build(rows: string[][]): Uint8Array {
    return XlsWriter.buildEx(rows, [], undefined);
  }

  /**
   * 带样式的版本：`merges` 是合并单元格区（0x00E5 记录），`border` 是细边框
   * 覆盖范围。给出 `border` 时会写入 FONT/XF 样式表（字节值从用户手里的
   * 真实模板原文提取），并把边框范围内的**空白格**补成 BLANK 记录，
   * 否则边框会断在空格上。样式按行取：第 0 行 = 标题（20 号宋体居中），
   * 第 1~2 行 = 表头（居中），其余 = 数据格；都带四边细边框。
   */
  static buildEx(rows: string[][], merges: XlsRect[], border: XlsRect | undefined): Uint8Array {
    const workbook: number[] = XlsWriter.buildWorkbook(rows, merges, border);
    return XlsWriter.wrapCfb(workbook);
  }

  // ------------------------------------------------------------------ 字节写入

  private static pushU16(out: number[], v: number): void {
    out.push(v & 0xFF);
    out.push((v >> 8) & 0xFF);
  }

  private static pushU32(out: number[], v: number): void {
    out.push(v & 0xFF);
    out.push((v >> 8) & 0xFF);
    out.push((v >> 16) & 0xFF);
    out.push((v >>> 24) & 0xFF);
  }

  /** UTF-16LE：按 code unit 逐个写，与 `String.charCodeAt` 一一对应 */
  private static pushUtf16(out: number[], s: string): void {
    for (let i = 0; i < s.length; i++) {
      const code: number = s.charCodeAt(i);
      out.push(code & 0xFF);
      out.push((code >> 8) & 0xFF);
    }
  }

  private static pushRecord(out: number[], id: number, payload: number[]): void {
    XlsWriter.pushU16(out, id);
    XlsWriter.pushU16(out, payload.length);
    for (let i = 0; i < payload.length; i++) {
      out.push(payload[i]);
    }
  }

  private static appendAll(out: number[], src: number[]): void {
    for (let i = 0; i < src.length; i++) {
      out.push(src[i]);
    }
  }

  // ------------------------------------------------------------------ BIFF8

  private static bofPayload(dt: number): number[] {
    const data: number[] = [];
    XlsWriter.pushU16(data, 0x0600); // BIFF8
    XlsWriter.pushU16(data, dt);
    XlsWriter.pushU16(data, 0x0DBB); // build
    XlsWriter.pushU16(data, 0x07CC); // year
    XlsWriter.pushU32(data, 0x00C1); // file history flags
    XlsWriter.pushU32(data, 0x0006); // lowest BIFF version
    return data;
  }

  /** 共享字符串表 → 完整的 SST + 若干 CONTINUE 记录字节（只在字符串边界切段） */
  private static buildSst(shared: string[]): number[] {
    const out: number[] = [];
    const items: number[][] = [];
    for (let i = 0; i < shared.length; i++) {
      const item: number[] = [];
      XlsWriter.pushU16(item, shared[i].length);
      item.push(0x01); // flags：UTF-16LE
      XlsWriter.pushUtf16(item, shared[i]);
      items.push(item);
    }

    const chunks: number[][] = [];
    let cur: number[] = [];
    let cap: number = MAX_PAYLOAD - 8; // 第一条 SST 还要放 8 字节计数头
    for (let i = 0; i < items.length; i++) {
      const item: number[] = items[i];
      if (item.length > cap) {
        if (cur.length > 0) {
          chunks.push(cur);
        }
        cur = [];
        cap = MAX_PAYLOAD;
      }
      XlsWriter.appendAll(cur, item);
      cap -= item.length;
    }
    if (cur.length > 0) {
      chunks.push(cur);
    }
    if (chunks.length === 0) {
      chunks.push([]);
    }

    const first: number[] = [];
    XlsWriter.pushU32(first, shared.length); // cstTotal
    XlsWriter.pushU32(first, shared.length); // cstUnique
    XlsWriter.appendAll(first, chunks[0]);
    XlsWriter.pushRecord(out, REC_SST, first);
    for (let i = 1; i < chunks.length; i++) {
      XlsWriter.pushRecord(out, REC_CONTINUE, chunks[i]);
    }
    return out;
  }

  /**
   * WINDOW1（工作簿窗口状态，18 字节）。真实 Excel/WPS 文件必有这条记录，
   * 缺了它严格解析器（如 MS Excel）会判定文件损坏。字节值取自真实生成的工作簿，
   * 语义：窗口位置/尺寸用默认值、显示滚动条与标签、当前与可见工作表 = 第 1 张。
   */
  private static window1Payload(): number[] {
    return [
      0xFF, 0x7F, 0xFF, 0x7F, 0x2C, 0x6D, 0x54, 0x30, 0x38, 0x00,
      0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x58, 0x02
    ];
  }

  /**
   * WINDOW2（工作表窗口状态，18 字节）。与 WINDOW1 同理为必写记录；
   * 字节值取自真实生成的工作簿：显示网格线与行列头、冻结在 A1、缩放 100%。
   */
  private static window2Payload(): number[] {
    return [
      0xB6, 0x06, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00,
      0x64, 0x00, 0x00, 0x00, 0x41, 0x00, 0x00, 0x00
    ];
  }

  // ------------------------------------------------------------------ 样式（字节取自用户的真实模板文件）

  /** FONT 记录（20 字节）：宋体 11 号常规 —— 模板正文字体，原文照抄 */
  private static readonly FONT_11: number[] = [
    0xDC, 0x00, 0x00, 0x00, 0xFF, 0x7F, 0x90, 0x01, 0x00, 0x00,
    0x00, 0x00, 0x86, 0x7F, 0x02, 0x01, 0x8B, 0x5B, 0x53, 0x4F
  ];

  /** FONT 记录（20 字节）：宋体 20 号 —— 模板标题字体（0x0190 = 400 缇 = 20pt） */
  private static readonly FONT_20: number[] = [
    0x90, 0x01, 0x00, 0x00, 0xFF, 0x7F, 0x90, 0x01, 0x00, 0x00,
    0x00, 0x00, 0x86, 0x7F, 0x02, 0x01, 0x8B, 0x5B, 0x53, 0x4F
  ];

  /** 细边框线型 + 颜色段（0x2040 = 四边细线，颜色取自动色），模板原文 */
  private static readonly XF_BORDER_HEAD: number[] = [0x40, 0x20, 0x40, 0x20, 0x00, 0x00];

  /** XF 末尾的填充段（2 字节：无填充图案），边框 XF 用 */
  private static readonly XF_AREA_PLAIN: number[] = [0xC0, 0x20];

  /** 16 条内置样式 XF（规范惯例：索引 0~15 是样式 XF），供单元格 XF 的父样式引用 */
  private static buildStyleXfs(): number[] {
    const out: number[] = [];
    const plain: number[] = [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC0, 0x20];
    // idx0：attr=0xFFF5、used=0
    XlsWriter.pushRecord(out, REC_XF, XlsWriter.styleXfBody(0, 0xFFF5, 0x00000000, plain));
    // idx1~2：字体 1
    XlsWriter.pushRecord(out, REC_XF, XlsWriter.styleXfBody(1, 0xFFF5, 0x0000F400, plain));
    XlsWriter.pushRecord(out, REC_XF, XlsWriter.styleXfBody(1, 0xFFF5, 0x0000F400, plain));
    // idx3~4：字体 2
    XlsWriter.pushRecord(out, REC_XF, XlsWriter.styleXfBody(2, 0xFFF5, 0x0000F400, plain));
    XlsWriter.pushRecord(out, REC_XF, XlsWriter.styleXfBody(2, 0xFFF5, 0x0000F400, plain));
    // idx5~14：字体 0
    for (let i = 0; i < 10; i++) {
      XlsWriter.pushRecord(out, REC_XF, XlsWriter.styleXfBody(0, 0xFFF5, 0x0000F400, plain));
    }
    // idx15：attr=0x0001、used=0（真实文件里最后一条样式 XF 就长这样）
    XlsWriter.pushRecord(out, REC_XF, XlsWriter.styleXfBody(0, 0x0001, 0x00000000, plain));
    return out;
  }

  private static styleXfBody(ifnt: number, attr: number, used: number, tail: number[]): number[] {
    const body: number[] = [];
    XlsWriter.pushU16(body, ifnt);
    XlsWriter.pushU16(body, 0); // ifmt
    XlsWriter.pushU16(body, attr);
    XlsWriter.pushU16(body, 0x0010); // algn
    XlsWriter.pushU32(body, used);
    XlsWriter.appendAll(body, tail);
    return body;
  }

  /**
   * 单元格 XF（20 字节）。`head` 是「ifnt+ifmt+attr+algn+used」12 字节前缀，
   * 边框 XF 的前缀取自模板单元格 XF 原文，只把字体索引换成自己字体表里的；
   * 尾部 = 线型段(2) + 颜色段(4) + 填充段(2) = 8 字节，总长 12+8 = 20。
   */
  private static cellXfBody(head: number[]): number[] {
    const body: number[] = [];
    XlsWriter.appendAll(body, head);
    XlsWriter.appendAll(body, XlsWriter.XF_BORDER_HEAD);
    XlsWriter.appendAll(body, XlsWriter.XF_AREA_PLAIN);
    return body;
  }

  /** 数据格：四边细边框、水平常规对齐（模板 XF#65 原文，字体 0） */
  private static readonly XF_DATA_HEAD: number[] = [
    0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x10, 0x00, 0x00, 0x20, 0x11, 0x11
  ];

  /** 表头格：四边细边框、水平垂直居中（模板 XF#71 原文，字体改 0） */
  private static readonly XF_HEAD_HEAD: number[] = [
    0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x12, 0x00, 0x00, 0x38, 0x11, 0x11
  ];

  /** 标题格：四边细边框、居中、字体 1（宋体 20 号）（模板 XF#69 原文） */
  private static readonly XF_TITLE_HEAD: number[] = [
    0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x12, 0x00, 0x00, 0x38, 0x11, 0x11
  ];

  private static buildWorkbook(rows: string[][], merges: XlsRect[], border: XlsRect | undefined): number[] {
    const bordered: boolean = border !== undefined;
    // 有边框时：16 条样式 XF 占 0~15，我们的单元格 XF 从 16 起
    const XF_DATA: number = bordered ? 16 : 0;
    const XF_HEAD: number = bordered ? 17 : 0;
    const XF_TITLE: number = bordered ? 18 : 0;

    // 1) 收词表：所有单元格文本去重后统一编号
    const shared: string[] = [];
    const index: Map<string, number> = new Map<string, number>();
    let ncols: number = 1;
    for (let r = 0; r < rows.length; r++) {
      const row: string[] = rows[r];
      if (row.length > ncols) {
        ncols = row.length;
      }
      for (let c = 0; c < row.length; c++) {
        const text: string = row[c];
        if (text.length === 0) {
          continue;
        }
        const found: number | undefined = index.get(text);
        if (found === undefined) {
          index.set(text, shared.length);
          shared.push(text);
        }
      }
    }
    const nrows: number = rows.length;

    // 2) 全局段前半：BOF → CODEPAGE → WINDOW1 →（有边框时）FONT ×3 → 样式 XF ×16 → 单元格 XF ×3。
    //    注意顺序：真实文件里 SST 在 BOUNDSHEET **之后**，严格解析器按此顺序校验
    const pre: number[] = [];
    XlsWriter.pushRecord(pre, REC_BOF, XlsWriter.bofPayload(DT_GLOBALS));
    XlsWriter.pushRecord(pre, REC_CODEPAGE, [0xE4, 0x04]);
    XlsWriter.pushRecord(pre, REC_WINDOW1, XlsWriter.window1Payload());
    if (bordered) {
      XlsWriter.pushRecord(pre, REC_FONT, XlsWriter.FONT_11);
      XlsWriter.pushRecord(pre, REC_FONT, XlsWriter.FONT_20);
      XlsWriter.pushRecord(pre, REC_FONT, XlsWriter.FONT_11);
      XlsWriter.appendAll(pre, XlsWriter.buildStyleXfs());
      XlsWriter.pushRecord(pre, REC_XF, XlsWriter.cellXfBody(XlsWriter.XF_DATA_HEAD));
      XlsWriter.pushRecord(pre, REC_XF, XlsWriter.cellXfBody(XlsWriter.XF_HEAD_HEAD));
      XlsWriter.pushRecord(pre, REC_XF, XlsWriter.cellXfBody(XlsWriter.XF_TITLE_HEAD));
    }

    // 3) 先把 SST 完整构建出来 —— BOUNDSHEET 里的 lbPlyPos 指向工作表 BOF 的绝对
    //    偏移，而 SST 排在 BOUNDSHEET 之后，**必须把 SST 的长度算进偏移**，
    //    否则 Excel 跳过去找不到 BOF，直接判文件损坏（此前空表 bug 的根因）
    const sst: number[] = XlsWriter.buildSst(shared);
    const name: string = 'Sheet1';
    const bsLen: number = 4 + 4 + 2 + 1 + 1 + name.length * 2;
    const sheetBofPos: number = pre.length + bsLen + sst.length + 4; // +4 = 中间的 EOF
    const bs: number[] = [];
    XlsWriter.pushU32(bs, sheetBofPos);
    XlsWriter.pushU16(bs, 0); // grbit：可见工作表
    bs.push(name.length); // cch
    bs.push(0x01); // grbitChr：名字是 UTF-16
    XlsWriter.pushUtf16(bs, name);

    const out: number[] = [];
    XlsWriter.appendAll(out, pre);
    XlsWriter.pushRecord(out, REC_BOUNDSHEET, bs);
    XlsWriter.appendAll(out, sst);
    XlsWriter.pushRecord(out, REC_EOF, []);

    // 4) 工作表段：BOF → DIMENSIONS(14 字节) → WINDOW2 → ROW×n → 单元格 → 合并区 → EOF
    XlsWriter.pushRecord(out, REC_BOF, XlsWriter.bofPayload(DT_SHEET));
    // DIMENSION 是 BIFF8 的 14 字节（rwMic/rwMac 各 4 字节 + colMic/colMac/保留位各 2 字节），
    // 少写末尾的保留位会被 Excel 判为文件损坏
    const dim: number[] = [];
    XlsWriter.pushU32(dim, 0);
    XlsWriter.pushU32(dim, nrows);
    XlsWriter.pushU16(dim, 0);
    XlsWriter.pushU16(dim, ncols);
    XlsWriter.pushU16(dim, 0); // 保留位
    XlsWriter.pushRecord(out, REC_DIMENSIONS, dim);
    XlsWriter.pushRecord(out, REC_WINDOW2, XlsWriter.window2Payload());
    // ROW：每个占用的行写一条（colMac = 列上界，行高 0 = 默认行高）
    for (let r = 0; r < nrows; r++) {
      const rowRec: number[] = [];
      XlsWriter.pushU16(rowRec, r);
      XlsWriter.pushU16(rowRec, 0);
      XlsWriter.pushU16(rowRec, ncols);
      XlsWriter.pushU16(rowRec, 0);
      XlsWriter.pushU16(rowRec, 0);
      XlsWriter.pushU16(rowRec, 0); // 保留位
      XlsWriter.pushU16(rowRec, 0); // grbit
      XlsWriter.pushU16(rowRec, 0); // ixfe
      XlsWriter.pushRecord(out, REC_ROW, rowRec);
    }
    // 单元格：有字写 LABELSST；边框范围内的空格补 BLANK（否则边框断在空格上）
    for (let r = 0; r < rows.length; r++) {
      const row: string[] = rows[r];
      for (let c = 0; c < ncols; c++) {
        const text: string = c < row.length ? row[c] : '';
        if (text.length > 0) {
          const found: number | undefined = index.get(text);
          let idx: number = 0;
          if (found === undefined) {
            idx = shared.length;
            shared.push(text);
            index.set(text, idx);
          } else {
            idx = found;
          }
          const cell: number[] = [];
          XlsWriter.pushU16(cell, r);
          XlsWriter.pushU16(cell, c);
          XlsWriter.pushU16(cell, XlsWriter.rowStyleOf(r, border, XF_DATA, XF_HEAD, XF_TITLE));
          XlsWriter.pushU32(cell, idx);
          XlsWriter.pushRecord(out, REC_LABELSST, cell);
        } else if (bordered && XlsWriter.inRect(r, c, border)) {
          const blank: number[] = [];
          XlsWriter.pushU16(blank, r);
          XlsWriter.pushU16(blank, c);
          XlsWriter.pushU16(blank, XlsWriter.rowStyleOf(r, border, XF_DATA, XF_HEAD, XF_TITLE));
          XlsWriter.pushRecord(out, REC_BLANK, blank);
        }
      }
    }
    // 合并单元格（0x00E5）：数量 + 每区 8 字节（行首/行尾/列首/列尾，含端点），
    // 记录排在所有单元格记录之后、EOF 之前；单格（无效合并）过滤掉
    const validMerges: XlsRect[] = [];
    for (let i = 0; i < merges.length; i++) {
      const m: XlsRect = merges[i];
      if (m.r2 > m.r1 || m.c2 > m.c1) {
        validMerges.push(m);
      }
    }
    if (validMerges.length > 0) {
      const body: number[] = [];
      XlsWriter.pushU16(body, validMerges.length);
      for (let i = 0; i < validMerges.length; i++) {
        XlsWriter.pushU16(body, validMerges[i].r1);
        XlsWriter.pushU16(body, validMerges[i].r2);
        XlsWriter.pushU16(body, validMerges[i].c1);
        XlsWriter.pushU16(body, validMerges[i].c2);
      }
      XlsWriter.pushRecord(out, REC_MERGEDCELLS, body);
    }
    XlsWriter.pushRecord(out, REC_EOF, []);
    return out;
  }

  /** 边框范围内的行样式：第 0 行标题、第 1~2 行表头、其余数据格（对应名册模板布局） */
  private static rowStyleOf(r: number, border: XlsRect | undefined,
    dataXf: number, headXf: number, titleXf: number): number {
    if (border === undefined || r < border.r1 || r > border.r2) {
      return dataXf;
    }
    if (r === border.r1) {
      return titleXf;
    }
    if (r <= border.r1 + 2) {
      return headXf;
    }
    return dataXf;
  }

  private static inRect(r: number, c: number, rect: XlsRect | undefined): boolean {
    if (rect === undefined) {
      return false;
    }
    return r >= rect.r1 && r <= rect.r2 && c >= rect.c1 && c <= rect.c2;
  }

  // ------------------------------------------------------------------ CFB 容器

  private static dirEntry(name: string, type: number, start: number, size: number, child: number): number[] {
    const e: number[] = [];
    XlsWriter.pushUtf16(e, name);
    e.push(0x00); // 名字结尾 NUL（UTF-16）
    e.push(0x00);
    while (e.length < 64) {
      e.push(0x00);
    }
    XlsWriter.pushU16(e, name.length * 2 + 2); // 0x40 cb：名字字节数（含结尾 NUL）
    e.push(type); // 0x42 类型：2 = 流，5 = 根
    e.push(0x01); // 0x43 颜色：黑
    XlsWriter.pushU32(e, FREE_SECTOR); // 0x44 左兄弟
    XlsWriter.pushU32(e, FREE_SECTOR); // 0x48 右兄弟
    XlsWriter.pushU32(e, child); // 0x4C 子节点
    for (let i = 0; i < 16; i++) {
      e.push(0x00); // 0x50 CLSID
    }
    XlsWriter.pushU32(e, 0); // 0x60 状态位
    for (let i = 0; i < 8; i++) {
      e.push(0x00); // 0x64 创建时间
    }
    for (let i = 0; i < 8; i++) {
      e.push(0x00); // 0x6C 修改时间
    }
    XlsWriter.pushU32(e, start); // 0x74 起始扇区
    XlsWriter.pushU32(e, size); // 0x78 大小（低 4 字节）
    XlsWriter.pushU32(e, 0); // 0x7C 大小（高 4 字节，v3 不用）
    return e;
  }

  private static wrapCfb(workbook: number[]): Uint8Array {
    while (workbook.length < MINI_CUTOFF) {
      workbook.push(0x00);
    }
    while (workbook.length % SECTOR_SIZE !== 0) {
      workbook.push(0x00);
    }
    const nsectors: number = workbook.length / SECTOR_SIZE;

    // 扇区布局：0 = FAT，1 = 目录，2 起 = 数据流
    const fat: number[] = [];
    fat.push(FAT_SECTOR);
    fat.push(END_OF_CHAIN);
    for (let i = 0; i < nsectors; i++) {
      fat.push(i === nsectors - 1 ? END_OF_CHAIN : 3 + i);
    }
    while (fat.length < SECTOR_SIZE / 4) {
      fat.push(FREE_SECTOR);
    }

    const out: number[] = [];

    // 头（512 字节）
    const sig: number[] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];
    XlsWriter.appendAll(out, sig);
    for (let i = 0; i < 16; i++) {
      out.push(0x00); // CLSID
    }
    XlsWriter.pushU16(out, 0x003E); // 次版本
    XlsWriter.pushU16(out, 0x0003); // 主版本
    XlsWriter.pushU16(out, 0xFFFE); // 字节序
    XlsWriter.pushU16(out, 0x0009); // 扇区位移：512
    XlsWriter.pushU16(out, 0x0006); // 迷你扇区位移：64
    for (let i = 0; i < 6; i++) {
      out.push(0x00); // 保留
    }
    XlsWriter.pushU32(out, 0); // 目录扇区数（v3 必须为 0）
    XlsWriter.pushU32(out, 1); // FAT 扇区数
    XlsWriter.pushU32(out, 1); // 第一个目录扇区
    XlsWriter.pushU32(out, 0); // 事务签名
    XlsWriter.pushU32(out, MINI_CUTOFF); // 迷你流阈值
    XlsWriter.pushU32(out, END_OF_CHAIN); // 第一个 miniFAT 扇区（没有）
    XlsWriter.pushU32(out, 0); // miniFAT 扇区数
    XlsWriter.pushU32(out, END_OF_CHAIN); // 第一个 DIFAT 扇区（没有）
    XlsWriter.pushU32(out, 0); // DIFAT 扇区数
    XlsWriter.pushU32(out, 0); // DIFAT[0] = FAT 扇区 0
    for (let i = 1; i < 109; i++) {
      XlsWriter.pushU32(out, FREE_SECTOR);
    }

    // FAT 扇区
    for (let i = 0; i < SECTOR_SIZE / 4; i++) {
      XlsWriter.pushU32(out, fat[i]);
    }

    // 目录扇区：根 + Workbook + 两条空项
    XlsWriter.appendAll(out, XlsWriter.dirEntry('Root Entry', 5, END_OF_CHAIN, 0, 1));
    XlsWriter.appendAll(out, XlsWriter.dirEntry('Workbook', 2, 2, workbook.length, FREE_SECTOR));
    for (let i = 0; i < 256; i++) {
      out.push(0x00);
    }

    XlsWriter.appendAll(out, workbook);
    // 先放进 ArrayBuffer 再取视图：不依赖 `new Uint8Array(number[])` 这个重载
    const buffer: ArrayBuffer = new ArrayBuffer(out.length);
    const bytes: Uint8Array = new Uint8Array(buffer);
    for (let i = 0; i < out.length; i++) {
      bytes[i] = out[i];
    }
    return bytes;
  }
}
