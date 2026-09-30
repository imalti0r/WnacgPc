# -*- coding: utf-8 -*-
"""把 shaders/src/*.frag (GLSL) 编译为 SPIR-V 并覆盖 shaders/*.frag 资源。
FragmentProgram.fromAsset 只接受 SPIR-V 字节码；GLSL 源码会报
"manifest could not be decoded"。用法: python tool/build_shaders.py
"""
import subprocess
import sys

GLSLANG = "tool/glslang/bin/glslang.exe"
SHADER_LIB = "D:/DevEnv/flutter/bin/cache/artifacts/engine/windows-x64/shader_lib"

for name in ("fsr", "a4k"):
    src = f"shaders/src/{name}.frag"
    out = f"shaders/{name}.frag"
    cmd = [GLSLANG, "-V", "--target-env", "opengl", "--amb", "--aml",
           "-DSKIA_GRAPHICS_BACKEND", f"-I{SHADER_LIB}", src, "-o", out]
    r = subprocess.run(cmd)
    if r.returncode != 0:
        sys.exit(f"{name} 编译失败")
    print(f"{name}: {out} 已更新")
