[CmdletBinding()]
param(
    [string]$Version = '',
    [switch]$ForceFrontend,
    [switch]$SkipFrontend,
    [switch]$ForceRuntime,
    [switch]$PauseOnExit,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Assert-CommandExists {
    param(
        [string]$Name,
        [string]$InstallHint
    )
    if ($null -eq (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "未找到命令 '$Name'。$InstallHint"
    }
}

function Find-InnoSetupCompiler {
    $candidates = @(
        'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
        'C:\Program Files\Inno Setup 6\ISCC.exe'
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }
    $fromPath = Get-Command 'ISCC.exe' -ErrorAction SilentlyContinue
    if ($null -ne $fromPath) {
        return $fromPath.Source
    }
    throw '未找到 Inno Setup 6 (ISCC.exe)，请先安装到默认目录 C:\Program Files (x86)\Inno Setup 6。'
}

function Invoke-GitOptional {
    param(
        [string]$RepoRoot,
        [string[]]$Arguments
    )
    $output = & git -C $RepoRoot @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) {
        return ''
    }
    return ($output -join "`n").Trim()
}

function Resolve-BuildVersions {
    param(
        [string]$RepoRoot,
        [string]$ExplicitVersion
    )
    $appVersion = ''
    if (-not [string]::IsNullOrWhiteSpace($ExplicitVersion)) {
        $normalized = $ExplicitVersion.Trim().TrimStart('v', 'V')
        if ($normalized -notmatch '^\d+\.\d+\.\d+$') {
            throw "版本号格式无效：$ExplicitVersion（需要 x.y.z 格式，例如 1.0.16）"
        }
        $appVersion = $normalized
    } else {
        $latestTag = Invoke-GitOptional -RepoRoot $RepoRoot -Arguments @('describe', '--tags', '--abbrev=0')
        if ($latestTag -match '^v?(\d+\.\d+\.\d+)$') {
            $appVersion = $Matches[1]
        } else {
            $appVersion = '0.0.0'
        }
    }

    $describe = Invoke-GitOptional -RepoRoot $RepoRoot -Arguments @('describe', '--tags', '--always', '--dirty')
    $buildVersion = if ([string]::IsNullOrWhiteSpace($describe)) {
        $appVersion
    } else {
        $describe.TrimStart('v', 'V')
    }

    $commit = Invoke-GitOptional -RepoRoot $RepoRoot -Arguments @('rev-parse', 'HEAD')
    if ([string]::IsNullOrWhiteSpace($commit)) {
        $commit = 'unknown'
    }

    $buildTime = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    return @{
        AppVersion   = $appVersion
        BuildVersion = $buildVersion
        Commit       = $commit
        BuildTime    = $buildTime
    }
}

function Test-ShouldRebuildFrontend {
    param(
        [string]$RepoRoot,
        [switch]$Force,
        [switch]$Skip
    )
    if ($Skip) {
        return @{ Rebuild = $false; Reason = '已通过 -SkipFrontend 参数跳过' }
    }
    if ($Force) {
        return @{ Rebuild = $true; Reason = '已指定 -ForceFrontend 强制重编' }
    }

    $staticIndex = Join-Path $RepoRoot 'internal\webui\static\index.html'
    if (-not (Test-Path -LiteralPath $staticIndex -PathType Leaf)) {
        return @{ Rebuild = $true; Reason = '缺少 internal/webui/static/index.html' }
    }

    $dirtyFrontend = Invoke-GitOptional -RepoRoot $RepoRoot -Arguments @('status', '--porcelain', '--', 'frontend')
    if (-not [string]::IsNullOrWhiteSpace($dirtyFrontend)) {
        return @{ Rebuild = $true; Reason = '检测到 frontend/ 存在本地未提交改动' }
    }

    $frontendCommitTsRaw = Invoke-GitOptional -RepoRoot $RepoRoot -Arguments @('log', '-1', '--format=%ct', '--', 'frontend')
    $staticCommitTsRaw = Invoke-GitOptional -RepoRoot $RepoRoot -Arguments @('log', '-1', '--format=%ct', '--', 'internal/webui/static')
    if ($frontendCommitTsRaw -match '^\d+$' -and $staticCommitTsRaw -match '^\d+$') {
        if ([int64]$frontendCommitTsRaw -gt [int64]$staticCommitTsRaw) {
            return @{ Rebuild = $true; Reason = 'frontend/ 最近提交晚于 internal/webui/static/' }
        }
    }

    return @{ Rebuild = $false; Reason = '未检测到未编译的前端源码改动，复用现有 internal/webui/static' }
}

function Invoke-FrontendBuild {
    param(
        [string]$RepoRoot,
        [string]$CacheRoot
    )
    Assert-CommandExists -Name 'node' -InstallHint '请安装 Node.js 24+。'
    Assert-CommandExists -Name 'npm' -InstallHint '请安装 Node.js / npm。'

    $frontendDir = Join-Path $RepoRoot 'frontend'
    $lockFile = Join-Path $frontendDir 'package-lock.json'
    $nodeModulesDir = Join-Path $frontendDir 'node_modules'
    $lockStampFile = Join-Path $CacheRoot 'frontend-lock.sha256'
    $currentLockHash = (Get-FileHash -LiteralPath $lockFile -Algorithm SHA256).Hash
    $cachedLockHash = if (Test-Path -LiteralPath $lockStampFile -PathType Leaf) {
        (Get-Content -LiteralPath $lockStampFile -Raw).Trim()
    } else {
        ''
    }

    if (-not (Test-Path -LiteralPath $nodeModulesDir -PathType Container) -or $currentLockHash -ne $cachedLockHash) {
        Write-Host '安装前端依赖 (npm ci)...'
        & npm ci --prefix $frontendDir
        if ($LASTEXITCODE -ne 0) {
            throw "npm ci 失败，退出码: $LASTEXITCODE"
        }
        Set-Content -LiteralPath $lockStampFile -Value $currentLockHash -Encoding utf8NoBOM
    } else {
        Write-Host '前端依赖未变化，复用现有 frontend/node_modules'
    }

    Write-Host '编译前端静态资源 (npm run build)...'
    & npm run build --prefix $frontendDir
    if ($LASTEXITCODE -ne 0) {
        throw "前端构建失败，退出码: $LASTEXITCODE"
    }
}

function Get-RuntimeInputsHash {
    param([string]$RepoRoot)
    $inputs = @(
        (Join-Path $RepoRoot 'go.mod'),
        (Join-Path $RepoRoot 'go.sum'),
        (Join-Path $RepoRoot 'cmd\browser-install\main.go')
    )
    $combined = ($inputs | ForEach-Object {
        (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash
    }) -join '|'
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($combined)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '')
    } finally {
        $sha.Dispose()
    }
}

