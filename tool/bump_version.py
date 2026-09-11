# -*- coding: utf-8 -*-
"""版本号一键更新：同步 pubspec.yaml / lib/version.dart / installer/wnacg_setup.iss。

用法:
  python tool/bump_version.py 1.0.2        # 指定版本号(build 号自动 +1)
  python tool/bump_version.py --build      # 只把 build 号 +1（版本号不变）
Windows exe 的版本资源由 flutter 工具链从 pubspec 自动注入，无需手动改。
"""
import re
import sys

PUBSPEC = "pubspec.yaml"
VERSION_DART = "lib/version.dart"
ISS = "installer/wnacg_setup.iss"


def read(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


def write(p, s):
    with open(p, "w", encoding="utf-8", newline="") as f:
        f.write(s)


def main():
    m = re.search(r"^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)", read(PUBSPEC), re.M)
    if not m:
        sys.exit("pubspec.yaml 里没找到 version: x.y.z+b")
    major, minor, patch, build = (int(x) for x in m.groups())

    if len(sys.argv) > 1 and sys.argv[1] == "--build":
        build += 1
    elif len(sys.argv) > 1:
        parts = sys.argv[1].split(".")
        if len(parts) != 3:
            sys.exit("版本号格式应为 x.y.z")
        major, minor, patch = (int(x) for x in parts)
        build += 1
    else:
        sys.exit(__doc__)

    ver = f"{major}.{minor}.{patch}"
    full = f"{ver}+{build}"

    s = read(PUBSPEC)
    s = re.sub(r"^version:\s*\S+.*$", f"version: {full}", s, count=1, flags=re.M)
    write(PUBSPEC, s)

    s = read(VERSION_DART)
    s = re.sub(r"const String appVersion = '[^']+';", f"const String appVersion = '{ver}';", s)
    s = re.sub(r"const int appBuild = \d+;", f"const int appBuild = {build};", s)
    write(VERSION_DART, s)

    s = read(ISS)
    s = re.sub(r'#define MyAppVersion "[^"]+"', f'#define MyAppVersion "{ver}"', s)
    write(ISS, s)

    print(f"版本已更新: {full} (pubspec / lib/version.dart / installer)")


if __name__ == "__main__":
    main()
