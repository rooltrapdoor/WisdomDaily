import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

/** 周几的中文label，下标 0 = 周一（与数据库 weekday 1..7 对应时需 -1） */
export const WEEKDAY_LABELS: string[] = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

/** 课程类型枚举，与 DB CHECK 约束保持一致 */
export const COURSE_TYPES: string[] = ['理论', '实验', '实践'];

/** 兜底色：写入数据库前的最后一道防线（ARGB，不透明浅灰） */
export const DEFAULT_COLOR: string = '#FFF0F0F0';

/**
 * 页面底色（也是窗口底色、系统状态栏与导航栏的底色）—— **唯一定义**。
 *
 * 页面根容器、`EntryAbility` 的窗口背景色与两条系统栏都取它。必取不可：底部
 * **手势导航条区域没有背景色 API**（`navigationBarColor` 只对三键导航生效），
 * 它的颜色是**透传窗口底色**来的 —— 窗口底色与页面底色一旦漂开，屏幕下方就是一条白边。
 *
 * 页面里另有底板、输入框、未选中胶囊碰巧同值，那些是**控件底色**、不是页面底色，
 * 保持字面量，不要改用它。
 */
export const PAGE_BG_COLOR: string = '#F3F4F6';

/** 界面主题色默认值（强调色：导航高亮、主按钮、滑杆等），ARGB 不透明蓝 */
export const THEME_COLOR_DEFAULT: string = '#FF1890FF';

/** "今天"高亮色默认值（周次栏今日日期徽标），ARGB 不透明蓝 */
export const TODAY_COLOR_DEFAULT: string = '#FF1890FF';

/** 提前提醒的默认提前量（分钟） */
export const NOTIFY_AHEAD_DEFAULT_MINUTES: number = 20;
/** 提前提醒的可用区间（分钟）：太小没意义，太大就变成"上一节课还没上完就提醒" */
export const NOTIFY_AHEAD_MIN_MINUTES: number = 1;
export const NOTIFY_AHEAD_MAX_MINUTES: number = 120;
/** 提醒第二天的课：触发时刻（24 小时制的整点） */
export const NOTIFY_NEXT_DAY_HOUR: number = 22;

export function nowMs(): number {
  return new Date().getTime();
}

/** 生成不可变业务主键（UUID v4） */
export function newUuid(): string {
  return util.generateRandomUUID(false).toLowerCase();
}

/** SQLite「数据库文件被锁」（`generic_error`）—— 典型来源是另一个进程正持着写锁 */
const CODE_DB_FILE_LOCKED: number = 14800024;
/** SQLite「某张表被锁」 */
const CODE_DB_TABLE_LOCKED: number = 14800025;

/**
 * 是不是「数据库被占用」这类**可以重试**的瞬时故障。
 *
 * 为什么必须单独识别它：桌面卡片与应用是两个进程、共用同一个库文件。一方开写事务时，
 * 另一方拿不到锁就会抛 14800024 —— 这不是数据坏了，等几毫秒再来一次就好；
 * 如果按普通错误处理，用户看到的就是"课表加载失败、整页空白"。
 *
 * 双保险：先认错误码；错误码被封装层抹掉时退回按 message 文本判。
 */
export function isDbLocked(e: Object): boolean {
  if (!(e instanceof Error)) {
    return false;
  }
  const code: number | undefined = (e as BusinessError).code;
  if (code === CODE_DB_FILE_LOCKED || code === CODE_DB_TABLE_LOCKED) {
    return true;
  }
  const message: string = (e as Error).message;
  return message.indexOf('database file is locked') >= 0
    || message.indexOf('database is locked') >= 0
    || message.indexOf('table in the database is locked') >= 0;
}

/** 等若干毫秒（重试退避用）。ArkTS 没有内置 sleep，这里用 setTimeout 包一层 */
export function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: (value: PromiseLike<void>) => void) => {
    setTimeout(() => {
      resolve(Promise.resolve());
    }, ms);
  });
}

