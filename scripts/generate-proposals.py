#!/usr/bin/env python3
"""生成 v0.9.1 的方案稿：图标变体 / 蓄力环概念 / 菜单栏录音态。仅为提案，不改产品。"""
import math, os
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "docs", "proposals")
os.makedirs(OUT, exist_ok=True)
SS = 4
FONT = ImageFont.truetype("/System/Library/Fonts/Hiragino Sans GB.ttc", 18)

def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

def gradient(size, top, bottom):
    img = Image.new("RGB", (1, size)); px = img.load()
    for y in range(size):
        t = y / max(1, size - 1); px[0, y] = lerp(top, bottom, t)
    return img.resize((size, size))

def squircle(size, inset, radius):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle([inset, inset, size - inset, size - inset], radius=radius, fill=255)
    return m

def arc_gradient(draw, box, width, start, end, steps=200):
    stops = [(0.0, (10,132,255)), (0.5, (100,210,255)), (1.0, (191,90,242))]
    def color_at(t):
        for i in range(len(stops)-1):
            t0,c0 = stops[i]; t1,c1 = stops[i+1]
            if t0 <= t <= t1:
                return lerp(c0,c1,(t-t0)/max(1e-6,t1-t0))
        return stops[-1][1]
    for i in range(steps):
        t0=i/steps; t1=(i+1)/steps
        a0=start+(end-start)*t0; a1=start+(end-start)*t1+0.7
        draw.arc(box, start=a0, end=a1, fill=color_at(t0)+(255,), width=width)

# ---------- 图标 A（当前已安装） ----------
icon_a = Image.open(os.path.join(ROOT, "Resources", "AppIcon-1024.png")).convert("RGBA")
icon_a.resize((512,512), Image.LANCZOS).save(os.path.join(OUT, "icon-A-current.png"))

# ---------- 通用合成：背景 + 内容 + 圆角遮罩 + 阴影 ----------
def compose_icon(bg_img, art_img, mask, out_path, shadow_alpha=70):
    icon = Image.alpha_composite(bg_img, art_img)
    icon.putalpha(mask)
    S = bg_img.size[0]
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sm = Image.new("L", (S, S), 0)
    ImageDraw.Draw(sm).rounded_rectangle(
        [100*SS, 100*SS + 8*SS, S-100*SS, S-100*SS + 18*SS],
        radius=185*SS, fill=shadow_alpha
    )
    shadow.putalpha(sm.filter(ImageFilter.GaussianBlur(24*SS)))
    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    canvas = Image.alpha_composite(canvas, shadow)
    canvas = Image.alpha_composite(canvas, icon)
    canvas.resize((512,512), Image.LANCZOS).save(out_path)

# ---------- 图标 B：浅色玻璃 ----------
S = 1024 * SS
mask = squircle(S, 100*SS, 185*SS)
bg = gradient(S, (244,247,252), (210,220,234)).convert("RGBA")
art = Image.new("RGBA", (S, S), (0, 0, 0, 0)); ad = ImageDraw.Draw(art)
cx = cy = S / 2; r = 250*SS; w = 30*SS
arc_gradient(ad, [cx-r, cy-r, cx+r, cy+r], w, -55, 250)
for ang, col in ((-55, (10,132,255)), (250, (191,90,242))):
    rad = math.radians(ang); ex = cx + r*math.cos(rad); ey = cy + r*math.sin(rad)
    ad.ellipse([ex-w/2, ey-w/2, ex+w/2, ey+w/2], fill=col + (255,))
fr = 30*SS
ad.ellipse([cx-fr*1.9, cy-fr*1.9, cx+fr*1.9, cy+fr*1.9], fill=(20,30,50,18))
ad.ellipse([cx-fr, cy-fr, cx+fr, cy+fr], fill=(16,24,40,255))
compose_icon(bg, art, mask, os.path.join(OUT, "icon-B-light.png"))

# ---------- 图标 C：声纹刻度环 ----------
S = 1024 * SS
mask = squircle(S, 100*SS, 185*SS)
bg = gradient(S, (12,15,23), (25,31,44)).convert("RGBA")
art = Image.new("RGBA", (S, S), (0, 0, 0, 0)); ac = ImageDraw.Draw(art)
cx = cy = S / 2
n = 32
base_r = 165 * SS
for i in range(n):
    ang = i/n*2*math.pi - math.pi/2
    h = (26 + 58*abs(math.sin(i*1.9+0.4))) * SS
    r0 = base_r; r1 = base_r + h
    col = (90,200,255) if i % 4 else (175,120,255)
    ac.line([cx+math.cos(ang)*r0, cy+math.sin(ang)*r0,
             cx+math.cos(ang)*r1, cy+math.sin(ang)*r1], fill=col+(240,), width=int(13*SS))
