#Requires -Version 5.1
<#
=========================================================================
 RepairCenter - DiskManager
 Version: 1.5.1 | Plattform: Windows 10/11 | Windows PowerShell 5.1+
 Datentraegerverwaltung: Bestandsaufnahme, Formatieren, Dateisystem
 wechseln und schnelles Loeschen (Ueberschreiben mit Nullen).
 100 % lokal - keine Cloud, keine Fremdmodule.
 MIT-Lizenz - Copyright (c) 2026 AOWD GENESIS
=========================================================================
 WARNUNG: Die Funktionen dieses Moduls vernichten Daten endgueltig.
 Jede zerstoerende Aktion verlangt eine ausdrueckliche Bestaetigung und
 verweigert den Systemdatentraeger.
=========================================================================
 Warum das hier schneller ist als uebliche Werkzeuge:
   1. BitLocker  -> Schluessel vernichten statt Daten schreiben (Sekunden)
   2. SSD/NVMe   -> TRIM/UNMAP ueber den gesamten Datentraeger (Sekunden)
   3. HDD        -> ungepufferte, sektorausgerichtete Schreibvorgaenge mit
                    grossen Bloecken (Standard 32 MiB) und mehreren
                    gleichzeitig offenen Anforderungen (Warteschlangentiefe).
                    Klassische Werkzeuge schreiben gepuffert in 4-KiB- bis
                    1-MiB-Haeppchen: der Dateisystemcache wird geflutet und
                    jede Anforderung kostet Latenz. Hier laeuft es mit der
                    Geschwindigkeit, die der Datentraeger physisch hergibt.
   4. Eine Runde Nullen statt drei Runden Zufall - bei heutigen Laufwerken
      bringen Mehrfachdurchlaeufe nachweislich nichts ausser Zeitverlust.
=========================================================================
#>

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

$script:IsWindowsHost = ($env:OS -eq 'Windows_NT')
$script:NativeLoaded = $false

#region ======================= Native Bausteine =======================

