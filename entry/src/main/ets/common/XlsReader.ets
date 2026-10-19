/**
 * 极简 `.xls`（OLE2 / BIFF8）读取器。
 *
 * 为什么需要它：HarmonyOS 没有任何现成的 Excel 解析能力，而"导入名单"要读的
 * 恰恰是老式 Excel 二进制格式（`D0 CF 11 E0` 开头的复合文档）。
 *
 * 职责被刻意压到最小：**只把一个工作簿的第一个工作表读成字符串二维表**。
 * 不做公式求值、不做样式、不写文件。表格内容由上层 `RosterImporter` 解释。
 *
 * 覆盖的记录：
 *   - 容器：CFB 头 / DIFAT / FAT / miniFAT / 目录项 / Workbook 流
 *   - 字符串：SST（含跨 `CONTINUE` 记录被切断的字符串）、LABEL、STRING
 *   - 数值：RK、MULRK、NUMBER
 *   - 结构：BOF（只取第一张 dt=0x0010 的工作表）、EOF、FORMULA 的缓存值
 *
 * 已知边界：只读第一个工作表；超过 `MAX_ROWS` 行 / `MAX_COLS` 列的部分丢弃；
 * 不支持 .xlsx（那是 zip + XML，另一套东西）与加密工作簿。
 */

const CFB_SIGNATURE: number[] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];

/** 链尾 / 空闲扇区哨兵值 */
const END_OF_CHAIN: number = 0xFFFFFFFE;
const FREE_SECTOR: number = 0xFFFFFFFF;
const MAX_CHAIN_STEPS: number = 2000000;

/** BIFF 记录类型 */
const REC_BOF: number = 0x0809;
const REC_EOF: number = 0x000A;
const REC_SST: number = 0x00FC;
const REC_CONTINUE: number = 0x003C;
const REC_LABELSST: number = 0x00FD;
const REC_LABEL: number = 0x0204;
const REC_STRING: number = 0x0207;
const REC_RK: number = 0x027E;
const REC_NUMBER: number = 0x0203;
const REC_MULRK: number = 0x00BD;
const REC_FORMULA: number = 0x0006;

/** BOF 的 dt 字段：工作簿全局 / 工作表 */
const DT_WORKBOOK_GLOBALS: number = 0x0005;
const DT_WORKSHEET: number = 0x0010;

const MAX_ROWS: number = 20000;
const MAX_COLS: number = 256;
const MAX_RECORD_LEN: number = 65535;

/** 目录项（复合文档里的一个流） */
class CfbEntry {
  name: string = '';
  type: number = 0;
  start: number = 0;
  size: number = 0;
}

/** SST 解析结果：字符串表 + 下一条待处理记录的位置 */
class SstResult {
  strings: string[] = [];
  next: number = 0;
}

/**
 * SST 的字节游标。
 *
 * 存在的唯一理由：SST 的字符数据**可以跨 `CONTINUE` 记录**，而续接记录在开头
 * **重新插入一个 grbit 字节**说明剩余部分的编码。所以不能把各段载荷首尾相接后
 * 线性解析 —— 必须在段边界处多读一个字节。`starts` 记录每段起点，供这里判断。
 */
class SstCursor {
  private buf: Uint8Array;
  private starts: number[];
  pos: number = 0;

  constructor(buf: Uint8Array, starts: number[]) {
    this.buf = buf;
    this.starts = starts;
  }

  u8(): number {
    const v: number = this.buf[this.pos];
    this.pos += 1;
    return v === undefined ? 0 : v;
  }

  u16(): number {
    const a: number = this.buf[this.pos];
    const b: number = this.buf[this.pos + 1];
    this.pos += 2;
    if (a === undefined || b === undefined) {
      return 0;
    }
    return a | (b << 8);
  }

  u32(): number {
    const a: number = this.buf[this.pos];
    const b: number = this.buf[this.pos + 1];
    const c: number = this.buf[this.pos + 2];
    const d: number = this.buf[this.pos + 3];
    this.pos += 4;
    if (a === undefined || b === undefined || c === undefined || d === undefined) {
      return 0;
    }
    return (a | (b << 8) | (c << 16) | (d << 24)) >>> 0;
  }

  /** 是否为某段 CONTINUE 载荷的起点（= 字符串中间被切断处） */
  private atBoundary(): boolean {
    if (this.pos === 0) {
      return false;
    }
    for (let i = 0; i < this.starts.length; i++) {
      if (this.starts[i] === this.pos) {
        return true;
      }
    }
    return false;
  }

