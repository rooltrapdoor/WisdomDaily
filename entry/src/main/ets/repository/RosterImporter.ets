import { Student } from '../model/Student';

/** 解析结果：能落库的学生 + 被跳过的行数 */
export class RosterParseResult {
  students: Student[] = [];
  /** 学号为空 / 学号重复 而被跳过的行数 */
  skipped: number = 0;
  /** 表头所在行（-1 = 没找到） */
  headerRow: number = -1;
}

/** 合并入库后的统计（由 ScheduleRepository.mergeRoster 返回） */
export class RosterImportResult {
  added: number = 0;
  updated: number = 0;
  unchanged: number = 0;
  skipped: number = 0;

  /** 一句话总结，用于提示条 */
  summary(): string {
    const parts: string[] = [];
    if (this.added > 0) {
      parts.push(`新增 ${this.added}`);
    }
    if (this.updated > 0) {
      parts.push(`更新 ${this.updated}`);
    }
    if (this.unchanged > 0) {
      parts.push(`未变动 ${this.unchanged}`);
    }
    if (this.skipped > 0) {
      parts.push(`跳过 ${this.skipped}`);
    }
    return parts.length === 0 ? '没有可导入的名单' : parts.join(' / ');
  }
}

/**
 * 班级名册 Excel 导入：把 `XlsReader` 读出的二维表解释成学生列表。
 *
 * 表头不是按固定行号认的 —— 模板第一行是合并的大标题（"课程名称+班级名称"），
 * 第二/三行才是表头（考勤、课堂状态还各占 5 列子表头）。所以这里**按内容找「学号」列**，
 * 以此定位表头行与各列下标，用户增删标题行、调列顺序都不会读错。
 *
 * 识别不到「学号」列时抛 `Error`，由调用方提示用户下载模板。
 */
export class RosterImporter {
  /** 全角字符 → 半角（中文输入法下输入学号非常容易带全角数字） */
  private static toHalfWidth(text: string): string {
    let out: string = '';
    for (let i = 0; i < text.length; i++) {
      const code: number = text.charCodeAt(i);
      if (code === 0x3000) {
        out += ' ';
      } else if (code >= 0xFF01 && code <= 0xFF5E) {
        out += String.fromCharCode(code - 0xFEE0);
      } else {
        out += text.charAt(i);
      }
    }
    return out;
  }

  /** 单元格文本清洗：全角转半角、去掉空白与首尾引号 */
  private static cell(value: string | undefined): string {
    if (value === undefined) {
      return '';
    }
    let text: string = RosterImporter.toHalfWidth(value).trim();
    while (text.length > 0 && (text.charAt(0) === "'" || text.charAt(0) === '’')) {
      text = text.substring(1).trim();
    }
    return text;
  }

  /** 姓名里的空白一般是误输入（"张 三"），去掉 */
  private static compact(value: string): string {
    let out: string = '';
    for (let i = 0; i < value.length; i++) {
      const ch: string = value.charAt(i);
      if (ch !== ' ' && ch !== '\t' && ch !== '\n' && ch !== '\r') {
        out += ch;
      }
    }
    return out;
  }

  private static normalizeSex(value: string): string {
    const text: string = value.trim();
    if (text.indexOf('男') >= 0) {
      return '男';
    }
    if (text.indexOf('女') >= 0) {
      return '女';
    }
    const upper: string = text.toUpperCase();
    if (upper === 'M' || upper === 'MALE' || upper === '1') {
      return '男';
    }
    if (upper === 'F' || upper === 'FEMALE' || upper === '0') {
      return '女';
    }
    return '';
  }

  /** 在表头行里按关键字找列下标（找不到返回 -1） */
  private static findColumn(header: string[], keyword: string): number {
    for (let c = 0; c < header.length; c++) {
      if (header[c].indexOf(keyword) >= 0) {
        return c;
      }
    }
    return -1;
  }

  static parse(table: string[][]): RosterParseResult {
    const result: RosterParseResult = new RosterParseResult();

    // 1) 按内容定位表头行
    let headerRow: number = -1;
    for (let r = 0; r < table.length && r < 20; r++) {
      const row: string[] = table[r];
      if (RosterImporter.findColumn(row, '学号') >= 0) {
        headerRow = r;
        break;
      }
    }
    if (headerRow < 0) {
      throw new Error('没找到「学号」列，请使用下载的模板填写后导入');
    }
    result.headerRow = headerRow;

    const header: string[] = table[headerRow];
    const noCol: number = RosterImporter.findColumn(header, '学号');
    let nameCol: number = RosterImporter.findColumn(header, '姓名');
    let sexCol: number = RosterImporter.findColumn(header, '性别');
    // 表头被改得认不出时，按模板的相对位置兜底（学号右边依次是姓名、性别）
    if (nameCol < 0) {
      nameCol = noCol + 1;
    }
    if (sexCol < 0) {
      sexCol = noCol + 2;
    }

    // 2) 逐行取数；学号是唯一键，空学号与重复学号都跳过
    const seen: Map<string, boolean> = new Map();
    for (let r = headerRow + 1; r < table.length; r++) {
      const row: string[] = table[r];
      const studentNo: string = RosterImporter.cell(row[noCol]);
      if (studentNo.length === 0 || studentNo === '学号') {
        continue;
      }
      if (seen.has(studentNo)) {
        result.skipped++;
        continue;
      }
      seen.set(studentNo, true);

      const student: Student = new Student();
      student.student_no = studentNo;
      student.name = RosterImporter.compact(RosterImporter.cell(row[nameCol]));
      student.sex = RosterImporter.normalizeSex(RosterImporter.cell(row[sexCol]));
      student.is_builtin = false;
      result.students.push(student);
    }

    if (result.students.length === 0) {
      throw new Error('文件里没有读到学生（学号一列是空的？）');
    }
    return result;
  }
}
