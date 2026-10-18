#!/usr/bin/env python3
"""生成 iOS 应用图标：白色主题（1024x1024，系统自动裁圆角）"""
from PIL import Image, ImageDraw, ImageFilter
import math, os

S = 1024
img = Image.new("RGB", (S, S), (255, 255, 255))
d = ImageDraw.Draw(img)

# ---- 背景：白 → 极浅灰 渐变 ----
for y in range(S):
    t = y / S
    v = int(255 - 12 * t)
    d.line([(0, y), (S, y)], fill=(v, v + 1 if v < 255 else 255, min(255, v + 3)))

# ---- 右上角淡绿光晕 ----
glow = Image.new("L", (S, S), 0)
gd = ImageDraw.Draw(glow)
for i in range(300, 0, -3):
    gd.ellipse([S - 40 - i, -60 - i, S - 40 + i, -60 + i], fill=int(40 * (1 - i / 300)))
img = Image.composite(Image.new("RGB", (S, S), (233, 248, 241)), img, glow.filter(ImageFilter.GaussianBlur(40)))
d = ImageDraw.Draw(img)

GREEN = (14, 159, 110)
GREEN_D = (10, 122, 85)
MINT = (231, 247, 240)
GREY = (229, 234, 240)
DARK = (17, 24, 39)

# ---- 手机外框 ----
pw, ph = 380, 660
x0, y0 = (S - pw) // 2, (S - ph) // 2 + 26
r = 84

# 投影
shadow = Image.new("L", (S, S), 0)
sd = ImageDraw.Draw(shadow)
sd.rounded_rectangle([x0 - 6, y0 + 14, x0 + pw + 6, y0 + ph + 26], radius=r + 8, fill=70)
img = Image.composite(Image.new("RGB", (S, S), (190, 205, 200)), img, shadow.filter(ImageFilter.GaussianBlur(34)))
d = ImageDraw.Draw(img)

# 机身（白底 + 绿描边）
d.rounded_rectangle([x0, y0, x0 + pw, y0 + ph], radius=r, fill=(255, 255, 255), outline=GREEN, width=26)
# 听筒
d.rounded_rectangle([S // 2 - 58, y0 + 44, S // 2 + 58, y0 + 62], radius=9, fill=GREY)
# 屏幕内浅绿面板
d.rounded_rectangle([x0 + 54, y0 + 120, x0 + pw - 54, y0 + ph - 120], radius=34, fill=MINT)

# ---- 终端符号 > ----
cx, cy = x0 + 108, y0 + 250
d.line([(cx, cy), (cx + 58, cy + 50)], fill=GREEN_D, width=26)
d.line([(cx + 58, cy + 50), (cx, cy + 100)], fill=GREEN_D, width=26)
# 光标
d.rounded_rectangle([cx + 96, cy + 72, cx + 210, cy + 102], radius=8, fill=GREEN)

# 输出两行（浅灰）
d.rounded_rectangle([x0 + 100, y0 + 440, x0 + pw - 100, y0 + 468], radius=14, fill=GREY)
d.rounded_rectangle([x0 + 100, y0 + 500, x0 + pw - 190, y0 + 528], radius=14, fill=GREY)

# ---- 右上信号弧 ----
for rad in (92, 148, 204):
    box = [S - 300 - rad, 300 - rad, S - 300 + rad, 300 + rad]
    d.arc(box, start=-72, end=22, fill=GREEN, width=22)
d.ellipse([S - 326, 274, S - 274, 326], fill=GREEN)

# ---- 底部三个圆点 ----
for i in range(3):
    xx = S // 2 - 52 + i * 52
    color = GREEN if i == 0 else GREY
    d.ellipse([xx - 9, y0 + ph - 86, xx + 9, y0 + ph - 68], fill=color)

out = "/var/minis/workspace/rc/ios/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
os.makedirs(os.path.dirname(out), exist_ok=True)
img.save(out, "PNG")
print("saved", out, img.size)