  /** 当前段还剩多少字节 */
  private segmentLeft(): number {
    let best: number = this.buf.length;
    for (let i = 0; i < this.starts.length; i++) {
      const s: number = this.starts[i];
      if (s > this.pos && s < best) {
        best = s;
      }
    }
    return best - this.pos;
  }

  /** 读 `count` 个字符；跨段时按段内重发的 grbit 切换编码 */
  readChars(count: number, high0: boolean): string {
    let high: boolean = high0;
    let left: number = count;
    let out: string = '';
    let guard: number = 0;
    while (left > 0 && guard < MAX_CHAIN_STEPS) {
      guard++;
      if (this.atBoundary()) {
        high = (this.u8() & 0x01) === 1;
      }
      const avail: number = this.segmentLeft();
      if (avail <= 0) {
        break;
      }
      let take: number = high ? Math.floor(avail / 2) : avail;
      if (take > left) {
        take = left;
      }
      if (take <= 0) {
        break;
      }
      if (high) {
        for (let i = 0; i < take; i++) {
          const lo: number = this.buf[this.pos + i * 2];
          const hi: number = this.buf[this.pos + i * 2 + 1];
          out += String.fromCharCode(((hi === undefined ? 0 : hi) << 8) | (lo === undefined ? 0 : lo));
        }
        this.pos += take * 2;
      } else {
        for (let i = 0; i < take; i++) {
          const b: number = this.buf[this.pos + i];
          out += String.fromCharCode(b === undefined ? 0 : b);
        }
        this.pos += take;
      }
      left -= take;
    }
    return out;
  }

  skip(n: number): void {
    this.pos += n;
  }
}

export class XlsReader {
  private readonly data: Uint8Array;
  private readonly view: DataView;
  private sectorSize: number = 512;
  private miniSectorSize: number = 64;
  private miniCutoff: number = 4096;
  private fat: number[] = [];

  private constructor(data: Uint8Array) {
    this.data = data;
    this.view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  }

  /**
   * 读取第一个工作表，返回「行 → 列 → 文本」的二维表。
   * 空单元格为 `''`；数字按整数优先的规则转成文本（`1` 而不是 `1.0`）。
   * 非 `.xls` / 结构损坏时抛 `Error`，由调用方转成用户可读的提示。
   */
  static readFirstSheet(data: Uint8Array): string[][] {
    const reader: XlsReader = new XlsReader(data);
    return reader.parse();
  }

  // ------------------------------------------------------------------ 基础读取

  private u8(off: number): number {
    return this.view.getUint8(off);
  }

  private u16(off: number): number {
    return this.view.getUint16(off, true);
  }

  private u32(off: number): number {
    return this.view.getUint32(off, true);
  }

  private f64(off: number): number {
    return this.view.getFloat64(off, true);
  }

  // ------------------------------------------------------------------ CFB 容器

  private checkSignature(): void {
    if (this.data.length < 512) {
      throw new Error('文件太小，不是有效的 .xls 工作簿');
    }
    for (let i = 0; i < CFB_SIGNATURE.length; i++) {
      if (this.u8(i) !== CFB_SIGNATURE[i]) {
        throw new Error('不是 .xls 格式（请另存为 Excel 97-2003 工作簿 .xls）');
      }
    }
  }

  /** 组装整张 FAT：先收 DIFAT 里的 FAT 扇区号，再逐扇区展开 */
  private buildFat(): void {
    const fatSectors: number[] = [];
    for (let i = 0; i < 109; i++) {
      const v: number = this.u32(76 + i * 4);
      if (v === FREE_SECTOR) {
        break;
      }
      fatSectors.push(v);
    }
    const perSector: number = this.sectorSize / 4 - 1;
    let next: number = this.u32(68);
    let guard: number = 0;
    while (next !== END_OF_CHAIN && next !== FREE_SECTOR && guard < 10000) {
      guard++;
      const base: number = 512 + next * this.sectorSize;
      for (let i = 0; i < perSector; i++) {
        const v: number = this.u32(base + i * 4);
        if (v !== FREE_SECTOR) {
          fatSectors.push(v);
        }
      }
      next = this.u32(base + perSector * 4);
    }

    const fat: number[] = [];
    const perFat: number = this.sectorSize / 4;
    for (let i = 0; i < fatSectors.length; i++) {
      const base: number = 512 + fatSectors[i] * this.sectorSize;
      for (let j = 0; j < perFat; j++) {
        fat.push(this.u32(base + j * 4));
      }
    }
    this.fat = fat;
  }

