param(
    [ValidatePattern('^[A-Za-z]$')]
    [string]$UsbDriveLetter = "",

    [int]$UsbDiskNumber = -1,

    [Parameter(Mandatory = $true)]
    [string]$IsoPath,

    [string]$ProjectSource = (Resolve-Path "$PSScriptRoot\..").Path,

    [int]$BootPartitionSizeGB = 8,

    [int]$DataPartitionSizeGB = 32,

    [switch]$CreatePersistencePartition,

    [string]$BootLabel = "UBUNTU_BOOT",

    [string]$DataLabel = "GPU_DATA",

    [string]$LogPath = "",

    [switch]$Force
)

$ErrorActionPreference = "Stop"

$transcriptStarted = $false
if ($LogPath) {
    $logDir = Split-Path -Parent $LogPath
    if ($logDir) {
        New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    }
    Start-Transcript -Path $LogPath -Force | Out-Null
    $transcriptStarted = $true
}

try {

function Require-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "This script must be run from an elevated PowerShell session."
    }
}

function Copy-ProjectPayload {
    param(
        [string]$SourceRoot,
        [string]$TargetRoot
    )

    $projectTarget = Join-Path $TargetRoot "GPU_Offline_Acceptance"
    New-Item -ItemType Directory -Force -Path $projectTarget | Out-Null

    $items = @(
        "README.md",
        "PROJECT_PLAN.md",
        "docs",
        "templates",
        "scripts",
        "boot_configs"
    )

    foreach ($item in $items) {
        $src = Join-Path $SourceRoot $item
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination $projectTarget -Recurse -Force
        }
    }

    foreach ($dir in @("tools", "logs", "reports", "inventory", "downloads")) {
        New-Item -ItemType Directory -Force -Path (Join-Path $projectTarget $dir) | Out-Null
    }

    $stagingDownloads = Join-Path $SourceRoot "staging\downloads"
    if (Test-Path -LiteralPath $stagingDownloads) {
        Copy-Item -Path (Join-Path $stagingDownloads "*") -Destination (Join-Path $projectTarget "downloads") -Recurse -Force
    }

    @"
GPU Offline Acceptance USB

Boot partition: $BootLabel
Data partition: $DataLabel
Persistence: raw partition; initialize from Linux with scripts/init_persistence_partition.sh

Start here:
1. Boot target server from UEFI USB.
2. Mount GPU_DATA in Linux.
3. Run:
   cd /mnt/gpu_acceptance/GPU_Offline_Acceptance
   bash scripts/offline_gpu_acceptance_collect.sh
"@ | Set-Content -Path (Join-Path $projectTarget "START_HERE.txt") -Encoding UTF8
}

Require-Admin

$iso = Resolve-Path -LiteralPath $IsoPath
$source = Resolve-Path -LiteralPath $ProjectSource
if ($UsbDiskNumber -ge 0) {
    $disks = @(Get-Disk -Number $UsbDiskNumber -ErrorAction Stop)
    $targetDescription = "disk $UsbDiskNumber"
} else {
    if (-not $UsbDriveLetter) {
        throw "Provide either -UsbDriveLetter or -UsbDiskNumber."
    }

    $drive = $UsbDriveLetter.TrimEnd(":").ToUpperInvariant()
    $partitions = @(Get-Partition -DriveLetter $drive -ErrorAction Stop)

    if ($partitions.Count -ne 1) {
        throw "Drive letter $drive maps to unexpected partition count: $($partitions.Count)"
    }

    $disks = @($partitions[0] | Get-Disk)
    $targetDescription = "drive $drive"
}

if ($disks.Count -ne 1) {
    throw "$targetDescription maps to unexpected disk count: $($disks.Count)"
}

$disk = $disks[0]

if ($disk.BusType -ne "USB") {
    throw "$targetDescription is disk $($disk.Number), but BusType is $($disk.BusType), not USB. Refusing to continue."
}

Write-Host "Target USB disk:"
$disk | Select-Object Number, FriendlyName, SerialNumber, BusType, Size | Format-List

if (-not $Force) {
    throw "This operation will erase $targetDescription on disk $($disk.Number). Re-run with -Force after confirming the target disk."
}

