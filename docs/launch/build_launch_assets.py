#!/usr/bin/env python3
from PIL import Image, ImageDraw, ImageFont, ImageFilter
import os, glob, math

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
L = os.path.join(ROOT, "docs/launch/assets")
RAW = os.path.join(L, "raw")
MOTION = os.path.join(L, "motion")
os.makedirs(MOTION, exist_ok=True)

AVENIR = "/System/Library/Fonts/Avenir Next.ttc"
CN = "/System/Library/Fonts/Hiragino Sans GB.ttc"
FONT_HEAVY = lambda s: ImageFont.truetype(AVENIR, s, index=8)
FONT_DEMI = lambda s: ImageFont.truetype(AVENIR, s, index=2)
FONT_MED = lambda s: ImageFont.truetype(AVENIR, s, index=5)
FONT_CN = lambda s: ImageFont.truetype(CN, s, index=2)
FONT_CN_LIGHT = lambda s: ImageFont.truetype(CN, s, index=0)

def gradient(w, h, top=(6, 8, 13), bottom=(10, 18, 30)):
    img = Image.new("RGBA", (w, h))
    d = ImageDraw.Draw(img)
    for y in range(h):
        t = y / max(1, h - 1)
        c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        d.line([(0, y), (w, y)], fill=c + (255,))
    return img

def glow(img, cx, cy, radius, color, alpha=60):
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    d.ellipse([cx - radius, cy - radius, cx + radius, cy + radius], fill=color + (alpha,))
    layer = layer.filter(ImageFilter.GaussianBlur(radius * 0.55))
    return Image.alpha_composite(img, layer)

def dots(img, step=64, color=(255, 255, 255, 9)):
    d = ImageDraw.Draw(img)
    for y in range(0, img.height, step):
        for x in range(0, img.width, step):
            d.ellipse([x, y, x + 1, y + 1], fill=color)
    return img

def text_tracked(draw, pos, text, font, fill, tracking=0):
    x, y = pos
    for ch in text:
        draw.text((x, y), ch, font=font, fill=fill)
        x += draw.textlength(ch, font=font) + tracking

def with_shadow(base, item, pos, blur=34, offset=(0, 18), opacity=110):
    shadow = Image.new("RGBA", item.size, (0, 0, 0, 0))
    alpha = item.getchannel("A")
    shadow.putalpha(alpha)
    shadow = shadow.filter(ImageFilter.GaussianBlur(blur))
    layer = Image.new("RGBA", base.size, (0, 0, 0, 0))
    black = Image.new("RGBA", item.size, (0, 0, 0, opacity))
    layer.paste(black, (pos[0] + offset[0], pos[1] + offset[1]), shadow)
    out = Image.alpha_composite(base, layer)
    out.alpha_composite(item, pos)
    return out

def trim_alpha(im):
    bbox = im.getbbox()
    return im.crop(bbox) if bbox else im

icon = Image.open(os.path.join(ROOT, "Resources/AppIcon-1024.png")).convert("RGBA")

# ---------- 16:9 icon showcase ----------
W, H = 2560, 1440
poster = gradient(W, H, (5, 7, 12), (9, 17, 29))
poster = glow(poster, 760, 660, 650, (10, 132, 255), 42)
poster = glow(poster, 1830, 500, 520, (100, 210, 255), 18)
poster = dots(poster, 80)
# icon
ic = icon.resize((680, 680), Image.LANCZOS)
poster = with_shadow(poster, ic, (230, 380), blur=48, offset=(0, 26), opacity=150)
d = ImageDraw.Draw(poster)
# small label
text_tracked(d, (1035, 390), "MACOS  ·  VOICE INPUT", FONT_MED(30), (140, 155, 178, 255), 5)
# wordmark
d.text((1022, 442), "FocusVoice", font=FONT_HEAVY(196), fill=(245, 248, 252, 255))
# thin cyan line
d.rounded_rectangle([1032, 690, 1262, 696], radius=3, fill=(90, 205, 255, 255))
# Chinese tagline
d.text((1028, 742), "按住说话，文字已在。", font=FONT_CN(78), fill=(235, 240, 247, 255))
# English subline
d.text((1030, 852), "An input layer for your voice.", font=FONT_DEMI(42), fill=(150, 165, 188, 255))
# chips
chips = ["本地识别", "实时出字", "随处可用"]
x = 1030
for c in chips:
    f = FONT_CN_LIGHT(28)
    tw = d.textlength(c, font=f)
    d.rounded_rectangle([x, 946, x + tw + 38, 1000], radius=27, outline=(70, 90, 120, 180), width=2, fill=(255, 255, 255, 7))
    d.text((x + 19, 955), c, font=f, fill=(180, 195, 214, 255))
    x += tw + 58