  /** 顺着 FAT（或 miniFAT）走链，返回扇区号序列 */
  private chain(start: number, fat: number[]): number[] {
    const out: number[] = [];
    let cur: number = start;
    let guard: number = 0;
    while (cur !== END_OF_CHAIN && cur !== FREE_SECTOR && cur < fat.length && guard < MAX_CHAIN_STEPS) {
      out.push(cur);
      cur = fat[cur];
      guard++;
    }
    return out;
  }

  /** 按普通扇区链读一段流 */
  private readByFat(start: number, size: number): Uint8Array {
    const out: Uint8Array = new Uint8Array(size);
    const sectors: number[] = this.chain(start, this.fat);
    let off: number = 0;
    for (let i = 0; i < sectors.length && off < size; i++) {
      const base: number = 512 + sectors[i] * this.sectorSize;
      const take: number = Math.min(this.sectorSize, size - off, this.data.length - base);
      if (take <= 0) {
        break;
      }
      out.set(this.data.subarray(base, base + take), off);
      off += take;
    }
    return out;
  }

  private readDirectory(): CfbEntry[] {
    const firstDir: number = this.u32(48);
    const sectors: number[] = this.chain(firstDir, this.fat);
    const entries: CfbEntry[] = [];
    const perSector: number = this.sectorSize / 128;
    for (let i = 0; i < sectors.length; i++) {
      const base: number = 512 + sectors[i] * this.sectorSize;
      for (let k = 0; k < perSector; k++) {
        const off: number = base + k * 128;
        if (off + 128 > this.data.length) {
          break;
        }
        const entry: CfbEntry = new CfbEntry();
        // offset 64 的 `cb` 是**字节数**（含结尾那 2 字节 NUL），必须先转成字符数
        // 再交给 readUtf16，否则名字会长出一倍、尾部粘满 NUL，`=== 'Workbook'` 永远不成立
        const nameBytes: number = this.u16(off + 64);
        const nameChars: number = nameBytes >= 4 ? (nameBytes >> 1) - 1 : 0;
        entry.name = XlsReader.trimNul(this.readUtf16(off, nameChars));
        entry.type = this.u8(off + 66);
        entry.start = this.u32(off + 116);
        // 流长度是 8 字节，低 4 字节对工作簿足够（判断 mini 流只看是否 < 4096）
        entry.size = this.u32(off + 120);
        entries.push(entry);
      }
    }
    return entries;
  }

  /** 读小流：先按 FAT 取"迷你流"母体，再按 miniFAT 在里面切 */
  private readMini(start: number, size: number): Uint8Array {
    const entries: CfbEntry[] = this.readDirectory();
    if (entries.length === 0) {
      throw new Error('工作簿目录为空');
    }
    const root: CfbEntry = entries[0];
    // 没有迷你流母体（有的生成器不建）时，按普通扇区链读，别傻等一个全 0 的结果
    if (root.start === END_OF_CHAIN || root.start === FREE_SECTOR || root.size <= 0) {
      return this.readByFat(start, size);
    }
    const mini: Uint8Array = this.readByFat(root.start, root.size);
    const miniFat: number[] = [];
    const miniFatSectors: number[] = this.chain(this.u32(60), this.fat);
    for (let i = 0; i < miniFatSectors.length; i++) {
      const base: number = 512 + miniFatSectors[i] * this.sectorSize;
      for (let j = 0; j < this.sectorSize / 4; j++) {
        miniFat.push(this.u32(base + j * 4));
      }
    }
    const out: Uint8Array = new Uint8Array(size);
    const sectors: number[] = this.chain(start, miniFat);
    let off: number = 0;
    for (let i = 0; i < sectors.length && off < size; i++) {
      const base: number = sectors[i] * this.miniSectorSize;
      const take: number = Math.min(this.miniSectorSize, size - off, mini.length - base);
      if (take <= 0) {
        break;
      }
      out.set(mini.subarray(base, base + take), off);
      off += take;
    }
    return out;
  }