/** 把任意异常转成可读字符串（错误码 + 消息），避免日志出现 [object Object] */
export function errText(e: Object): string {
  if (e instanceof Error) {
    const error: Error = e as Error;
    const be: BusinessError = e as BusinessError;
    const code: number | undefined = be.code;
    return code === undefined ? error.message : `code=${code}, message=${error.message}`;
  }
  return JSON.stringify(e);
}

/**
 * 日志专用的详细错误描述：在 `errText` 的基础上补一个"出错位置"。
 *
 * 分工：`errText` 给用户看（越短越好），本函数给日志看（越准越好）。
 * `TypeError` 这类运行时错误只有 message（例如 `undefined is not callable`）时，
 * 光看消息无法知道是谁被当成函数调用了 —— 此时调用栈里的第一行业务帧是唯一线索。
 * 栈在 release 包里可能被裁剪（取不到就只返回 `errText` 的结果，不额外报错）。
 */
export function errDetail(e: Object): string {
  const base: string = errText(e);
  if (!(e instanceof Error)) {
    return base;
  }
  const stack: string | undefined = (e as Error).stack;
  if (stack === undefined || stack.length === 0) {
    return base;
  }
  const lines: string[] = stack.split('\n');
  const where: string = lines.length > 1 ? lines[1].trim() : '';
  return where.length === 0 ? base : `${base} @ ${where}`;
}

/** 数字兜底：null / undefined / NaN → 默认值 */
export function numOr(value: number | null | undefined, fallback: number): number {
  if (value === null || value === undefined) {
    return fallback;
  }
  return isNaN(value) ? fallback : value;
}

/** 夹紧到 [min, max] */
export function clamp(value: number, min: number, max: number): number {
  if (value < min) {
    return min;
  }
  return value > max ? max : value;
}

/**
 * 提前提醒分钟数归一化：脏值（undefined / NaN / 越界）一律收进合法区间。
 *
 * 为什么要收敛而不是直接拒绝：这个值来自一个**手输输入框**，也会从库里读回来。
 * 落库前收一次、读库后再收一次，任何一环写进 0 或 100000 都不会让提醒逻辑崩掉
 * （0 会让提醒与上课同时发生，过大则提前量盖过整个上午）。
 */
export function clampNotifyMinutes(value: number | null | undefined): number {
  const raw: number = numOr(value, NOTIFY_AHEAD_DEFAULT_MINUTES);
  return Math.round(clamp(raw, NOTIFY_AHEAD_MIN_MINUTES, NOTIFY_AHEAD_MAX_MINUTES));
}

/**
 * 颜色归一化：把 `#RGB` / `#RRGGBB` / `#AARRGGBB` 全部统一成 8 位大写 `#AARRGGBB`。
 *
 * - 6 位 `#RRGGBB` 视为不透明（补 `FF` Alpha），兼容历史数据；
 * - 拾色器产出的颜色带真实 Alpha，直接透传；
 * - 数据库层用 CHECK 约束（6 位或 8 位十六进制）兜住格式。
 */
export function normalizeColor(input: string | null | undefined): string {
  if (!input) {
    return DEFAULT_COLOR;
  }
  let hex: string = input.trim().replace('#', '').toUpperCase();
  if (hex.length === 3) {
    hex = `${hex[0]}${hex[0]}${hex[1]}${hex[1]}${hex[2]}${hex[2]}`;
  }
  if (hex.length === 6) {
    hex = `FF${hex}`;
  }
  if (hex.length !== 8 || !/^[0-9A-F]{8}$/.test(hex)) {
    return DEFAULT_COLOR;
  }
  return `#${hex}`;
}

/** 取纯色 6 位 RGB（**不带 `#` 前缀**，丢弃 Alpha），用于 HSV 计算与纯色渐变端点 */
export function rgbHexOf(input: string | null | undefined): string {
  return normalizeColor(input).substring(3);
}

