# -*- coding: utf-8 -*-
"""WNACG 二次元图标生成器 (Pillow)
绘制一个双马尾少女半身像图标，输出 1024px PNG 与多尺寸 .ico
用法: python tool/make_icon.py [输出目录]
"""
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
SS = 2  # 超采样倍数
W = SIZE * SS

# ---------- 调色板 ----------
BG_TOP = (255, 158, 199)      # 樱粉
BG_BOT = (124, 107, 240)      # 紫罗兰
GLOW = (255, 230, 245)
HAIR = (255, 143, 200)        # 发色粉
HAIR_DARK = (214, 92, 160)    # 发色描边/阴影
HAIR_LIGHT = (255, 205, 230)  # 高光
SKIN = (255, 233, 218)
SKIN_LINE = (232, 160, 140)
EYE_TOP = (74, 63, 143)
EYE_BOT = (126, 200, 255)
CLOTH = (90, 79, 207)
CLOTH_DARK = (64, 55, 160)
BOW = (255, 96, 130)

def P(*vals):
    """把 1024 基准坐标放大到超采样画布"""
    return [v * SS for v in vals]

def bezier(p0, p1, p2, p3, n=48):
    pts = []
    for i in range(n + 1):
        t = i / n
        mt = 1 - t
        x = (mt**3 * p0[0] + 3 * mt**2 * t * p1[0]
             + 3 * mt * t**2 * p2[0] + t**3 * p3[0])
        y = (mt**3 * p0[1] + 3 * mt**2 * t * p1[1]
             + 3 * mt * t**2 * p2[1] + t**3 * p3[1])
        pts.append((x, y))
    return pts

def poly(draw, pts, fill, outline=None, width=0):
    pts = [(float(x), float(y)) for x, y in pts]
    draw.polygon(pts, fill=fill)
    if outline and width > 0:
        draw.line(pts + [pts[0]], fill=outline, width=width, joint="curve")

def star4(draw, cx, cy, r, fill):
    """四角闪光星"""
    pts = []
    for i in range(8):
        ang = math.pi / 4 * i - math.pi / 2
        rr = r if i % 2 == 0 else r * 0.28
        pts.append((cx + rr * math.cos(ang), cy + rr * math.sin(ang)))
    draw.polygon(pts, fill=fill)

def grad_rect(size, top, bot, horizontal=False):
    """垂直/对角线性渐变"""
    w, h = size
    g = Image.new("RGB", (1, h)) if not horizontal else Image.new("RGB", (w, 1))
    n = h if not horizontal else w
    px = []
    for i in range(n):
        t = i / max(n - 1, 1)
        px.append(tuple(int(top[k] + (bot[k] - top[k]) * t) for k in range(3)))
    g.putdata(px)
    if horizontal:
        g = g.transpose(Image.TRANSPOSE)
    return g.resize((w, h))