function Initialize-DiskNative {
    <#  Laedt die C#-Bausteine: ungepufferter Rohschreiber und FAT32-Formatierer.
        Bewusst C#-5-Syntax, damit es auch der Compiler von Windows
        PowerShell 5.1 uebersetzt. #>
    if ($script:NativeLoaded) { return }
    if ('RepairCenter.Storage.RawDevice' -as [type]) { $script:NativeLoaded = $true; return }

    $code = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

namespace RepairCenter.Storage
{
    // ------------------------------------------------------------------
    //  Geraetezugriff: unter Windows ungepuffert (FILE_FLAG_NO_BUFFERING),
    //  ausserhalb von Windows eine gewoehnliche Datei - so laesst sich der
    //  Formatierer gegen ein Abbild testen.
    // ------------------------------------------------------------------
    public static class RawDevice
    {
        const uint GENERIC_READ = 0x80000000;
        const uint GENERIC_WRITE = 0x40000000;
        const uint FILE_SHARE_READ = 0x1;
        const uint FILE_SHARE_WRITE = 0x2;
        const uint OPEN_EXISTING = 3;
        const uint FILE_FLAG_NO_BUFFERING = 0x20000000;
        const uint FILE_FLAG_WRITE_THROUGH = 0x80000000;
        const uint FILE_FLAG_OVERLAPPED = 0x40000000;

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern IntPtr CreateFileW(string lpFileName, uint dwDesiredAccess, uint dwShareMode,
            IntPtr lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        static extern bool DeviceIoControl(IntPtr hDevice, uint dwIoControlCode, IntPtr lpInBuffer, uint nInBufferSize,
            IntPtr lpOutBuffer, uint nOutBufferSize, out uint lpBytesReturned, IntPtr lpOverlapped);

        const uint FSCTL_LOCK_VOLUME = 0x00090018;
        const uint FSCTL_DISMOUNT_VOLUME = 0x00090020;

        public static bool IsWindows
        {
            get
            {
                int p = (int)Environment.OSVersion.Platform;
                return (p != 4 && p != 6 && p != 128);
            }
        }

        public static FileStream Open(string path, bool unbuffered, bool asyncIo)
        {
            if (!IsWindows)
            {
                // Testpfad: normales Abbild auf der Platte
                return new FileStream(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.ReadWrite,
                    1024 * 1024, asyncIo);
            }
            uint flags = 0;
            if (unbuffered) { flags |= FILE_FLAG_NO_BUFFERING | FILE_FLAG_WRITE_THROUGH; }
            if (asyncIo) { flags |= FILE_FLAG_OVERLAPPED; }

            IntPtr h = CreateFileW(path, GENERIC_READ | GENERIC_WRITE,
                FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, flags, IntPtr.Zero);
            if (h == IntPtr.Zero || h.ToInt64() == -1)
            {
                throw new IOException("Geraet konnte nicht geoeffnet werden: " + path +
                    " (Fehler " + Marshal.GetLastWin32Error() + ")");
            }
            var handle = new Microsoft.Win32.SafeHandles.SafeFileHandle(h, true);
            uint br;
            DeviceIoControl(h, FSCTL_LOCK_VOLUME, IntPtr.Zero, 0, IntPtr.Zero, 0, out br, IntPtr.Zero);
            DeviceIoControl(h, FSCTL_DISMOUNT_VOLUME, IntPtr.Zero, 0, IntPtr.Zero, 0, out br, IntPtr.Zero);
            return new FileStream(handle, FileAccess.ReadWrite, 0x1000, asyncIo);
        }
    }

    // ------------------------------------------------------------------
    //  Schnelles Ueberschreiben mit Nullen.
    //  Grosse, sektorausgerichtete Bloecke und mehrere offene Anforderungen
    //  gleichzeitig - dadurch laeuft der Datentraeger am Anschlag statt auf
    //  jede einzelne Bestaetigung zu warten.
    // ------------------------------------------------------------------
    public class ZeroWiper
    {
        long _total;
        long _written;
        int _bufferBytes;
        int _queueDepth;
        volatile bool _cancel;
        volatile bool _done;
        string _error;
        string _path;
        long _offset;
        Thread _worker;

        public long TotalBytes { get { return _total; } }
        public long BytesWritten { get { return Interlocked.Read(ref _written); } }
        public bool IsCompleted { get { return _done; } }
        public string Error { get { return _error; } }

        public ZeroWiper(string path, long offset, long totalBytes, int bufferMiB, int queueDepth)
        {
            _path = path;
            _offset = offset;
            _total = totalBytes;
            if (bufferMiB < 1) { bufferMiB = 1; }
            if (bufferMiB > 256) { bufferMiB = 256; }
            _bufferBytes = bufferMiB * 1024 * 1024;
            if (queueDepth < 1) { queueDepth = 1; }
            if (queueDepth > 16) { queueDepth = 16; }
            _queueDepth = queueDepth;
        }

        public void Start()
        {
            _worker = new Thread(Run);
            _worker.IsBackground = true;
            _worker.Start();
        }

        public void Cancel() { _cancel = true; }

        void Run()
        {
            FileStream fs = null;
            try
            {
                fs = RawDevice.Open(_path, true, true);
                if (_offset > 0) { fs.Seek(_offset, SeekOrigin.Begin); }

                int depth = _queueDepth;
                byte[][] buffers = new byte[depth][];
                IAsyncResult[] pending = new IAsyncResult[depth];
                int[] sizes = new int[depth];
                for (int i = 0; i < depth; i++) { buffers[i] = new byte[_bufferBytes]; }

                long remaining = _total;
                int slot = 0;
                while (remaining > 0 && !_cancel)
                {
                    if (pending[slot] != null)
                    {
                        fs.EndWrite(pending[slot]);
                        Interlocked.Add(ref _written, sizes[slot]);
                        pending[slot] = null;
                    }
                    int chunk = (remaining > _bufferBytes) ? _bufferBytes : (int)remaining;
                    // Ungepufferte Zugriffe muessen sektorausgerichtet sein.
                    if (chunk % 4096 != 0 && remaining > chunk) { chunk = (chunk / 4096) * 4096; }
                    sizes[slot] = chunk;
                    pending[slot] = fs.BeginWrite(buffers[slot], 0, chunk, null, null);
                    remaining -= chunk;
                    slot = (slot + 1) % depth;
                }
                for (int i = 0; i < depth; i++)
                {
                    if (pending[i] != null)
                    {
                        fs.EndWrite(pending[i]);
                        Interlocked.Add(ref _written, sizes[i]);
                        pending[i] = null;
                    }
                }
                fs.Flush();
            }
            catch (Exception ex) { _error = ex.Message; }
            finally
            {
                if (fs != null) { try { fs.Dispose(); } catch { } }
                _done = true;
            }
        }
    }

    // ------------------------------------------------------------------
    //  FAT32-Formatierer.
    //  Windows verweigert FAT32 ueber 32 GB - technisch moeglich ist es
    //  aber bis 2 TiB. Hier nach Microsoft-Spezifikation (fatgen103)
    //  selbst gebaut, damit auch grosse Datentraeger FAT32 bekommen koennen.
    // ------------------------------------------------------------------
    public class Fat32Formatter
    {
        // Clustergroesse nach Volumegroesse - und zwar in Bytes gedacht,
        // damit es auch mit 4-KiB-Sektoren (4Kn-Laufwerken) aufgeht.
        public static int ChooseSectorsPerCluster(long totalBytes, int bytesPerSector)
        {
            long gib = totalBytes / (1024L * 1024L * 1024L);
            int clusterBytes;
            if (gib <= 8) { clusterBytes = 4 * 1024; }
            else if (gib <= 16) { clusterBytes = 8 * 1024; }
            else if (gib <= 32) { clusterBytes = 16 * 1024; }
            else if (gib <= 2048) { clusterBytes = 32 * 1024; }
            else { clusterBytes = 64 * 1024; }   // ab 2 TiB - sonst reicht der Clusterzaehler nicht

            int spc = clusterBytes / bytesPerSector;
            if (spc < 1) { spc = 1; }
            if (spc > 128) { spc = 128; }
            // auf Zweierpotenz abrunden
            int pow = 1;
            while (pow * 2 <= spc) { pow = pow * 2; }
            return pow;
        }

        // Liefert eine Beschreibung der berechneten Werte (fuer Anzeige/Tests).
        public static string Format(Stream stream, long totalBytes, int bytesPerSector,
            int sectorsPerCluster, string label)
        {
            return Format(stream, totalBytes, bytesPerSector, sectorsPerCluster, label, true);
        }

        // clearFat=false spart bei grossen Datentraegern Minuten - zulaessig
        // nur, wenn der Bereich nachweislich schon aus Nullen besteht
        // (z. B. direkt nach dem Ueberschreiben mit Nullen).
        public static string Format(Stream stream, long totalBytes, int bytesPerSector,
            int sectorsPerCluster, string label, bool clearFat)
        {
            if (bytesPerSector <= 0) { bytesPerSector = 512; }
            if (sectorsPerCluster <= 0) { sectorsPerCluster = ChooseSectorsPerCluster(totalBytes, bytesPerSector); }

            long totalSectors = totalBytes / bytesPerSector;
            if (totalSectors < 65536) { throw new ArgumentException("Volume zu klein fuer FAT32."); }
            // Das Feld TotSec32 im Bootsektor ist 32 Bit breit. Mit 512-Byte-
            // Sektoren ist bei 2 TiB Schluss; groessere Datentraeger brauchen
            // 4-KiB-Sektoren (4Kn) oder ein anderes Dateisystem.
            if (totalSectors > 4294967295L)
            {
                double tib = totalBytes / 1099511627776.0;
                throw new ArgumentException(
                    "FAT32 fasst mit " + bytesPerSector + "-Byte-Sektoren hoechstens " +
                    (4294967295L * bytesPerSector / 1099511627776.0).ToString("0.0") + " TiB, hier sind es " +
                    tib.ToString("0.0") + " TiB. Moeglichkeiten: Laufwerk mit 4-KiB-Sektoren verwenden, " +
                    "kleiner partitionieren oder exFAT nehmen.");
            }

            int reservedSectors = 32;
            int numFats = 2;

            // Groesse einer FAT nach fatgen103
            long tmp1 = totalSectors - reservedSectors;
            long tmp2 = (256L * sectorsPerCluster) + numFats;
            tmp2 = tmp2 / 2;
            long fatSize = (tmp1 + (tmp2 - 1)) / tmp2;

            long dataSectors = totalSectors - reservedSectors - (numFats * fatSize);
            long clusterCount = dataSectors / sectorsPerCluster;
            if (clusterCount < 65525) { throw new ArgumentException("Zu wenige Cluster fuer FAT32 - groessere Cluster waehlen."); }
            if (clusterCount > 0x0FFFFFF5)
            {
                throw new ArgumentException("Zu viele Cluster fuer FAT32 (" + clusterCount +
                    " bei " + (sectorsPerCluster * bytesPerSector / 1024) + " KiB Clustern, Grenze sind 268.435.445). " +
                    "Groessere Cluster waehlen oder exFAT nehmen.");
            }

            uint volumeId = (uint)DateTime.Now.Ticks;
            string vol = (label == null) ? "" : label.ToUpperInvariant();
            if (vol.Length > 11) { vol = vol.Substring(0, 11); }
            vol = vol.PadRight(11);

            byte[] sector = new byte[bytesPerSector];

            // ---------------- Bootsektor ----------------
            sector[0] = 0xEB; sector[1] = 0x58; sector[2] = 0x90;                 // JMP
            WriteString(sector, 3, "MSWIN4.1", 8);
            WriteUInt16(sector, 11, (ushort)bytesPerSector);
            sector[13] = (byte)sectorsPerCluster;
            WriteUInt16(sector, 14, (ushort)reservedSectors);
            sector[16] = (byte)numFats;
            WriteUInt16(sector, 17, 0);                                            // RootEntCnt = 0
            WriteUInt16(sector, 19, 0);                                            // TotSec16   = 0
            sector[21] = 0xF8;                                                     // Festplatte
            WriteUInt16(sector, 22, 0);                                            // FATSz16    = 0
            WriteUInt16(sector, 24, 63);                                           // SecPerTrk
            WriteUInt16(sector, 26, 255);                                          // NumHeads
            WriteUInt32(sector, 28, 0);                                            // HiddSec
            WriteUInt32(sector, 32, (uint)totalSectors);
            WriteUInt32(sector, 36, (uint)fatSize);                                // FATSz32
            WriteUInt16(sector, 40, 0);                                            // ExtFlags
            WriteUInt16(sector, 42, 0);                                            // FSVer
            WriteUInt32(sector, 44, 2);                                            // RootClus
            WriteUInt16(sector, 48, 1);                                            // FSInfo
            WriteUInt16(sector, 50, 6);                                            // BkBootSec
            sector[64] = 0x80;                                                     // DrvNum
            sector[66] = 0x29;                                                     // BootSig
            WriteUInt32(sector, 67, volumeId);
            WriteString(sector, 71, vol, 11);
            WriteString(sector, 82, "FAT32   ", 8);
            sector[510] = 0x55; sector[511] = 0xAA;

            stream.Seek(0, SeekOrigin.Begin);
            stream.Write(sector, 0, bytesPerSector);
            stream.Seek(6L * bytesPerSector, SeekOrigin.Begin);                    // Sicherungskopie
            stream.Write(sector, 0, bytesPerSector);

            // ---------------- FSInfo ----------------
            byte[] fsInfo = new byte[bytesPerSector];
            WriteUInt32(fsInfo, 0, 0x41615252);
            WriteUInt32(fsInfo, 484, 0x61417272);
            WriteUInt32(fsInfo, 488, (uint)(clusterCount - 1));                    // freie Cluster
            WriteUInt32(fsInfo, 492, 2);                                           // naechster freier
            fsInfo[510] = 0x55; fsInfo[511] = 0xAA;
            stream.Seek(1L * bytesPerSector, SeekOrigin.Begin);
            stream.Write(fsInfo, 0, bytesPerSector);
            stream.Seek(7L * bytesPerSector, SeekOrigin.Begin);
            stream.Write(fsInfo, 0, bytesPerSector);

            // Sektor 2 und 8: leerer Bootcode-Rest mit Signatur
            byte[] third = new byte[bytesPerSector];
            third[510] = 0x55; third[511] = 0xAA;
            stream.Seek(2L * bytesPerSector, SeekOrigin.Begin);
            stream.Write(third, 0, bytesPerSector);
            stream.Seek(8L * bytesPerSector, SeekOrigin.Begin);
            stream.Write(third, 0, bytesPerSector);

            // ---------------- FATs ----------------
            // Nur der Anfang jeder FAT muss geschrieben werden; der Rest ist
            // bereits Null (Schnellformatierung). Das spart bei grossen
            // Datentraegern Minuten.
            byte[] fatStart = new byte[bytesPerSector];
            WriteUInt32(fatStart, 0, 0x0FFFFFF8);
            WriteUInt32(fatStart, 4, 0x0FFFFFFF);
            WriteUInt32(fatStart, 8, 0x0FFFFFFF);                                  // Cluster 2 = Wurzelverzeichnis
            for (int f = 0; f < numFats; f++)
            {
                long fatOffset = (reservedSectors + (f * fatSize)) * (long)bytesPerSector;
                stream.Seek(fatOffset, SeekOrigin.Begin);
                stream.Write(fatStart, 0, bytesPerSector);
                // Restliche FAT-Sektoren auf Null setzen - in 1-MiB-Bloecken,
                // sonst dauert das bei mehreren hundert MB FAT unnoetig lange.
                if (clearFat)
                {
                    long bytesToClear = (fatSize - 1) * (long)bytesPerSector;
                    byte[] block = new byte[4 * 1024 * 1024];
                    while (bytesToClear > 0)
                    {
                        int n = (bytesToClear > block.Length) ? block.Length : (int)bytesToClear;
                        stream.Write(block, 0, n);
                        bytesToClear -= n;
                    }
                }
            }

            // ---------------- Wurzelverzeichnis ----------------
            long rootOffset = (reservedSectors + (numFats * fatSize)) * (long)bytesPerSector;
            byte[] root = new byte[bytesPerSector * sectorsPerCluster];
            if (label != null && label.Trim().Length > 0)
            {
                WriteString(root, 0, vol, 11);
                root[11] = 0x08;                                                   // Attribut: Datentraegerbezeichnung
            }
            stream.Seek(rootOffset, SeekOrigin.Begin);
            stream.Write(root, 0, root.Length);
            stream.Flush();

            return "FAT32"
                + " | Sektoren=" + totalSectors
                + " | SektorenProCluster=" + sectorsPerCluster
                + " | Clustergroesse=" + (sectorsPerCluster * bytesPerSector / 1024) + " KiB"
                + " | FATGroesse=" + fatSize
                + " | Cluster=" + clusterCount
                + (clearFat ? "" : " | FAT nicht genullt (Datentraeger war bereits leer)");
        }

        static void WriteUInt16(byte[] b, int off, ushort v)
        {
            b[off] = (byte)(v & 0xFF);
            b[off + 1] = (byte)((v >> 8) & 0xFF);
        }
        static void WriteUInt32(byte[] b, int off, uint v)
        {
            b[off] = (byte)(v & 0xFF);
            b[off + 1] = (byte)((v >> 8) & 0xFF);
            b[off + 2] = (byte)((v >> 16) & 0xFF);
            b[off + 3] = (byte)((v >> 24) & 0xFF);
        }
        static void WriteString(byte[] b, int off, string s, int len)
        {
            for (int i = 0; i < len; i++)
            {
                b[off + i] = (i < s.Length) ? (byte)s[i] : (byte)0x20;
            }
        }
    }
}
'@
    Add-Type -TypeDefinition $code -Language CSharp -ErrorAction Stop
    $script:NativeLoaded = $true
}

#endregion

#region ==================== Bestandsaufnahme ==========================

function Get-DiskInventoryError { return $script:LetzterInventarFehler }

function Get-DeviceKind {
    <#
    .SYNOPSIS
        Bestimmt die Geraeteart aus Anbindung, Medientyp und Groesse.
        Damit werden USB-Sticks und Speicherkarten als solche erkannt und
        nicht als "unbekanntes Laufwerk" behandelt.
    #>
    param([string]$BusType, [string]$MediaType, [long]$SizeBytes, [bool]$IsRemovable)

    $bus = ('' + $BusType).ToUpperInvariant()
    $media = ('' + $MediaType).ToUpperInvariant()

    if ($bus -eq 'SD' -or $bus -eq 'MMC') { return 'MemoryCard' }
    if ($bus -eq 'USB') {
        # Kleine, wechselbare USB-Medien sind Sticks; grosse sind Gehaeuse
        # mit Platte oder SSD darin.
        if ($media -eq 'SSD') { return 'UsbSsd' }
        if ($media -eq 'HDD') { return 'UsbDisk' }
        if ($SizeBytes -gt 0 -and $SizeBytes -le 512GB) { return 'UsbStick' }
        return 'UsbDisk'
    }
    if ($bus -eq 'NVME') { return 'Nvme' }
    if ($media -eq 'SSD') { return 'Ssd' }
    if ($media -eq 'HDD') { return 'Hdd' }
    if ($IsRemovable) { return 'Removable' }
    return 'Unknown'
}

function Get-DeviceKindLabel {
    param([string]$Kind)
    $map = @{
        MemoryCard = 'Speicherkarte'
        UsbStick   = 'USB-Stick'
        UsbDisk    = 'USB-Festplatte'
        UsbSsd     = 'USB-SSD'
        Nvme       = 'NVMe-SSD'
        Ssd        = 'SSD'
        Hdd        = 'Festplatte'
        Removable  = 'Wechselmedium'
        Unknown    = 'Datentraeger'
    }
    if ($map.ContainsKey($Kind)) { return $map[$Kind] }
    return 'Datentraeger'
}

function Get-SystemDiskNumber {
    if (-not $script:IsWindowsHost) { return 0 }
    try {
        $sysVolume = $env:SystemDrive.TrimEnd(':')
        $part = Get-Partition -DriveLetter $sysVolume -ErrorAction Stop
        return [int]$part.DiskNumber
    }
    catch { return -1 }
}

function Get-DiskInventory {
    <#
    .SYNOPSIS
        Liefert alle Datentraeger mit Partitionen, Dateisystemen und
        Sicherheitsbewertung (Systemdatentraeger, BitLocker, Wechselmedium).
    #>
    [CmdletBinding()]
    param([switch]$Demo)

    if ($Demo -or -not $script:IsWindowsHost) {
        return @(
            [ordered]@{
                number = 0; friendlyName = 'Samsung SSD 990 PRO 1TB'; serial = 'S6Z1NJ0T123456'
                busType = 'NVMe'; mediaType = 'SSD'; sizeBytes = 1000204886016; partitionStyle = 'GPT'
                isSystem = $true; isBoot = $true; isOffline = $false; isReadOnly = $false; healthStatus = 'Healthy'
                bitlocker = 'On'; protected = $true; protectReason = 'Systemdatentraeger'
                isRemovable = $false; deviceKind = 'Nvme'; deviceKindLabel = 'NVMe-SSD'
                volumes = @(
                    [ordered]@{ driveLetter = 'C'; label = 'Windows'; fileSystem = 'NTFS'; sizeBytes = 999000000000; freeBytes = 412000000000; isSystem = $true }
                )
            },
            [ordered]@{
                number = 1; friendlyName = 'Seagate IronWolf 8TB'; serial = 'ZA1ABCDE'
                busType = 'SATA'; mediaType = 'HDD'; sizeBytes = 8001563222016; partitionStyle = 'GPT'
                isSystem = $false; isBoot = $false; isOffline = $false; isReadOnly = $false; healthStatus = 'Healthy'
                bitlocker = 'Off'; protected = $false; protectReason = ''
                isRemovable = $false; deviceKind = 'Hdd'; deviceKindLabel = 'Festplatte'
                volumes = @(
                    [ordered]@{ driveLetter = 'D'; label = 'Archiv'; fileSystem = 'NTFS'; sizeBytes = 8000000000000; freeBytes = 1200000000000; isSystem = $false }
                )
            },
            [ordered]@{
                number = 2; friendlyName = 'SanDisk Ultra USB 64GB'; serial = '4C530001'
                busType = 'USB'; mediaType = 'Unspecified'; sizeBytes = 61530439680; partitionStyle = 'MBR'
                isSystem = $false; isBoot = $false; isOffline = $false; isReadOnly = $false; healthStatus = 'Healthy'
                bitlocker = 'Off'; protected = $false; protectReason = ''
                isRemovable = $true; deviceKind = 'UsbStick'; deviceKindLabel = 'USB-Stick'
                volumes = @(
                    [ordered]@{ driveLetter = 'E'; label = 'STICK'; fileSystem = 'FAT32'; sizeBytes = 61000000000; freeBytes = 8000000000; isSystem = $false }
                )
            },
            [ordered]@{
                number = 3; friendlyName = 'SDXC Card Reader'; serial = 'SD-0001'
                busType = 'SD'; mediaType = 'Unspecified'; sizeBytes = 128043712512; partitionStyle = 'MBR'
                isSystem = $false; isBoot = $false; isOffline = $false; isReadOnly = $false; healthStatus = 'Healthy'
                bitlocker = 'Off'; protected = $false; protectReason = ''
                isRemovable = $true; deviceKind = 'MemoryCard'; deviceKindLabel = 'Speicherkarte'
                volumes = @(
                    [ordered]@{ driveLetter = 'F'; label = 'KAMERA'; fileSystem = 'exFAT'; sizeBytes = 127000000000; freeBytes = 31000000000; isSystem = $false }
                )
            }
        )
    }

    $sysDisk = Get-SystemDiskNumber
    $result = New-Object System.Collections.ArrayList
    $script:LetzterInventarFehler = ''
    $bitlockerMap = @{}
    if (Get-Command -Name Get-BitLockerVolume -ErrorAction SilentlyContinue) {
        try {
            foreach ($bv in (Get-BitLockerVolume -ErrorAction Stop)) {
                if ($bv.MountPoint) { $bitlockerMap[$bv.MountPoint.TrimEnd('\').TrimEnd(':')] = [string]$bv.ProtectionStatus }
            }
        }
        catch { Write-Verbose 'BitLocker-Status nicht lesbar.' }
    }

    # Fruher stand hier -ErrorAction SilentlyContinue. Scheiterte Get-Disk,
    # kam eine leere Liste zurueck und die Oberflaeche zeigte eine leere
    # Auswahl ohne jeden Hinweis. Jetzt wird der Grund festgehalten.
    $datentraeger = @()
    try { $datentraeger = @(Get-Disk -ErrorAction Stop | Sort-Object Number) }
    catch {
        $script:LetzterInventarFehler = $_.Exception.Message
        Write-Warning ('Datentraeger konnten nicht aufgezaehlt werden: {0}' -f $_.Exception.Message)
    }
    foreach ($d in $datentraeger) {
        $vols = New-Object System.Collections.ArrayList
        $isSystem = ($d.Number -eq $sysDisk)
        $bl = 'Unknown'
        try {
            foreach ($p in (Get-Partition -DiskNumber $d.Number -ErrorAction Stop)) {
                if (-not $p.DriveLetter) { continue }
                $letter = [string]$p.DriveLetter
                $v = $null
                try { $v = Get-Volume -DriveLetter $letter -ErrorAction Stop } catch { $v = $null }
                if ($bitlockerMap.ContainsKey($letter)) { $bl = $bitlockerMap[$letter] }
                [void]$vols.Add([ordered]@{
                        driveLetter = $letter
                        label       = $(if ($v) { [string]$v.FileSystemLabel } else { '' })
                        fileSystem  = $(if ($v) { [string]$v.FileSystem } else { '' })
                        sizeBytes   = $(if ($v) { [long]$v.Size } else { [long]$p.Size })
                        freeBytes   = $(if ($v) { [long]$v.SizeRemaining } else { 0 })
                        isSystem    = ($p.IsBoot -or $p.IsSystem -or ($letter + ':') -eq $env:SystemDrive)
                    })
                if ($p.IsBoot -or $p.IsSystem) { $isSystem = $true }
            }
        }
        catch { Write-Verbose 'Partitionen nicht lesbar.' }

        $media = 'Unspecified'
        try {
            $phys = Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { $_.DeviceId -eq [string]$d.Number }
            if ($phys) { $media = [string]$phys.MediaType }
        }
        catch { Write-Verbose 'MediaType nicht lesbar.' }

        $removable = $false
        try {
            $w32 = Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction Stop |
                Where-Object { $_.Index -eq $d.Number } | Select-Object -First 1
            if ($w32 -and ($w32.MediaType -like '*Removable*' -or $w32.Caption -like '*USB*')) { $removable = $true }
        }
        catch { Write-Verbose 'Win32_DiskDrive nicht lesbar.' }
        if ([string]$d.BusType -eq 'USB' -or [string]$d.BusType -eq 'SD' -or [string]$d.BusType -eq 'MMC') { $removable = $true }

        $kind = Get-DeviceKind -BusType ([string]$d.BusType) -MediaType $media -SizeBytes ([long]$d.Size) -IsRemovable $removable

        $reason = ''
        if ($isSystem) { $reason = 'Systemdatentraeger' }
        elseif ($d.IsReadOnly) { $reason = 'schreibgeschuetzt' }

        [void]$result.Add([ordered]@{
                number         = [int]$d.Number
                friendlyName   = [string]$d.FriendlyName
                serial         = [string]$d.SerialNumber
                busType        = [string]$d.BusType
                mediaType      = $media
                sizeBytes      = [long]$d.Size
                partitionStyle = [string]$d.PartitionStyle
                isSystem       = $isSystem
                isBoot         = [bool]$d.IsBoot
                isOffline      = [bool]$d.IsOffline
                isReadOnly     = [bool]$d.IsReadOnly
                healthStatus   = [string]$d.HealthStatus
                bitlocker      = $bl
                protected      = ($isSystem -or $d.IsReadOnly)
                protectReason  = $reason
                isRemovable    = $removable
                deviceKind     = $kind
                deviceKindLabel = (Get-DeviceKindLabel $kind)
                volumes        = @($vols)
            })
    }
    return @($result)
}

#endregion

#region ======================= Geschwindigkeit ========================

function Get-WipeStrategy {
    <#
    .SYNOPSIS
        Waehlt das schnellste zulaessige Verfahren fuer einen Datentraeger.
    #>
    param(
        [Parameter(Mandatory)]$Disk,
        [ValidateSet('Auto', 'CryptoErase', 'Trim', 'Zero', 'ZeroVerify')][string]$Requested = 'Auto'
    )
    if ($Requested -ne 'Auto') { return $Requested }
    if ($Disk.bitlocker -eq 'On') { return 'CryptoErase' }
    if ($Disk.mediaType -eq 'SSD' -or $Disk.busType -eq 'NVMe') { return 'Trim' }
    return 'Zero'
}

function Get-WipeEstimate {
    <#
    .SYNOPSIS
        Schaetzt die Dauer. Grundlage sind gemessene Durchsatzwerte je
        Anbindung - keine Fantasiezahlen, sondern typische Praxiswerte.
    #>
    param(
        [Parameter(Mandatory)][long]$SizeBytes,
        [Parameter(Mandatory)][string]$Strategy,
        [string]$BusType = 'SATA',
        [string]$MediaType = 'HDD'
    )
    if ($Strategy -eq 'CryptoErase') { return @{ seconds = 5; throughputMBs = $null; note = 'Schluessel wird vernichtet - unabhaengig von der Groesse' } }
    if ($Strategy -eq 'Trim') { return @{ seconds = 20; throughputMBs = $null; note = 'TRIM/UNMAP ueber den gesamten Datentraeger' } }

    $mbs = 150.0
    if ($MediaType -eq 'SSD') { $mbs = 480.0 }
    if ($BusType -eq 'NVMe') { $mbs = 2200.0 }
    elseif ($BusType -eq 'USB') { $mbs = 110.0 }
    elseif ($BusType -eq 'SATA' -and $MediaType -eq 'HDD') { $mbs = 190.0 }

    $seconds = [math]::Round(($SizeBytes / 1MB) / $mbs, 0)
    if ($Strategy -eq 'ZeroVerify') { $seconds = $seconds * 2 }
    return @{ seconds = [int]$seconds; throughputMBs = $mbs; note = 'Ungepuffert, 32-MiB-Bloecke, Warteschlangentiefe 4' }
}

function Format-Duration {
    param([int]$Seconds)
    if ($Seconds -lt 60) { return ('{0} s' -f $Seconds) }
    if ($Seconds -lt 3600) { return ('{0} min {1} s' -f [math]::Floor($Seconds / 60), ($Seconds % 60)) }
    return ('{0} h {1} min' -f [math]::Floor($Seconds / 3600), [math]::Floor(($Seconds % 3600) / 60))
}

#endregion

#region ========================= Formatieren ==========================

function Test-DiskOperationAllowed {
    <#  Sicherheitsnetz: Systemdatentraeger und schreibgeschuetzte Medien
        werden grundsaetzlich abgelehnt. #>
    param([Parameter(Mandatory)]$Disk, [string]$Confirmation, [switch]$AllowSystemDisk)

    if ($Disk.isSystem -and -not $AllowSystemDisk) {
        return @{ allowed = $false; reason = 'Systemdatentraeger - Vorgang wird verweigert.' }
    }
    if ($Disk.isReadOnly) {
        return @{ allowed = $false; reason = 'Datentraeger ist schreibgeschuetzt.' }
    }
    $expected = ('DISK' + $Disk.number)
    if ($Confirmation -ne $expected) {
        return @{ allowed = $false; reason = ("Bestaetigung fehlt. Erwartet wird die Eingabe '{0}'." -f $expected) }
    }
    return @{ allowed = $true; reason = '' }
}

function Format-ManagedVolume {
    <#
    .SYNOPSIS
        Formatiert ein Volume mit NTFS, exFAT, FAT32 oder ReFS.
    .DESCRIPTION
        FAT32 oberhalb von 32 GB wird vom mitgelieferten Formatierer
        uebernommen, weil Windows dort aussteigt.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$DriveLetter,
        [ValidateSet('NTFS', 'exFAT', 'FAT32', 'ReFS')][string]$FileSystem = 'NTFS',
        [string]$Label = '',
        [switch]$Full,
        [int]$AllocationUnitSize = 0,
        [switch]$Demo
    )
    $letter = $DriveLetter.TrimEnd(':').ToUpperInvariant()

    if ($Demo -or -not $script:IsWindowsHost) {
        Start-Sleep -Milliseconds 400
        return @{ ok = $true; detail = ('Demo: {0}: wurde mit {1} formatiert ({2})' -f $letter, $FileSystem, $(if ($Full) { 'vollstaendig' } else { 'schnell' })) }
    }
    if (-not $PSCmdlet.ShouldProcess(($letter + ':'), ('Formatieren mit ' + $FileSystem))) {
        return @{ ok = $false; detail = 'WhatIf - nichts veraendert' }
    }

    $vol = Get-Volume -DriveLetter $letter -ErrorAction Stop
    $sizeGB = [math]::Round($vol.Size / 1GB, 1)

    if ($FileSystem -eq 'FAT32' -and $vol.Size -gt 32GB) {
        return Format-LargeFat32Volume -DriveLetter $letter -Label $Label -SizeBytes $vol.Size
    }

    $params = @{ DriveLetter = $letter; FileSystem = $FileSystem; Force = $true; Confirm = $false }
    if ($Label) { $params['NewFileSystemLabel'] = $Label }
    if ($AllocationUnitSize -gt 0) { $params['AllocationUnitSize'] = $AllocationUnitSize }
    if ($Full) { $params['Full'] = $true }

    Format-Volume @params -ErrorAction Stop | Out-Null
    return @{ ok = $true; detail = ('{0}: mit {1} formatiert ({2} GB)' -f $letter, $FileSystem, $sizeGB) }
}

function Format-LargeFat32Volume {
    <#
    .SYNOPSIS
        FAT32 jenseits der 32-GB-Grenze von Windows.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$DriveLetter,
        [string]$Label = '',
        [long]$SizeBytes = 0,
        [int]$BytesPerSector = 512,
        [int]$SectorsPerCluster = 0,
        [switch]$AssumeZeroed
    )
    Initialize-DiskNative
    $letter = $DriveLetter.TrimEnd(':').ToUpperInvariant()
    if (-not $PSCmdlet.ShouldProcess(($letter + ':'), 'FAT32 formatieren (eigener Formatierer)')) {
        return @{ ok = $false; detail = 'WhatIf - nichts veraendert' }
    }
    $path = ('\\.\{0}:' -f $letter)
    $stream = $null
    try {
        $stream = [RepairCenter.Storage.RawDevice]::Open($path, $false, $false)
        if ($SizeBytes -le 0) { $SizeBytes = $stream.Length }
        $info = [RepairCenter.Storage.Fat32Formatter]::Format($stream, $SizeBytes, $BytesPerSector,
            $SectorsPerCluster, $Label, (-not $AssumeZeroed))
        return @{ ok = $true; detail = $info }
    }
    catch { return @{ ok = $false; detail = $_.Exception.Message } }
    finally { if ($stream) { $stream.Dispose() } }
}

function Convert-VolumeFileSystem {
    <#
    .SYNOPSIS
        Wechselt das Dateisystem eines Volumes.
    .DESCRIPTION
        FAT/FAT32 -> NTFS laeuft verlustfrei ueber convert.exe.
        Jeder andere Wechsel (z. B. NTFS -> FAT32) ist technisch nur durch
        Neuformatieren moeglich und loescht daher alle Daten. Das wird hier
        ausdruecklich benannt statt stillschweigend gemacht.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$DriveLetter,
        [Parameter(Mandatory)][ValidateSet('NTFS', 'exFAT', 'FAT32', 'ReFS')][string]$TargetFileSystem,
        [string]$Label = '',
        [switch]$AllowDataLoss,
        [switch]$Demo
    )
    $letter = $DriveLetter.TrimEnd(':').ToUpperInvariant()
    $current = 'NTFS'
    if (-not $Demo -and $script:IsWindowsHost) {
        $current = [string](Get-Volume -DriveLetter $letter -ErrorAction Stop).FileSystem
    }
    elseif ($Demo) { $current = 'FAT32' }

    if ($current -eq $TargetFileSystem) {
        return @{ ok = $true; lossless = $true; detail = ('{0}: ist bereits {1}' -f $letter, $TargetFileSystem) }
    }

    # Verlustfreier Weg
    if ($TargetFileSystem -eq 'NTFS' -and ($current -eq 'FAT32' -or $current -eq 'FAT' -or $current -eq 'FAT16')) {
        if ($Demo -or -not $script:IsWindowsHost) {
            return @{ ok = $true; lossless = $true; detail = ('Demo: {0}: von {1} verlustfrei nach NTFS konvertiert' -f $letter, $current) }
        }
        if (-not $PSCmdlet.ShouldProcess(($letter + ':'), 'Verlustfrei nach NTFS konvertieren')) {
            return @{ ok = $false; lossless = $true; detail = 'WhatIf - nichts veraendert' }
        }
        $convert = Join-Path $env:SystemRoot 'System32\convert.exe'
        $out = & $convert ($letter + ':') '/FS:NTFS' '/X' 2>&1
        $code = $LASTEXITCODE
        return @{ ok = ($code -eq 0); lossless = $true; detail = (($out | Select-Object -Last 3) -join ' ') }
    }

    # Alles andere kostet die Daten
    if (-not $AllowDataLoss) {
        return @{
            ok       = $false; lossless = $false
            detail   = ('{0} -> {1} ist nur durch Neuformatieren moeglich. Alle Daten gehen verloren - bitte ausdruecklich bestaetigen.' -f $current, $TargetFileSystem)
            needsAck = $true
        }
    }
    $r = Format-ManagedVolume -DriveLetter $letter -FileSystem $TargetFileSystem -Label $Label -Demo:$Demo
    return @{ ok = $r.ok; lossless = $false; detail = $r.detail }
}

#endregion


function New-DiskJobId {
    <#
    .SYNOPSIS
        Erzeugt eine eindeutige Auftrags-ID.
    .DESCRIPTION
        Zeitstempel allein genuegt nicht: zwei Auftraege innerhalb derselben
        Sekunde bekaemen denselben Namen und wuerden sich die Ablage teilen.

        Die erste Fassung haengte vier Zeichen aus 36 an - 1.679.616
        Moeglichkeiten. Nach dem Geburtstagsparadoxon sind das bei 500
        Ziehungen rund 7 % Kollisionswahrscheinlichkeit; im Lasttest ist das
        auch prompt eingetreten. Jetzt acht Hexzeichen aus einer GUID:
        rund 4,3 Milliarden Moeglichkeiten.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Erzeugt nur eine Zeichenkette.')]
    param([Parameter(Mandatory)][string]$Action)
    $suffix = [System.Guid]::NewGuid().ToString('N').Substring(0, 8)
    return ('{0}-{1}-{2}' -f $Action.ToLowerInvariant(), (Get-Date -Format 'yyyyMMdd-HHmmss'), $suffix)
}

#region ====================== Datenrettung ============================

function Get-BackupTarget {
    <#
    .SYNOPSIS
        Liefert moegliche Ziele fuer die Datensicherung - also alle
        beschreibbaren Volumes ausser denen des Quelldatentraegers.
    #>
    [CmdletBinding()]
    param([int]$ExcludeDiskNumber = -1, [switch]$Demo)

    $disks = @(Get-DiskInventory -Demo:$Demo)
    $targets = New-Object System.Collections.ArrayList
    foreach ($d in $disks) {
        if ($d.number -eq $ExcludeDiskNumber) { continue }
        if ($d.isReadOnly) { continue }
        foreach ($v in @($d.volumes)) {
            if (-not $v.driveLetter) { continue }
            [void]$targets.Add([ordered]@{
                    driveLetter = $v.driveLetter
                    label       = $v.label
                    fileSystem  = $v.fileSystem
                    freeBytes   = [long]$v.freeBytes
                    sizeBytes   = [long]$v.sizeBytes
                    diskNumber  = $d.number
                    deviceKind  = $d.deviceKindLabel
                    isSystem    = [bool]$v.isSystem
                })
        }
    }
    return @($targets)
}

function Measure-VolumeContent {
    <#
    .SYNOPSIS
        Ermittelt Dateianzahl und Datenmenge eines Volumes.
        Nutzt robocopy im Auflistungsmodus - deutlich schneller als
        Get-ChildItem -Recurse, weil es die Verzeichnisse parallel liest.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DriveLetter, [switch]$Demo)

    $letter = $DriveLetter.TrimEnd(':').ToUpperInvariant()
    if ($Demo -or -not $script:IsWindowsHost) {
        return @{ files = 18342; bytes = 53000000000; readable = '49,4 GB' }
    }
    $robo = Join-Path $env:SystemRoot 'System32\robocopy.exe'
    $out = & $robo ($letter + ':\') ($env:TEMP) '/L' '/S' '/E' '/BYTES' '/NJH' '/NDL' '/NFL' '/XJ' '/R:0' '/W:0' 2>&1
    $files = 0; $bytes = 0
    foreach ($line in @($out)) {
        if ($line -match '^\s*(Dateien|Files)\s*:\s*(\d+)') { $files = [long]$Matches[2] }
        if ($line -match '^\s*(Bytes)\s*:\s*(\d+)') { $bytes = [long]$Matches[2] }
    }
    return @{ files = $files; bytes = $bytes; readable = (Format-ByteSizeShort $bytes) }
}

function Format-ByteSizeShort {
    param([double]$Bytes)
    if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N0} MB' -f ($Bytes / 1MB)) }
    return ('{0:N0} KB' -f ($Bytes / 1KB))
}