/**
 * "配置型"颜色归一化 + 回退：`#RGB` / `#RRGGBB` / `#AARRGGBB` → 8 位 ARGB；
 * 空或格式非法时返回 `fallback`（而不是统一兜底成灰）。
 *
 * 与 `normalizeColor` 的区别：后者用于"课程色"这类必须落库成合法颜色的场景，
 * 任何异常都兜底成 DEFAULT_COLOR；而主题色这类界面配置如果被静默改成灰色，
 * 用户会一头雾水，所以这里保留调用方给的默认值。
 */
export function colorOr(input: string | null | undefined, fallback: string): string {
  if (!input) {
    return fallback;
  }
  let hex: string = input.trim().replace('#', '').toUpperCase();
  if (hex.length === 3) {
    hex = `${hex[0]}${hex[0]}${hex[1]}${hex[1]}${hex[2]}${hex[2]}`;
  }
  if (hex.length === 6) {
    hex = `FF${hex}`;
  }
  return /^[0-9A-F]{8}$/.test(hex) ? `#${hex}` : fallback;
}

/** 取 Alpha 通道（0~1，1 = 不透明）；6 位或解析失败按不透明处理 */
export function alphaOf(input: string | null | undefined): number {
  if (!input) {
    return 1;
  }
  const hex: string = input.trim().replace('#', '').toUpperCase();
  if (hex.length === 8 && /^[0-9A-F]{8}$/.test(hex)) {
    return parseInt(hex.substring(0, 2), 16) / 255;
  }
  return 1;
}

/** 给 6 位 RGB（或 8 位 ARGB，原 Alpha 被覆盖）设置透明度，返回 8 位 `#AARRGGBB` */
export function withAlpha(input: string, alpha01: number): string {
  // rgbHexOf 返回不带 '#' 的 6 位 RRGGBB，不能再 substring 截位（否则只剩 5 位）
  const rgb: string = rgbHexOf(input);
  const a255: number = Math.round(clamp(alpha01, 0, 1) * 255);
  const aHex: string = a255.toString(16).toUpperCase().padStart(2, '0');
  return `#${aHex}${rgb}`;
}

/** sRGB 单通道（0~255）→ 线性光值；WCAG 2.x 相对亮度的第一步 */
function linearChannel(channel: number): number {
  const c: number = clamp(channel, 0, 255) / 255;
  // 低亮度段走线性近似（sRGB 传递函数的 12.92 分段），否则直接用幂函数
  return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
}

/**
 * 颜色的 WCAG 2.x 相对亮度（0~1，黑 0 / 白 1）。
 * 含 Alpha 时先按 sRGB 合成到白底（课程卡片渲染在白色页面上），再线性化求加权和。
 */
export function luminanceOf(color: string): number {
  const normalized: string = normalizeColor(color);
  const a: number = parseInt(normalized.substring(1, 3), 16) / 255;
  const hex: string = normalized.substring(3);
  const r: number = parseInt(hex.substring(0, 2), 16) * a + 255 * (1 - a);
  const g: number = parseInt(hex.substring(2, 4), 16) * a + 255 * (1 - a);
  const b: number = parseInt(hex.substring(4, 6), 16) * a + 255 * (1 - a);
  return 0.2126 * linearChannel(r) + 0.7152 * linearChannel(g) + 0.0722 * linearChannel(b);
}

/**
 * 取与背景对比最强的前景色：**只返回纯黑或纯白**，二者取对比度更高的那个。
 *
 * 判据用 WCAG 相对亮度（见 `luminanceOf`），而不是 BT.601 的
 * `0.299R + 0.587G + 0.114B` 加权和 + 阈值 128。原因：BT.601 给蓝色只有 0.114 权重，
 * 会把 `#1890FF` 这类中亮蓝/红判成"深色"而配上白字 —— 实测黑字对比度 6.5:1、
 * 白字只有 3.2:1，正是"字和底色对比不够强"的来源。
 *
 * 黑白两种字色的对比度分别是 `(L+0.05)/0.05` 与 `1.05/(L+0.05)`
 * （WCAG 对比度公式），两者在 `L = 0.1791` 处恰好相等：亮度高于该点黑字对比更强，
 * 低于该点白字更强 —— 所以这里取的是"对比度最大"而非"看起来深还是浅"。
 */
