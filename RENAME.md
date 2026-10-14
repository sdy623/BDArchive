# 修改已编译记录的 ID — 1.8.0

已编译、尚未刻碟的记录可修改**碟片 ID**或**归档 ID**，无需重新扫描源文件或编译 DwarFS。

## 界面操作

1. 重新打开 `START.bat`，进入「5 编号与卷标」，刷新并选中一条记录。
2. 填写「新碟片 ID」或「新归档 ID」，点击对应修改按钮。归档 ID 修改作用于所选记录的整套 Archive Set。
3. 默认只预览，在日志查看新旧 ID、卷标及需重新准备的目录；预览不占号。
4. 确认输入后，勾选「执行编号管理」，再点对应按钮应用。两个 ID 都要改时分两次操作，每次重新选中当前记录。
5. 回制作页填写当前归档 ID，点击「载入原计划设置」，再准备。已编译镜像会复用。

## 保留与更新

| 项目 | 修改碟片 ID | 修改归档 ID |
|---|---|---|
| catalog 记录 | 修改原记录，不增加记录 | 修改原 set 及其碟片关联 |
| DwarFS | 同一盘内重命名目录及镜像文件，更新 build.json 路径 | 保留原镜像与构建目录 |
| 源文件与镜像内容 | 不读取、不复制、不重编、不重新计算 payload 哈希 | 同左 |
| 全库 disc_index、逻辑 volume_id | 保持不变 | 保持不变，旧 set 前缀可能仍在逻辑卷号中 |
| 卷标、卷描述 | 按原计划保存的模板重新展开 | 按原模板重新展开 `{set_id}`、`{set_token}` 等 |
| 清单与摘要 | 更新 plan、CSV、摘要与索引 | 同时修订 ingest 的归档 ID，更新清单之间的哈希引用 |
| NFC | 旧 `/disc/…` 跳转到新记录 | 旧 `/set/…` 跳转到新记录 |

改名只对小型管理文件计算哈希。ingest 中的文件清单及源 SHA-256 保持原值；DwarFS 原创建参数、日志和验证时间保留，改名不产生新的 integrity PASS。

**所有同套的已生成 staging 都需要重新准备**，因为各盘保存了整套 SET-MANIFEST。旧 staging 以同盘目录移动保存到 `identity-history/rename-…/staging/`，不复制 payload。再次准备会重做清单、封存哈希及配置中的 PAR2；DwarFS 不重编。旧目录或 PAR2 仍可能占空间，本功能不自动清理它们。未生成 staging 时，修改 ID 不会触发这项工作。

旧 ID 保留为别名，不能分配给另一条记录；多次改名时旧地址直接跳转当前 ID。索引号不新增，自动计数器不倒退。全库 catalog_id 与 Windows 光盘文件系统序列号不属于可修改字段。SQLite 为可重建索引；同步失败时 JSON 已保存，可重新执行 catalog sync。

## 命令行

```powershell
# 默认仅预览；执行时在末尾加 -Execute
.\scripts\rename-disc.ps1 -DiscId BD-B-0001 -NewDiscId IPA-001
.\scripts\rename-set.ps1 -SetId BACKUP-DEMO-OLD -NewSetId BACKUP-DEMO-NEW

# manage-ids / archive-agent 也支持同样的子命令
.\scripts\manage-ids.ps1 -Command rename-disc -DiscId BD-B-0001 -NewDiscId IPA-001 -Execute
.\scripts\manage-ids.ps1 -Command rename-set -SetId OLD-SET -NewSetId NEW-SET -Execute
```

随附 `rename-disc.bat`、`rename-set.bat`；自定义配置可加 `-Config`，`-WhatIf` 和 `-DryRun` 始终只预览。

## 边界与中断

套内任一记录已写盘、已验证（包括模拟）、已登记、已删除或源已删除时拒绝改名。已写入物理盘的标识无法通过 catalog 改写。本功能要求现有 ingest、plan、catalog 一致；不会重建用户删掉的计划。只有扫描尚未分盘的 set 暂不支持改名。

这是普通不可变计划规则的显式例外：在独占 archive.lock 下创建身份修订，先保存改名前的管理文件和移动日志，再更新清单。失败会回滚；进程被强制终止留下 `pending-identity-change.json` 时，其他写操作会暂停。使用第 5 页「恢复中断的改名」，或：

```powershell
.\scripts\manage-ids.ps1 -Command repair-identity-change -Execute
```

未提交事务回滚到原 ID；已经提交则清除中断标志。不要手工删除 pending 文件、编辑恢复日志或移动相关目录。恢复历史只描述当时的变更，不能作为任意时间的撤销按钮。