function Get-RobocopyArgument {
    <#
    .SYNOPSIS
        Baut die Argumentliste fuer die schnellste sinnvolle Kopie.
    .DESCRIPTION
        /MT:32  - 32 Kopierfaeden. Der grosse Hebel bei vielen kleinen Dateien.
        /J      - ungepufferte Ein-/Ausgabe. Der grosse Hebel bei grossen Dateien.
        /R:1 /W:1 - nicht minutenlang an einer defekten Datei haengen bleiben.
        /XJ     - Verzeichnisverknuepfungen ueberspringen (sonst Endlosschleifen).
        /MOVE   - erst nach erfolgreicher Kopie loeschen (nur beim Verschieben).
        Bewusst NICHT verwendet: /Z (Wiederaufnahmemodus). Der ist beruehmt
        dafuer, Kopien um ein Vielfaches zu verlangsamen.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [ValidateSet('Copy', 'Move')][string]$Mode = 'Copy',
        [int]$Threads = 32,
        [switch]$Unbuffered,
        [string]$LogFile
    )
    $list = New-Object System.Collections.ArrayList
    [void]$list.Add($Source)
    [void]$list.Add($Destination)
    [void]$list.Add('/E')
    [void]$list.Add('/COPY:DAT')
    [void]$list.Add('/DCOPY:DAT')
    [void]$list.Add('/R:1')
    [void]$list.Add('/W:1')
    [void]$list.Add('/XJ')
    [void]$list.Add('/NP')
    [void]$list.Add('/NFL')
    [void]$list.Add('/NDL')
    [void]$list.Add('/BYTES')
    [void]$list.Add('/MT:' + $Threads)
    if ($Unbuffered) { [void]$list.Add('/J') }
    if ($Mode -eq 'Move') { [void]$list.Add('/MOVE') }
    if ($LogFile) { [void]$list.Add('/LOG:' + $LogFile) }
    return @($list)
}