# footer
d.text((1032, 1132), "FOCUSVOICE FOR MAC  ·  v0.13.4", font=FONT_MED(24), fill=(96, 112, 136, 255))
d.text((230, 1190), "SenseVoice on-device  ·  Apple Silicon  ·  macOS 13+", font=FONT_MED(28), fill=(105, 121, 145, 255))
poster.convert("RGB").save(os.path.join(L, "icon-showcase-16x9.png"))
poster.resize((1920, 1080), Image.LANCZOS).convert("RGB").save(os.path.join(L, "icon-showcase-16x9-1920.png"))

# ---------- 16:9 HUD hero ----------
hero = gradient(W, H, (4, 6, 10), (10, 16, 27))
hero = glow(hero, 1980, 660, 700, (10, 132, 255), 46)
hero = glow(hero, 1350, 420, 500, (100, 210, 255), 20)
hero = dots(hero, 80)
d = ImageDraw.Draw(hero)
text_tracked(d, (180, 340), "FOCUSVOICE", FONT_MED(28), (130, 148, 174, 255), 7)
d.text((172, 392), "你的声音，", font=FONT_CN(112), fill=(245, 248, 252, 255))
d.text((172, 526), "直接变成文字。", font=FONT_CN(112), fill=(245, 248, 252, 255))
d.text((178, 700), "按住鼠标，说一句话；松开，文字已经写好。", font=FONT_CN_LIGHT(38), fill=(155, 170, 192, 255))
d.text((178, 770), "它住在菜单栏里，出现在你正在用的任何输入框。", font=FONT_CN_LIGHT(32), fill=(110, 126, 150, 255))
# HUD
hud = Image.open(os.path.join(RAW, "hud.png")).convert("RGBA")
hud = trim_alpha(hud)
scale = 1.62
hud_big = hud.resize((int(hud.width * scale), int(hud.height * scale)), Image.LANCZOS)
hero = with_shadow(hero, hud_big, (1280, 520), blur=46, offset=(0, 24), opacity=150)
# ring + caption（用最后一帧，整圈刻度完整）
ring_path = "/tmp/launch_ring_frames/r17.png"
if not os.path.exists(ring_path):
    ring_path = sorted(glob.glob("/tmp/launch_ring_frames/r*.png"))[-1]
ring = Image.open(ring_path).convert("RGBA")
ring = trim_alpha(ring).resize((210, 210), Image.LANCZOS)
glow_disc = Image.new("RGBA", hero.size, (0, 0, 0, 0))
gd = ImageDraw.Draw(glow_disc)
gd.ellipse([1210, 250, 1630, 670], fill=(10, 132, 255, 38))
hero = Image.alpha_composite(hero, glow_disc.filter(ImageFilter.GaussianBlur(50)))
hero.alpha_composite(ring, (1280, 340))
d = ImageDraw.Draw(hero)
d.text((1518, 404), "0.6 秒蓄力", font=FONT_CN_LIGHT(28), fill=(140, 156, 180, 255))
d.text((180, 1180), "PRESS  ·  SPEAK  ·  IT'S WRITTEN", font=FONT_MED(26), fill=(88, 104, 128, 255))
hero.convert("RGB").save(os.path.join(L, "hero-hud-16x9.png"))

# ---------- Settings scenes ----------
def settings_scene(src, out, caption):
    win = Image.open(src).convert("RGBA")
    win = trim_alpha(win)
    canvas = gradient(1600, 1200, (6, 8, 13), (12, 20, 33))
    canvas = glow(canvas, 1200, 420, 420, (10, 132, 255), 26)
    canvas = dots(canvas, 64)
    target_w = 1050
    scale = target_w / win.width
    win = win.resize((target_w, int(win.height * scale)), Image.LANCZOS)
    x = (1600 - target_w) // 2
    y = 60
    canvas = with_shadow(canvas, win, (x, y), blur=36, offset=(0, 18), opacity=140)
    d = ImageDraw.Draw(canvas)
    d.text((80, 1090), caption, font=FONT_CN_LIGHT(30), fill=(115, 132, 156, 255))
    canvas.convert("RGB").save(os.path.join(L, out))