def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "icon_out")
    os.makedirs(out_dir, exist_ok=True)

    # --- 背景：圆角方 + 对角渐变 ---
    bg = grad_rect((W, W), BG_TOP, BG_BOT)
    mask = Image.new("L", (W, W), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, W - 1, W - 1), radius=int(0.22 * W), fill=255)
    base = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    base.paste(bg, (0, 0), mask)
    d = ImageDraw.Draw(base)

    # 头后柔光圆
    glow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse(P(212, 130, 812, 730), fill=GLOW + (110,))
    glow = glow.filter(ImageFilter.GaussianBlur(40 * SS))
    base.alpha_composite(glow)
    d = ImageDraw.Draw(base)

    ow = int(6 * SS)  # 统一描边宽度

    # --- 双马尾（左右两大泪滴形，向外翻卷）---
    for side in (-1, 1):
        rx0 = 512 + side * 238   # 根部 x
        tip_x = 512 + side * 470
        pts = (bezier(P(rx0, 330), P(rx0 + side * 300, 430), P(tip_x + side * 40, 600), P(tip_x, 872))
               + bezier(P(tip_x, 872), P(tip_x - side * 70, 928), P(tip_x - side * 130, 850), P(tip_x - side * 128, 790))
               + bezier(P(tip_x - side * 128, 790), P(tip_x - side * 150, 560), P(rx0 - side * 96, 470), P(rx0, 330)))
        poly(d, pts, fill=HAIR, outline=HAIR_DARK, width=ow)

    # --- 后发（脑后大团）---
    poly(d, bezier(P(258, 470), P(232, 150), P(792, 150), P(766, 470))
            + bezier(P(766, 470), P(780, 700), P(700, 780), P(512, 790))
            + bezier(P(512, 790), P(324, 780), P(244, 700), P(258, 470)),
         fill=HAIR_DARK, width=0)

    # --- 脖子 + 身体（肩部水手服，椭圆穹顶）---
    d.rounded_rectangle(P(458, 600, 566, 780), radius=40 * SS, fill=SKIN, outline=SKIN_LINE, width=int(4 * SS))
    d.ellipse(P(238, 726, 786, 1330), fill=CLOTH, outline=CLOTH_DARK, width=ow)
    # 白色水手领（小 V 领）
    poly(d, [P(512, 742), P(576, 822), P(512, 930), P(448, 822)],
         fill=(255, 255, 255))
    # 领巾
    poly(d, [P(512, 806), P(544, 856), P(512, 896), P(480, 856)], fill=BOW)

    # --- 脸 ---
    d.ellipse(P(318, 268, 706, 682), fill=SKIN, outline=SKIN_LINE, width=ow)

    # --- 腮红 ---
    blush = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    bd = ImageDraw.Draw(blush)
    bd.ellipse(P(330, 552, 410, 606), fill=(255, 120, 150, 90))
    bd.ellipse(P(614, 552, 694, 606), fill=(255, 120, 150, 90))
    base.alpha_composite(blush)

    # --- 眼睛 ---
    for ex in (418, 606):
        cx, cy, rx, ry = ex * SS, 512 * SS, 58 * SS, 74 * SS
        # 眼白
        d.ellipse((cx - rx, cy - ry, cx + rx, cy + ry),
                  fill=(255, 255, 255), outline=SKIN_LINE, width=int(3 * SS))
        # 虹膜渐变
        gw, gh = int(rx * 1.7), int(ry * 1.8)
        grad = grad_rect((gw, gh), EYE_TOP, EYE_BOT)
        gmask = Image.new("L", (gw, gh), 0)
        ImageDraw.Draw(gmask).ellipse(
            (int(gw * 0.07), int(gh * 0.08), int(gw * 0.93), int(gh * 0.92)), fill=255)
        iris = Image.new("RGBA", (gw, gh), (0, 0, 0, 0))
        iris.paste(grad, (0, 0), gmask)
        base.alpha_composite(iris, (int(cx - gw / 2), int(cy - gh / 2)))
        d = ImageDraw.Draw(base)
        # 瞳孔 + 高光
        d.ellipse((cx - rx * 0.34, cy - ry * 0.28, cx + rx * 0.34, cy + ry * 0.52), fill=(40, 32, 84))
        d.ellipse((cx - rx * 0.52, cy - ry * 0.62, cx - rx * 0.02, cy - ry * 0.12), fill=(255, 255, 255))
        d.ellipse((cx + rx * 0.10, cy + ry * 0.18, cx + rx * 0.38, cy + ry * 0.44), fill=(255, 255, 255, 200))
        # 上睫毛（cx/cy 已是超采样坐标，不能再过 P()）
        lash = bezier((cx - rx * 1.12, cy - ry * 0.66), (cx - rx * 0.4, cy - ry * 1.28),
                      (cx + rx * 0.6, cy - ry * 1.22), (cx + rx * 1.12, cy - ry * 0.72))
        lash += bezier((cx + rx * 1.12, cy - ry * 0.72), (cx, cy - ry * 0.82),
                       (cx - rx * 0.3, cy - ry * 0.92), (cx - rx * 1.12, cy - ry * 0.66))
        poly(d, lash, fill=(70, 50, 80))

    # --- 眉毛 ---
    for ex in (418, 606):
        sgn = -1 if ex > 512 else 1
        pts = bezier(P((ex - 46) * SS, 402 * SS), P(ex * SS, 384 * SS),
                     P((ex + 20) * SS, 382 * SS), P((ex + 48) * SS, 392 * SS))
        d.line(pts, fill=HAIR_DARK, width=int(7 * SS), joint="curve")

    # --- 鼻子/嘴 ---
    d.ellipse(P(506, 574, 518, 586), fill=SKIN_LINE)
    # w 形猫嘴
    m = bezier(P(492, 606), P(500, 624), P(510, 620), P(512, 608)) \
        + bezier(P(512, 608), P(514, 620), P(524, 624), P(532, 606))
    d.line(m, fill=(200, 110, 110), width=int(6 * SS), joint="curve")

    # --- 刘海（盖住额头的一排圆弧尖）---
    bang = [P(292, 512)]
    bang += bezier(P(292, 512), P(268, 220), P(430, 148), P(512, 150))
    bang += bezier(P(512, 150), P(600, 148), P(760, 220), P(732, 512))
    # 下缘锯齿曲线（从右往左）
    zig = bezier(P(732, 512), P(720, 420), P(668, 400), P(650, 452))
    zig += bezier(P(650, 452), P(636, 380), P(566, 372), P(548, 430))
    zig += bezier(P(548, 430), P(532, 366), P(458, 366), P(444, 428))
    zig += bezier(P(444, 428), P(430, 380), P(364, 386), P(352, 452))
    zig += bezier(P(352, 452), P(338, 414), P(300, 436), P(292, 512))
    poly(d, bang + zig, fill=HAIR, outline=HAIR_DARK, width=ow)

    # 刘海高光弧
    hl = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    hd = ImageDraw.Draw(hl)
    hd.arc(P(360, 200, 668, 470), start=195, end=315, fill=HAIR_LIGHT + (230,), width=int(16 * SS))
    base.alpha_composite(hl)
    d = ImageDraw.Draw(base)

    # --- 呆毛（ahoge）---
    poly(d, bezier(P(512, 152), P(470, 80), P(560, 60), P(596, 104))
            + bezier(P(596, 104), P(548, 96), P(540, 128), P(512, 160)),
         fill=HAIR, outline=HAIR_DARK, width=int(4 * SS))

    # --- 发饰蝴蝶结（右侧马尾根）---
    bx, by = 762 * SS, 372 * SS
    for sgn in (-1, 1):
        poly(d, [P(bx / SS + sgn * 4, by / SS - 6), P(bx / SS + sgn * 62, by / SS - 40),
                 P(bx / SS + sgn * 54, by / SS + 18), P(bx / SS + sgn * 8, by / SS + 6)],
             fill=BOW, outline=(214, 60, 96), width=int(4 * SS))
    d.ellipse(P(bx / SS - 14, by / SS - 14, bx / SS + 14, by / SS + 14),
              fill=(255, 130, 160), outline=(214, 60, 96), width=int(4 * SS))

    # --- 装饰：闪光与花瓣 ---
    deco = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    dd = ImageDraw.Draw(deco)
    star4(dd, 150 * SS, 250 * SS, 34 * SS, (255, 255, 255, 220))
    star4(dd, 890 * SS, 180 * SS, 26 * SS, (255, 255, 255, 200))
    star4(dd, 862 * SS, 620 * SS, 20 * SS, (255, 255, 255, 170))
    for px, py, pr in ((120, 700, 22), (896, 812, 26), (214, 118, 16)):
        dd.ellipse(P(px - pr, py - pr, px + pr, py + pr * 0.62), fill=(255, 214, 232, 150))
    base.alpha_composite(deco)

    # --- 输出 ---
    final = base.resize((SIZE, SIZE), Image.LANCZOS)
    png_path = os.path.join(out_dir, "wnacg_icon_1024.png")
    final.save(png_path)
    ico_path = os.path.join(out_dir, "app_icon.ico")
    final.save(ico_path, format="ICO",
               sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
    print("saved:", png_path)
    print("saved:", ico_path)

if __name__ == "__main__":
    main()