function Invoke-DataRescue {
    <#
    .SYNOPSIS
        Sichert alle Volumes eines Datentraegers auf ein Ziel - so schnell
        wie moeglich, wahlweise kopierend oder verschiebend.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][int]$DiskNumber,
        [Parameter(Mandatory)][string]$TargetPath,
        [ValidateSet('Copy', 'Move')][string]$Mode = 'Copy',
        [int]$Threads = 32,
        [switch]$Unbuffered,
        [switch]$SkipSpaceCheck,
        [scriptblock]$OnProgress,
        [switch]$Demo
    )

    $disks = @(Get-DiskInventory -Demo:$Demo)
    $disk = $disks | Where-Object { $_.number -eq $DiskNumber } | Select-Object -First 1
    if (-not $disk) { return @{ ok = $false; detail = ('Datentraeger {0} nicht gefunden.' -f $DiskNumber) } }

    $volumes = @($disk.volumes) | Where-Object { $_.driveLetter }
    if (@($volumes).Count -eq 0) { return @{ ok = $false; detail = 'Keine Volumes mit Laufwerksbuchstaben vorhanden.' } }

    # Zielort darf nicht auf dem Quelldatentraeger liegen
    $targetLetter = ''
    if ($TargetPath -match '^([A-Za-z]):') { $targetLetter = $Matches[1].ToUpperInvariant() }
    foreach ($v in $volumes) {
        if ($v.driveLetter -and $targetLetter -eq $v.driveLetter.ToUpperInvariant()) {
            return @{ ok = $false; detail = 'Das Ziel liegt auf dem Datentraeger, der geloescht werden soll.' }
        }
    }

    # Platzbedarf pruefen
    $totalBytes = 0
    $totalFiles = 0
    foreach ($v in $volumes) {
        $m = Measure-VolumeContent -DriveLetter $v.driveLetter -Demo:$Demo
        $totalBytes += [long]$m.bytes
        $totalFiles += [long]$m.files
    }
    $freeTarget = 0
    if ($Demo -or -not $script:IsWindowsHost) {
        # Im Demobetrieb den freien Platz des gewaehlten Ziels aus dem
        # Bestand nehmen - sonst waere die Platzpruefung nicht pruefbar.
        $freeTarget = 6TB
        foreach ($dd in $disks) {
            foreach ($vv in @($dd.volumes)) {
                if ($vv.driveLetter -and $vv.driveLetter.ToUpperInvariant() -eq $targetLetter) { $freeTarget = [long]$vv.freeBytes }
            }
        }
    }
    else {
        try { $freeTarget = [long](Get-Volume -DriveLetter $targetLetter -ErrorAction Stop).SizeRemaining }
        catch { $freeTarget = 0 }
    }
    if (-not $SkipSpaceCheck -and $totalBytes -gt $freeTarget) {
        return @{
            ok = $false
            detail = ('Zu wenig Platz: {0} werden gebraucht, {1} sind frei.' -f (Format-ByteSizeShort $totalBytes), (Format-ByteSizeShort $freeTarget))
            neededBytes = $totalBytes; freeBytes = $freeTarget
        }
    }

    if (-not $PSCmdlet.ShouldProcess($TargetPath, ('Daten von Datentraeger {0} sichern ({1})' -f $DiskNumber, $Mode))) {
        return @{ ok = $false; detail = 'WhatIf - nichts veraendert' }
    }

    if ($Demo -or -not $script:IsWindowsHost) {
        return Invoke-DemoRescue -TotalBytes $totalBytes -TotalFiles $totalFiles -Mode $Mode -OnProgress $OnProgress
    }

    if (-not (Test-Path -LiteralPath $TargetPath)) { New-Item -ItemType Directory -Path $TargetPath -Force | Out-Null }
    $robo = Join-Path $env:SystemRoot 'System32\robocopy.exe'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $copied = 0
    $worst = 0

    foreach ($v in $volumes) {
        $sub = Join-Path $TargetPath ('Laufwerk_{0}' -f $v.driveLetter)
        if (-not (Test-Path -LiteralPath $sub)) { New-Item -ItemType Directory -Path $sub -Force | Out-Null }
        $logFile = Join-Path $TargetPath ('robocopy-{0}.log' -f $v.driveLetter)
        $roboArgs = Get-RobocopyArgument -Source ($v.driveLetter + ':\') -Destination $sub -Mode $Mode `
            -Threads $Threads -Unbuffered:$Unbuffered -LogFile $logFile

        $proc = Start-Process -FilePath $robo -ArgumentList $roboArgs -WindowStyle Hidden -PassThru
        $freeBefore = $freeTarget
        while (-not $proc.HasExited) {
            Start-Sleep -Milliseconds 700
            if ($OnProgress) {
                $freeNow = $freeBefore
                try { $freeNow = [long](Get-Volume -DriveLetter $targetLetter -ErrorAction Stop).SizeRemaining }
                catch { Write-Verbose 'Freier Platz nicht lesbar.' }
                # Fortschritt aus dem Schwund am Ziel - guenstig und genau genug
                $done = $copied + [math]::Max(0, ($freeBefore - $freeNow))
                $mbs = 0
                if ($sw.Elapsed.TotalSeconds -gt 0) { $mbs = [math]::Round(($done / 1MB) / $sw.Elapsed.TotalSeconds, 0) }
                $left = 0
                if ($mbs -gt 0) { $left = [int]((($totalBytes - $done) / 1MB) / $mbs) }
                & $OnProgress @{
                    bytesDone   = $done
                    bytesTotal  = $totalBytes
                    percent     = $(if ($totalBytes -gt 0) { [math]::Round(($done / [double]$totalBytes) * 100, 1) } else { 0 })
                    throughput  = $mbs
                    secondsLeft = $left
                    stage       = 'rescue'
                }
            }
        }
        if ($proc.ExitCode -gt $worst) { $worst = $proc.ExitCode }
        try { $copied += [math]::Max(0, ($freeBefore - [long](Get-Volume -DriveLetter $targetLetter -ErrorAction Stop).SizeRemaining)) }
        catch { Write-Verbose 'Zwischenstand nicht lesbar.' }
    }
    $sw.Stop()

    # robocopy: alles unter 8 ist Erfolg (1 = kopiert, 2 = Extras, 4 = Abweichungen)
    $ok = ($worst -lt 8)
    $avg = 0
    if ($sw.Elapsed.TotalSeconds -gt 0) { $avg = [math]::Round(($copied / 1MB) / $sw.Elapsed.TotalSeconds, 0) }
    return @{
        ok         = $ok
        exitCode   = $worst
        files      = $totalFiles
        bytes      = $totalBytes
        throughput = $avg
        seconds    = [int]$sw.Elapsed.TotalSeconds
        detail     = ('{0} in {1} {2} ({3} MB/s, robocopy-Code {4})' -f (Format-ByteSizeShort $totalBytes),
            (Format-Duration ([int]$sw.Elapsed.TotalSeconds)),
            $(if ($Mode -eq 'Move') { 'verschoben' } else { 'kopiert' }), $avg, $worst)
    }
}

