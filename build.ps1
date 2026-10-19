#requires -Version 5.1
<#
.SYNOPSIS
  Builds static Qt 6 (qtbase only, MSVC x64, /MT) and packages it for a release.

.DESCRIPTION
  Run from an MSVC x64 developer environment (cl, cmake and ninja on PATH).
  Use a SHORT WorkDir (for example C:\q) to stay clear of MAX_PATH.
  -DryRun prints every command and path without downloading or building.
#>
param(
    [string]$QtVersion = '6.10.3',
    [string]$Build     = '1',
    [string]$WorkDir   = 'C:\q',
    [string]$OutDir    = 'C:\qout',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$parts      = $QtVersion.Split('.')
$majorMinor = $parts[0] + '.' + $parts[1]
$srcName    = "qtbase-everywhere-src-$QtVersion"
$tarName    = "$srcName.tar.xz"
$baseUrl    = "https://download.qt.io/archive/qt/$majorMinor/$QtVersion/submodules"
$tarUrl     = "$baseUrl/$tarName"
$shaUrl     = "$tarUrl.sha256"
$md5Url     = "$baseUrl/md5sums.txt"
$assetName  = "qt-$QtVersion-static-msvc2022-x64-mt.zip"
$tag        = "qt-$QtVersion-msvc2022-x64-mt-$Build"

$tarPath    = Join-Path $WorkDir $tarName
$srcDir     = Join-Path $WorkDir $srcName
$buildDir   = Join-Path $WorkDir 'build'
$installDir = Join-Path $WorkDir 'install'
$assetPath  = Join-Path $OutDir $assetName

$configureArgs = @(
    '-static', '-static-runtime', '-release', '-optimize-size',
    '-no-icu', '-no-opengl',
    '-nomake', 'tests', '-nomake', 'examples',
    '-no-ltcg',
    '-prefix', $installDir
)
$configureExe = Join-Path $srcDir 'configure.bat'
$configureCmd = $configureExe + ' ' + ($configureArgs -join ' ')

# Runs a native command and fails on a non-zero exit code.
function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments)
    Write-Host ">> $Exe $($Arguments -join ' ')"
    if ($DryRun) { return }
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $Exe $($Arguments -join ' ')"
    }
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

# Reads the expected SHA-256 of $tarName from the .sha256 file, or md5sums.txt as a fallback.
function Get-ExpectedHash {
    $text = $null
    try {
        $text = (Invoke-WebRequest -UseBasicParsing -Uri $shaUrl).Content
        if ($text -is [byte[]]) { $text = [System.Text.Encoding]::ASCII.GetString($text) }
        $m = [regex]::Match($text, '(?i)\b([0-9a-f]{64})\b')
        if ($m.Success) { return @{ Algo = 'SHA256'; Hash = $m.Groups[1].Value.ToLower() } }
    } catch {
        Write-Host "No usable .sha256 file ($($_.Exception.Message)); trying md5sums.txt"
    }
    $text = (Invoke-WebRequest -UseBasicParsing -Uri $md5Url).Content
    if ($text -is [byte[]]) { $text = [System.Text.Encoding]::ASCII.GetString($text) }
    foreach ($line in ($text -split "`n")) {
        if ($line -match '(?i)^\s*([0-9a-f]{32})\s+\*?(\S+)\s*$' -and $Matches[2] -eq $tarName) {
            return @{ Algo = 'MD5'; Hash = $Matches[1].ToLower() }
        }
    }
    throw "No checksum found for $tarName"
}

Write-Host "Qt version   : $QtVersion (build $Build)"
Write-Host "Source URL   : $tarUrl"
Write-Host "Checksum URL : $shaUrl (fallback: $md5Url)"
Write-Host "WorkDir      : $WorkDir"
Write-Host "Source dir   : $srcDir"
Write-Host "Build dir    : $buildDir"
Write-Host "Install dir  : $installDir"
Write-Host "OutDir       : $OutDir"
Write-Host "Release tag  : $tag"
Write-Host "Asset        : $assetPath"
Write-Host "Other assets : BUILD-INFO.txt, SHA256SUMS.txt, LICENSES\* (flattened), $tarName"