  private readStream(start: number, size: number): Uint8Array {
    if (size <= 0 || start === END_OF_CHAIN || start === FREE_SECTOR) {
      throw new Error('工作簿流为空');
    }
    if (size < this.miniCutoff) {
      return this.readMini(start, size);
    }
    return this.readByFat(start, size);
  }

  /** 截掉目录项名字尾部可能残留的 NUL（名字区固定 64 字节，其余补 0） */
  private static trimNul(value: string): string {
    const idx: number = value.indexOf('\u0000');
    return idx < 0 ? value : value.substring(0, idx);
  }

  /**
   * 从容器里取出 `Workbook`（BIFF8）或 `Book`（BIFF5）流。
   *
   * 名字匹配失败时不直接放弃：少数工具（部分 WPS / 第三方库）写出的流名带前后缀，
   * 这时退而取"最大的那个流"——工作簿流必然是容器里最大的，比抛错更有用。
   * 真找不到才报错，并把目录清单写进消息里，方便下次一眼看出文件到底是什么。
   */
  private workbookStream(): Uint8Array {
    const entries: CfbEntry[] = this.readDirectory();
    let fallback: CfbEntry | null = null;
    for (let i = 0; i < entries.length; i++) {
      const entry: CfbEntry = entries[i];
      if (entry.type !== 2 || entry.size <= 0) {
        continue;
      }
      if (entry.name === 'Workbook' || entry.name === 'Book') {
        return this.readStream(entry.start, entry.size);
      }
      if (fallback === null || entry.size > fallback.size) {
        fallback = entry;
      }
    }
    if (fallback !== null) {
      return this.readStream(fallback.start, fallback.size);
    }
    throw new Error(`工作簿里没有找到 Workbook 流（容器内条目：${
      XlsReader.describeEntries(entries)}）`);
  }

  private static describeEntries(entries: CfbEntry[]): string {
    let out: string = '';
    for (let i = 0; i < entries.length; i++) {
      if (entries[i].type !== 2 && entries[i].type !== 5) {
        continue;
      }
      out += `${out.length > 0 ? '、' : ''}${entries[i].name}(${entries[i].size}B)`;
    }
    return out.length > 0 ? out : '空';
  }

  private readUtf16(off: number, chars: number): string {
    let out: string = '';
    for (let i = 0; i < chars; i++) {
      const p: number = off + i * 2;
      if (p + 1 >= this.data.length) {
        break;
      }
      out += String.fromCharCode(this.u16(p));
    }
    return out;
  }

  // ------------------------------------------------------------------ BIFF 解析

  private parse(): string[][] {
    this.checkSignature();
    this.sectorSize = 1 << this.u16(30);
    this.miniSectorSize = 1 << this.u16(32);
    this.miniCutoff = this.u32(56);
    this.buildFat();
    return this.parseWorkbook(this.workbookStream());
  }

