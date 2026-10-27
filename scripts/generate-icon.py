#!/usr/bin/env python3
"""FocusVoice 图标：深色圆角方形 + 渐变声纹刻度环 + 白色焦点。与蓄力环「声纹」一致。"""
import math, os
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, "Resources")
os.makedirs(RES, exist_ok=True)
SS = 4
BASE = 1024
S = BASE * SS
MARGIN = 100 * SS
CORNER = 185 * SS

def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

def vertical_gradient(size, top, bottom):
    img = Image.new("RGB", (1, size)); px = img.load()
    for y in range(size):
        px[0, y] = lerp(top, bottom, y / max(1, size - 1))
    return img.resize((size, size))

def squircle_mask():
    m = Image.new("L", (S, S), 0)
    ImageDraw.Draw(m).rounded_rectangle([MARGIN, MARGIN, S-MARGIN, S-MARGIN], radius=CORNER, fill=255)
    return m

def conic_gradient(size, colors):
    """colors: [(t0, rgb), ...] 覆盖 0..1；用扇形近似 conic 渐变。"""
    img = Image.new("RGB", (size, size), colors[0][1])
    d = ImageDraw.Draw(img)
    cx = cy = size / 2
    r = size
    steps = 720
    def color_at(t):
        for i in range(len(colors)-1):
            t0, c0 = colors[i]; t1, c1 = colors[i+1]
            if t0 <= t <= t1:
                return lerp(c0, c1, (t-t0)/max(1e-6, t1-t0))
        return colors[-1][1]
    for i in range(steps):
        t0 = i/steps
        # 从 12 点方向开始
        a0 = -90 + 360*t0
        a1 = a0 + 360/steps + 0.4
        d.pieslice([cx-r, cy-r, cx+r, cy+r], start=a0, end=a1, fill=color_at(t0))
    return img

def main():
    # 背景
    bg = vertical_gradient(S, (12, 15, 23), (25, 30, 43)).convert("RGBA")
    mask = squircle_mask()

    # 声纹刻度 mask
    n = 12
    # 与 HoldRingHUD.buildVoiceprint 完全同一组高度/半径比例（仅做整体缩放）
    heights = [0.38, 0.95, 0.52, 0.78, 0.34, 1.0, 0.45, 0.86, 0.32, 0.72, 0.55, 0.92]
    radii = [0.835, 0.795, 0.85, 0.81, 0.84, 0.79, 0.855, 0.815, 0.84, 0.795, 0.85, 0.815]
    bar_mask = Image.new("L", (S, S), 0)
    bd = ImageDraw.Draw(bar_mask)
    cx = cy = S / 2
    for i in range(n):
        ang = i/n*2*math.pi - math.pi/2
        # Apple 图标安全区：mark 外径约画布 55%，离圆角边留足空间
        r0 = radii[i] * 0.235 * S
        r1 = r0 + heights[i] * 0.075 * S
        w = int(0.050 * S)
        bd.line([cx+math.cos(ang)*r0, cy+math.sin(ang)*r0,
                 cx+math.cos(ang)*r1, cy+math.sin(ang)*r1],
                fill=255, width=w)
        for px, py in ((cx+math.cos(ang)*r0, cy+math.sin(ang)*r0),
                       (cx+math.cos(ang)*r1, cy+math.sin(ang)*r1)):
            bd.ellipse([px-w/2, py-w/2, px+w/2, py+w/2], fill=255)

    grad = conic_gradient(S, [(0.0, (10,132,255)), (0.5, (100,210,255)), (1.0, (10,132,255))]).convert("RGBA")
    bars = Image.new("RGBA", (S, S), (0,0,0,0))
    bars.paste(grad, (0,0), bar_mask)

    # 中心焦点 + 光晕
    art = Image.new("RGBA", (S, S), (0,0,0,0))
    ad = ImageDraw.Draw(art)
    art.alpha_composite(bars)
    fr = 0.046 * S
    ad.ellipse([cx-fr*1.30, cy-fr*1.30, cx+fr*1.30, cy+fr*1.30], fill=(110,190,255,30))
    ad.ellipse([cx-fr, cy-fr, cx+fr, cy+fr], fill=(255,255,255,248))

    # 轻度辉光
    glow = bars.filter(ImageFilter.GaussianBlur(16*SS))
    art = Image.alpha_composite(glow, art)

    icon = Image.alpha_composite(bg, art)
    icon.putalpha(mask)

    # 阴影 + 合成
    shadow = Image.new("RGBA", (S, S), (0,0,0,0))
    sm = Image.new("L", (S, S), 0)
    ImageDraw.Draw(sm).rounded_rectangle(
        [MARGIN, MARGIN+8*SS, S-MARGIN, S-MARGIN+18*SS], radius=CORNER, fill=80)
    shadow.putalpha(sm.filter(ImageFilter.GaussianBlur(24*SS)))
    canvas = Image.new("RGBA", (S, S), (0,0,0,0))
    canvas = Image.alpha_composite(canvas, shadow)
    canvas = Image.alpha_composite(canvas, icon)
    master = canvas.resize((BASE, BASE), Image.LANCZOS)
    master.save(os.path.join(RES, "AppIcon-1024.png"))

    iconset = os.path.join(ROOT, "build", "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)
    for size in (16, 32, 64, 128, 256, 512, 1024):
        master.resize((size, size), Image.LANCZOS).save(os.path.join(iconset, f"icon_{size}x{size}.png"))
        if size <= 512:
            master.resize((size*2, size*2), Image.LANCZOS).save(os.path.join(iconset, f"icon_{size}x{size}@2x.png"))

    # 菜单栏模板图标：10 根迷你声纹 + 中心点（简化版，20pt 基准，比之前更大）
    bar_heights = [0.35, 0.95, 0.50, 0.85, 0.28, 1.0, 0.42, 0.86, 0.24, 0.72]
    for px in (20, 40):
        scale = px / 20
        img = Image.new("RGBA", (px*4, px*4), (0,0,0,0))
        d = ImageDraw.Draw(img)
        c = px*2
        r0 = 4.2 * scale * 4
        w = max(2, int(1.5*scale*4))
        for i in range(10):
            ang = i/10*2*math.pi - math.pi/2
            r1 = r0 + (1.2 + 0.8*bar_heights[i]) * scale * 4
            d.line([c+math.cos(ang)*r0, c+math.sin(ang)*r0,
                    c+math.cos(ang)*r1, c+math.sin(ang)*r1], fill=(0,0,0,255), width=w)
            for rr in (r0, r1):
                p=(c+math.cos(ang)*rr, c+math.sin(ang)*rr)
                d.ellipse([p[0]-w/2, p[1]-w/2, p[0]+w/2, p[1]+w/2], fill=(0,0,0,255))
        dr = 1.7 * scale * 4
        d.ellipse([c-dr, c-dr, c+dr, c+dr], fill=(0,0,0,255))
        suffix = "" if px == 20 else "@2x"
        img.resize((px, px), Image.LANCZOS).save(os.path.join(RES, f"MenuBarIcon{suffix}.png"))

    print("generated app icon + menu bar template")

if __name__ == "__main__":
    main()