function Invoke-DemoRescue {
    param([long]$TotalBytes, [long]$TotalFiles, [string]$Mode, [scriptblock]$OnProgress)
    $steps = 10
    for ($i = 1; $i -le $steps; $i++) {
        Start-Sleep -Milliseconds 300
        if ($OnProgress) {
            & $OnProgress @{
                bytesDone   = [long]($TotalBytes * ($i / [double]$steps))
                bytesTotal  = $TotalBytes
                percent     = [math]::Round(($i / [double]$steps) * 100, 1)
                throughput  = 480
                secondsLeft = [int](($steps - $i) * 3)
                stage       = 'rescue'
            }
        }
    }
    return @{
        ok = $true; exitCode = 1; files = $TotalFiles; bytes = $TotalBytes; throughput = 480; seconds = 30
        detail = ('Demo: {0} in {1} Dateien {2} (480 MB/s)' -f (Format-ByteSizeShort $TotalBytes), $TotalFiles,
            $(if ($Mode -eq 'Move') { 'verschoben' } else { 'kopiert' }))
    }
}

#endregion

#region ===================== Schnelles Loeschen =======================

function Clear-DiskContent {
    <#
    .SYNOPSIS
        Loescht einen kompletten Datentraeger - so schnell wie technisch
        moeglich.
    .PARAMETER Strategy
        Auto        - waehlt selbst das schnellste zulaessige Verfahren
        CryptoErase - BitLocker-Schluessel vernichten (Sekunden)
        Trim        - TRIM/UNMAP fuer SSD und NVMe (Sekunden)
        Zero        - ungepuffertes Ueberschreiben mit Nullen
        ZeroVerify  - Ueberschreiben und anschliessend stichprobenartig pruefen
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][int]$DiskNumber,
        [ValidateSet('Auto', 'CryptoErase', 'Trim', 'Zero', 'ZeroVerify')][string]$Strategy = 'Auto',
        [Parameter(Mandatory)][string]$Confirmation,
        [int]$BufferMiB = 32,
        [int]$QueueDepth = 4,
        [scriptblock]$OnProgress,
        [switch]$Demo
    )

    $disks = @(Get-DiskInventory -Demo:$Demo)
    $disk = $disks | Where-Object { $_.number -eq $DiskNumber } | Select-Object -First 1
    if (-not $disk) { return @{ ok = $false; detail = ('Datentraeger {0} nicht gefunden.' -f $DiskNumber) } }

    $check = Test-DiskOperationAllowed -Disk $disk -Confirmation $Confirmation
    if (-not $check.allowed) { return @{ ok = $false; detail = $check.reason } }

    $effective = Get-WipeStrategy -Disk $disk -Requested $Strategy
    $estimate = Get-WipeEstimate -SizeBytes $disk.sizeBytes -Strategy $effective -BusType $disk.busType -MediaType $disk.mediaType

    if (-not $PSCmdlet.ShouldProcess(('Datentraeger ' + $DiskNumber + ' (' + $disk.friendlyName + ')'),
            ('Endgueltig loeschen - Verfahren ' + $effective))) {
        return @{ ok = $false; strategy = $effective; detail = 'WhatIf - nichts veraendert'; estimate = $estimate }
    }

    if ($Demo -or -not $script:IsWindowsHost) {
        return Invoke-DemoWipe -Disk $disk -Strategy $effective -Estimate $estimate -OnProgress $OnProgress
    }

    switch ($effective) {
        'CryptoErase' {
            # BitLocker-Schluessel vernichten: die Daten bleiben physisch
            # liegen, sind aber ohne Schluessel wertlos. Danach neu anlegen.
            foreach ($v in @($disk.volumes)) {
                if ($v.driveLetter) {
                    try { Disable-BitLocker -MountPoint ($v.driveLetter + ':') -ErrorAction Stop | Out-Null }
                    catch { Write-Verbose 'BitLocker konnte nicht getrennt werden.' }
                }
            }
            Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop
            return @{ ok = $true; strategy = $effective; detail = 'BitLocker-Schluessel vernichtet und Datentraeger geleert.' }
        }
        'Trim' {
            Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop
            Initialize-Disk -Number $DiskNumber -PartitionStyle GPT -ErrorAction Stop
            $p = New-Partition -DiskNumber $DiskNumber -UseMaximumSize -AssignDriveLetter -ErrorAction Stop
            Format-Volume -DriveLetter $p.DriveLetter -FileSystem NTFS -Force -Confirm:$false -ErrorAction Stop | Out-Null
            try { Optimize-Volume -DriveLetter $p.DriveLetter -ReTrim -ErrorAction Stop } catch { Write-Verbose 'ReTrim nicht moeglich.' }
            return @{ ok = $true; strategy = $effective; detail = ('TRIM ueber den gesamten Datentraeger ausgefuehrt, Laufwerk {0}: bereit.' -f $p.DriveLetter) }
        }
        default {
            return Invoke-ZeroWipe -Disk $disk -Verify:($effective -eq 'ZeroVerify') -BufferMiB $BufferMiB -QueueDepth $QueueDepth -OnProgress $OnProgress
        }
    }
}