function Test-PlaywrightRuntimeValid {
    param([string]$RuntimeRoot)
    $driverNode = Join-Path $RuntimeRoot 'playwright-driver\node.exe'
    $driverCli = Join-Path $RuntimeRoot 'playwright-driver\package\cli.js'
    $browsersJson = Join-Path $RuntimeRoot 'playwright-driver\package\browsers.json'
    if (-not (Test-Path -LiteralPath $driverNode -PathType Leaf)) { return $false }
    if (-not (Test-Path -LiteralPath $driverCli -PathType Leaf)) { return $false }
    if (-not (Test-Path -LiteralPath $browsersJson -PathType Leaf)) { return $false }

    $spec = Get-Content -Raw -LiteralPath $browsersJson | ConvertFrom-Json
    $chromiumRev = ($spec.browsers | Where-Object name -eq 'chromium' | Select-Object -First 1).revision
    $headlessRev = ($spec.browsers | Where-Object name -eq 'chromium-headless-shell' | Select-Object -First 1).revision
    if ([string]::IsNullOrWhiteSpace($chromiumRev) -or [string]::IsNullOrWhiteSpace($headlessRev)) {
        return $false
    }

    $chromiumDir = Join-Path $RuntimeRoot "playwright-browsers\chromium-$chromiumRev"
    $headlessDir = Join-Path $RuntimeRoot "playwright-browsers\chromium_headless_shell-$headlessRev"
    if (-not (Test-Path -LiteralPath $chromiumDir -PathType Container)) { return $false }
    if (-not (Test-Path -LiteralPath $headlessDir -PathType Container)) { return $false }

    $browserExe = Get-ChildItem -LiteralPath (Join-Path $RuntimeRoot 'playwright-browsers') -Recurse -File |
        Where-Object { $_.Name -in @('chrome.exe', 'headless_shell.exe', 'chrome-headless-shell.exe') } |
        Select-Object -First 1
    return ($null -ne $browserExe)
}

