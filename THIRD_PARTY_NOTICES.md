# Third-party tools and attribution / 第三方工具与来源

The MIT license covers this repository's source and documentation. It does **not** relicense any external executable, Windows component, codec, font, or trademark. No external tool executable is bundled in this public source tree. Install optional tools separately from their official providers and comply with their own license terms.

本仓库 MIT 许可仅覆盖本项目源码与文档，不重新许可外部程序、Windows 组件、编解码器、字体或商标。公开源码不捆绑第三方可执行文件；按需从官方来源自行安装，并遵守其许可。

| External component | Use in this project | Distribution boundary |
|---|---|---|
| PowerShell / Windows Forms / .NET | Windows application and command host | Provided by the host operating system or separately installed runtime |
| Python 3.10+ standard library | SQLite catalog, local read-only HTTP pages, plist parsing | Separately installed; no Python package dependencies |
| DwarFS 0.15.7 | Create, check, extract and optionally mount independent shards | Optional external CLI; not bundled |
| WinFsp | Optional DwarFS mounting | External driver/runtime; never silently installed |
| ImgBurn | Optional physical-disc writing backend | External proprietary application; not redistributed |
| Windows IMAPI2 / IMAPI2FS | Device enumeration, UDF image authoring and writing | Operating-system component |
| MKVToolNix / mkvmerge | Keyframe-aligned video splitting without re-encoding | Optional external CLI; not bundled |
| FFmpeg | Video contact sheets | Optional external CLI; not bundled |
| par2cmdline / MultiPar par2j | Optional recovery volumes | Optional external CLI; not bundled |

Interface references and provenance are listed in [SOURCES.md](SOURCES.md). Those references do not claim that a particular drive/media combination has passed testing. Selected KMD design materials are adapted below with their original license notices. Only the explicitly listed OFL font assets are bundled; other system fonts are referenced by name and not distributed. All demo catalog records are examples, not verified physical media.

接口依据见 [SOURCES.md](SOURCES.md)。引用文档不代表某光驱与盘片已通过实机验收。下列 KMD 设计材料按原许可移植并保留声明；仅分发明确列出的 OFL 字体，其余系统字体仅按字体名引用。示例目录记录不代表真实光盘。

## KSP Mission Display design adaptation / KMD 设计移植

The mission-control palette, typography roles and visual hierarchy are adapted from KSP Mission Display. Repository-relative provenance:  `mission-display/DESIGN.md` section 10 and `mission-display/app/globals.css`. These references deliberately contain no developer-machine paths. Archive operations, identities and burn authorization remain BD Archive Toolkit responsibilities. No SpaceX marks or proprietary logos are included.

任务控制台配色、字体职责与视觉层级来自 KSP Mission Display。上游相对路径：`mission-display/DESIGN.md` 第 10 节与 `mission-display/app/globals.css`；不包含开发机器的绝对路径。归档操作、身份和刻录授权仍由本工具负责，不包含 SpaceX 标志或专有商标图形。

Both upstream notices are reproduced in full because the source subtree and parent repository carry separate contributor attributions.

### KSP Operations Suite — parent repository notice

MIT License

Copyright (c) 2026 KSP Operations Suite contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.


### KSP Mission Display — adapted subtree notice

MIT License

Copyright (c) 2026 KSP Mission Display contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Bundled offline fonts / 离线字体

The following Latin font subsets are included for process-private desktop rendering. They are decoded from the installed Fontsource WOFF1 containers to sfnt/TTF; glyph and name tables are unchanged, and the table and whole-font checksums are verified. This is not a system-wide font installation. No font is downloaded at runtime.

下列 Latin 子集用于进程内桌面渲染：从已安装 Fontsource 的 WOFF1 容器解码为 sfnt/TTF，字形与名称表保持原样，并核对表校验和及完整字体校验和。不安装系统字体，也不在运行时下载字体。中文字符由系统中文字体回退提供；本项目未捆绑 IBM Plex Sans SC，不宣称其已打包。

| Files | Upstream attribution | License notice |
|---|---|---|
| `assets/fonts/barlow-condensed-400.ttf`, `barlow-condensed-600.ttf` | Copyright 2017 The Barlow Project Authors | [Barlow Condensed OFL](assets/fonts/barlow-condensed-OFL.txt) |
| `assets/fonts/ibm-plex-sans-400.ttf`, `ibm-plex-sans-600.ttf` | Copyright 2019 IBM Corp. All rights reserved. | [IBM Plex Sans OFL](assets/fonts/ibm-plex-sans-OFL.txt) |
| `assets/fonts/ibm-plex-mono-400.ttf`, `ibm-plex-mono-600.ttf` | Copyright 2017 IBM Corp. All rights reserved. | [IBM Plex Mono OFL](assets/fonts/ibm-plex-mono-OFL.txt) |

All bundled fonts remain under the **SIL Open Font License 1.1**, not MIT. Each linked file preserves the complete Fontsource-supplied copyright and license notice. [Font provenance](assets/fonts/provenance.json) records source package-relative paths, source/output SHA-256 and output byte counts; no machine-specific paths are recorded. The public-export checker permits only these six exact font files with matching checksums and intact companion notices.

所有捆绑字体继续遵循 **SIL Open Font License 1.1**，不改为 MIT。链接文件保留 Fontsource 随附的完整版权与许可声明。[字体来源记录](assets/fonts/provenance.json) 包含包内相对路径、源 / 输出 SHA-256 和字节数，不记录机器路径。公开检查只允许这六个路径、校验和及许可副本全部匹配的字体。## React frontend distribution

The ready-to-run build contains React and React DOM under the MIT license. Build tooling (Vite, TypeScript, Playwright) is a development dependency, not an installed archive tool. Exact versions and integrity hashes are recorded in ui/package-lock.json. Bundled runtime license texts are reproduced in ui/THIRD_PARTY_LICENSES.txt.