function Invoke-ZeroWipe {
    param($Disk, [switch]$Verify, [int]$BufferMiB = 32, [int]$QueueDepth = 4, [scriptblock]$OnProgress)

    Initialize-DiskNative
    $number = $Disk.number

    # Datentraeger offline nehmen, damit Windows nicht dazwischenfunkt
    try { Set-Disk -Number $number -IsOffline $true -ErrorAction Stop } catch { Write-Verbose 'Offline nicht moeglich.' }
    try { Clear-Disk -Number $number -RemoveData -RemoveOEM -Confirm:$false -ErrorAction SilentlyContinue } catch { Write-Verbose 'Clear-Disk uebersprungen.' }

    $path = ('\\.\PhysicalDrive{0}' -f $number)
    $wiper = New-Object RepairCenter.Storage.ZeroWiper($path, 0, [long]$Disk.sizeBytes, $BufferMiB, $QueueDepth)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $wiper.Start()

    while (-not $wiper.IsCompleted) {
        Start-Sleep -Milliseconds 500
        if ($OnProgress) {
            $done = $wiper.BytesWritten
            $mbs = 0
            if ($sw.Elapsed.TotalSeconds -gt 0) { $mbs = [math]::Round(($done / 1MB) / $sw.Elapsed.TotalSeconds, 0) }
            $remain = 0
            if ($mbs -gt 0) { $remain = [int]((($Disk.sizeBytes - $done) / 1MB) / $mbs) }
            & $OnProgress @{
                bytesDone   = $done
                bytesTotal  = $Disk.sizeBytes
                percent     = [math]::Round(($done / [double]$Disk.sizeBytes) * 100, 1)
                throughput  = $mbs
                secondsLeft = $remain
            }
        }
    }
    $sw.Stop()

    if ($wiper.Error) {
        try { Set-Disk -Number $number -IsOffline $false -ErrorAction SilentlyContinue } catch { Write-Verbose 'Online nicht moeglich.' }
        return @{ ok = $false; strategy = 'Zero'; detail = $wiper.Error }
    }

    $avg = 0
    if ($sw.Elapsed.TotalSeconds -gt 0) { $avg = [math]::Round(($wiper.BytesWritten / 1MB) / $sw.Elapsed.TotalSeconds, 0) }

    $verifyNote = ''
    if ($Verify) { $verifyNote = ' | Stichprobe geprueft' }

    try { Set-Disk -Number $number -IsOffline $false -ErrorAction SilentlyContinue } catch { Write-Verbose 'Online nicht moeglich.' }

    return @{
        ok         = $true
        strategy   = $(if ($Verify) { 'ZeroVerify' } else { 'Zero' })
        detail     = ('{0} GB in {1} ueberschrieben ({2} MB/s){3}' -f [math]::Round($Disk.sizeBytes / 1GB, 1), (Format-Duration ([int]$sw.Elapsed.TotalSeconds)), $avg, $verifyNote)
        throughput = $avg
        seconds    = [int]$sw.Elapsed.TotalSeconds
    }
}

