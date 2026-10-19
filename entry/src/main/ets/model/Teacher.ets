import { TeacherRow } from './Rows';
import { Course } from './Course';

/** 教师（对应 teacher 表）。(学期, 工号, 姓名) 唯一，重复导入同一教师只做字段合并 */
@ObservedV2
export class Teacher {
  @Trace id: number = 0;
  /** 工号，业务上唯一，如 2024***25 */
  @Trace staff_no: number = 0;
  @Trace name: string = '请修改教师姓名';
  @Trace department: string | undefined = undefined;
  @Trace age: number | undefined = undefined;
  @Trace sex: string | undefined = undefined;
  @Trace telephone: string | undefined = undefined;

  static create(name: string, staffNo: number): Teacher {
    const teacher: Teacher = new Teacher();
    teacher.name = name;
    teacher.staff_no = staffNo;
    return teacher;
  }

  static fromRow(row: TeacherRow): Teacher {
    const teacher: Teacher = new Teacher();
    teacher.id = row.id;
    teacher.staff_no = row.staff_no;
    teacher.name = row.name;
    teacher.department = row.department;
    teacher.age = row.age;
    teacher.sex = row.sex;
    teacher.telephone = row.telephone;
    return teacher;
  }

  toRow(semesterId: number): TeacherRow {
    return {
      id: this.id,
      semester_id: semesterId,
      staff_no: this.staff_no,
      name: this.name,
      department: this.department,
      age: this.age,
      sex: this.sex,
      telephone: this.telephone,
      sort_order: 0
    };
  }

  displayName(): string {
    return `${this.staff_no} ${this.name}`;
  }

  clone(): Teacher {
    const copy: Teacher = new Teacher();
    copy.id = this.id;
    copy.staff_no = this.staff_no;
    copy.name = this.name;
    copy.department = this.department;
    copy.age = this.age;
    copy.sex = this.sex;
    copy.telephone = this.telephone;
    return copy;
  }
}

/** 一位教师 + 他的课程（旧结构 TeacherCourse 的等价物） */
@ObservedV2
export class TeacherCourses {
  @Trace teacher: Teacher = new Teacher();
  @Trace courses: Course[] = [];

  static of(teacher: Teacher, courses: Course[]): TeacherCourses {
    const holder: TeacherCourses = new TeacherCourses();
    holder.teacher = teacher;
    holder.courses = courses;
    return holder;
  }

  /** 同 学期 + 同教师 → 同一份课表；教师用 id 判定，不用姓名 */
  static indexOfTeacher(list: TeacherCourses[], teacherId: number): number {
    for (let i = 0; i < list.length; i++) {
      if (list[i].teacher.id === teacherId) {
        return i;
      }
    }
    return -1;
  }

  findCourse(courseName: string, courseType: string): Course | undefined {
    for (let i = 0; i < this.courses.length; i++) {
      const c: Course = this.courses[i];
      if (c.course_name === courseName && c.course_type === courseType) {
        return c;
      }
    }
    return undefined;
  }

  countPeriods(): number {
    let total: number = 0;
    for (let i = 0; i < this.courses.length; i++) {
      total += this.courses[i].countPeriods();
    }
    return total;
  }

  clone(): TeacherCourses {
    return TeacherCourses.of(this.teacher.clone(), this.courses.map((c: Course) => c.clone()));
  }
}
