#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把工程目录 harmonyos_course_app 改名为 WisdomDaily，并同步 DevEco 的 IDE 元数据。

为什么单独一个脚本：Windows 上无法重命名"正被 DevEco 打开的目录"，
所以这一步必须在**关闭 DevEco Studio 之后**单独执行。

用法（在任意目录）：
    python migrate_folder_name.py --check     # 只体检，不动任何东西
    python migrate_folder_name.py             # 执行改名 + 修 IDE 元数据

做完即可删除本脚本。
"""
import os
import re
import subprocess
import sys

PARENT = r"F:\Codes\harmony"
OLD_NAME = "harmonyos_course_app"
NEW_NAME = "WisdomDaily"
OLD_DIR = os.path.join(PARENT, OLD_NAME)
NEW_DIR = os.path.join(PARENT, NEW_NAME)

CHECK_ONLY = "--check" in sys.argv

# DevEco 进程名（子串匹配，小写比较）
IDE_PROCS = ("devecostudio", "deveco")


def ide_running():
    try:
        p = subprocess.run(["tasklist", "/FO", "CSV"], capture_output=True,
                           text=True, errors="replace", timeout=60)
    except Exception as e:
        return None, "无法枚举进程：%s" % e
    hits = []
    for line in p.stdout.splitlines():
        low = line.lower()
        if any(k in low for k in IDE_PROCS):
            hits.append(line.split(",")[0].strip('"'))
    return hits, None


def fix_ide_metadata(root):
    """同步 .idea 里所有含旧工程名/旧路径的地方。返回改动清单。"""
    changes = []

    # 1) .idea/modules.xml —— 指向的 .iml 文件名
    p = os.path.join(root, ".idea", "modules.xml")
    if os.path.exists(p):
        t = open(p, encoding="utf-8").read()
        n = t.replace(OLD_NAME + ".iml", NEW_NAME + ".iml")
        if n != t:
            open(p, "w", encoding="utf-8", newline="").write(n)
            changes.append(".idea/modules.xml：.iml 引用改名")

    # 2) .iml 文件本身
    old_iml = os.path.join(root, ".idea", "modules", OLD_NAME + ".iml")
    new_iml = os.path.join(root, ".idea", "modules", NEW_NAME + ".iml")
    if os.path.exists(old_iml):
        os.rename(old_iml, new_iml)
        changes.append(".idea/modules/%s.iml → %s.iml" % (OLD_NAME, NEW_NAME))

    # 3) .idea/workspace.xml —— Hvigor run configuration 名
    p = os.path.join(root, ".idea", "workspace.xml")
    if os.path.exists(p):
        t = open(p, encoding="utf-8").read()
        n = t.replace("Hvigor." + OLD_NAME, "Hvigor." + NEW_NAME)
        n = n.replace('name="%s [' % OLD_NAME, 'name="%s [' % NEW_NAME)
        if n != t:
            open(p, "w", encoding="utf-8", newline="").write(n)
            changes.append(".idea/workspace.xml：run configuration 名")

    # 4) .idea/.deveco/**/*.cache.json —— 绝对路径 + BUNDLE_NAME
    deveco = os.path.join(root, ".idea", ".deveco")
    for dp, _dn, fn in os.walk(deveco):
        for f in fn:
            if not f.endswith(".json"):
                continue
            fp = os.path.join(dp, f)
            t = open(fp, encoding="utf-8").read()
            n = t.replace(OLD_DIR.replace("\\", "\\\\"), NEW_DIR.replace("\\", "\\\\"))
            n = n.replace(OLD_DIR, NEW_DIR)
            n = n.replace("harmonyos_course_app", NEW_NAME)
            if n != t:
                open(fp, "w", encoding="utf-8", newline="").write(n)
                changes.append(os.path.relpath(fp, root) + "：路径/BUNDLE_NAME")
    return changes


def main():
    print("旧目录 :", OLD_DIR, "(存在=%s)" % os.path.isdir(OLD_DIR))
    print("新目录 :", NEW_DIR, "(已存在=%s)" % os.path.exists(NEW_DIR))

    if not os.path.isdir(OLD_DIR):
        print("\n旧目录不存在 —— 可能已经改过名了。")
        return 1
    if os.path.exists(NEW_DIR):
        print("\n目标目录已存在，拒绝继续（避免覆盖）。")
        return 1

    procs, err = ide_running()
    if err:
        print("\n" + err)
    if procs:
        print("\n! DevEco 正在运行：", ", ".join(sorted(set(procs))))
        print("  请先**完全退出 DevEco Studio**（含托盘/所有窗口），再重新运行本脚本。")
        print("  在 IDE 打开状态下 os.rename 必然报 WinError 32，本次不做任何改动。")
        return 2
    print("\nDevEco 未在运行 —— 可以改名。")

    if CHECK_ONLY:
        print("\n--check：到此为止，未做任何改动。")
        return 0

    try:
        os.rename(OLD_DIR, NEW_DIR)
    except OSError as e:
        print("\n改名失败：%s %s" % (type(e).__name__, e))
        print("（无副作用，可重试。）")
        return 3
    print("目录已改名：%s → %s" % (OLD_DIR, NEW_DIR))

    print("\n同步 IDE 元数据：")
    for c in fix_ide_metadata(NEW_DIR):
        print("  -", c)

    print("\n完成。下一步：")
    print("  1. 用 DevEco 打开", NEW_DIR, "（会重新索引，属正常）")
    print("  2. File → Project Structure → Signing Configs：取消再勾选")
    print("     \"Automatically generate signature\" 重新签名（bundleName 已改，旧 .p7b 不匹配）")
    print("  3. Build → Build Hap(s) 验证；卡片需重新添加")
    return 0


if __name__ == "__main__":
    sys.exit(main())
