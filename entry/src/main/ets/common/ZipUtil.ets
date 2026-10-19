/**
 * ZIP 压缩 / 解压 + 沙箱文件读写的薄封装（课表导出包与导入用）。
 *
 * 为什么单独成文件：`@ohos.zlib` 的 `compressFiles` / `decompressFile` 都是**路径进、路径出**
 * 的接口，而导出包要先在 `cacheDir` 里落一堆临时文件（xls + manifest.json + 说明），
 * 再压成一个 zip 交给系统"另存为"；导入则反过来。这一整套"建目录 → 写文件 → 打包 → 清理"
 * 的样板如果散在页面里，页面会被文件 IO 淹没，且清理逻辑漏一处就留下一堆缓存垃圾。
 *
 * 三条刻意的取舍（前两条都是踩过坑换来的）：
 *  1. **压出的 zip 条目名 = 各临时文件的 basename**（`compressFiles` 就是这么定的），
 *     所以临时文件名必须就是用户会看到的名字 —— 不再额外造目录层级。
 *  2. **`decompressFile` 的 `outFile` 是"解压目标目录"，且必须已经存在**：
 *     传一个还不存在的路径会直接抛 `900002 The input destination file is invalid`
 *     —— 官方错误码文档的处理步骤原文就是"调用 decompressFile 接口前，检查目标路径是否为已存在的
 *     目录。如果目录不存在，请先创建该目录"。所以 `decompress()` 内部先 `ensureDir(outDir)`；
 *     调用方仍应只提供**唯一**目录名（`uniqueTempDir`），因为目标目录中同名文件会被**覆盖**。
 *  3. 传进 `zlib` 的路径必须是**真实沙箱路径**：文件选择器给的 `file://docs/...` URI 它不认
 *     （`fileIo` 反而认得），所以导入要先 `fileIo` 读字节、写进 `cacheDir` 再解压。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
import { Logger } from './Logger';
import { errText } from './Util';

const TAG: string = 'ZipUtil';

export class ZipUtil {
  /** 路径是否存在（不区分文件/目录） */
  static exists(path: string): boolean {
    try {
      return fs.accessSync(path);
    } catch (e) {
      return false;
    }
  }

  /** 目录不存在则递归创建 */
  static ensureDir(dir: string): void {
    if (!ZipUtil.exists(dir)) {
      fs.mkdirSync(dir, true);
    }
  }

  /** 目录下的条目名（不含路径）；目录不存在返回空数组 */
  static list(dir: string): string[] {
    try {
      return ZipUtil.exists(dir) ? fs.listFileSync(dir) : [];
    } catch (e) {
      Logger.warn(TAG, `列举目录失败 ${dir}：${errText(e)}`);
      return [];
    }
  }

  /**
   * 递归删除文件或目录。
   *
   * 只用于清理本模块自己在 `cacheDir` 里建的临时目录，**永远不要在别处拿它删用户数据**：
   * 它不做任何保护性判断。
   */
  static removeTree(path: string): void {
    try {
      if (!ZipUtil.exists(path)) {
        return;
      }
      if (fs.statSync(path).isDirectory()) {
        const names: string[] = ZipUtil.list(path);
        for (let i = 0; i < names.length; i++) {
          ZipUtil.removeTree(`${path}/${names[i]}`);
        }
        fs.rmdirSync(path);
      } else {
        fs.unlinkSync(path);
      }
    } catch (e) {
      Logger.warn(TAG, `清理失败 ${path}：${errText(e)}`);
    }
  }

  /**
   * 在 `baseDir` 下造一个不会重名的目录名。
   *
   * 只造名字、**不创建**：解压类接口自己会 `ensureDir`（见 `decompress`），
   * 导出类用法则由调用方自己 `ensureDir`。唯一性是为了不覆盖上一次的产物。
   */
  static uniqueTempDir(baseDir: string, prefix: string): string {
    const stamp: string = `${new Date().getTime()}_${Math.floor(Math.random() * 100000)}`;
    return `${baseDir}/${prefix}_${stamp}`;
  }

  /** 写文本（UTF-8，覆盖写） */
  static writeText(path: string, text: string): void {
    const file: fs.File = fs.openSync(path,
      fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, text);
    } finally {
      fs.closeSync(file);
    }
  }

  /** 写字节（覆盖写）。先拷进一个"刚好这么大"的 ArrayBuffer，避免带上视图的起止偏移 */
  static writeBytes(path: string, bytes: Uint8Array): void {
    const buffer: ArrayBuffer = new ArrayBuffer(bytes.byteLength);
    new Uint8Array(buffer).set(bytes);
    const file: fs.File = fs.openSync(path,
      fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, buffer);
    } finally {
      fs.closeSync(file);
    }
  }

  static readText(path: string): string {
    return fs.readTextSync(path);
  }

  /** 读整个文件为字节；空文件返回长度 0 的数组（不抛异常） */
  static readBytes(path: string): Uint8Array {
    const size: number = fs.statSync(path).size;
    if (size <= 0) {
      return new Uint8Array(0);
    }
    const buffer: ArrayBuffer = new ArrayBuffer(size);
    const file: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      const read: number = fs.readSync(file.fd, buffer);
      return new Uint8Array(buffer, 0, read);
    } finally {
      fs.closeSync(file);
    }
  }

  /**
   * 把若干文件压成一个 zip（条目名 = 各文件的 basename，不保留目录层级）。
   *
   * `zipPath` 的父目录必须**已经存在**（`compressFile` 的 900002 同样指"目标路径无效"），
   * 调用方应先 `ensureDir`。
   */
  static async compress(files: string[], zipPath: string): Promise<void> {
    const options: zlib.Options = { level: zlib.CompressLevel.COMPRESS_LEVEL_DEFAULT_COMPRESSION };
    await zlib.compressFiles(files, zipPath, options);
  }

  /**
   * 解压 zip 到 `outDir`（目录不存在会被建出来 —— **必须**这样做，见文件头第 2 条）。
   *
   * 目标目录中同名文件会被覆盖，所以调用方要给它一个专属目录（`uniqueTempDir`）。
   */
  static async decompress(zipPath: string, outDir: string): Promise<void> {
    ZipUtil.ensureDir(outDir);
    await zlib.decompressFile(zipPath, outDir);
  }
}
