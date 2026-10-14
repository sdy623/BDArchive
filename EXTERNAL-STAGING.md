# 接入现成照片盘

1.11.0 可把其他工具已经分好的照片盘目录直接作为待刻目录，保持盘号、卷标、全库索引和逻辑 Volume ID。ImgBurn 项目引用完整目录；普通 NTFS 硬链接表现为文件，不使用 DwarFS，也不把照片再复制到 archive_root。

## 使用入口

重新打开 START.bat，进入「2 光盘与恢复」，选中已有照片记录，在「现成照片盘目录」选择含 `data` 与 `00_DISC_CATALOG` 的盘根目录。按钮「接入现成照片盘」默认预览，显示实际文件数、容量和归一化后的根目录；勾选「执行接入并封包」才写入本地元数据。

选到 `00_DISC_CATALOG` 时，此入口自动使用其上一层；普通扫描、准备与刻录入口会阻止只归档该索引子目录。不要重新扫描索引、重新分盘或占用新盘号。

```powershell
# 示例：按实际路径和已有盘号替换。默认只读预览。
.\scripts\import-stage.ps1 -DiscId BD-P-0005 -Source 'F:\Prepared\BD-P-0005'
# 在该根目录封包；不写光盘。
.\scripts\import-stage.ps1 -DiscId BD-P-0005 -Source 'F:\Prepared\BD-P-0005' -Execute
```

同名 BAT 支持相同参数，`archive-agent.ps1 -Command import-stage` 也可调用；`-WhatIf`/`-DryRun` 只预览。GUI 工作进程显示 SHA-256 字节进度、速度和停止按钮。CLI 显示逐文件哈希进度，可用 Ctrl+C 中断；下次同盘号、同路径继续。

## 现成目录契约

```text
BD-P-0005/
  data/                          原照片相对路径、RAW/JPEG/XMP
  00_DISC_CATALOG/
    CONTENTS.csv
    DISC-INFO.json
    CONTENTS.html, CATALOG.db…    原工具的其他索引文件可选
```

`CONTENTS.csv` 必须含 `archive_path,bytes,sha256`；路径以 `data/` 开头，SHA-256 为 64 位小写十六进制，不能有重复路径。`DISC-INFO.json` 必须含 `disc_id,archive_set_id,photo_files,logical_payload_bytes`，盘号须与所选记录一致。data 的文件数、总大小和成员必须与清单吻合。

当前入口适配**I 类照片套装中的一张已分好盘记录**，PAR2=0、未登记、未实际写盘、未删除源。一个套装可以有多张盘；每次按所选 `disc_id` 只接入对应的一个外部盘根目录，不会把第一张盘误当成当前盘，也不会自动接入同目录下其他光盘。允许覆盖旧错误模拟绑定，保留模拟历史；有实际写入或不明写入历史时拒绝。尚未支持批量创建外部照片记录或接入后改 ID；已有普通归档的改 ID 功能不受影响。

现成目录须与 archive_root 分离，不能是目录联接/符号链接；普通文件硬链接可用。Windows PowerShell 5.1 遇到超过 240 字符路径时要求 PowerShell 7，不会默默漏文件。

## 校验、记录与停止

预览只枚举文件属性并读取小型索引，不读照片内容。首次封包复用 CSV 的预期哈希，**每个照片文件只读取一次**核对。写入 DISC.json、SET-MANIFEST.json、SHA256SUMS、RESTORE.md、摘要和 TOOLKIT-IMPORT.json。原 `00_DISC_CATALOG` 不修改，因此其原来的 NOT_SEALED 状态仍是原规划工具的历史记录；当前工具是否完成封包，以 catalog 中的 stage 和 SHA256SUMS 为准。

旧 ingest/plan 不覆盖：候选清单写在 `sets/<set>/revisions/<id>`；封包成功后，一次 catalog 替换切换清单和待刻路径。旧待刻目录、模拟目录和写入历史保留。停止、哈希不符或容量失败均不会激活半成品。续做从 `external-imports/<disc>/pending.json` 找回候选元数据；已经写入的候选文件须一致，不会覆盖有变化的文件。若目录、CSV 或候选清单已变化，保留并报错，不能手改 checkpoint 跳过检查。

完成后 7 天内沿用既有封包复用规则；不会因点接入、准备或刻录而再次读取未变化的照片。执行接入和同套的其他操作互斥；不同套可以并行，同一个外部输出目录也互斥。检查过程中持有照片的只读句柄，避免通过硬链接修改正在核对的内容。

接入的外部链接目录禁用 delete-source：工具不了解其他软件管理的原始文件名和副本关系。硬链接不等于独立备份。

## 刻录与恢复

完成后点击「打开待刻目录」应看到 `data` 和 `00_DISC_CATALOG`。真实刻碟依然逐盘展示目录、容量、盘号、卷标和光驱，并要求用户亲自确认；接入按钮不会启动 ImgBurn。刻后回读仍默认关闭，手动回读通过才标为 VERIFIED。

直接复制盘内 data 保留相对路径即可恢复照片；或使用 restore-set.ps1 的清单恢复流程。盘内原 HTML/CSV catalog 用于检索。保存独立的全库 catalog；不依赖原 F: 盘符恢复。