export function textColorOf(backgroundColor: string): string {
  return luminanceOf(backgroundColor) > 0.1791 ? '#000000' : '#FFFFFF';
}

/** RGB 颜色结构 */
export interface RGB {
  r: number;
  g: number;
  b: number;
}

/** HSV 颜色结构（h:0-360, s:0-1, v:0-1） */
export interface HSV {
  h: number;
  s: number;
  v: number;
}

/** HEX（`#RRGGBB` 或 `#AARRGGBB`）→ RGB（丢弃 Alpha）；解析失败返回 undefined */
export function hexToRgb(hex: string): RGB | undefined {
  if (!hex) {
    return undefined;
  }
  const raw: string = hex.trim().replace('#', '').toUpperCase();
  let str: string;
  if (raw.length === 8 && /^[0-9A-F]{8}$/.test(raw)) {
    str = raw.substring(2);
  } else if (raw.length === 6 && /^[0-9A-F]{6}$/.test(raw)) {
    str = raw;
  } else if (raw.length === 3 && /^[0-9A-F]{3}$/.test(raw)) {
    str = `${raw[0]}${raw[0]}${raw[1]}${raw[1]}${raw[2]}${raw[2]}`;
  } else {
    return undefined;
  }
  return {
    r: parseInt(str.substring(0, 2), 16),
    g: parseInt(str.substring(2, 4), 16),
    b: parseInt(str.substring(4, 6), 16)
  };
}

/** RGB → 6 位 HEX */
export function rgbToHex(r: number, g: number, b: number): string {
  const clampedR: number = clamp(Math.round(r), 0, 255);
  const clampedG: number = clamp(Math.round(g), 0, 255);
  const clampedB: number = clamp(Math.round(b), 0, 255);
  const toHex = (n: number): string => {
    const s: string = n.toString(16);
    return s.length === 1 ? '0' + s : s;
  };
  return `#${toHex(clampedR)}${toHex(clampedG)}${toHex(clampedB)}`.toUpperCase();
}

/** RGB → HSV */
export function rgbToHsv(r: number, g: number, b: number): HSV {
  const rr: number = r / 255;
  const gg: number = g / 255;
  const bb: number = b / 255;
  const max: number = Math.max(rr, gg, bb);
  const min: number = Math.min(rr, gg, bb);
  const diff: number = max - min;
  let h: number = 0;
  if (diff !== 0) {
    if (max === rr) {
      h = ((gg - bb) / diff + 6) % 6;
    } else if (max === gg) {
      h = (bb - rr) / diff + 2;
    } else {
      h = (rr - gg) / diff + 4;
    }
    h *= 60;
  }
  return {
    h: Math.round(h),
    s: max === 0 ? 0 : diff / max,
    v: max
  };
}

/** HSV → RGB */
export function hsvToRgb(h: number, s: number, v: number): RGB {
  const hh: number = ((h % 360) + 360) % 360 / 60;
  const c: number = v * s;
  const x: number = c * (1 - Math.abs(hh % 2 - 1));
  const m: number = v - c;
  let r: number = 0;
  let g: number = 0;
  let b: number = 0;
  if (hh < 1) {
    r = c; g = x; b = 0;
  } else if (hh < 2) {
    r = x; g = c; b = 0;
  } else if (hh < 3) {
    r = 0; g = c; b = x;
  } else if (hh < 4) {
    r = 0; g = x; b = c;
  } else if (hh < 5) {
    r = x; g = 0; b = c;
  } else {
    r = c; g = 0; b = x;
  }
  return {
    r: (r + m) * 255,
    g: (g + m) * 255,
    b: (b + m) * 255
  };
}

