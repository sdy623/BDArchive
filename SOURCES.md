# 官方接口依据

核对日期：2026-09-05。链接是接口依据，不代表本机硬件已通过验收。用户指定的数据价值分级、收纳选择和样例数字按用户方案实现。

- [DwarFS 0.15.7 mkdwarfs 手册](https://github.com/mhx/dwarfs/blob/v0.15.7/doc/mkdwarfs.md)：独立镜像创建参数与输入形式。
- [DwarFS 0.15.7 dwarfsck 手册](https://github.com/mhx/dwarfs/blob/v0.15.7/doc/dwarfsck.md)：完整性检查及非零退出码。
- [DwarFS 0.15.7 dwarfsextract 手册](https://github.com/mhx/dwarfs/blob/v0.15.7/doc/dwarfsextract.md)：输入镜像与既存输出目录。
- [DwarFS 0.15.7 挂载手册](https://github.com/mhx/dwarfs/blob/v0.15.7/doc/dwarfs.md)：只读挂载选项。
- [MKVToolNix mkvmerge 官方手册](https://mkvtoolnix.download/doc/mkvmerge.html)：size 分割、关键帧限制、识别 JSON 和退出码。
- [ImgBurn 官方论坛命令行说明](https://forum.imgburn.com/topic/21050-batch-mode-again/)：BUILD、DEVICE、UDFREVISION、目录递归、VERIFY 和禁止删除选项。
- [Microsoft UDFRevision](https://learn.microsoft.com/en-us/windows/win32/api/imapi2fs/nf-imapi2fs-ifilesystemimage-get_udfrevision)：版本编码形式。
- [Microsoft 介质 finalized 状态](https://learn.microsoft.com/en-us/windows/win32/api/imapi2/ne-imapi2-imapi_format2_data_media_state)：FINALIZED 为 0x4000。
- [Microsoft 空白介质检查](https://learn.microsoft.com/en-us/windows/win32/api/imapi2/nf-imapi2-idiscformat2-get_mediaheuristicallyblank)：启发式空白不足以作为肯定检查，应检查 physically blank。
- [par2cmdline 官方项目](https://github.com/Parchive/par2cmdline)：创建、验证和冗余百分比。
- [MultiPar 官方 par2j 命令手册](https://github.com/Yutaka-Sawada/MultiPar/blob/master/source/par2j/Command_par2j.txt)：/rr、/sn、/d、Unicode 选项及 verify 的 external files。

本项目没有复制第三方工具二进制，也不使用 Nero 私有 API。

iPhone 摘要字段参考 [libimobiledevice 的 idevicebackup2 实现](https://github.com/libimobiledevice/libimobiledevice/blob/master/tools/idevicebackup2.c)：Info.plist 中 Product Type、Product Version、Last Backup Date，以及 Manifest.plist 的 IsEncrypted boolean。解析只输出明确允许的摘要字段；原始设备标识不进入摘要。

## 1.2.1 GUI / DPI

- Microsoft [WinForms automatic scaling](https://learn.microsoft.com/en-us/dotnet/desktop/winforms/forms/autoscale)：DPI 基准与自动缩放。
- Microsoft [Application.SetHighDpiMode](https://learn.microsoft.com/en-us/dotnet/api/system.windows.forms.application.sethighdpimode?view=windowsdesktop-9.0) 与 [SetThreadDpiAwarenessContext](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setthreaddpiawarenesscontext)：窗口创建前的 awareness 配置及线程范围。
- Microsoft [.NET Framework WinForms High DPI](https://learn.microsoft.com/en-us/dotnet/desktop/winforms/high-dpi-support-in-windows-forms)：旧框架的显式启用限制；本项目不修改 PowerShell 宿主配置。
- Microsoft [TableLayoutPanel](https://learn.microsoft.com/en-us/dotnet/desktop/winforms/controls/tablelayoutpanel-control-overview) 与 [FlowLayoutPanel](https://learn.microsoft.com/en-us/dotnet/desktop/winforms/controls/flowlayoutpanel-control-overview)：自动布局。


## 1.4.0 卷描述接口验证

- 本机 ImgBurn 2.5.8.0 `ReadMe.txt`：逐文件系统 VOLUMELABEL、SRC IBB、PORTABLE、SETTINGS、NOSAVESETTINGS。完整文件未复制进分发包。
- [ImgBurn 项目字段示例](https://forum.imgburn.com/topic/14623-bdmv-ibb-file/)；模板使用 Identifier_* 字段，经过实际镜像回读测试，不只依赖示例。
- [ImgBurn 作者关于 UDF Application 的长度说明](https://forum.imgburn.com/topic/20910-volume-identifiers/)：UDF 只有 23 字节；本工具主动拒绝超限。
- [Microsoft IFileSystemImage](https://learn.microsoft.com/en-us/windows/win32/api/imapi2fs/nn-imapi2fs-ifilesystemimage)：已用 COM 接口提供 VolumeName，不提供上述 Application setter。
- [Linux UDF ECMA-167 结构定义](https://raw.githubusercontent.com/torvalds/linux/master/fs/udf/ecma_167.h)：用于测试解析 PVD/LVD 的字段位置，没有复制运行时代码。

实测修正：ImgBurn 的 Identifier_VolumeSet 未控制 UDF 内部 Volume Set，故标为清单字段；不自动改镜像字节或宣称该字段已物理写入。

1.8.1 速度选项核对本机 ImgBurn 2.5.8.0 ReadMe.txt 第 90–95 行：`/SPEED` 接受下拉框匹配值，官方给出 `MAX`、`1x` 和地区格式的小数示例。没有推断当前盘片的实际最高速度。

### 1.9.1 finalization detection

- Microsoft [IMAPI media-state enum](https://learn.microsoft.com/en-us/windows/win32/api/imapi2/ne-imapi2-imapi_format2_data_media_state): 0x4000 finalized and 0x8000 unsupported are separate flags.
- Microsoft [SCSI_PASS_THROUGH](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntddscsi/ns-ntddscsi-_scsi_pass_through) and [IOCTL_SCSI_PASS_THROUGH](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntddscsi/ni-ntddscsi-ioctl_scsi_pass_through): buffered, synchronous, DataIn=1; Windows requires a read/write device handle even for the fixed read-only CDB.
- Installed Windows SDK 10.0.26100.0 shared/scsi.h lines 403–410, 2013–2021, 2044–2077: READ DISC INFORMATION opcode=0x51, allocation length bytes 7–8; DISC_INFORMATION byte 2 status fields; complete disc=2, complete last session=3. shared/ntddscsi.h lines 79 and 132–146 supply IOCTL and structure layout.
