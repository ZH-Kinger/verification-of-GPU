param(
    [string]$DownloadRoot = (Resolve-Path "$PSScriptRoot\..\staging\downloads").Path
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path -LiteralPath $DownloadRoot
$manifest = Join-Path $root "DOWNLOAD_MANIFEST.txt"
$iso = Join-Path $root "iso\ubuntu-24.04.4-live-server-amd64.iso"
$sums = Join-Path $root "iso\SHA256SUMS"

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("Download manifest")
$lines.Add("Generated: $(Get-Date -Format s)")
$lines.Add("Root: $($root.Path)")
$lines.Add("")

if ((Test-Path -LiteralPath $iso) -and (Test-Path -LiteralPath $sums)) {
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $iso).Hash.ToLowerInvariant()
    $expectedLine = Select-String -Path $sums -Pattern "ubuntu-24.04.4-live-server-amd64.iso" | Select-Object -First 1
    $expected = ""
    if ($expectedLine) {
        $expected = ($expectedLine.Line -split "\s+")[0].ToLowerInvariant()
    }
    $lines.Add("Ubuntu ISO SHA256 expected: $expected")
    $lines.Add("Ubuntu ISO SHA256 actual:   $actual")
    $lines.Add("Ubuntu ISO SHA256 match:    $($expected -eq $actual)")
    $lines.Add("")
} else {
    $lines.Add("Ubuntu ISO SHA256 match:    SKIPPED")
    $lines.Add("")
}

$lines.Add("Files:")
Get-ChildItem -LiteralPath $root -Recurse -File |
    Where-Object { $_.FullName -ne $manifest } |
    Sort-Object FullName |
    ForEach-Object {
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant()
        $relative = $_.FullName.Substring($root.Path.Length).TrimStart("\", "/")
        $lines.Add("$hash  $($_.Length)  $relative")
    }

$lines | Set-Content -Path $manifest -Encoding UTF8
Write-Host "Manifest written: $manifest"