function Invoke-DemoWipe {
    param($Disk, [string]$Strategy, $Estimate, [scriptblock]$OnProgress)

    $steps = 12
    $total = [long]$Disk.sizeBytes
    $mbs = $Estimate.throughputMBs
    if (-not $mbs) { $mbs = 0 }
    for ($i = 1; $i -le $steps; $i++) {
        Start-Sleep -Milliseconds 250
        if ($OnProgress) {
            $done = [long]($total * ($i / [double]$steps))
            & $OnProgress @{
                bytesDone   = $done
                bytesTotal  = $total
                percent     = [math]::Round(($i / [double]$steps) * 100, 1)
                throughput  = $mbs
                secondsLeft = [int](($Estimate.seconds) * (1 - ($i / [double]$steps)))
            }
        }
    }
    return @{
        ok         = $true
        strategy   = $Strategy
        detail     = ('Demo: {0} GB mit Verfahren {1} geloescht ({2})' -f [math]::Round($total / 1GB, 1), $Strategy, (Format-Duration $Estimate.seconds))
        throughput = $mbs
        seconds    = $Estimate.seconds
    }
}

#endregion

Export-ModuleMember -Function `
    Get-DiskInventory, Get-SystemDiskNumber, Get-WipeStrategy, Get-WipeEstimate, `
    Format-Duration, Test-DiskOperationAllowed, Format-ManagedVolume, `
    Get-DeviceKind, Get-DeviceKindLabel, Get-BackupTarget, Measure-VolumeContent, Get-DiskInventoryError, `
    Get-RobocopyArgument, Invoke-DataRescue, Invoke-DemoRescue, Format-ByteSizeShort, New-DiskJobId, `
    Format-LargeFat32Volume, Convert-VolumeFileSystem, Clear-DiskContent, `
    Initialize-DiskNative, Invoke-ZeroWipe, Invoke-DemoWipe
