using System;
using System.IO;
using System.Text;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class ArchiveFileLinks {
    public sealed class FileStamp { public long Bytes; public long MtimeTicks; }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool GetVolumePathNameW(string path, StringBuilder volume, uint length);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool GetVolumeNameForVolumeMountPointW(string path, StringBuilder name, uint length);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool CreateHardLinkW(string name, string existing, IntPtr security);
    [StructLayout(LayoutKind.Sequential)] struct Info {
        public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Creation, Access, Write;
        public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetFileInformationByHandle(SafeFileHandle file, out Info info);
    static string NativePath(string path) {
        path=Path.GetFullPath(path);
        if (path.StartsWith(@"\\?\")) return path;
        return path.StartsWith(@"\\") ? @"\\?\UNC\"+path.Substring(2) : @"\\?\"+path;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool GetDiskFreeSpaceExW(string directory, out ulong available, out ulong total, out ulong free);
    public static long AvailableBytes(string directory) {
        ulong available, total, free;
        if (!GetDiskFreeSpaceExW(NativePath(directory),out available,out total,out free)) throw new Win32Exception(Marshal.GetLastWin32Error());
        return checked((long)available);
    }
    public static string Volume(string path) {
        var root=new StringBuilder(32768);var name=new StringBuilder(128);
        if (!GetVolumePathNameW(NativePath(path),root,(uint)root.Capacity)) throw new Win32Exception(Marshal.GetLastWin32Error());
        if (!GetVolumeNameForVolumeMountPointW(root.ToString(),name,(uint)name.Capacity)) throw new Win32Exception(Marshal.GetLastWin32Error());
        return name.ToString();
    }
    public static void Create(string source,string target) {
        if (!CreateHardLinkW(NativePath(target),NativePath(source),IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error());
    }
    public static string Identity(string path) {
        using(var stream=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete)) {
            Info info;if(!GetFileInformationByHandle(stream.SafeFileHandle,out info)) throw new Win32Exception(Marshal.GetLastWin32Error());
            return info.Volume.ToString("X8")+":"+info.IndexHigh.ToString("X8")+info.IndexLow.ToString("X8");
        }
    }
    public static FileStamp Stamp(string path) {
        // Directory entries for NTFS hard links can retain stale size/mtime.
        // Query the underlying handle; this reads metadata and zero payload bytes.
        using(var stream=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.Read)) {
            Info info;if(!GetFileInformationByHandle(stream.SafeFileHandle,out info)) throw new Win32Exception(Marshal.GetLastWin32Error());
            long write=((long)(uint)info.Write.dwHighDateTime<<32)|(uint)info.Write.dwLowDateTime;
            return new FileStamp {Bytes=((long)info.SizeHigh<<32)|info.SizeLow,MtimeTicks=DateTime.FromFileTimeUtc(write).Ticks};
        }
    }
}
