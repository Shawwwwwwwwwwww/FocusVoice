# FocusVoice 产品介绍页素材

用于 Notion Site 发布。所有素材均由当前 v0.13.4 App 截图/录制生成。

## 文件

- `index.html`：可直接本地打开/托管的产品页预览（深色 Apple 风格）。
- `notion-page.md`：Notion 页面文案，按顺序复制即可。
- `assets/icon-showcase-16x9.png`：16:9 品牌稿件（图标 + 产品名 + 标语），2560×1440。
- `assets/icon-showcase-16x9-1920.png`：1920×1080 版本。
- `assets/icon-1024.png`：透明/方形图标。
- `assets/hero-hud-16x9.png`：16:9 产品场景图（文案 + HUD）。
- `assets/settings-speech.png` / `settings-general.png`：设置页场景图。
- `assets/toast.png` / `menubar.png`：提示与菜单栏。
- `assets/motion/ring-demo.gif`：蓄力环动效。
- `assets/motion/live-typing.gif`：实时转写动效。
- `assets/motion/inserted-toast.gif`：已插入提示动效。
- `assets/raw/`：原始截图（重新排版用）。

## 发布到 Notion

1. 新建 Notion 页面，标题 **FocusVoice**；
2. 首屏上传 `assets/icon-showcase-16x9.png` 作为封面/首图；
3. 按 `notion-page.md` 的结构复制标题、正文；
4. 在各段落下上传对应的图片/GIF；
5. 下载按钮：把 `../../dist/FocusVoice-0.13.4.dmg` 上传到 Notion/网盘，替换 CTA 链接。

## 托管 HTML

`index.html` 是相对路径引用 `assets/`，可直接部署到 GitHub Pages / Netlify。
上线前把下载链接改成实际 DMG 地址（当前为本地相对路径）。