  private parseWorkbook(wb: Uint8Array): string[][] {
    const cells: Map<number, Map<number, string>> = new Map();
    let sst: string[] = [];
    let inFirstSheet: boolean = false;
    let sheetSeen: boolean = false;
    let pendingR: number = -1;
    let pendingC: number = -1;
    let pos: number = 0;
    const n: number = wb.length;

    while (pos + 4 <= n) {
      const rt: number = wb[pos] | (wb[pos + 1] << 8);
      const rl: number = (wb[pos + 2] | (wb[pos + 3] << 8)) & 0xFFFF;
      const body: number = pos + 4;
      if (rl > MAX_RECORD_LEN || body + rl > n) {
        break;
      }

      if (rt === REC_SST) {
        const result: SstResult = this.parseSst(wb, body, rl);
        sst = result.strings;
        pos = result.next;
        continue;
      }

      if (rt === REC_BOF) {
        const dt: number = body + 4 <= n ? wb[body + 2] | (wb[body + 3] << 8) : DT_WORKBOOK_GLOBALS;
        if (dt === DT_WORKSHEET && !sheetSeen) {
          inFirstSheet = true;
          sheetSeen = true;
        }
        pos = body + rl;
        continue;
      }

      if (rt === REC_EOF) {
        if (inFirstSheet) {
          inFirstSheet = false;
        }
        pos = body + rl;
        continue;
      }

      if (!inFirstSheet) {
        pos = body + rl;
        continue;
      }

      if (rt === REC_LABELSST && rl >= 10) {
        const r: number = wb[body] | (wb[body + 1] << 8);
        const c: number = wb[body + 2] | (wb[body + 3] << 8);
        const idx: number = (wb[body + 6] | (wb[body + 7] << 8) | (wb[body + 8] << 16)
          | (wb[body + 9] << 24)) >>> 0;
        this.put(cells, r, c, idx < sst.length ? sst[idx] : '');
      } else if (rt === REC_LABEL && rl >= 9) {
        const r: number = wb[body] | (wb[body + 1] << 8);
        const c: number = wb[body + 2] | (wb[body + 3] << 8);
        const cch: number = wb[body + 6] | (wb[body + 7] << 8);
        const grbit: number = wb[body + 8];
        const cursor: SstCursor = new SstCursor(wb.subarray(0), [0]);
        cursor.pos = body + 9;
        this.put(cells, r, c, cursor.readChars(cch, (grbit & 0x01) === 1));
      } else if (rt === REC_STRING && rl >= 3 && pendingR >= 0) {
        const cch: number = wb[body] | (wb[body + 1] << 8);
        const grbit: number = wb[body + 2];
        const cursor: SstCursor = new SstCursor(wb.subarray(0), [0]);
        cursor.pos = body + 3;
        this.put(cells, pendingR, pendingC, cursor.readChars(cch, (grbit & 0x01) === 1));
        pendingR = -1;
        pendingC = -1;
      } else if (rt === REC_RK && rl >= 10) {
        const r: number = wb[body] | (wb[body + 1] << 8);
        const c: number = wb[body + 2] | (wb[body + 3] << 8);
        const rk: number = (wb[body + 6] | (wb[body + 7] << 8) | (wb[body + 8] << 16)
          | (wb[body + 9] << 24)) >>> 0;
        this.put(cells, r, c, XlsReader.numberToText(this.decodeRk(rk)));
      } else if (rt === REC_NUMBER && rl >= 14) {
        const r: number = wb[body] | (wb[body + 1] << 8);
        const c: number = wb[body + 2] | (wb[body + 3] << 8);
        const dv: DataView = new DataView(wb.buffer, wb.byteOffset + body + 6, 8);
        this.put(cells, r, c, XlsReader.numberToText(dv.getFloat64(0, true)));
      } else if (rt === REC_MULRK && rl >= 12) {
        const r: number = wb[body] | (wb[body + 1] << 8);
        const cFirst: number = wb[body + 2] | (wb[body + 3] << 8);
        const count: number = Math.floor((rl - 6) / 6);
        for (let k = 0; k < count; k++) {
          const p: number = body + 4 + k * 6 + 2;
          const rk: number = (wb[p] | (wb[p + 1] << 8) | (wb[p + 2] << 16) | (wb[p + 3] << 24)) >>> 0;
          this.put(cells, r, cFirst + k, XlsReader.numberToText(this.decodeRk(rk)));
        }
      } else if (rt === REC_FORMULA && rl >= 14) {
        const r: number = wb[body] | (wb[body + 1] << 8);
        const c: number = wb[body + 2] | (wb[body + 3] << 8);
        const b6: number = wb[body + 12];
        const b7: number = wb[body + 13];
        if (b6 === 0xFF && b7 === 0xFF) {
          // 结果不是数字：0=字符串（值在下一条 STRING 记录里），1/2/3=布尔/错误/空
          if (wb[body + 6] === 0x00) {
            pendingR = r;
            pendingC = c;
          } else if (wb[body + 6] === 0x01) {
            this.put(cells, r, c, wb[body + 8] === 0 ? 'FALSE' : 'TRUE');
          }
        } else {
          const dv: DataView = new DataView(wb.buffer, wb.byteOffset + body + 6, 8);
          this.put(cells, r, c, XlsReader.numberToText(dv.getFloat64(0, true)));
        }
      }

      pos = body + rl;
    }

    return XlsReader.toTable(cells);
  }

  private put(cells: Map<number, Map<number, string>>, r: number, c: number, text: string): void {
    if (r < 0 || r >= MAX_ROWS || c < 0 || c >= MAX_COLS) {
      return;
    }
    let row: Map<number, string> | undefined = cells.get(r);
    if (row === undefined) {
      row = new Map();
      cells.set(r, row);
    }
    row.set(c, text);
  }

