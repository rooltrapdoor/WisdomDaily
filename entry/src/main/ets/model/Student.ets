import { ClassInfoRow, StudentRow } from './Rows';
import { newUuid } from '../common/Util';

/** 班级档案（对应 class_info 表）。class_id 不可变，班级改名不影响任何关联 */
@ObservedV2
export class ClassInfo {
  @Trace class_id: string = '';
  @Trace class_name: string = '';

  static create(name: string): ClassInfo {
    const info: ClassInfo = new ClassInfo();
    info.class_id = newUuid();
    info.class_name = name;
    return info;
  }

  static fromRow(row: ClassInfoRow): ClassInfo {
    const info: ClassInfo = new ClassInfo();
    info.class_id = row.class_id;
    info.class_name = row.class_name;
    return info;
  }
}

/**
 * 学生（对应 student 表）。
 *
 * 与旧结构的差异：
 *  - `telephone` 改为 string，保留前导 0，支持国际格式；
 *  - 修正字段拼写 `remake` → `remark`（迁移时自动兼容旧数据）；
 *  - 不再冗余存 `class_name`，需要时由 class_info 联表取得，杜绝两处名字不一致。
 */
@ObservedV2
export class Student {
  @Trace id: number = 0;
  /** 学号 */
  @Trace student_no: string = '';
  @Trace class_id: string = '';
  @Trace name: string = '';
  @Trace age: number | undefined = undefined;
  @Trace sex: string | undefined = undefined;
  @Trace telephone: string | undefined = undefined;
  @Trace remark: string | undefined = undefined;
  /** 系统预置数据，首次导入后置 false */
  @Trace is_builtin: boolean = false;

  static fromRow(row: StudentRow): Student {
    const student: Student = new Student();
    student.id = row.id;
    student.student_no = row.student_no;
    student.class_id = row.class_id;
    student.name = row.name;
    student.age = row.age;
    student.sex = row.sex;
    student.telephone = row.telephone;
    student.remark = row.remark;
    student.is_builtin = row.is_builtin;
    return student;
  }

  toRow(classId: string, sortOrder: number): StudentRow {
    return {
      id: this.id,
      student_no: this.student_no,
      class_id: classId,
      class_name: '',
      name: this.name,
      age: this.age,
      sex: this.sex,
      telephone: this.telephone,
      remark: this.remark,
      is_builtin: this.is_builtin,
      sort_order: sortOrder
    };
  }

  clone(): Student {
    const copy: Student = new Student();
    copy.id = this.id;
    copy.student_no = this.student_no;
    copy.class_id = this.class_id;
    copy.name = this.name;
    copy.age = this.age;
    copy.sex = this.sex;
    copy.telephone = this.telephone;
    copy.remark = this.remark;
    copy.is_builtin = this.is_builtin;
    return copy;
  }
}

/** 一个班级的名单（旧 ClassStudent 的等价物） */
@ObservedV2
export class ClassRoster {
  @Trace class_id: string = '';
  @Trace class_name: string = '';
  @Trace students: Student[] = [];

  static of(info: ClassInfo, students: Student[]): ClassRoster {
    const roster: ClassRoster = new ClassRoster();
    roster.class_id = info.class_id;
    roster.class_name = info.class_name;
    roster.students = students;
    return roster;
  }

  count(): number {
    return this.students.length;
  }

  find(studentNo: string): Student | undefined {
    for (let i = 0; i < this.students.length; i++) {
      if (this.students[i].student_no === studentNo) {
        return this.students[i];
      }
    }
    return undefined;
  }
}
