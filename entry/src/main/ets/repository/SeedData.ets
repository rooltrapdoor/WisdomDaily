import { DbExecutor } from '../db/DbExecutor';
import { DaoSupport } from '../dao/DaoSupport';
import { SemesterDao } from '../dao/SemesterDao';
import { ScheduleTemplateDao } from '../dao/ScheduleTemplateDao';
import { TeacherDao } from '../dao/TeacherDao';
import { CourseDao } from '../dao/CourseDao';
import { ClassInfoDao } from '../dao/ClassInfoDao';
import { TimePeriodDao } from '../dao/TimePeriodDao';
import { AppSettingDao } from '../dao/AppSettingDao';
import { ScheduleTemplate } from '../model/ScheduleTemplate';
import { Semester } from '../model/Semester';
import { Teacher } from '../model/Teacher';
import { ClassGroup, Course, TimePeriod } from '../model/Course';
import { Tables } from '../db/TableSchema';
import { DateUtil } from '../common/DateUtil';
import { Logger } from '../common/Logger';

const TAG: string = 'SeedData';

/**
 * 首次安装的出厂数据。
 *
 * 与旧实现的区别：旧版把种子数据放在 `resources/rawfile/*.json`，
 * 启动时先复制到沙箱再读回来——即"用文件系统当数据库"。
 * 现在直接以 INSERT 写入表里，rawfile 目录彻底空掉，启动路径少一次 IO 与一次解析。
 */
export class SeedData {
  /** 库里一学期都没有时，写入默认学期与一门示例课；已有数据则什么都不做 */
  static async seedIfEmpty(exec: DbExecutor): Promise<boolean> {
    const semesterCount: number = await SemesterDao.count(exec);
    if (semesterCount > 0) {
      await AppSettingDao.ensureRow(exec);
      await AppSettingDao.repairPointers(exec);
      return false;
    }

    Logger.info(TAG, '检测到空库，写入出厂数据');

    // 1. 默认作息模板（受保护，不可删除）
    const template: ScheduleTemplate = ScheduleTemplate.standard('默认');
    const templateId: number = await ScheduleTemplateDao.insert(exec, template);

    // 2. 默认学期，绑定默认作息模板，开学日取本周一
    const semester: Semester = new Semester();
    semester.name = '默认学期';
    semester.total_weeks = 20;
    semester.start_date = DateUtil.toDateString(DateUtil.weekMonday(DateUtil.today()));
    semester.schedule_id = templateId;
    const semesterId: number = await SemesterDao.insert(exec, semester, 0);

    // 3. 示例教师 + 示例课程，让首启界面不是一片空白
    const teacher: Teacher = Teacher.create('教师名称', 20240001);
    teacher.department = '计算机科学与技术学院';
    teacher.sex = '男';
    const teacherId: number = await TeacherDao.insert(exec, teacher, semesterId, 0);

    const course: Course = Course.create('C++', '理论');
    course.course_score = 2;
    const courseRowId: number = await CourseDao.insert(exec, course, semesterId, teacherId, 0);

    const classId: string = await ClassInfoDao.ensureByName(exec, '22软件2');
    const group: ClassGroup = new ClassGroup();
    group.class_id = classId;
    group.class_name = '22软件2';
    group.population = 46;
    group.color = '#C77DFF';
    const groupId: number = await CourseDao.upsertGroup(exec, courseRowId, group, 0, group.class_id);

    const period: TimePeriod = TimePeriod.empty(semester.total_weeks);
    period.weekday = 1;
    period.start_time = 1;
    period.end_time = 2;
    period.class_room = '3403';
    await TimePeriodDao.insert(exec, groupId, period, semester.total_weeks);

    // 4. 当前指向
    await AppSettingDao.savePointers(exec, semesterId, teacherId);

    Logger.info(TAG, `出厂数据写入完成：semester=${semesterId}, teacher=${teacherId}, course=${courseRowId}`);
    return true;
  }

  /** 出厂数据是否完整（表存在且至少有一个学期） */
  static async isSeeded(exec: DbExecutor): Promise<boolean> {
    const count: number = await DaoSupport.scalarNumber(exec,
      `SELECT COUNT(*) AS v FROM ${Tables.SEMESTER}`, []);
    return count > 0;
  }
}
