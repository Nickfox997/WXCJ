# Windows 原生交叉编译 iOS dylib（不需要 Linux / WSL / 虚拟机 / Theos）
#
# 原理：Windows 版 LLVM 自带 clang + ld64.lld（Mach-O 链接器），
#       配合 theos/sdks 的 iPhoneOS SDK，可以直接产出 arm64 Mach-O 动态库。
#
# 用法：
#   pwsh -File scripts\win-build.ps1
#   pwsh -File scripts\win-build.ps1 -SdkVersion 16.5
#
# 前置（脚本会检查）：
#   winget install --id LLVM.LLVM -e
#   git clone --filter=blob:none --sparse https://github.com/theos/sdks.git G:\toolchain\theos-sdks

param(
    [string]$SdkRoot    = "G:\toolchain\theos-sdks",
    [string]$SdkVersion = "16.5",
    [string]$OutName    = "libmarsbridge.dylib"
)

$ErrorActionPreference = 'Continue'   # 注意：不能设 Stop，否则 clang 的 stderr warning 会中断脚本
$llvmBin = Join-Path $env:ProgramFiles 'LLVM\bin'
$clang   = Join-Path $llvmBin 'clang.exe'
$sdkDir  = Join-Path $SdkRoot "iPhoneOS$SdkVersion.sdk"
$proj    = Join-Path $PSScriptRoot '..\WeChatAIChatTweak'
$srcDir  = Join-Path $proj 'src'
$outPath = Join-Path $PSScriptRoot "..\$OutName"

# ── 1. 环境检查 ──
Write-Host "== [1/5] 环境检查 ==" -ForegroundColor Cyan
if (-not (Test-Path $clang)) { throw "找不到 clang：$clang`n请先 winget install --id LLVM.LLVM -e" }
$env:PATH = "$llvmBin;$env:PATH"
$ld64 = Join-Path $llvmBin 'ld64.lld.exe'
if (-not (Test-Path $ld64)) { throw "找不到 ld64.lld（Mach-O 链接器）" }
Write-Host "  clang  = $clang"
Write-Host "  ld64   = $ld64"
if (-not (Test-Path (Join-Path $sdkDir 'usr\include'))) {
    Write-Host "  SDK 缺失，尝试 sparse checkout ..." -ForegroundColor Yellow
    Push-Location $SdkRoot
    git sparse-checkout init --cone 2>&1 | Out-Null
    git sparse-checkout set "iPhoneOS$SdkVersion.sdk" 2>&1 | Out-Null
    git checkout -f HEAD 2>&1 | Out-Null
    Pop-Location
    if (-not (Test-Path (Join-Path $sdkDir 'usr\include'))) { throw "SDK 获取失败：$sdkDir" }
}
Write-Host "  SDK    = $sdkDir"

# ── 2. 修复 git symlink 占位文件（Windows 上是关键步骤）──
# Windows 默认 core.symlinks=false，git 把符号链接检出成"内容是目标路径"的小文本文件，
# 导致 libSystem.tbd 这类文件变成 15 字节废文件，链接器报 unhandled file type。
Write-Host "== [2/5] 修复 SDK 中的 symlink 占位文件 ==" -ForegroundColor Cyan
$script:fixedCount = 0
Get-ChildItem $sdkDir -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Length -gt 0 -and $_.Length -lt 256 } |
    ForEach-Object {
        try {
            $t = [System.IO.File]::ReadAllText($_.FullName).Trim()
            if ($t -and $t -notmatch '\s' -and $t -notmatch '^---' -and $t -match '^[\w\.\-/]+$') {
                $target = Join-Path $_.DirectoryName $t
                if ((Test-Path $target) -and -not (Get-Item $target).PSIsContainer) {
                    if ((Get-Item $target).Length -ne $_.Length) {
                        Copy-Item $target $_.FullName -Force
                        $script:fixedCount++
                    }
                }
            }
        } catch { }
    }