  private parseSst(wb: Uint8Array, bodyOff: number, len: number): SstResult {
    const chunks: Uint8Array[] = [];
    chunks.push(wb.subarray(bodyOff, Math.min(bodyOff + len, wb.length)));
    let pos: number = bodyOff + len;
    while (pos + 4 <= wb.length) {
      const rt: number = wb[pos] | (wb[pos + 1] << 8);
      const rl: number = (wb[pos + 2] | (wb[pos + 3] << 8)) & 0xFFFF;
      if (rt !== REC_CONTINUE || pos + 4 + rl > wb.length) {
        break;
      }
      chunks.push(wb.subarray(pos + 4, pos + 4 + rl));
      pos += 4 + rl;
    }

    let total: number = 0;
    for (let i = 0; i < chunks.length; i++) {
      total += chunks[i].length;
    }
    const buf: Uint8Array = new Uint8Array(total);
    const starts: number[] = [];
    let off: number = 0;
    for (let i = 0; i < chunks.length; i++) {
      starts.push(off);
      buf.set(chunks[i], off);
      off += chunks[i].length;
    }

    const cursor: SstCursor = new SstCursor(buf, starts);
    const result: SstResult = new SstResult();
    if (buf.length < 8) {
      result.next = pos;
      return result;
    }
    cursor.pos = 0;
    const count: number = cursor.u32();
    cursor.u8();
    cursor.u8();
    cursor.u8();
    cursor.u8();

    const strings: string[] = [];
    for (let i = 0; i < count && cursor.pos < buf.length; i++) {
      const cch: number = cursor.u16();
      if (cursor.pos >= buf.length) {
        break;
      }
      const grbit: number = cursor.u8();
      let cRun: number = 0;
      let extSize: number = 0;
      if ((grbit & 0x08) !== 0) {
        cRun = cursor.u16();
      }
      if ((grbit & 0x04) !== 0) {
        extSize = cursor.u32() | 0;
      }
      strings.push(cursor.readChars(cch, (grbit & 0x01) === 1));
      if (cRun > 0) {
        cursor.skip(4 * cRun);
      }
      if (extSize > 0) {
        cursor.skip(extSize);
      }
    }
    result.strings = strings;
    result.next = pos;
    return result;
  }

  /**
   * RK 值解包。
   *
   * `rk` 是 32 位无符号数：最低位 = 是否除以 100，次低位 = 整数还是浮点。
   * 浮点分支里那 30 位是 IEEE754 double 的**高 30 位**，所以拼成 8 字节大端再读。
   */
  private decodeRk(rk: number): number {
    if ((rk & 0x02) !== 0) {
      return (rk | 0) >> 2;
    }
    const tmp: Uint8Array = new Uint8Array(8);
    const hi: number = (rk & 0xFFFFFFFC) >>> 0;
    tmp[0] = (hi >>> 24) & 0xFF;
    tmp[1] = (hi >>> 16) & 0xFF;
    tmp[2] = (hi >>> 8) & 0xFF;
    tmp[3] = hi & 0xFF;
    const dv: DataView = new DataView(tmp.buffer);
    let value: number = dv.getFloat64(0, false);
    if ((rk & 0x01) !== 0) {
      value = value / 100;
    }
    return value;
  }

  /** 数字转文本：整数不带小数点，避免"序号 1"变成"1.0" */
  private static numberToText(value: number): string {
    if (!isFinite(value)) {
      return '';
    }
    if (Number.isInteger(value) && Math.abs(value) < 1e15) {
      return value.toFixed(0);
    }
    return `${value}`;
  }

  /** 把稀疏单元格表铺成规整二维数组（缺列补空串） */
  private static toTable(cells: Map<number, Map<number, string>>): string[][] {
    if (cells.size === 0) {
      return [];
    }
    let maxRow: number = -1;
    let maxCol: number = -1;
    const rows: number[] = [];
    cells.forEach((row: Map<number, string>, r: number) => {
      rows.push(r);
      if (r > maxRow) {
        maxRow = r;
      }
      row.forEach((_text: string, c: number) => {
        if (c > maxCol) {
          maxCol = c;
        }
      });
    });
    rows.sort((a: number, b: number) => a - b);
    const table: string[][] = [];
    for (let i = 0; i < rows.length; i++) {
      const r: number = rows[i];
      const row: Map<number, string> | undefined = cells.get(r);
      const line: string[] = [];
      for (let c = 0; c <= maxCol; c++) {
        const text: string | undefined = row === undefined ? undefined : row.get(c);
        line.push(text === undefined ? '' : text);
      }
      table.push(line);
    }
    return table;
  }
}