/** 给定色相在最高饱和度/明度下的纯色 HEX（用于绘制方形拾色器底色） */
export function hueColor(h: number): string {
  const rgb: RGB = hsvToRgb(h, 1, 1);
  return rgbToHex(rgb.r, rgb.g, rgb.b);
}

/** HEX → HSV；解析失败返回 h=0,s=0,v=1 */
export function hexToHsv(hex: string): HSV {
  const rgb: RGB | undefined = hexToRgb(hex);
  if (rgb === undefined) {
    return { h: 0, s: 0, v: 1 };
  }
  return rgbToHsv(rgb.r, rgb.g, rgb.b);
}

/** HSV → HEX */
export function hsvToHex(h: number, s: number, v: number): string {
  const rgb: RGB = hsvToRgb(h, s, v);
  return rgbToHex(rgb.r, rgb.g, rgb.b);
}

/** 名称清洗：去掉首尾空白与控制字符，限制长度；空则返回兜底名 */
export function cleanName(raw: string | null | undefined, fallback: string, maxLength: number = 64): string {
  if (!raw) {
    return fallback;
  }
  const cleaned: string = raw.trim().replace(/[\r\n\t]/g, ' ');
  if (cleaned.length === 0) {
    return fallback;
  }
  return cleaned.length > maxLength ? cleaned.substring(0, maxLength) : cleaned;
}

/**
 * 学号（编号类字符串）的自然序比较：连续数字按数值比，其余按字符比。
 *
 * 纯字典序会把 "10" 排在 "2" 前面（名册按学号升序时看着像乱序），
 * 所以数字段必须整段解析成数值再比。短前缀相同则返回更短的在前。
 */
export function compareNo(a: string, b: string): number {
  const left: string = a === undefined || a === null ? '' : a;
  const right: string = b === undefined || b === null ? '' : b;
  let i: number = 0;
  let j: number = 0;
  while (i < left.length && j < right.length) {
    const ca: number = left.charCodeAt(i);
    const cb: number = right.charCodeAt(j);
    if (isDigit(ca) && isDigit(cb)) {
      let na: number = 0;
      let nb: number = 0;
      while (i < left.length && isDigit(left.charCodeAt(i))) {
        na = na * 10 + (left.charCodeAt(i) - 48);
        i++;
      }
      while (j < right.length && isDigit(right.charCodeAt(j))) {
        nb = nb * 10 + (right.charCodeAt(j) - 48);
        j++;
      }
      if (na !== nb) {
        return na < nb ? -1 : 1;
      }
    } else {
      if (ca !== cb) {
        return ca < cb ? -1 : 1;
      }
      i++;
      j++;
    }
  }
  if (left.length - i === right.length - j) {
    return 0;
  }
  return left.length - i < right.length - j ? -1 : 1;
}

function isDigit(code: number): boolean {
  return code >= 48 && code <= 57;
}

/** 判断星期几是否落在 week_nums 里（数组有序/无序都支持） */
export function weekContains(weekNums: number[], week: number): boolean {
  for (let i = 0; i < weekNums.length; i++) {
    if (weekNums[i] === week) {
      return true;
    }
  }
  return false;
}

/** 生成连续周次数组 [1..totalWeeks] */
export function fullWeekRange(totalWeeks: number): number[] {
  const result: number[] = [];
  for (let i = 1; i <= totalWeeks; i++) {
    result.push(i);
  }
  return result;
}

/** 数组去重 + 越界过滤 + 升序，用于周次集合落库前的规范化 */
export function normalizeWeeks(weeks: number[], maxWeek: number): number[] {
  const result: number[] = [];
  for (let i = 0; i < weeks.length; i++) {
    const w: number = Math.floor(weeks[i]);
    if (w >= 1 && w <= maxWeek && result.indexOf(w) < 0) {
      result.push(w);
    }
  }
  result.sort((a: number, b: number) => a - b);
  return result;
}