fr = 24*SS
ac.ellipse([cx-fr*1.7, cy-fr*1.7, cx+fr*1.7, cy+fr*1.7], fill=(120,190,255,50))
ac.ellipse([cx-fr, cy-fr, cx+fr, cy+fr], fill=(255,255,255,245))
art = Image.alpha_composite(art.filter(ImageFilter.GaussianBlur(14*SS)), art)
compose_icon(bg, art, mask, os.path.join(OUT, "icon-C-voiceprint.png"))

# ---------- 蓄力环概念稿 ----------
def ring_frame(kind, t, size=320):
    s=size*SS
    img=Image.new("RGBA",(s,s),(0,0,0,0)); d=ImageDraw.Draw(img)
    cx=cy=s/2; r=110*SS; w=6*SS
    # 轨道
    d.ellipse([cx-r,cy-r,cx+r,cy+r], outline=(255,255,255,26), width=int(2*SS))
    # 进度（ease-in 近似：progress = t^1.7）
    p=min(1,t/0.6); eased=p**1.7
    start=-90; end=start+360*eased
    if eased>0:
        d.arc([cx-r,cy-r,cx+r,cy+r], start=start, end=end, fill=(90,200,255,235), width=w)
    # 笔尖
    ang=math.radians(end); hx=cx+r*math.cos(ang); hy=cy+r*math.sin(ang)
    hr=5*SS
    d.ellipse([hx-hr*2,hy-hr*2,hx+hr*2,hy+hr*2], fill=(90,200,255,70))
    d.ellipse([hx-hr,hy-hr,hx+hr,hy+hr], fill=(255,255,255,255))
    if kind=="pulse":
        # 两个音对应的两段高光（在 t=0.06 / 0.18 亮起）
        for pt, life in ((0.06,0.16),(0.18,0.14)):
            if t>=pt:
                seg_end=-90+360*((min(t,pt+life)/0.6)**1.7)
                seg_start=max(-90,seg_end-28)
                d.arc([cx-r,cy-r,cx+r,cy+r], start=seg_start, end=seg_end, fill=(255,255,255,210), width=w)
    if kind=="breathe":
        # 亮度随进度做一次呼吸（0.2~0.35s 更亮）
        if 0.16<=t<=0.36:
            d.arc([cx-r,cy-r,cx+r,cy+r], start=start, end=max(start+1,end), fill=(150,225,255,120), width=int(w*1.8))
    if t>=0.58:
        # 蓄满：高光扫过一小段
        d.arc([cx-r,cy-r,cx+r,cy+r], start=-20, end=25, fill=(255,255,255,240), width=int(w*1.2))
    return img.resize((size,size), Image.LANCZOS)

for kind,name in (("pulse","ring-A-双脉冲"),("breathe","ring-B-呼吸线")):
    frames=[ring_frame(kind,t) for t in (0.10,0.20,0.38,0.60)]
    W,H=frames[0].size; pad=10; label=26
    sheet=Image.new("RGBA",(W*4+pad*5, H+label+pad*2),(22,22,26,255))
    dd=ImageDraw.Draw(sheet)
    for i,(t,fr) in enumerate(zip((0.10,0.20,0.38,0.60),frames)):
        x=pad+i*(W+pad)
        sheet.alpha_composite(fr,(x,pad))
        dd.text((x+10,pad+H+2), f"t={t:.2f}s", fill=(220,220,228,255), font=FONT)
    sheet.convert("RGB").save(os.path.join(OUT,f"{name}.png"))

# ---------- 菜单栏录音态 ----------
def menubar_icon(recording, size=180, dark=True):
    s=size*4
    img=Image.new("RGBA",(s,s),(0,0,0,0)); d=ImageDraw.Draw(img)
    c=s//2; r=180*0.34
    w=int(size*0.09*4)
    color=(255,255,255,255) if dark else (20,20,22,255)
    d.arc([c-r,c-r,c+r,c+r], start=-55, end=250, fill=color, width=w)
    if recording:
        rd=size*0.16
        d.ellipse([c-rd,c-rd,c+rd,c+rd], fill=(255,69,58,255))
    else:
        d.ellipse([c-size*0.09,c-size*0.09,c+size*0.09,c+size*0.09], fill=color)
    return img.resize((size,size), Image.LANCZOS)

sheet=Image.new("RGB",(760,300),(22,22,26))
for i,(rec,label) in enumerate([(False,"空闲"),(True,"录音中")]):
    bar=Image.new("RGB",(340,90),(40,40,44)); bar.paste(menubar_icon(rec,size=60), (30,15), menubar_icon(rec,size=60))
    d=ImageDraw.Draw(bar); d.text((110,32), label, fill=(230,230,235), font=FONT)
    sheet.paste(bar,(30+i*370, 60))
d=ImageDraw.Draw(sheet); d.text((30,20), "菜单栏图标：空闲（模板单色） / 录音中（红色录制点，非模板）", fill=(220,220,228), font=FONT)
sheet.save(os.path.join(OUT,"menubar-states.png"))
print("proposals generated in", OUT)
