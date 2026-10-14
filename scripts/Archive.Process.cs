using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;

// Readers run on CLR threads, never PowerShell callbacks without a runspace.
// Owns the tool and optional binary producer; cancellation never searches by name.
public sealed class ArchiveStreamingProcess : IDisposable {
    public Process Process { get; private set; }
    private StreamWriter log;
    private Thread stdout, stderr, binaryPump, producerError;
    private Process producer;
    private volatile bool stopping;
    private readonly object gate = new object();
    private Exception readerError;
    public static string Quote(string value) {
        if (value == null) value = "";
        var b = new StringBuilder("\""); int slashes = 0;
        foreach (char c in value) {
            if (c == '\\') { slashes++; continue; }
            if (c == '"') b.Append('\\', slashes * 2 + 1);
            else b.Append('\\', slashes);
            b.Append(c); slashes = 0;
        }
        b.Append('\\', slashes * 2); return b.Append('"').ToString();
    }
    public ArchiveStreamingProcess(string exe, string[] args, string logPath) : this(exe, args, logPath, null, null) { }
    public ArchiveStreamingProcess(string exe, string[] args, string logPath, string inputExe, string[] inputArgs) {
        log = new StreamWriter(new FileStream(logPath, FileMode.CreateNew, FileAccess.Write, FileShare.ReadWrite), new UTF8Encoding(false));
        log.AutoFlush = true;
        var info = new ProcessStartInfo(exe);
        var command = new StringBuilder();
        foreach (string arg in args) { if (command.Length > 0) command.Append(' '); command.Append(Quote(arg)); }
        info.Arguments = command.ToString(); info.UseShellExecute = false; info.CreateNoWindow = true;
        info.RedirectStandardOutput = true; info.RedirectStandardError = true; info.RedirectStandardInput = inputExe != null;
        info.StandardOutputEncoding = new UTF8Encoding(false); info.StandardErrorEncoding = new UTF8Encoding(false);
        Process = new Process(); Process.StartInfo = info;
        try {
            Process.Start();
            if (inputExe != null) {
                var pi = new ProcessStartInfo(inputExe); var pa = new StringBuilder();
                foreach (string arg in inputArgs) { if (pa.Length > 0) pa.Append(' '); pa.Append(Quote(arg)); }
                pi.Arguments = pa.ToString(); pi.UseShellExecute = false; pi.CreateNoWindow = true;
                pi.RedirectStandardOutput = true; pi.RedirectStandardError = true;
                pi.StandardErrorEncoding = new UTF8Encoding(false);
                producer = new Process(); producer.StartInfo = pi; producer.Start();
                producerError = new Thread(() => Pump(producer.StandardError)); producerError.IsBackground = true; producerError.Start();
                binaryPump = new Thread(PumpBinary); binaryPump.IsBackground = true; binaryPump.Start();
            }
            stdout = new Thread(() => Pump(Process.StandardOutput)); stdout.IsBackground = true; stdout.Start();
            stderr = new Thread(() => Pump(Process.StandardError)); stderr.IsBackground = true; stderr.Start();
        } catch { StopOwnedProcess(); log.Dispose(); Process.Dispose(); throw; }
    }
    private void Pump(StreamReader reader) {
        try {
            string line;
            // ReadLine accepts both carriage-return progress updates and LF logs.
            while ((line = reader.ReadLine()) != null) lock (gate) { log.WriteLine(line); }
        } catch (Exception e) { lock (gate) { readerError = e; } }
    }
    private void PumpBinary() {
        try {
            // Bounded producer/consumer pipeline; no complete tar or payload tree.
            byte[] buffer = new byte[1048576]; int n;
            while ((n = producer.StandardOutput.BaseStream.Read(buffer, 0, buffer.Length)) > 0)
                Process.StandardInput.BaseStream.Write(buffer, 0, n);
        } catch (Exception e) { if (!stopping) lock (gate) { readerError = e; } }
        finally { try { Process.StandardInput.Close(); } catch { } }
    }
    public void StopOwnedProcess() {
        stopping = true;
        if (producer != null) { try { if (!producer.HasExited) producer.Kill(); producer.WaitForExit(); } catch (InvalidOperationException) { } }
        try { if (!Process.HasExited) Process.Kill(); Process.WaitForExit(); } catch (InvalidOperationException) { }
    }
    public int Finish() {
        Process.WaitForExit();
        if (producer != null) {
            if (Process.ExitCode != 0 && !producer.HasExited) producer.Kill();
            producer.WaitForExit(); binaryPump.Join(); producerError.Join();
        }
        stdout.Join(); stderr.Join(); log.Flush();
        if (readerError != null && !stopping) throw new IOException("Native output capture failed", readerError);
        return Process.ExitCode != 0 ? Process.ExitCode : (producer == null ? 0 : producer.ExitCode);
    }
    public void Dispose() {
        // Disposal alone is never permission to interrupt physical media writing.
        if (Process.HasExited) {
            if (stdout != null) stdout.Join(); if (stderr != null) stderr.Join();
            if (binaryPump != null) binaryPump.Join(); if (producerError != null) producerError.Join(); log.Dispose();
        }
        if (producer != null) producer.Dispose(); Process.Dispose();
    }
}
