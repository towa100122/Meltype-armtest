# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 lnkiai
#
# Meltype IME (TSF の DLL) をビルドする。Visual Studio Build Tools (C++) が要る。
#   powershell -ExecutionPolicy Bypass -File native\tip\build.ps1 [-Configuration Release|Debug]
# 出力: native\tip\bin\x64・x86・arm64 に、MeltypeTip.dll (stub) と MeltypeTipImpl.dll (impl)。
# arm64 は ARM64X (ARM64 + ARM64EC) なので、ARM64 と x64 のプロセスから同じ DLL を読み込める。

param([ValidateSet('Release', 'Debug')][string]$Configuration = 'Release')

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) { throw 'Visual Studio (Build Tools) の C++ ビルドツールが見つかりません。Meltype IME をビルドするには、Visual Studio Build Tools の「C++ によるデスクトップ開発」を入れてください。' }
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw 'Visual Studio の C++ ビルドツールが見つかりません。' }
$vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvarsall.bat'
# vcvarsall.bat は vswhere.exe を PATH から探すので、見つからないという表示が出ないように足しておく
$env:PATH = (Split-Path $vswhere) + ';' + $env:PATH

# ファイルの SHA-256 (Get-FileHash は、ほかのシェルから起動した PowerShell では読み込めないことがあるので .NET で計算する)
function Get-Sha256([string]$path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($path))).Replace('-', '') }
    finally { $sha.Dispose() }
}

$dlls = @(
    @{ Name = 'MeltypeTip'; Sources = 'Dll.cpp', 'Stub.cpp', 'Common.cpp' },
    @{ Name = 'MeltypeTipImpl'; Sources = 'Impl.cpp', 'TextService.cpp', 'CandidateWindow.cpp', 'DisplayAttributes.cpp', 'LangBar.cpp', 'Pipe.cpp', 'Json.cpp', 'Common.cpp' }
)
# /Brepro: 同じソースからは同じ DLL にする (日時を埋め込まない)。入れ直したときに、変わっていない DLL を登録し直さない (UAC を出さない) ため
$optimize = if ($Configuration -eq 'Release') { '/O2 /MT /DNDEBUG' } else { '/Od /MTd /Zi' }
$libs = 'ole32.lib oleaut32.lib uuid.lib user32.lib gdi32.lib advapi32.lib d2d1.lib dwrite.lib dwmapi.lib'

function Build-Dlls([string]$arch, [string]$vcarch, [string]$out, [string]$obj, [string]$extraCompile, [string]$extraLink) {
    $out = Join-Path $here "bin\$arch"
    $obj = Join-Path $here "obj\$arch"
    New-Item -ItemType Directory -Force -Path $out, $obj | Out-Null
    $cmd = @(
        "call `"$vcvars`" $vcarch",
        "cd /d `"$here`"",
        "rc /nologo /fo `"$obj\MeltypeTip.res`" MeltypeTip.rc"
    ) + @($dlls | ForEach-Object {
        $name = $_.Name
        $linkOptions = $extraLink.Replace('{name}', $name)
        "cl /nologo /Brepro /std:c++17 /EHsc /W4 /wd4100 /utf-8 /DUNICODE /D_UNICODE $extraCompile $optimize /Fo`"$obj\\`" /Fd`"$obj\\`" /LD $($_.Sources -join ' ') `"$obj\MeltypeTip.res`" /link /Brepro /DEF:$name.def /IMPLIB:`"$obj\$name.lib`" /OUT:`"$out\$name.dll`" $libs $linkOptions"
    }) -join ' && '
    Write-Host "== $arch =="
    cmd /c $cmd
    if ($LASTEXITCODE -ne 0) { throw "$arch のビルドに失敗しました。" }
}

foreach ($arch in 'x64', 'x86') {
    $vcarch = if ($arch -eq 'x64') { 'x64' } else { 'x64_x86' }
    Build-Dlls $arch $vcarch (Join-Path $here "bin\$arch") (Join-Path $here "obj\$arch") '' ''
    # 署名する前の中身のハッシュ。インストールのとき、登録済みの DLL と同じかを比べるのに使う (署名には毎回違う時刻が入るため)。
    # impl のハッシュは、インストール先での impl のフォルダー名にもなり、Meltype.exe が要求の impl と照合する
    foreach ($name in $dlls.Name) {
        $dll = Join-Path $here "bin\$arch\$name.dll"
        [IO.File]::WriteAllText("$dll.sha256", (Get-Sha256 $dll))
    }
}

# ARM64X は、ARM64 のリンク入力を /LINKREPROFULLPATHRSP で保存してから、ARM64EC のリンクに
# /machine:arm64x と /defArm64Native を付けて ARM64 側と合成する。
$arm64Repro = Join-Path $here 'obj\arm64-repro'
$arm64NativeOut = Join-Path $here 'bin\arm64-native'
Remove-Item -LiteralPath $arm64Repro, $arm64NativeOut -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $arm64Repro, $arm64NativeOut | Out-Null
Build-Dlls 'arm64-native' 'x64_arm64' $arm64NativeOut (Join-Path $here 'obj\arm64-native') '' "/LINKREPROFULLPATHRSP:`"$arm64Repro\{name}.rsp`""

foreach ($name in $dlls.Name) {
    $rsp = Join-Path $arm64Repro "$name.rsp"
    if (-not (Test-Path -LiteralPath $rsp)) { throw "ARM64 のリンク入力が見つかりません: $rsp" }
    $nativeInputs = @(
        Get-Content -LiteralPath $rsp |
            Where-Object { $_ -match '(?i)\.(obj|lib)"?$' }
    )
    if (-not $nativeInputs) { throw "ARM64 のリンク入力が空です: $rsp" }
    $nativeArgs = $nativeInputs -join ' '
    $sources = (($dlls | Where-Object Name -eq $name).Sources -join ' ')
    $def = Join-Path $here "$name.def"
    $nativeRes = Join-Path $here 'obj\arm64-native\MeltypeTip.res'
    $out = Join-Path $here 'bin\arm64'
    $obj = Join-Path $here 'obj\arm64ec'
    New-Item -ItemType Directory -Force -Path $out, $obj | Out-Null
    $cmd = @(
        "call `"$vcvars`" x64_arm64",
        "cd /d `"$here`"",
        "cl /nologo /Brepro /arm64EC /std:c++17 /EHsc /W4 /wd4100 /utf-8 /DUNICODE /D_UNICODE $optimize /Fo`"$obj\\`" /Fd`"$obj\\`" /LD $sources `"$nativeRes`" /link /Brepro /machine:arm64x /DEF:`"$def`" /defArm64Native:`"$def`" /IMPLIB:`"$obj\$name.lib`" /OUT:`"$out\$name.dll`" $libs $nativeArgs"
    ) -join ' && '
    Write-Host "== arm64 ($name) =="
    cmd /c $cmd
    if ($LASTEXITCODE -ne 0) { throw "arm64 ($name) のビルドに失敗しました。" }
}
foreach ($name in $dlls.Name) {
    $dll = Join-Path $here "bin\arm64\$name.dll"
    [IO.File]::WriteAllText("$dll.sha256", (Get-Sha256 $dll))
}
Write-Host 'できました:' (Join-Path $here 'bin')
