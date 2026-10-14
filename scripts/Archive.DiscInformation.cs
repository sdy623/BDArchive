using System;
using System.IO;
using System.Runtime.InteropServices;
using System.ComponentModel;
using Microsoft.Win32.SafeHandles;

// Only MMC READ DISC INFORMATION (0x51), DataIn=1, 34 bytes. No caller can
// supply another CDB. Does not close, repair, erase, write or eject media.
public static class ArchiveDiscInformation {
    [StructLayout(LayoutKind.Sequential)] struct PassThrough {
        public ushort Length;
        public byte ScsiStatus, PathId, TargetId, Lun, CdbLength, SenseInfoLength, DataIn;
        public uint DataTransferLength, TimeOutValue;
        public UIntPtr DataBufferOffset;
        public uint SenseInfoOffset;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst=16)] public byte[] Cdb;
    }
    public sealed class Result {
        public int DiscStatus, LastSessionStatus;
        public bool Erasable, Finalized;
        public string HeaderHex;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool DeviceIoControl(SafeFileHandle file, uint code, IntPtr input, uint inputSize, IntPtr output, uint outputSize, out uint returned, IntPtr overlapped);
    public static Result Parse(byte[] data) {
        if (data==null || data.Length<4 || ((data[0]<<8)|data[1])<2) throw new InvalidDataException("Truncated MMC disc information.");
        // ntddscsi.h/scsi.h: DiscStatus bits 0..1, LastSessionStatus 2..3,
        // DISK_STATUS_COMPLETE = 2. Do not treat appendable (1) as finalized.
        int status=data[2]&3;
        return new Result { DiscStatus=status,LastSessionStatus=(data[2]>>2)&3,Erasable=(data[2]&0x10)!=0,Finalized=status==2,HeaderHex=BitConverter.ToString(data,0,4) };
    }
    public static Result Read(string drive) {
        if (drive==null || !System.Text.RegularExpressions.Regex.IsMatch(drive,@"^[A-Za-z]:[\\/]?$")) throw new ArgumentException("Optical drive letter required.");
        string root=drive.Substring(0,2).ToUpperInvariant()+@"\";
        if (new DriveInfo(root).DriveType!=DriveType.CDRom) throw new InvalidOperationException("Target is not an optical device.");
        // Windows requires READ|WRITE handle access for this IOCTL even for a
        // read-only CDB. Only the fixed 0x51 request below is ever submitted.
        using(var file=CreateFileW(@"\\.\"+root.Substring(0,2),0xc0000000,3,IntPtr.Zero,3,0,IntPtr.Zero)) {
            if(file.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            int header=Marshal.SizeOf(typeof(PassThrough)), dataOffset=512, total=dataOffset+34;
            IntPtr memory=Marshal.AllocHGlobal(total);
            try {
                Marshal.Copy(new byte[total],0,memory,total);
                var cdb=new byte[16];cdb[0]=0x51;cdb[8]=34;
                var request=new PassThrough {Length=(ushort)header,CdbLength=10,SenseInfoLength=32,DataIn=1,DataTransferLength=34,TimeOutValue=10,DataBufferOffset=new UIntPtr((uint)dataOffset),SenseInfoOffset=(uint)header,Cdb=cdb};
                Marshal.StructureToPtr(request,memory,false);
                uint returned;
                // CTL_CODE(IOCTL_SCSI_BASE=4,0x401,METHOD_BUFFERED,READ|WRITE).
                if(!DeviceIoControl(file,0x4d004,memory,(uint)total,memory,(uint)total,out returned,IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error());
                var response=(PassThrough)Marshal.PtrToStructure(memory,typeof(PassThrough));
                if(response.ScsiStatus!=0) throw new IOException("MMC READ DISC INFORMATION failed, SCSI status="+response.ScsiStatus+".");
                if(response.DataTransferLength<4 || returned<dataOffset+4) throw new InvalidDataException("Short MMC response.");
                var bytes=new byte[Math.Min(34,(int)response.DataTransferLength)];Marshal.Copy(IntPtr.Add(memory,dataOffset),bytes,0,bytes.Length);
                return Parse(bytes);
            } finally { Marshal.FreeHGlobal(memory); }
        }
    }
}