if ($DryRun) {
    Write-Host '-- DryRun: nothing will be downloaded or built --'
    Write-Host "download  : $tarUrl -> $tarPath"
    Write-Host "verify    : checksum from $shaUrl"
    Write-Host "extract   : tar -xf $tarPath -C $WorkDir"
    Write-Host "configure : (in $buildDir) $configureCmd"
    Write-Host "build     : cmake --build . --parallel"
    Write-Host "install   : cmake --install ."
    Write-Host "zip       : tar -a -c -f $assetPath -C $installDir ."
    Write-Host "write     : $(Join-Path $OutDir 'BUILD-INFO.txt'), $(Join-Path $OutDir 'SHA256SUMS.txt')"
    return
}

New-Item -ItemType Directory -Force -Path $WorkDir, $OutDir | Out-Null

# 1. Download and verify
if (-not (Test-Path $tarPath)) {
    Write-Host "Downloading $tarUrl"
    Invoke-WebRequest -UseBasicParsing -Uri $tarUrl -OutFile $tarPath
}
$expected = Get-ExpectedHash
$actual = (Get-FileHash -Algorithm $expected.Algo -Path $tarPath).Hash.ToLower()
if ($actual -ne $expected.Hash) {
    throw "$($expected.Algo) mismatch for ${tarName}: expected $($expected.Hash), got $actual"
}
Write-Host "$($expected.Algo) verified: $actual"

# 2. Extract
if (Test-Path $srcDir) { Remove-Item -Recurse -Force $srcDir }
Invoke-Native 'tar' @('-xf', $tarPath, '-C', $WorkDir)
if (-not (Test-Path $configureExe)) { throw "configure.bat not found at $configureExe" }

# 3. Configure, build, install
foreach ($d in @($buildDir, $installDir)) {
    if (Test-Path $d) { Remove-Item -Recurse -Force $d }
}
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
Push-Location $buildDir
try {
    Invoke-Native $configureExe $configureArgs
    Invoke-Native 'cmake' @('--build', '.', '--parallel')
    Invoke-Native 'cmake' @('--install', '.')
} finally {
    Pop-Location
}

# 4. Licences (also shipped inside the zip) and BUILD-INFO.txt
$licSrc = Join-Path $srcDir 'LICENSES'
if (-not (Test-Path $licSrc)) { throw "LICENSES folder not found in $srcDir" }
Copy-Item -Recurse -Force $licSrc (Join-Path $installDir 'LICENSES')

$clOut = (cmd /c "cl 2>&1" | Select-Object -First 1)
$gitHead = 'unknown'
$head = (& git -C $PSScriptRoot rev-parse HEAD 2>$null)
if ($LASTEXITCODE -eq 0 -and $head) { $gitHead = $head }
$sdk = $env:WindowsSDKVersion
if (-not $sdk) { $sdk = 'unknown' }

$info = @(
    "Qt $QtVersion",
    "MSVC $clOut",
    "Windows SDK $sdk",
    "configure $configureCmd",
    "date $([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))",
    "build-repo $gitHead"
) -join "`r`n"
Write-Utf8NoBom (Join-Path $OutDir 'BUILD-INFO.txt') ($info + "`r`n")
Copy-Item -Force (Join-Path $OutDir 'BUILD-INFO.txt') (Join-Path $installDir 'BUILD-INFO.txt')

# 5. Package: zip with the install tree at the root, plus loose licences and the source
if (Test-Path $assetPath) { Remove-Item -Force $assetPath }
Invoke-Native 'tar' @('-a', '-c', '-f', $assetPath, '-C', $installDir, '.')
Get-ChildItem -File $licSrc | Copy-Item -Force -Destination $OutDir
Copy-Item -Force $tarPath $OutDir

# 6. SHA256SUMS.txt (flat files only; gh release create takes OutDir\*)
$sumsPath = Join-Path $OutDir 'SHA256SUMS.txt'
if (Test-Path $sumsPath) { Remove-Item -Force $sumsPath }
$lines = foreach ($f in (Get-ChildItem -File $OutDir | Sort-Object Name)) {
    (Get-FileHash -Algorithm SHA256 -Path $f.FullName).Hash.ToLower() + '  ' + $f.Name
}
Write-Utf8NoBom $sumsPath (($lines -join "`n") + "`n")

Write-Host "Done. Output in $OutDir"
Get-ChildItem -File $OutDir | ForEach-Object { Write-Host ("  {0}  ({1:N0} bytes)" -f $_.Name, $_.Length) }