Write-Host "  修复 $($script:fixedCount) 个"

# ── 3. 编译 ──
Write-Host "== [3/5] 编译源文件 ==" -ForegroundColor Cyan
$srcs = Get-ChildItem (Join-Path $srcDir '*.m'), (Join-Path $srcDir '*.c') -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'WCAIAutoEngine.m' }
if (-not $srcs) { throw "找不到源文件：$srcDir" }
Write-Host "  源文件 $($srcs.Count) 个"

$objDir = Join-Path $env:TEMP 'wcai-obj'
Remove-Item $objDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $objDir | Out-Null

$cflags = @(
    '-target', 'arm64-apple-ios14.0',
    '-isysroot', ($sdkDir -replace '\\','/'),
    '-fobjc-arc', '-O2', '-fvisibility=hidden',
    '-Wno-unused-function', '-Wno-deprecated-declarations',
    '-Wno-arc-performSelector-leaks', '-Wno-nullability-completeness',
    '-Wno-objc-method-access', '-Wno-incompatible-pointer-types',
    '-DWCAI_DISABLE_AUTO=1',
    '-DWCAI_MAIN_ACCOUNT_BUILD=1',
    '-DWCAI_ENABLE_GOT_PATCH=0',
    '-I', ($srcDir -replace '\\','/')
)
$objs = @()
foreach ($s in $srcs) {
    $o = Join-Path $objDir "$($s.BaseName).o"
    $a = $cflags + @('-c','-o',$o,$s.FullName)
    $r = & $clang @a 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  FAIL $($s.Name)" -ForegroundColor Red
        ($r.Trim() -split "`n" | Select-Object -First 8) | ForEach-Object { Write-Host "    $_" }
        throw "编译失败"
    }
    $objs += $o
    Write-Host "  OK   $($s.Name)"
}

# ── 4. 链接 ──
Write-Host "== [4/5] 链接 Mach-O ==" -ForegroundColor Cyan
$largs = @(
    '-target','arm64-apple-ios14.0',
    '-isysroot',($sdkDir -replace '\\','/'),
    '-dynamiclib',
    '-fuse-ld=lld',                       # 必须用 lld 名字，绝对路径会丢掉 Darwin 参数
    '-install_name',"@executable_path/Frameworks/$OutName",
    '-undefined','dynamic_lookup',        # 微信私有类留到运行时解析
    '-framework','Foundation',
    '-framework','UIKit',
    '-framework','CoreGraphics',
    '-lsqlite3',
    '-Wl,-no_fixup_chains',               # 必须：否则 ld64.lld 把 __mod_init_func 转成 __init_offsets，
                                          # 注入场景下构造器可能不执行（插件完全不工作）
    '-Wl,-dead_strip',
    '-o',$outPath
) + $objs
$r = & $clang @largs 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    Write-Host ($r.Trim()) -ForegroundColor Red
    throw "链接失败"
}

# ── 5. 验证 ──
Write-Host "== [5/5] 验证 ==" -ForegroundColor Cyan
$fi = Get-Item $outPath
$magic = [System.IO.File]::ReadAllBytes($outPath)[0..3]
$isMachO = ($magic[0] -eq 0xCF -and $magic[1] -eq 0xFA -and $magic[2] -eq 0xED -and $magic[3] -eq 0xFE)
Write-Host "  产物  : $outPath"
Write-Host "  大小  : $([math]::Round($fi.Length/1KB,1)) KB"
Write-Host "  Mach-O: $(if($isMachO){'是 (arm64)'}else{'否 — 构建异常'})"
if (-not $isMachO) { throw "产物不是 Mach-O" }
Write-Host ""
Write-Host "完成。下一步：用全能签把这个 dylib 注入砸壳后的微信 IPA。" -ForegroundColor Green
Write-Host "注意：只出 arm64 单架构 —— 注入 dylib 在 A12+ 的 arm64e 设备上可正常加载。" -ForegroundColor DarkGray