Write-Host "ERASING disk $($disk.Number). Existing data on $targetDescription will be removed."

Clear-Disk -Number $disk.Number -RemoveData -RemoveOEM -Confirm:$false
$disk = Get-Disk -Number $disk.Number
if ($disk.PartitionStyle -eq "RAW") {
    Initialize-Disk -Number $disk.Number -PartitionStyle MBR
} else {
    Write-Host "Disk $($disk.Number) already has partition style $($disk.PartitionStyle); continuing."
}

$bootSizeBytes = [UInt64]$BootPartitionSizeGB * 1GB
$bootPart = New-Partition -DiskNumber $disk.Number -Size $bootSizeBytes -AssignDriveLetter -IsActive
Format-Volume -Partition $bootPart -FileSystem FAT32 -NewFileSystemLabel $BootLabel -Confirm:$false

if ($CreatePersistencePartition) {
    $dataSizeBytes = [UInt64]$DataPartitionSizeGB * 1GB
    $dataPart = New-Partition -DiskNumber $disk.Number -Size $dataSizeBytes -AssignDriveLetter
} else {
    $dataPart = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
}
Format-Volume -Partition $dataPart -FileSystem exFAT -NewFileSystemLabel $DataLabel -Confirm:$false

if ($CreatePersistencePartition) {
    $persistPart = New-Partition -DiskNumber $disk.Number -UseMaximumSize
    try {
        Set-Partition -DiskNumber $disk.Number -PartitionNumber $persistPart.PartitionNumber -NoDefaultDriveLetter $true
    } catch {
        Write-Host "Could not set NoDefaultDriveLetter for persistence partition; continuing."
        Write-Host $_.Exception.Message
    }
    Write-Host "Created raw persistence partition number $($persistPart.PartitionNumber)."
    Write-Host "Format it from Linux with scripts/init_persistence_partition.sh."
}

$bootLetter = ($bootPart | Get-Volume).DriveLetter
$dataLetter = ($dataPart | Get-Volume).DriveLetter

if (-not $bootLetter -or -not $dataLetter) {
    throw "Unable to resolve boot/data drive letters after formatting."
}

$bootRoot = "$bootLetter`:\"
$dataRoot = "$dataLetter`:\"

Write-Host "Mounting ISO: $($iso.Path)"
$mounted = Mount-DiskImage -ImagePath $iso.Path -PassThru
try {
    $isoDrive = ($mounted | Get-Volume).DriveLetter
    if (-not $isoDrive) {
        throw "Unable to find mounted ISO drive letter."
    }

    $isoRoot = "$isoDrive`:\"
    Write-Host "Copying ISO contents to $bootRoot"
    robocopy $isoRoot $bootRoot /E /R:2 /W:2 /NFL /NDL /NJH /NJS /NP
    if ($LASTEXITCODE -gt 7) {
        throw "robocopy ISO copy failed with code $LASTEXITCODE"
    }
}
finally {
    Dismount-DiskImage -ImagePath $iso.Path
}

$localGrub = Join-Path $source.Path "boot_configs\grub.cfg"
$localLoopback = Join-Path $source.Path "boot_configs\loopback.cfg"
if (Test-Path -LiteralPath $localGrub) {
    Copy-Item -LiteralPath $localGrub -Destination (Join-Path $bootRoot "boot\grub\grub.cfg") -Force
}
if (Test-Path -LiteralPath $localLoopback) {
    Copy-Item -LiteralPath $localLoopback -Destination (Join-Path $bootRoot "boot\grub\loopback.cfg") -Force
}

Write-Host "Copying GPU acceptance project to $dataRoot"
Copy-ProjectPayload -SourceRoot $source.Path -TargetRoot $dataRoot

Write-Host "USB build complete."
Write-Host "Boot partition: $bootRoot ($BootLabel)"
Write-Host "Data partition: $dataRoot ($DataLabel)"

}
catch {
    Write-Host "ERROR: $($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace
    throw
}
finally {
    if ($transcriptStarted) {
        Stop-Transcript | Out-Null
    }
}
