# 场景规则与来源

三个场景分别规划：照片原文件、游戏录像母版、旧设备及小文件备份。介质容量和工具行为以本地检测与实际验证为准。

## 照片

照片场景主要处理用户已经选定的 C 层落选或暂存 RAW；不能把整个摄影资产库都按低价值、单副本数据处理。

| 层 | 保存意图 | 工具行为 |
|---|---|---|
| A | 精选、不可重拍、作品、最终 TIFF/JPEG；保留 HDD/另一份 | `Scenario=photo, PhotoTier=A` → category M / BD-M；原文件；禁止本工具删除源 |
| B | 正常 RAW / 尚未精修；保持其他副本 | photo B → category I / BD-P；原文件；禁止本工具删除源 |
| C | 连拍落选、未挑、舍不得删的低频 RAW | photo C → category I / BD-P；符合门槛才可单独请求删除源 |

PhotoTier 是用户针对这次 Archive Set 的选择，不是自动评分。混合价值内容应先分开文件夹/套装，原目录不被脚本移动。不要把 A/B 的重要数据混入 C 来绕过门槛。

保留 RAW、XMP、JPEG/TIFF、项目目录、清单和用户提供的主题。规划优先整目录；过大目录拆分时同名照片家族不拆开。仅逐位相同的文件可省略实体副本；有 RAW/JPEG/XMP 同名伴随文件时保持整个家族实体，以便该盘独立查看。别名仍写入完整 manifest，可在恢复时重建。

照片摘要不显示 iOS、备份加密或密码字段。`PHOTO-CATALOG.csv` 将文件相对路径、类型、家族、SHA-256 和实际盘号关联起来；原始修改时间仅在 ingest 中作为文件属性，不充当拍摄日期。程序不会解析 Lightroom 数据库、改变评级或写入 XMP。

## 游戏录像

现存最高质量版本就是 archival master。`MasterStatus` 可记 `original_capture`、`encoded_copy_is_master`、`existing_highest_quality`。`EarlierOriginalStatus=DELETED` 仅指更早的原始录像已被用户删除，不等于本次 ingest 源文件已删除；后者由审计记录管理。

MKV/MP4 直接放盘。超大录像先用 `split-video.ps1` 生成独立可播放段，再 ingest 专用输出目录。每段容器时间从本地起点开始；保留 mkvmerge 支持的轨道、章节和标签，并记录原文件识别信息、哈希及各段累计时长估计。不能声称可逐字节重建原始容器或精确还原原始 packet PTS。正式接受前检查轨道/章节和每段开头、中间、结尾。

事件摘要由用户填写；ffmpeg 联系表用于浏览，不等于自动理解事件。没有现存录像时，不编造事件、编码或分辨率。

## 旧 iPhone / 小文件备份

一个 Archive Set 对应一次已完成的备份。先按目录与大小规划各盘，再分别 mkdwarfs；不是把一个巨大 DwarFS 分卷。默认约 21 GiB / 44 GiB payload，并扣除 PAR2、介质和小文件开销。

每个 shard 内重复关键根文件，每个镜像独立 integrity 检查、SHA-256、解包回验。恢复整套后再逐文件比对。仅包含部分 shard 的目录不是可用的完整 iPhone 备份。

iPhone 信息从 XML/binary plist 白名单解析；未知字段保持 UNKNOWN。文件夹 ID 对外脱敏，密码只记保管位置。`SecondCopy` 是备注，不自动证明第二份可读。少量 catalog 和恢复说明另放核心层，NFC 贴壳、仅存稳定 URL。

## 刻碟授权

用户明确要求“刻碟必须用户确认”。因此每次真实写盘都必须先完成 staging 和校验，显示具体盘号、Archive Set、大小、介质、光驱、backend 与 SHA256SUMS 哈希，再由用户在窗口/终端输入该盘的确认短语。`-BurnConfirmed` 只启用这段交互，不能跳过它。

Skill/Agent 可以准备、模拟、展示待刻结果；不得自填确认短语、向输入流自动发送答案、篡改确认函数或把“开发工具/制作归档”当作写盘授权。确认只覆盖当次所示的单张盘；目标改变或换替代盘需再次确认。取消发生在写入前，保留 STAGED。它是交互操作门槛，不是对能任意改本机脚本的用户的安全隔离。
