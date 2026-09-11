# Task 41 迁移后验证：读取注册表统计 + 抽查迁移条目
# 用法: python tool/verify_migration.py
import io
import json
import os
import zipfile
import re

REG = os.path.expandvars(r"%APPDATA%/com.wnacg/wnacg_pc/downloads/downloads.json")
MR_ROOT = "E:/Folders/Python/NovelDownload/wnacg"
IMG = re.compile(r"\.(jpe?g|png|webp|gif|bmp|avif)$", re.I)

reg = json.load(io.open(REG, encoding="utf-8"))
official = [e for e in reg if e.get("official") and e.get("isZip")]
migrated = [e for e in official
            if not e["zipPath"].startswith("C:/Users/Admin/AppData")]
print(f"注册表总数={len(reg)} 官方ZIP={len(official)} 其中 E 盘迁移条目={len(migrated)}")

bad = 0
for e in migrated:
    zp = e["zipPath"]
    ok_exist = os.path.isfile(zp)
    name_ok = re.match(r"^\d+-", os.path.basename(zp)) is not None
    if not (ok_exist and name_ok):
        bad += 1
        print("  异常:", zp, "存在=" , ok_exist, "命名=", name_ok)
        if bad > 10:
            break
print("命名/存在性异常:", bad)

# 抽 3 本核验 zip 可开 + 页数一致
import random
random.seed(41)
for e in random.sample(migrated, min(3, len(migrated))):
    try:
        with zipfile.ZipFile(e["zipPath"]) as z:
            pages = sum(1 for n in z.namelist()
                        if not n.endswith("/") and IMG.search(n))
        print("抽查:", os.path.basename(e["zipPath"])[:50],
              "| 注册页数:", e["count"], "| 实际:", pages,
              "| 一致:", pages == e["count"])
    except Exception as ex:
        print("抽查失败:", e["zipPath"], ex)