settings_scene(os.path.join(RAW, "settings-speech.png"), "settings-speech.png", "语音模型：一键下载，本地离线识别")
settings_scene(os.path.join(RAW, "settings-general.png"), "settings-general.png", "控制面板：按住即说、浮层外观与语言")

# ---------- Still images ----------
toast = Image.open(os.path.join(RAW, "toast.png")).convert("RGBA")
toast = trim_alpha(toast)
tc = gradient(1200, 500, (6, 8, 13), (12, 20, 33))
tc = glow(tc, 600, 250, 300, (10, 132, 255), 30)
tc = dots(tc, 64)
t2 = toast.resize((int(toast.width * 2.0), int(toast.height * 2.0)), Image.LANCZOS)
tc = with_shadow(tc, t2, ((1200 - t2.width) // 2, (500 - t2.height) // 2), blur=34, offset=(0, 16), opacity=140)
tc.convert("RGB").save(os.path.join(L, "toast.png"))

menubar = Image.open(os.path.join(RAW, "menubar.png")).convert("RGBA")
mc = gradient(1600, 260, (4, 6, 10), (12, 18, 30))
mb = menubar.resize((int(menubar.width * 1.1), int(menubar.height * 1.1)), Image.LANCZOS)
mc.alpha_composite(mb, (40, (260 - mb.height) // 2))
mc.convert("RGB").save(os.path.join(L, "menubar.png"))

icon.resize((1024, 1024), Image.LANCZOS).save(os.path.join(L, "icon-1024.png"))

# ---------- GIFs ----------
def gif_from_frames(paths, out, size, bg, durations=80, scale=1.0, pad=0):
    frames = []
    for p in paths:
        im = Image.open(p).convert("RGBA")
        im = trim_alpha(im)
        if scale != 1.0:
            im = im.resize((int(im.width * scale), int(im.height * scale)), Image.LANCZOS)
        canvas = Image.new("RGBA", size, bg + (255,))
        canvas.alpha_composite(im, ((size[0] - im.width) // 2, (size[1] - im.height) // 2))
        frames.append(canvas.convert("RGB").convert("P", palette=Image.ADAPTIVE, colors=128))
    frames[0].save(out, save_all=True, append_images=frames[1:], duration=durations, loop=0, optimize=True)

ring_frames = sorted(glob.glob("/tmp/launch_ring_frames/r*.png"), key=lambda p: int(os.path.basename(p)[1:-4]))
gif_from_frames(ring_frames, os.path.join(MOTION, "ring.gif"), (480, 480), (10, 14, 22), durations=55, scale=2.4)

hud_frames = sorted(glob.glob("/tmp/launch_hud_frames/h*.png"), key=lambda p: int(os.path.basename(p)[1:-4]))
gif_from_frames(hud_frames, os.path.join(MOTION, "hud.gif"), (760, 300), (10, 14, 22), durations=120, scale=1.3)

# toast fade/slide gif
base = Image.open(os.path.join(L, "toast.png")).convert("RGBA")
t0 = toast.resize((int(toast.width * 2.0), int(toast.height * 2.0)), Image.LANCZOS)
frames = []
for i in range(1, 16):
    f = gradient(900, 300, (6, 8, 13), (12, 20, 33))
    alpha = min(1.0, i / 5)
    offset = int((1 - alpha) * 12)
    im = t0.copy(); im.putalpha(im.getchannel("A").point(lambda v: int(v * alpha)))
    f.alpha_composite(im, ((900 - im.width) // 2, 90 + offset))
    frames.append(f.convert("RGB").convert("P", palette=Image.ADAPTIVE, colors=128))
for i in range(18):
    f = gradient(900, 300, (6, 8, 13), (12, 20, 33))
    f.alpha_composite(t0, ((900 - t0.width) // 2, 90))
    frames.append(f.convert("RGB").convert("P", palette=Image.ADAPTIVE, colors=128))
for i in range(5, 0, -1):
    f = gradient(900, 300, (6, 8, 13), (12, 20, 33))
    alpha = i / 5
    im = t0.copy(); im.putalpha(im.getchannel("A").point(lambda v: int(v * alpha)))
    f.alpha_composite(im, ((900 - im.width) // 2, 90))
    frames.append(f.convert("RGB").convert("P", palette=Image.ADAPTIVE, colors=128))
frames[0].save(os.path.join(MOTION, "toast.gif"), save_all=True, append_images=frames[1:], duration=70, loop=0, optimize=True)

print("assets built in", L)