function Sync-DirectoryWithRobocopy {
    param(
        [string]$Source,
        [string]$Destination
    )
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    & robocopy $Source $Destination /MIR /NFL /NDL /NJH /NJS /NC /NS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) {
        throw "robocopy 同步目录失败 ($Source -> $Destination)，退出码: $LASTEXITCODE"
    }
}

function Invoke-InnoSetupInstallerBuild {
    param(
        [string]$RepoRoot,
        [string]$IsccPath,
        [string]$AppVersion
    )
    $freeDrive = $null
    foreach ($letter in @('R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z')) {
        $candidate = "${letter}:"
        if (-not (Test-Path -LiteralPath "$candidate\")) {
            $freeDrive = $candidate
            break
        }
    }
    if ($null -eq $freeDrive) {
        throw 'R:-Z: 盘符均已被占用，无法创建 Inno Setup 短路径映射。'
    }

    $previousAppVersion = $env:APP_VERSION
    $env:APP_VERSION = $AppVersion
    $substCreated = $false
    $locationPushed = $false

    try {
        & "$env:SystemRoot\System32\subst.exe" $freeDrive $RepoRoot
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath "$freeDrive\")) {
            throw "无法创建临时盘符映射: $freeDrive -> $RepoRoot"
        }
        $substCreated = $true

        Push-Location "$freeDrive\"
        $locationPushed = $true

        $scriptPath = (Resolve-Path 'packaging\windows\installer.iss').Path
        $outputDir = (Resolve-Path 'dist\windows').Path
        & $IsccPath /Qp "/O$outputDir" $scriptPath
        if ($LASTEXITCODE -ne 0) {
            throw "Inno Setup 编译失败，退出码: $LASTEXITCODE"
        }
    } finally {
        if ($locationPushed) {
            Pop-Location
        }
        if ($substCreated) {
            & "$env:SystemRoot\System32\subst.exe" $freeDrive /D | Out-Null
        }
        $env:APP_VERSION = $previousAppVersion
    }
}

$exitCode = 0
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$cacheRoot = Join-Path $repoRoot 'cache'
$cacheRuntimeDir = Join-Path $cacheRoot 'playwright-runtime\amd64'
$distWindowsDir = Join-Path $repoRoot 'dist\windows'
$distRuntimeDir = Join-Path $distWindowsDir 'playwright-runtime\amd64'
$sysoFiles = @(
    (Join-Path $repoRoot 'cmd\server\rsrc_windows_amd64.syso'),
    (Join-Path $repoRoot 'cmd\tray\rsrc_windows_amd64.syso')
)

