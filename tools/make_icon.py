#!/usr/bin/env python3
"""生成 iOS 应用图标（1024x1024，无圆角，系统自动裁切）"""
from PIL import Image, ImageDraw
import math, os

S = 1024
img = Image.new("RGB", (S, S), (11, 15, 20))
d = ImageDraw.Draw(img)

# 对角渐变背景
for y in range(S):
    t = y / S
    r = int(11 + 12 * t)
    g = int(15 + 30 * t)
    b = int(20 + 34 * t)
    d.line([(0, y), (S, y)], fill=(r, g, b))

# 背景光晕
glow = Image.new("RGB", (S, S), (0, 0, 0))
gd = ImageDraw.Draw(glow)
for i in range(220, 0, -2):
    a = int(22 * (1 - i / 220))
    gd.ellipse([S//2 - i*2, S//2 - i*2, S//2 + i*2, S//2 + i*2], fill=(7, a + 10, a))
img = Image.blend(img, Image.blend(img, glow, 0.0), 0.0)
d = ImageDraw.Draw(img)

ACCENT = (43, 224, 168)
DIM = (26, 90, 74)

# 手机外框
pw, ph = 340, 600
x0, y0 = (S - pw) // 2, (S - ph) // 2 + 20
r = 76
d.rounded_rectangle([x0, y0, x0 + pw, y0 + ph], radius=r, outline=ACCENT, width=26)
# 听筒
d.rounded_rectangle([S//2 - 52, y0 + 42, S//2 + 52, y0 + 58], radius=8, fill=DIM)

# 屏幕内终端符号 >
cx, cy = x0 + 92, y0 + 250
d.line([(cx, cy), (cx + 52, cy + 46)], fill=ACCENT, width=22)
d.line([(cx + 52, cy + 46), (cx, cy + 92)], fill=ACCENT, width=22)
# 光标
d.rectangle([cx + 86, cy + 66, cx + 186, cy + 96], fill=ACCENT)

# 三条信号弧（右上）
for i, rad in enumerate((70, 120, 170)):
    box = [S - 250 - rad, 250 - rad, S - 250 + rad, 250 + rad]
    d.arc(box, start=-70, end=20, fill=ACCENT, width=18)
# 信号源点
d.ellipse([S - 264, 236, S - 224, 276], fill=ACCENT)

# 底部小点装饰
for i in range(3):
    xx = S//2 - 40 + i * 40
    d.ellipse([xx - 7, y0 + ph - 78, xx + 7, y0 + ph - 64], fill=DIM if i else ACCENT)

os.makedirs("/var/minis/workspace/rc/ios/Resources/Assets.xcassets/AppIcon.appiconset", exist_ok=True)
out = "/var/minis/workspace/rc/ios/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
img.save(out, "PNG")
print("saved", out, img.size)
