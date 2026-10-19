import { BackupExtensionAbility, BundleVersion } from '@kit.CoreFileKit';
import { Logger } from '../common/Logger';

const TAG: string = 'EntryBackupAbility';

/**
 * 系统备份 / 恢复扩展。
 *
 * 现在备份的内容是一整个关系库文件（含 WAL），不再是一堆零散的 JSON 文档：
 * 备份的一致性由数据库自身保证，不会出现"课表备份成功但名单备份失败"的半套数据。
 */
export default class EntryBackupAbility extends BackupExtensionAbility {
  async onBackup(): Promise<void> {
    Logger.info(TAG, 'onBackup：备份数据库文件');
  }

  async onRestore(bundleVersion: BundleVersion): Promise<void> {
    Logger.info(TAG, `onRestore：从版本 ${bundleVersion.code}/${bundleVersion.name} 恢复数据库`);
  }
}