try {
    Write-Step '检查构建工具链'
    Assert-CommandExists -Name 'go' -InstallHint '请先安装 Go。'
    Assert-CommandExists -Name 'git' -InstallHint '请先安装 Git。'
    $isccPath = Find-InnoSetupCompiler
    Write-Host "ISCC: $isccPath"

    New-Item -ItemType Directory -Force -Path $cacheRoot, $distWindowsDir | Out-Null

    Write-Step '解析版本元数据'
    $versions = Resolve-BuildVersions -RepoRoot $repoRoot -ExplicitVersion $Version
    Write-Host "安装包版本 (APP_VERSION): $($versions.AppVersion)"
    Write-Host "程序版本 (Version): $($versions.BuildVersion)"
    Write-Host "提交哈希 (Commit): $($versions.Commit)"

    Write-Step '检查嵌入式前端'
    $frontendDecision = Test-ShouldRebuildFrontend -RepoRoot $repoRoot -Force:$ForceFrontend -Skip:$SkipFrontend
    Write-Host $frontendDecision.Reason
    if ($frontendDecision.Rebuild) {
        Invoke-FrontendBuild -RepoRoot $repoRoot -CacheRoot $cacheRoot
    }

    Write-Step '生成 Windows 图标与清单资源 (.syso)'
    Push-Location $repoRoot
    try {
        & (Join-Path $repoRoot 'packaging\windows\build-resources.ps1')
        if ($LASTEXITCODE -ne 0) {
            throw "生成 Windows 资源失败，退出码: $LASTEXITCODE"
        }

        Write-Step '编译 Windows 二进制程序'
        $versionLdflags = "-s -w -X xianyu-go/internal/version.Version=$($versions.BuildVersion) -X xianyu-go/internal/version.Commit=$($versions.Commit) -X xianyu-go/internal/version.BuildTime=$($versions.BuildTime)"

        & go build -trimpath -ldflags $versionLdflags -o (Join-Path $distWindowsDir 'xianyu-server.exe') ./cmd/server
        if ($LASTEXITCODE -ne 0) { throw "编译 xianyu-server.exe 失败，退出码: $LASTEXITCODE" }

        & go build -trimpath -ldflags '-s -w' -o (Join-Path $distWindowsDir 'browser-install.exe') ./cmd/browser-install
        if ($LASTEXITCODE -ne 0) { throw "编译 browser-install.exe 失败，退出码: $LASTEXITCODE" }

        & go build -trimpath -ldflags '-s -w -H=windowsgui' -o (Join-Path $distWindowsDir 'xianyu-tray.exe') ./cmd/tray
        if ($LASTEXITCODE -ne 0) { throw "编译 xianyu-tray.exe 失败，退出码: $LASTEXITCODE" }
    } finally {
        Pop-Location
    }

    Write-Step '准备并校验 Playwright Chromium 运行时缓存'
    $runtimeStampFile = Join-Path $cacheRuntimeDir '.browser-install.stamp'
    $expectedRuntimeHash = Get-RuntimeInputsHash -RepoRoot $repoRoot
    $cachedRuntimeHash = if (Test-Path -LiteralPath $runtimeStampFile -PathType Leaf) {
        (Get-Content -LiteralPath $runtimeStampFile -Raw).Trim()
    } else {
        ''
    }

    $cacheValid = (-not $ForceRuntime) -and
        ($cachedRuntimeHash -eq $expectedRuntimeHash) -and
        (Test-PlaywrightRuntimeValid -RuntimeRoot $cacheRuntimeDir)

    if ($cacheValid) {
        Write-Host "命中本地缓存，跳过下载: $cacheRuntimeDir"
    } else {
        Write-Host "下载 Playwright driver 与 Chromium 到缓存目录: $cacheRuntimeDir"
        $driverDir = Join-Path $cacheRuntimeDir 'playwright-driver'
        $browserDir = Join-Path $cacheRuntimeDir 'playwright-browsers'
        New-Item -ItemType Directory -Force -Path $driverDir, $browserDir | Out-Null

        $browserInstallExe = Join-Path $distWindowsDir 'browser-install.exe'
        $userDownloadHost = $env:PLAYWRIGHT_DOWNLOAD_HOST
        $previousNoProxy = $env:NO_PROXY
        try {
            if ([string]::IsNullOrWhiteSpace($userDownloadHost)) {
                $env:PLAYWRIGHT_DOWNLOAD_HOST = 'https://registry.npmmirror.com/-/binary/playwright'
                $env:NO_PROXY = if ([string]::IsNullOrWhiteSpace($previousNoProxy)) {
                    'localhost,127.0.0.1,npmmirror.com,registry.npmmirror.com'
                } else {
                    "$previousNoProxy,npmmirror.com,registry.npmmirror.com"
                }
                Write-Host "优先使用国内镜像加速下载: $($env:PLAYWRIGHT_DOWNLOAD_HOST)"
                & $browserInstallExe -driver-dir $driverDir -browser-dir $browserDir
                if ($LASTEXITCODE -ne 0) {
                    Write-Host '国内镜像下载失败，回退至 Playwright 默认源重试...' -ForegroundColor Yellow
                    Remove-Item Env:PLAYWRIGHT_DOWNLOAD_HOST -ErrorAction SilentlyContinue
                    $env:NO_PROXY = $previousNoProxy
                    & $browserInstallExe -driver-dir $driverDir -browser-dir $browserDir
                }
            } else {
                & $browserInstallExe -driver-dir $driverDir -browser-dir $browserDir
            }
            if ($LASTEXITCODE -ne 0) {
                throw "browser-install.exe 下载 Playwright 运行时失败，退出码: $LASTEXITCODE"
            }
        } finally {
            if ([string]::IsNullOrWhiteSpace($userDownloadHost)) {
                Remove-Item Env:PLAYWRIGHT_DOWNLOAD_HOST -ErrorAction SilentlyContinue
            } else {
                $env:PLAYWRIGHT_DOWNLOAD_HOST = $userDownloadHost
            }
            $env:NO_PROXY = $previousNoProxy
        }
        if (-not (Test-PlaywrightRuntimeValid -RuntimeRoot $cacheRuntimeDir)) {
            throw 'Playwright 运行时校验失败：缺少 node.exe、chromium 或 chromium_headless_shell。'
        }
        Set-Content -LiteralPath $runtimeStampFile -Value $expectedRuntimeHash -Encoding utf8NoBOM
    }

    Write-Host '同步运行时到 dist/windows/playwright-runtime/amd64...'
    Sync-DirectoryWithRobocopy -Source $cacheRuntimeDir -Destination $distRuntimeDir
    $distStamp = Join-Path $distRuntimeDir '.browser-install.stamp'
    Remove-Item -LiteralPath $distStamp -Force -ErrorAction SilentlyContinue
    if (-not (Test-PlaywrightRuntimeValid -RuntimeRoot $distRuntimeDir)) {
        throw 'dist/windows/playwright-runtime/amd64 运行时校验失败。'
    }

    Write-Step '编译 Inno Setup 安装包'
    Invoke-InnoSetupInstallerBuild -RepoRoot $repoRoot -IsccPath $isccPath -AppVersion $versions.AppVersion

    $installerPath = Join-Path $distWindowsDir 'Ydisks-Xianyu-Helper-Setup.exe'
    if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
        throw "未生成目标安装包: $installerPath"
    }
    $sizeMB = [Math]::Round((Get-Item -LiteralPath $installerPath).Length / 1MB, 2)
    Write-Host "`n[成功] 安装包已生成：$installerPath ($sizeMB MB)" -ForegroundColor Green
} catch {
    $exitCode = 1
    Write-Host "`n[失败] $($_.Exception.Message)" -ForegroundColor Red
} finally {
    foreach ($syso in $sysoFiles) {
        Remove-Item -LiteralPath $syso -Force -ErrorAction SilentlyContinue
    }
    if ($PauseOnExit -and -not $NoPause) {
        Write-Host "`n[提示] 执行完毕，请按回车键退出..." -ForegroundColor Yellow
        [void][System.Console]::ReadLine()
    }
}

exit $exitCode
