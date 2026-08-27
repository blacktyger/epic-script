<#
.SYNOPSIS
    Epic Cash source installer for Windows.

.DESCRIPTION
    Builds the node, the wallet or the miner from pinned upstream sources and puts the binaries
    on your PATH. There are no prebuilt binaries involved, so what you run is what you compiled.

        irm https://raw.githubusercontent.com/blacktyger/epic-script/main/install.ps1 | iex

    Read it before you run it:

        irm https://raw.githubusercontent.com/blacktyger/epic-script/main/install.ps1 | more

    Run it from a PowerShell prompt, which is what Windows Terminal opens. There is no
    `powershell -ExecutionPolicy Bypass -c "..."` wrapper here on purpose: from a PowerShell
    prompt the outer shell expands $env:NAME inside the double quotes before the child starts,
    so the child gets a bare `=value` token and the launch fails with "The Process object must
    have the UseShellExecute property set to false in order to use environment variables".
    Execution policy governs script files on disk, not a string handed to iex, so the bypass
    flag was never doing anything either. From cmd.exe, use:

        powershell -c "irm <url>/install.ps1 | iex"

    Piped through iex, PowerShell cannot bind parameters, so use environment variables:

        $env:EPIC_COMPONENT='node'; $env:EPIC_YES='1'; irm https://raw.githubusercontent.com/blacktyger/epic-script/main/install.ps1 | iex

    Run as a saved file and the parameters below work normally.

.PARAMETER Component
    node, wallet, miner, node_wallet or all. Default: node_wallet

.PARAMETER Yes
    Answer yes to every question, up front. The same as answering `a` at the first one.

.PARAMETER InstallDeps
    Approve installing missing build tools without being asked. Only needed for unattended runs:
    an interactive run prints the exact winget command for each one and offers to run it.

.PARAMETER Check
    Run the preflight checks and stop. Changes nothing.

.PARAMETER WithTor
    Build the node and wallet with --features with-tor.

.PARAMETER MinerFeatures
    cpu, opencl or cuda. Default: cpu

.PARAMETER BinDir
    Where binaries go. Default: %LOCALAPPDATA%\Epic\bin

.PARAMETER SrcDir
    Where sources are cloned and built. Default: %LOCALAPPDATA%\Epic\src

.PARAMETER Jobs
    Parallel build jobs. Default: cargo's own choice.

.PARAMETER NoModifyPath
    Do not touch the user PATH.

.PARAMETER NoPatchCmake
    Refuse the miner's two build-script fixes rather than applying them. The miner will not
    build on a current CMake without them.

.PARAMETER ForceCheckout
    Discard uncommitted changes in an existing source checkout. Without it, a checkout with local
    edits stops the run rather than being overwritten.

.PARAMETER FastSync
    Download a chain snapshot into %USERPROFILE%\.epic\main\chain_data so a new node does not
    validate from genesis. Node only.

.PARAMETER BootstrapUrl
    Where the snapshot comes from. Default: https://bootstrap.epiccash.com/bootstrap.zip

.NOTES
    Licence: MIT. Source: https://github.com/blacktyger/epic-script

    Environment variable equivalents, which are the easier route through a pipe:
    EPIC_COMPONENT, EPIC_YES, EPIC_INSTALL_DEPS, EPIC_CHECK_ONLY, EPIC_WITH_TOR,
    EPIC_MINER_FEATURES, EPIC_BIN_DIR, EPIC_SRC_DIR, EPIC_JOBS, EPIC_NO_MODIFY_PATH,
    EPIC_NO_PATCH_CMAKE, EPIC_FORCE_CHECKOUT, EPIC_FAST_SYNC, EPIC_BOOTSTRAP_URL

    This script never installs anything system-wide on its own. Binaries go under your own
    profile, and build tools are only installed if you pass -InstallDeps.

    It never runs `epic-wallet init`, because that generates a seed phrase. Creating a wallet
    stays your explicit step.
#>

[CmdletBinding()]
param(
    [string]$Component,
    [switch]$Yes,
    [switch]$InstallDeps,
    [switch]$Check,
    [switch]$WithTor,
    [string]$MinerFeatures,
    [string]$BinDir,
    [string]$SrcDir,
    [int]$Jobs,
    [switch]$NoModifyPath,
    [switch]$NoPatchCmake,
    [switch]$FastSync,
    [switch]$ForceCheckout,
    [string]$BootstrapUrl
)

# No [ValidateSet] on Component or MinerFeatures, deliberately, and the reason is the whole reason
# this script exists in one piece. A validation attribute cannot be applied when the script is run
# through Invoke-Expression, which is exactly what `irm ... | iex` does: PowerShell reports
#
#   Cannot process argument because the value of argument "validValues" is out of range
#
# and nothing runs. Values are checked in Resolve-Settings instead, which also produces a better
# message than the attribute does. Verified against PowerShell 7.4: a plain [string] parameter and
# a [switch] both survive iex, a [ValidateSet] one does not.

# Copied into script scope here, at the top level, because this is the only point all three
# invocation modes agree on. Run as a file, parameters land in script scope. Run through iex, they
# land in the caller's. Run through [scriptblock]::Create, they land in the block's own scope and
# the functions below cannot see them at all, which failed with
# "The variable '$script:Component' cannot be retrieved because it has not been set".
$script:OptComponent = $Component
$script:OptMinerFeatures = $MinerFeatures
$script:OptBinDir = $BinDir
$script:OptSrcDir = $SrcDir
$script:OptBootstrapUrl = $BootstrapUrl
$script:OptJobs = $Jobs
$script:OptYes = [bool]$Yes
$script:OptInstallDeps = [bool]$InstallDeps
$script:OptCheck = [bool]$Check
$script:OptWithTor = [bool]$WithTor
$script:OptNoModifyPath = [bool]$NoModifyPath
$script:OptNoPatchCmake = [bool]$NoPatchCmake
$script:OptFastSync = [bool]$FastSync
$script:OptForceCheckout = [bool]$ForceCheckout

$InstallerVersion = '1.0.0'

# Stop on the first unhandled error rather than limping onward with a half-built install.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# ---------------------------------------------------------------------------
# Pinned upstream sources. Release tags, not master, so a rerun next month builds the same
# code. See the .sh installer and the README for why the miner comes from a fork.
# ---------------------------------------------------------------------------

$Sources = @{
    node   = @{
        Repo = 'https://github.com/EpicCash/epic.git'
        Ref  = 'v4.0.3'
        Dir  = 'epic'
        Bin  = 'epic.exe'
        Disk = 3000
    }
    wallet = @{
        Repo = 'https://github.com/EpicCash/epic-wallet.git'
        Ref  = 'v4.0.0'
        Dir  = 'epic-wallet'
        Bin  = 'epic-wallet.exe'
        Disk = 3000
    }
    miner  = @{
        Repo     = 'https://github.com/blacktyger/epic-miner.git'
        Ref      = 'e9d0d85dbb2db39aca66a3d1b5baf95788523694'
        Upstream = 'https://github.com/EpicCash/epic-miner.git'
        Dir      = 'epic-miner'
        Bin      = 'epic-miner.exe'
        Disk     = 1500
    }
}

# The oldest Windows SDK that can compile croaring-sys, which builds with -std:c11 and needs
# stdalign.h. SDK 10.0.19041 fails on exactly that; MSVC gained the C11 headers in 10.0.20348.
$MinWindowsSdk = [version]'10.0.20348.0'

# Chain snapshot for -FastSync, so a new node does not have to validate from genesis. The wiki
# still points at bootstrap.epic.tech, which no longer resolves.
$BootstrapUrlDefault = 'https://bootstrap.epiccash.com/bootstrap.zip'

# Directories that identify an unpacked chain database, used to find the payload inside the
# archive rather than assuming its layout.
$ChainMarkers = @('lmdb', 'txhashset', 'header', 'chain', 'peer')

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

# Colour and a spinner when the host can show them, plain text when it cannot. NO_COLOR is
# honoured because it is the convention, and a redirected stream gets no escape codes because
# nobody wants them in a log file.
function Initialize-Style {
    $script:Fancy = $true
    if ($env:NO_COLOR) { $script:Fancy = $false }
    try {
        if ([Console]::IsOutputRedirected) { $script:Fancy = $false }
    } catch {
        $script:Fancy = $false
    }
    $script:StepN = 0
    $script:StepTotal = 0
}

function Get-Mark([string]$Kind) {
    if ($script:Fancy) {
        switch ($Kind) { 'ok' { return [char]0x2713 } 'warn' { return '!' } 'err' { return [char]0x2717 } }
    }
    switch ($Kind) { 'ok' { return 'ok' } 'warn' { return 'warning' } 'err' { return 'error' } }
}

function Write-Plain([string]$Message) {
    Write-Host $Message
}

# A step heading. Numbered so a reader knows how much is left, which matters when one of them
# takes twenty minutes.
function Write-Step([string]$Title) {
    $script:StepN++
    Write-Host ''
    Write-Host "[$($script:StepN)/$($script:StepTotal)] " -NoNewline -ForegroundColor DarkGray
    Write-Host $Title -ForegroundColor White
}

# Retained under its old name because the whole script calls it. Now an indented plain line: the
# repeated prefix was most of the visual noise.
function Write-Info([string]$Message) {
    Write-Host "        $Message"
}

function Write-Detail([string]$Message) {
    Write-Host "        $Message" -ForegroundColor DarkGray
}

function Write-Ok([string]$Message) {
    Write-Host "        $(Get-Mark 'ok') " -NoNewline -ForegroundColor Green
    Write-Host $Message
}

function Write-Warn([string]$Message) {
    Write-Host "        $(Get-Mark 'warn') " -NoNewline -ForegroundColor Yellow
    Write-Host $Message
}

function Stop-WithError([string]$Message) {
    Write-Host ''
    $lead = if ($script:Fancy) { "$(Get-Mark 'err') " } else { 'error: ' }
    Write-Host $lead -NoNewline -ForegroundColor Red
    Write-Host $Message -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# Running noisy commands
#
# A cargo build prints hundreds of lines nobody reads while it succeeds, and the twenty that
# matter when it fails. So output goes to a log, a spinner shows the wait is alive, and the tail
# of the log is printed only if the command fails.
#
# Start-Process rather than the call operator, because polling HasExited is what makes a spinner
# possible at all, and because it gives a real exit code for a native command.
# ---------------------------------------------------------------------------

function Invoke-Logged {
    param(
        [string]$Label,
        [string]$LogPath,
        [string]$Exe,
        [string[]]$Arguments,
        [string]$WorkingDirectory
    )

    New-Item -ItemType Directory -Path (Split-Path $LogPath -Parent) -Force | Out-Null
    # Start-Process refuses to send both streams to one file, so stderr lands beside the log and
    # is folded in afterwards. One file holds the whole story by the time anyone reads it.
    $errPath = "$LogPath.err"

    $startArgs = @{
        FilePath               = $Exe
        NoNewWindow            = $true
        PassThru               = $true
        RedirectStandardOutput = $LogPath
        RedirectStandardError  = $errPath
    }
    if ($Arguments -and $Arguments.Count -gt 0) { $startArgs.ArgumentList = $Arguments }
    if ($WorkingDirectory) { $startArgs.WorkingDirectory = $WorkingDirectory }

    $proc = Start-Process @startArgs
    $started = Get-Date

    if ($script:Fancy) {
        $frames = @('|', '/', '-', '\')
        $i = 0
        while (-not $proc.HasExited) {
            $spent = (Get-Date) - $started
            $stamp = '{0}m{1:d2}s' -f [int]$spent.TotalMinutes, $spent.Seconds
            Write-Host "`r        $($frames[$i % 4]) $Label  $stamp " -NoNewline -ForegroundColor Cyan
            $i++
            Start-Sleep -Milliseconds 400
        }
        Write-Host "`r$(' ' * 78)`r" -NoNewline
    } else {
        Write-Detail "$Label, logging to $LogPath"
    }

    $proc.WaitForExit()

    if (Test-Path $errPath) {
        Get-Content -LiteralPath $errPath -ErrorAction SilentlyContinue | Add-Content -LiteralPath $LogPath
        Remove-Item -LiteralPath $errPath -Force -ErrorAction SilentlyContinue
    }

    $spent = (Get-Date) - $started
    if ($proc.ExitCode -eq 0 -and $script:Fancy) {
        $stamp = '{0}m{1:d2}s' -f [int]$spent.TotalMinutes, $spent.Seconds
        Write-Host "        $(Get-Mark 'ok') " -NoNewline -ForegroundColor Green
        Write-Host "$Label  " -NoNewline
        Write-Host $stamp -ForegroundColor DarkGray
    }
    return $proc.ExitCode
}

# The part of a failed log worth reading, which is the end of it.
function Show-LogTail([string]$LogPath, [int]$Lines = 25) {
    if (-not (Test-Path $LogPath)) { return }
    Write-Plain ''
    Write-Host "last $Lines lines of $LogPath" -ForegroundColor DarkGray
    Write-Plain ''
    Get-Content -LiteralPath $LogPath -Tail $Lines -ErrorAction SilentlyContinue | ForEach-Object { Write-Plain $_ }
    Write-Plain ''
}

# ---------------------------------------------------------------------------
# Environment overrides
#
# Piped into iex, the param() block is unreachable, so environment variables are the only way
# to pass anything. An explicit parameter always wins over a variable.
# ---------------------------------------------------------------------------

function Resolve-Settings {
    # An explicit parameter always wins over an environment variable, which wins over the default.
    $script:Component = if ($script:OptComponent) { $script:OptComponent }
        elseif ($env:EPIC_COMPONENT) { $env:EPIC_COMPONENT } else { 'node_wallet' }
    $script:MinerFeatures = if ($script:OptMinerFeatures) { $script:OptMinerFeatures }
        elseif ($env:EPIC_MINER_FEATURES) { $env:EPIC_MINER_FEATURES } else { 'cpu' }
    $script:BinDir = if ($script:OptBinDir) { $script:OptBinDir }
        elseif ($env:EPIC_BIN_DIR) { $env:EPIC_BIN_DIR } else { Join-Path $env:LOCALAPPDATA 'Epic\bin' }
    $script:SrcDir = if ($script:OptSrcDir) { $script:OptSrcDir }
        elseif ($env:EPIC_SRC_DIR) { $env:EPIC_SRC_DIR } else { Join-Path $env:LOCALAPPDATA 'Epic\src' }
    $script:BootstrapUrl = if ($script:OptBootstrapUrl) { $script:OptBootstrapUrl }
        elseif ($env:EPIC_BOOTSTRAP_URL) { $env:EPIC_BOOTSTRAP_URL } else { $BootstrapUrlDefault }
    $script:Jobs = if ($script:OptJobs) { $script:OptJobs }
        elseif ($env:EPIC_JOBS) { [int]$env:EPIC_JOBS } else { 0 }

    $script:Yes = $script:OptYes -or ($env:EPIC_YES -eq '1')
    $script:InstallDeps = $script:OptInstallDeps -or ($env:EPIC_INSTALL_DEPS -eq '1')
    $script:Check = $script:OptCheck -or ($env:EPIC_CHECK_ONLY -eq '1')
    $script:WithTor = $script:OptWithTor -or ($env:EPIC_WITH_TOR -eq '1')
    $script:NoModifyPath = $script:OptNoModifyPath -or ($env:EPIC_NO_MODIFY_PATH -eq '1')
    $script:NoPatchCmake = $script:OptNoPatchCmake -or ($env:EPIC_NO_PATCH_CMAKE -eq '1')
    $script:FastSync = $script:OptFastSync -or ($env:EPIC_FAST_SYNC -eq '1')
    $script:ForceCheckout = $script:OptForceCheckout -or ($env:EPIC_FORCE_CHECKOUT -eq '1')

    # Checked here rather than with a [ValidateSet] attribute, which cannot be applied under iex.
    $valid = @('node', 'wallet', 'miner', 'node_wallet', 'all')
    if ($script:Component -notin $valid) {
        Stop-WithError "unknown component '$($script:Component)'. Choose $($valid -join ', ')."
    }
    if ($script:MinerFeatures -notin @('cpu', 'opencl', 'cuda')) {
        Stop-WithError "unknown miner features '$($script:MinerFeatures)'. Choose cpu, opencl or cuda."
    }

    # The snapshot is the node's chain database, so it is meaningless without the node.
    if ($script:FastSync -and -not (Test-WantNode)) {
        Stop-WithError @"
-FastSync downloads the node's chain data, but '$($script:Component)' does not include the node.
    Use -Component node or -Component node_wallet.
"@
    }

    $script:MinerHome = Join-Path $env:LOCALAPPDATA 'Epic\miner'
    $script:MetaDir = Join-Path $env:LOCALAPPDATA 'Epic\install'
    $script:LogDir = Join-Path $script:MetaDir 'logs'
    # The node resolves its home from the user profile, not LOCALAPPDATA.
    $script:EpicMainHome = Join-Path $env:USERPROFILE '.epic\main'
}

function Test-WantNode { $script:Component -in @('node', 'node_wallet', 'all') }
function Test-WantWallet { $script:Component -in @('wallet', 'node_wallet', 'all') }
function Test-WantMiner { $script:Component -in @('miner', 'all') }

function Get-SelectedComponents {
    $selected = @()
    if (Test-WantNode) { $selected += 'node' }
    if (Test-WantWallet) { $selected += 'wallet' }
    if (Test-WantMiner) { $selected += 'miner' }
    return $selected
}

# ---------------------------------------------------------------------------
# Host checks
# ---------------------------------------------------------------------------

function Assert-PowerShellVersion {
    if ($PSVersionTable.PSVersion.Major -lt 5) {
        Stop-WithError @"
PowerShell 5.1 or later is required. This is $($PSVersionTable.PSVersion).
    Install PowerShell 7 from https://aka.ms/powershell and rerun.
"@
    }

    # Windows PowerShell 5.1 defaults to SSL3/TLS1.0 on older builds, which every relevant
    # host now refuses. .NET 4.5 or later is needed for TLS 1.2 to be available at all.
    if ($PSVersionTable.PSVersion.Major -eq 5) {
        if ([System.Enum]::GetNames([System.Net.SecurityProtocolType]) -notcontains 'Tls12') {
            Stop-WithError @"
this Windows PowerShell cannot negotiate TLS 1.2, which means .NET Framework is older than 4.5.
    Install PowerShell 7 from https://aka.ms/powershell and rerun.
"@
        }
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }
}

function Get-HostArchitecture {
    # PROCESSOR_ARCHITECTURE in the environment lies under WoW64, so read the machine value.
    try {
        $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
        $arch = (Get-ItemProperty -LiteralPath $key).PROCESSOR_ARCHITECTURE
    } catch {
        $arch = if ([Environment]::Is64BitOperatingSystem) { 'AMD64' } else { 'X86' }
    }

    switch ($arch) {
        'AMD64' { return 'x86_64' }
        'ARM64' { return 'aarch64' }
        default {
            Stop-WithError "unsupported processor architecture '$arch'. This installer covers x64 and ARM64."
        }
    }
}

function Test-Command([string]$Name) {
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

# Does a file exist at this absolute path, without ever throwing?
#
# Join-Path and Test-Path both resolve the drive qualifier through the PowerShell provider, so a
# candidate path on a drive the machine does not have throws rather than returning false:
#
#   Cannot find drive. A drive with the name 'D' does not exist.
#
# With $ErrorActionPreference = 'Stop' that aborts the whole install, which is what happened to the
# first person to run this on a machine with no D: drive. [System.IO.Path]::Combine is pure string
# work and touches no provider, and the Test-Path is guarded both ways.
function Test-FileAt([string]$Directory, [string]$Leaf) {
    if (-not $Directory) { return $false }
    try {
        $full = [System.IO.Path]::Combine($Directory, $Leaf)
        return (Test-Path -LiteralPath $full -PathType Leaf -ErrorAction SilentlyContinue)
    } catch {
        return $false
    }
}

# bindgen loads libclang.dll at build time. The LLVM component bundled with Visual Studio
# ships only clang-format and clang-tidy, so a real LLVM install is needed.
function Find-LibClang {
    if (Test-FileAt $env:LIBCLANG_PATH 'libclang.dll') {
        return $env:LIBCLANG_PATH
    }

    # Where the LLVM installer and the common package managers put it. No non-system drive is
    # guessed: a hardcoded D:\LLVM\bin here is what threw on the first Windows machine to run this,
    # and guessing drive letters is not a substitute for LIBCLANG_PATH anyway.
    $candidates = @(
        [System.IO.Path]::Combine($env:ProgramFiles, 'LLVM\bin')
        [System.IO.Path]::Combine(${env:ProgramFiles(x86)}, 'LLVM\bin')
        [System.IO.Path]::Combine($env:LOCALAPPDATA, 'Programs\LLVM\bin')
        [System.IO.Path]::Combine($env:ChocolateyInstall, 'lib\llvm\tools\LLVM\bin')
    )
    foreach ($dir in $candidates) {
        if (Test-FileAt $dir 'libclang.dll') { return $dir }
    }

    # Anything on PATH wins over a guess, including an install on a drive we would never try.
    if (Test-Command 'clang') {
        $clangDir = Split-Path (Get-Command 'clang').Source -Parent
        if (Test-FileAt $clangDir 'libclang.dll') { return $clangDir }
    }

    return $null
}

function Find-VisualStudio {
    # vswhere ships with the VS Installer. It is normally under Program Files (x86) even for a
    # 64-bit install, but both roots are checked because that is not guaranteed, and Combine is used
    # so an unset variable yields no candidate rather than a thrown Join-Path.
    $roots = @(${env:ProgramFiles(x86)}, $env:ProgramFiles) | Where-Object { $_ }
    $vswhere = $null
    foreach ($root in $roots) {
        $candidate = [System.IO.Path]::Combine($root, 'Microsoft Visual Studio\Installer\vswhere.exe')
        if (Test-Path -LiteralPath $candidate -PathType Leaf -ErrorAction SilentlyContinue) {
            $vswhere = $candidate
            break
        }
    }
    if (-not $vswhere) { return $null }

    $path = & $vswhere -latest -products '*' `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $path) { return $null }
    return $path
}

# Returns the newest installed Windows SDK version, or $null.
function Get-NewestWindowsSdk {
    $roots = @(${env:ProgramFiles(x86)}, $env:ProgramFiles) | Where-Object { $_ }
    $versions = foreach ($root in $roots) {
        $include = [System.IO.Path]::Combine($root, 'Windows Kits\10\Include')
        if (-not (Test-Path -LiteralPath $include -ErrorAction SilentlyContinue)) { continue }
        Get-ChildItem -LiteralPath $include -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $parsed = $null
            if ([version]::TryParse($_.Name, [ref]$parsed)) { $parsed }
        }
    }
    if (-not $versions) { return $null }
    return ($versions | Sort-Object -Descending | Select-Object -First 1)
}

# Strawberry Perl, specifically. The miner's vendored OpenSSL runs OpenSSL's Configure, which
# rejects the msys perl that ships with Git for Windows because it emits forward-slash paths.
function Find-StrawberryPerl {
    # Strawberry's own installer default, plus the Chocolatey and Scoop locations. Same rule as
    # libclang: no drive letters are guessed, and anything on PATH beats a guess.
    $candidates = @(
        [System.IO.Path]::Combine($env:SystemDrive + '\', 'Strawberry\perl\bin')
        [System.IO.Path]::Combine($env:ChocolateyInstall, 'lib\strawberryperl\tools\perl\bin')
        [System.IO.Path]::Combine($env:USERPROFILE, 'scoop\apps\perl\current\perl\bin')
    )
    foreach ($dir in $candidates) {
        if (Test-FileAt $dir 'perl.exe') { return $dir }
    }

    if (Test-Command 'perl') {
        $perl = (Get-Command 'perl').Source
        # Git for Windows ships an msys perl that OpenSSL's Configure rejects, because it emits
        # forward-slash paths. Finding that one is worse than finding none.
        if ($perl -notmatch 'Git|usr\\bin|msys') { return (Split-Path $perl -Parent) }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

# The exact winget command for one entry, so what is printed is what runs.
#
# --override is passed through for Visual Studio Build Tools. Without it winget installs the VS
# Installer and no workload at all, which produces no compiler while looking like it succeeded.
function Get-WingetCommand($Entry) {
    $cmd = "winget install --accept-package-agreements --accept-source-agreements --id $($Entry.Winget)"
    if ($Entry.ContainsKey('Override')) { $cmd += " --override `"$($Entry['Override'])`"" }
    return $cmd
}

function Invoke-WingetInstall($Entry) {
    # Not named $args: that is an automatic variable, and assigning to it inside a function is a
    # trap even where it happens to work.
    $wingetArgs = @(
        'install'
        '--accept-package-agreements'
        '--accept-source-agreements'
        '--id', $Entry.Winget
    )
    if ($Entry.ContainsKey('Override')) { $wingetArgs += @('--override', $Entry['Override']) }

    & winget @wingetArgs
    if ($LASTEXITCODE -ne 0) {
        # Not fatal on its own: the rest of the list is still worth attempting, and the rerun
        # re-checks everything anyway, so a genuinely missing tool is caught then rather than
        # guessed at now.
        Write-Warn "winget returned $LASTEXITCODE for $($Entry.Winget). Continuing with the rest."
    }
}

function Invoke-Preflight {
    $missing = @()

    if (-not (Test-Command 'git')) { $missing += @{ Name = 'Git'; Winget = 'Git.Git' } }
    if (-not (Test-Command 'cmake')) { $missing += @{ Name = 'CMake'; Winget = 'Kitware.CMake' } }

    $script:LibClangPath = Find-LibClang
    if (-not $script:LibClangPath) {
        # The LLVM component bundled with Visual Studio ships only clang-format and clang-tidy, so
        # a separate LLVM install is what the bindgen crates need.
        $missing += @{ Name = 'LLVM (for libclang.dll)'; Winget = 'LLVM.LLVM' }
    }

    if (Test-WantMiner) {
        $script:PerlPath = Find-StrawberryPerl
        if (-not $script:PerlPath) {
            $missing += @{ Name = 'Strawberry Perl (miner only)'; Winget = 'StrawberryPerl.StrawberryPerl' }
        }
    }

    # The MSVC toolchain joins the same list rather than being a separate hard error. It needs
    # --override because the bare Build Tools package installs an installer with no workload, which
    # produces no compiler and looks like the install worked.
    $vs = Find-VisualStudio
    if (-not $vs) {
        $missing += @{
            Name     = 'Visual Studio Build Tools, C++ workload'
            Winget   = 'Microsoft.VisualStudio.2022.BuildTools'
            Override = '--quiet --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'
            Note     = 'Several GB, and it brings a current Windows SDK with it.'
        }
    }

    # Only worth offering separately when the compiler is already here. When Build Tools is being
    # installed above, --includeRecommended brings an SDK newer than the floor anyway.
    $sdk = if ($vs) { Get-NewestWindowsSdk } else { $null }
    if ($vs -and (-not $sdk -or $sdk -lt $MinWindowsSdk)) {
        $missing += @{
            Name   = "Windows SDK $MinWindowsSdk or newer (found $(if ($sdk) { $sdk } else { 'none' }))"
            Winget = 'Microsoft.WindowsSDK.10.0.22621'
            Note   = "croaring-sys compiles with -std:c11 and needs stdalign.h, which MSVC only ships from $MinWindowsSdk onward. If winget cannot find this package, add it through the Visual Studio Installer under Individual Components."
        }
    }

    if ($missing.Count -gt 0) {
        Write-Plain ''
        Write-Info 'missing build tools:'
        foreach ($m in $missing) {
            Write-Plain "          $($m.Name)"
            if ($m.ContainsKey('Note')) { Write-Detail "    $($m['Note'])" }
        }
        Write-Plain ''

        # One command per package rather than one line with every id. winget's positional argument
        # is a single query, so a multi-package line is not something to hand a reader as a
        # copy-paste, and printing exactly what runs matters more than printing it compactly.
        Write-Info 'Install them with:'
        foreach ($m in $missing) { Write-Detail "  $(Get-WingetCommand $m)" }
        Write-Plain ''

        # Offer, rather than refuse. Refusing and telling the reader to rerun with a switch made
        # them sit through the whole preflight twice to reach the same point, when permission was
        # the only thing missing. -InstallDeps still exists for runs with no console to ask on.
        if (-not $script:InstallDeps) {
            if (-not (Test-CanPrompt)) {
                Stop-WithError @"
these need installing first, and there is no console here to ask on.
    Run the commands above yourself, or rerun with -InstallDeps to allow it.
"@
            }
            if (-not (Test-Command 'winget')) {
                Stop-WithError @"
winget is not available, so these cannot be installed automatically.
    Install them by hand, or get App Installer from the Microsoft Store, then rerun.
"@
            }
            Write-Plain 'winget may show a UAC prompt for each one.'
            Write-Plain ''
            if (-not (Confirm-Action 'Install them now?')) {
                Stop-WithError 'declined, nothing was changed. Install the tools above and rerun.'
            }
        } elseif (-not (Test-Command 'winget')) {
            Stop-WithError @"
winget is not available, so the tools cannot be installed automatically.
    Install them by hand, or get App Installer from the Microsoft Store, then rerun.
"@
        }

        foreach ($m in $missing) {
            Write-Info "installing $($m.Name)"
            Invoke-WingetInstall $m
        }

        Write-Plain ''
        Stop-WithError @"
build tools were installed, but this shell's PATH and environment predate them.
    Open a new terminal and rerun this installer. That is a refresh, not a failure.
"@
    }

    Write-Info "MSVC toolchain: $vs"
    Write-Info "Windows SDK: $(if ($sdk) { $sdk } else { Get-NewestWindowsSdk })"

    Write-Info "libclang: $($script:LibClangPath)"
    if (Test-WantMiner) { Write-Info "perl: $($script:PerlPath)" }

    Test-DiskSpace
    if (Test-WantMiner) { Test-CMakeEmptyTarget }
}

function Test-DiskSpace {
    $needed = 800
    foreach ($name in Get-SelectedComponents) { $needed += $Sources[$name].Disk }

    $root = [System.IO.Path]::GetPathRoot((Resolve-PathParent $script:SrcDir))
    try {
        $drive = Get-PSDrive -Name $root.TrimEnd(':\') -ErrorAction Stop
        $freeMb = [int]($drive.Free / 1MB)
    } catch {
        Write-Warn "could not read free space on $root. Builds need about $needed MiB."
        return
    }

    Write-Info "disk: $freeMb MiB free on $root, about $needed MiB needed"
    if ($freeMb -lt $needed) {
        Stop-WithError @"
not enough free disk space on ${root}: $freeMb MiB available, about $needed MiB needed.
    Point -SrcDir at a roomier drive, or install one component at a time.
"@
    }
}

# The miner's build scripts ask the cmake crate for an empty build target, which becomes
# `cmake --build . --target ""`. CMake used to tolerate that and now rejects it. Two files are
# affected, in two different repositories:
#
#   cuckoo-miner\src\build.rs   in epic-miner
#   randomx-rust\build.rs       in the randomx-rust submodule
#
# Neither is skippable. cuckoo_miner is a non-optional dependency of epic_miner_config, and
# randomx is a direct dependency of the miner itself. This probe decides whether the one-line fix
# is needed. Once both forks carry no_build_target, it stops firing.
function Test-CMakeEmptyTarget {
    $script:CmakeNeedsPatch = $false
    if (-not (Test-Command 'cmake')) { return }

    $probe = Join-Path ([System.IO.Path]::GetTempPath()) "epic-cmake-probe-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $build = Join-Path $probe 'build'
    New-Item -ItemType Directory -Path $build -Force | Out-Null

    try {
        Set-Content -LiteralPath (Join-Path $probe 'CMakeLists.txt') -Encoding ascii -Value @(
            'cmake_minimum_required(VERSION 3.5)'
            'project(probe C)'
            'add_library(probe STATIC probe.c)'
        )
        Set-Content -LiteralPath (Join-Path $probe 'probe.c') -Encoding ascii -Value 'int probe(void){return 0;}'

        & cmake -S $probe -B $build 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { return }

        & cmake --build $build --target "" --config Release 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { return }

        $script:CmakeNeedsPatch = $true
        Write-Info "cmake: $((& cmake --version | Select-Object -First 1)) rejects an empty build target"
    } finally {
        Remove-Item -LiteralPath $probe -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Replace .build_target("") with .no_build_target(true) in the miner's two build scripts.
#
# This is the only place the installer changes source before compiling it, so it is disclosed in
# full and confirmed. The two calls are equivalent in intent: both mean "configure and build the
# default target". Only the newer spelling is accepted by current CMake.
function Repair-CMakeBuildScripts([string]$Root) {
    $targets = @('cuckoo-miner\src\build.rs', 'randomx-rust\build.rs')

    Write-Plain ''
    Write-Info "the miner's build scripts need a one-line change each to build with this CMake:"
    foreach ($rel in $targets) {
        $full = Join-Path $Root $rel
        if ((Test-Path $full) -and (Select-String -LiteralPath $full -Pattern '\.build_target\(""\)' -Quiet)) {
            Write-Plain "    $rel"
            Write-Plain '        -  .build_target("")'
            Write-Plain '        +  .no_build_target(true)'
        }
    }
    Write-Plain ''

    if ($script:NoPatchCmake) {
        Stop-WithError @"
the miner cannot build with this CMake and -NoPatchCmake was passed.
    Apply the two changes above in $Root and run cargo build --release there,
    or install the node and wallet instead with -Component node_wallet.
"@
    }
    if (-not (Confirm-Action 'Apply those two changes to the checkout and continue?')) {
        Stop-WithError 'declined. The miner cannot build with this CMake unless they are applied.'
    }

    foreach ($rel in $targets) {
        $full = Join-Path $Root $rel
        if (-not (Test-Path $full)) {
            Write-Warn "expected $rel in the checkout and it is not there, skipping"
            continue
        }
        if (-not (Select-String -LiteralPath $full -Pattern '\.build_target\(""\)' -Quiet)) {
            Write-Info "$rel already uses no_build_target, nothing to change"
            continue
        }

        $content = Get-Content -LiteralPath $full -Raw
        $patched = $content -replace '\.build_target\(""\)', '.no_build_target(true)'
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($full, $patched, $utf8NoBom)

        if (-not (Select-String -LiteralPath $full -Pattern 'no_build_target\(true\)' -Quiet)) {
            Stop-WithError "rewrote $rel but the change is not present. Stopping rather than guessing."
        }
        Write-Info "patched $rel"
    }
}

function Resolve-PathParent([string]$Path) {
    $current = $Path
    while ($current -and -not (Test-Path $current)) {
        $parent = Split-Path $current -Parent
        if ($parent -eq $current) { break }
        $current = $parent
    }
    if (-not $current) { return $Path }
    return $current
}

# ---------------------------------------------------------------------------
# Rust toolchain
# ---------------------------------------------------------------------------

function Install-RustIfMissing {
    if (Test-Command 'cargo') {
        Write-Info "cargo: $((& cargo --version) -join '')"
        if (-not (Test-Command 'rustup')) {
            Write-Warn @"
rustup is not installed, so the toolchain pinned by rust-toolchain.toml (1.89.0) cannot be
    selected automatically. The build will use the cargo already on PATH and may fail.
"@
        }
        return
    }

    Write-Info 'cargo is not on PATH, so Rust needs installing.'
    if (-not (Confirm-Action 'Install the Rust toolchain with rustup, from https://win.rustup.rs?')) {
        Stop-WithError @"
Rust is required. Install it and rerun:
    winget install --id Rustlang.Rustup
"@
    }

    $arch = if ($script:HostArch -eq 'aarch64') { 'aarch64' } else { 'x86_64' }
    $url = "https://static.rust-lang.org/rustup/dist/$arch-pc-windows-msvc/rustup-init.exe"
    $exe = Join-Path ([System.IO.Path]::GetTempPath()) 'rustup-init.exe'

    Write-Info "downloading $url"
    Invoke-Download -Url $url -Destination $exe

    & $exe -y --no-modify-path
    if ($LASTEXITCODE -ne 0) { Stop-WithError 'rustup-init failed.' }

    $cargoBin = Join-Path $env:USERPROFILE '.cargo\bin'
    $env:PATH = "$cargoBin;$env:PATH"
    if (-not (Test-Command 'cargo')) {
        Stop-WithError 'rustup finished but cargo is still not on PATH.'
    }
    $script:RustWasInstalled = $true
    Write-Info "installed $((& cargo --version) -join '')"
}

function Invoke-Download([string]$Url, [string]$Destination) {
    # curl.exe ships with Windows 10 1803 and later and is faster than Invoke-WebRequest on
    # PowerShell 5.1. Note the .exe: bare `curl` is an alias for Invoke-WebRequest.
    if (Test-Command 'curl.exe') {
        & curl.exe --proto '=https' --tlsv1.2 -fsSL -o $Destination $Url
        if ($LASTEXITCODE -eq 0 -and (Test-Path $Destination)) { return }
    }

    $progress = $global:ProgressPreference
    try {
        $global:ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
    } finally {
        $global:ProgressPreference = $progress
    }

    if (-not (Test-Path $Destination)) {
        Stop-WithError "downloaded $Url but nothing arrived at $Destination. Did an antivirus remove it?"
    }
}

# ---------------------------------------------------------------------------
# Prompting
# ---------------------------------------------------------------------------

# True when a question can actually be answered. Separate from Confirm-Action because some callers
# want to change what they do when nobody can be asked, rather than give up.
function Test-CanPrompt {
    if ($script:Yes) { return $true }
    try {
        if (-not [Environment]::UserInteractive) { return $false }
        if ([Console]::IsInputRedirected) { return $false }
    } catch {
        return $false
    }
    return $true
}

function Confirm-Action([string]$Question) {
    if ($script:Yes) { return $true }

    # Fetched with irm and run through iex, stdin is still the console, so Read-Host works. The
    # case to guard is a genuinely non-interactive session, where prompting would either throw or
    # block forever. Both checks are needed: UserInteractive is true in plenty of CI containers.
    if (-not (Test-CanPrompt)) {
        Stop-WithError @"
cannot prompt, and this needs an answer: $Question
    There is no interactive console attached, which is normal in CI.
    Rerun with -Yes, or set `$env:EPIC_YES='1', to accept without prompting.
"@
    }

    $answer = Read-Host "$Question [y/N/a]"
    if ($answer -in @('y', 'Y', 'yes', 'YES', 'Yes')) { return $true }
    if ($answer -in @('a', 'A', 'all', 'ALL', 'All')) {
        # Yes to this and to everything after it. The point of asking each time is that a reader
        # may want to stop at one of them, but once they have decided they should not have to keep
        # deciding. -Yes is the same answer given up front.
        $script:Yes = $true
        Write-Detail 'answering yes to the remaining questions too'
        return $true
    }
    return $false
}

# ---------------------------------------------------------------------------
# Source and build
# ---------------------------------------------------------------------------

# Paths this installer modifies inside a checkout itself. Excluded from the uncommitted-changes
# check below, or the miner's own cmake fix would look like the user's work on every rerun.
$InstallerPatchedPaths = @('cuckoo-miner/src/build.rs', 'randomx-rust/build.rs')

# Refuse to throw away work that is not ours.
#
# The update path ends in `git checkout --force`, which discards uncommitted changes to tracked
# files. Fine for a checkout this script created and nobody touched, data loss for someone who
# pointed -SrcDir at a clone they were editing.
#
# Only tracked modifications matter: --force leaves untracked files alone and cannot lose commits,
# since the ref stays reachable.
function Assert-CheckoutIsClean([string]$Directory, [string]$Name) {
    $dirty = & git -C $Directory status --porcelain --untracked-files=no 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $dirty) { return }

    $theirs = @()
    foreach ($line in @($dirty)) {
        if (-not $line) { continue }
        $path = $line.Substring(3).Trim()
        if ($InstallerPatchedPaths -notcontains $path) { $theirs += $path }
    }
    if ($theirs.Count -eq 0) { return }

    if ($script:ForceCheckout) {
        Write-Warn "discarding uncommitted changes in $Directory, because -ForceCheckout was passed"
        return
    }

    $list = ($theirs | ForEach-Object { "          $_" }) -join "`n"
    Stop-WithError @"
$Name at $Directory has uncommitted changes to tracked files:
$list
        Updating it to the pinned ref runs git checkout --force, which discards those.

        Commit or stash them, or point somewhere else with -SrcDir, or pass
        -ForceCheckout to discard them deliberately.
"@
}

function Get-Source([hashtable]$Source, [bool]$Recursive) {
    $dir = Join-Path $script:SrcDir $Source.Dir

    # A directory that is not a checkout cannot be cloned into, and git's own message for it does
    # not say what to do about it.
    if ((Test-Path $dir) -and -not (Test-Path (Join-Path $dir '.git'))) {
        if (@(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue).Count -gt 0) {
            Stop-WithError @"
$dir already exists, is not a git checkout, and is not empty.
        This installer needs that path for the $($Source.Dir) sources. Move it aside, or choose
        a different tree with -SrcDir.
"@
        }
    }

    $log = Join-Path $script:LogDir "fetch-$($Source.Dir).log"
    if (Test-Path (Join-Path $dir '.git')) {
        Assert-CheckoutIsClean -Directory $dir -Name $Source.Dir
        $code = Invoke-Logged -Label "updating $($Source.Dir) to $($Source.Ref)" -LogPath $log `
            -Exe 'git' -Arguments @('-C', $dir, 'fetch', '--tags', '--force', 'origin')
        if ($code -ne 0) { Show-LogTail $log; Stop-WithError "git fetch failed in $dir. Full log: $log" }
    } else {
        $code = Invoke-Logged -Label "cloning $($Source.Dir) at $($Source.Ref)" -LogPath $log `
            -Exe 'git' -Arguments @('clone', '--quiet', $Source.Repo, $dir)
        if ($code -ne 0) { Show-LogTail $log; Stop-WithError "git clone of $($Source.Repo) failed. Full log: $log" }
    }

    & git -C $dir checkout --force $Source.Ref
    if ($LASTEXITCODE -ne 0) { Stop-WithError "could not check out $($Source.Ref) in $dir" }

    if ($Recursive) {
        $subLog = Join-Path $script:LogDir "submodules-$($Source.Dir).log"
        $code = Invoke-Logged -Label "fetching $($Source.Dir) submodules" -LogPath $subLog `
            -Exe 'git' -Arguments @('-C', $dir, 'submodule', 'update', '--init', '--recursive')
        if ($code -ne 0) { Show-LogTail $subLog; Stop-WithError "submodule checkout failed in $dir. Full log: $subLog" }
    }

    $head = (& git -C $dir rev-parse --short HEAD)
    Write-Detail "$($Source.Dir) is at $head"
    return $dir
}

function Invoke-CargoBuild([string]$Directory, [string]$Name, [string[]]$ExtraArgs) {
    $cargoArgs = @('build', '--release')
    if ($script:Jobs -gt 0) { $cargoArgs += @('-j', "$($script:Jobs)") }
    if ($ExtraArgs) { $cargoArgs += $ExtraArgs }

    # bindgen needs this, and a user-set value may be missing or point at Visual Studio's LLVM,
    # which ships no libclang.dll.
    $env:LIBCLANG_PATH = $script:LibClangPath

    $log = Join-Path $script:LogDir "build-$Name.log"
    $code = Invoke-Logged -Label "compiling $Name" -LogPath $log `
        -Exe 'cargo' -Arguments $cargoArgs -WorkingDirectory $Directory

    if ($code -ne 0) {
        Show-LogTail $log
        Stop-WithError @"
the build of $Name failed.
        The cargo error above is the real cause. The usual ones on Windows are a Windows SDK
        older than $MinWindowsSdk, which fails on stdalign.h, LIBCLANG_PATH pointing at Visual
        Studio's LLVM, which has no libclang.dll, or Git for Windows' msys perl sitting ahead of
        Strawberry Perl on PATH.

        Full log:  $log
        Sources:   $Directory  (kept, so a retry does not reclone)
"@
    }
}

function Build-Component([string]$Name) {
    $source = $Sources[$Name]

    switch ($Name) {
        'node' {
            $dir = Get-Source -Source $source -Recursive $false
            Invoke-CargoBuild -Directory $dir -Name 'node' -ExtraArgs $(if ($script:WithTor) { @('--features', 'with-tor') } else { @() })
        }
        'wallet' {
            $dir = Get-Source -Source $source -Recursive $false
            Invoke-CargoBuild -Directory $dir -Name 'wallet' -ExtraArgs $(if ($script:WithTor) { @('--features', 'with-tor') } else { @() })
        }
        'miner' {
            $dir = Get-Source -Source $source -Recursive $true

            # The checkout above resets the working tree, so this runs on every build.
            if ($script:CmakeNeedsPatch) { Repair-CMakeBuildScripts -Root $dir }

            # Strawberry Perl must come before Git's msys perl, or vendored OpenSSL fails to
            # configure.
            if ($script:PerlPath) { $env:PATH = "$($script:PerlPath);$env:PATH" }

            $extra = switch ($script:MinerFeatures) {
                'cpu' { @() }
                'opencl' { @('--features', 'opencl') }
                # Upstream's README documents --features cuda,tui here, which cannot work:
                # there is no tui feature in the manifest and cargo rejects it outright.
                'cuda' { @('--no-default-features', '--features', 'cuda') }
            }
            Invoke-CargoBuild -Directory $dir -Name 'miner' -ExtraArgs $extra
        }
    }
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

function Add-Receipt([string]$Line) {
    Add-Content -LiteralPath $script:Receipt -Value $Line
}

function Install-ComponentBinary([string]$Name) {
    $source = $Sources[$Name]
    $built = Join-Path (Join-Path $script:SrcDir $source.Dir) "target\release\$($source.Bin)"

    if (-not (Test-Path $built)) {
        Stop-WithError "expected a built binary at $built and it is not there"
    }

    $target = Join-Path $script:BinDir $source.Bin

    # Say what is being replaced. Overwriting silently is fine until the version that was there
    # mattered, and by then it is gone.
    if (Test-Path $target) {
        $was = $null
        try { $was = (& $target --version 2>$null | Select-Object -First 1) } catch { $was = $null }
        Write-Detail "replacing $(if ($was) { $was } else { "an existing $($source.Bin)" }) at $target"
    }

    try {
        Copy-Item -LiteralPath $built -Destination $target -Force
    } catch [System.UnauthorizedAccessException] {
        Stop-WithError @"
could not replace $target, which usually means it is running.
        Stop the running $($source.Bin) and rerun.
"@
    }
    Add-Receipt $target
    Write-Info "installed $target"
}

# The miner is not a single binary. It needs its Cuckoo plugins on disk and refuses to start
# without an epic-miner.toml in the working directory, so it gets its own directory and a
# launcher that supplies both.
function Install-Miner {
    $src = Join-Path $script:SrcDir $Sources.miner.Dir
    $built = Join-Path $src 'target\release'

    New-Item -ItemType Directory -Path $script:MinerHome -Force | Out-Null

    $exe = Join-Path $built $Sources.miner.Bin
    if (-not (Test-Path $exe)) { Stop-WithError "expected a built miner at $exe" }
    Copy-Item -LiteralPath $exe -Destination (Join-Path $script:MinerHome $Sources.miner.Bin) -Force

    $plugins = Join-Path $built 'plugins'
    if (Test-Path $plugins) {
        $dest = Join-Path $script:MinerHome 'plugins'
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        Copy-Item -Path (Join-Path $plugins '*') -Destination $dest -Recurse -Force
        Write-Info "installed mining plugins to $dest"
    } else {
        Write-Info 'no Cuckoo plugins were built, which is expected on Windows. RandomX still works.'
    }

    # RandomX may be linked as a DLL rather than statically. If one was produced, put it beside
    # the binary so the loader finds it.
    $randomx = Get-ChildItem -Path (Join-Path $built 'build') -Filter 'randomx.dll' -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($randomx) {
        Copy-Item -LiteralPath $randomx.FullName -Destination (Join-Path $script:MinerHome 'randomx.dll') -Force
        Write-Info 'installed randomx.dll beside the miner'
    }

    $configTarget = Join-Path $script:MinerHome 'epic-miner.toml'
    if (Test-Path $configTarget) {
        Write-Info "kept the existing $configTarget"
    } else {
        Copy-Item -LiteralPath (Join-Path $src 'epic-miner.toml') -Destination $configTarget -Force
        $pluginDir = (Join-Path $script:MinerHome 'plugins') -replace '\\', '/'
        (Get-Content -LiteralPath $configTarget) `
            -replace '^#miner_plugin_dir = .*', "miner_plugin_dir = `"$pluginDir`"" |
            Set-Content -LiteralPath $configTarget
        Write-Info "wrote $configTarget with miner_plugin_dir set"
    }

    # A .cmd launcher, so it works from cmd.exe and PowerShell alike.
    $launcher = Join-Path $script:BinDir 'epic-miner.cmd'
    $launcherBody = @"
@echo off
rem Generated by epic-script. Supplies the plugin directory and a working directory
rem containing epic-miner.toml, neither of which the miner can find on its own.
setlocal
set "EPIC_MINER_HOME=$($script:MinerHome)"
if not exist "%CD%\epic-miner.toml" cd /d "%EPIC_MINER_HOME%"
"%EPIC_MINER_HOME%\$($Sources.miner.Bin)" %*
"@
    Set-Content -LiteralPath $launcher -Value $launcherBody -Encoding ascii
    Add-Receipt $launcher
    Write-Info "installed $launcher as a launcher for $script:MinerHome\$($Sources.miner.Bin)"
}

# ---------------------------------------------------------------------------
# Fast sync
#
# A fresh node validates the whole chain from genesis, which takes hours. The project publishes a
# snapshot of the chain database, and dropping that in beforehand turns the wait into a download.
#
# Worth understanding before using it: this is somebody else's copy of the chain database, fetched
# over TLS with no signature published alongside it. The node still verifies the proof-of-work and
# the MMR roots as it loads and continues, so a doctored snapshot does not let anyone hand you fake
# coins. It is a much weaker guarantee than validating from genesis yourself. Skip the flag if you
# would rather wait.
# ---------------------------------------------------------------------------

# Size of the archive in MiB, or $null when the server will not say.
function Get-BootstrapSizeMb {
    try {
        $response = Invoke-WebRequest -Uri $script:BootstrapUrl -Method Head -UseBasicParsing -TimeoutSec 30
        $length = $response.Headers['Content-Length']
        if ($length) { return [int]([int64]$length / 1MB) }
    } catch {
        return $null
    }
    return $null
}

# Find the chain database inside the extracted archive, whatever it was wrapped in.
function Find-ChainPayload([string]$Staging) {
    $hit = Get-ChildItem -LiteralPath $Staging -Directory -Recurse -Depth 2 -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'chain_data' } | Select-Object -First 1
    if ($hit) { return $hit.FullName }

    # Otherwise the archive may hold the database contents directly, at the root or one level down.
    $candidates = @(Get-Item -LiteralPath $Staging) +
        @(Get-ChildItem -LiteralPath $Staging -Directory -ErrorAction SilentlyContinue)
    foreach ($candidate in $candidates) {
        foreach ($marker in $ChainMarkers) {
            if (Test-Path (Join-Path $candidate.FullName $marker) -PathType Container) {
                return $candidate.FullName
            }
        }
    }
    return $null
}

# Move the unpacked database into place and clear the staging tree. Separated out because this is
# the only part of fast sync that touches data the user may already care about.
function Install-ChainPayload([string]$Payload, [string]$ChainDir, [string]$Staging, [string]$Zip) {
    $script:ChainBackup = $null

    # Move the old directory aside rather than deleting it, so a failure here leaves a recoverable
    # chain instead of a destroyed one.
    if (Test-Path $ChainDir) {
        $script:ChainBackup = "$ChainDir.replaced-$(Get-Date -Format 'yyyyMMddHHmmss')"
        Move-Item -LiteralPath $ChainDir -Destination $script:ChainBackup
    }

    $parent = Split-Path $ChainDir -Parent
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    Move-Item -LiteralPath $Payload -Destination $ChainDir

    # Only the archive and the staging tree are removed, and both were created by this script.
    Remove-Item -LiteralPath $Zip -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $Staging 'extracted') -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Staging -Recurse -Force -ErrorAction SilentlyContinue
}

# Guidance printed whenever the snapshot cannot be fetched or used. The install itself has already
# succeeded by this point, so this is advice, not an error.
function Show-BootstrapManualHelp {
    $chain = Join-Path $script:EpicMainHome 'chain_data'
    Write-Plain ''
    Write-Plain '    The node and wallet are installed and work. Only the snapshot is missing, so the'
    Write-Plain '    node will validate from genesis instead. That is slower, and it is also the'
    Write-Plain '    stronger guarantee, so it is a perfectly good outcome.'
    Write-Plain ''
    Write-Plain '    To bootstrap by hand later, from a machine or network that can reach the file:'
    Write-Plain ''
    Write-Plain "        Invoke-WebRequest $($script:BootstrapUrl) -OutFile bootstrap.zip"
    Write-Plain '        Expand-Archive bootstrap.zip -DestinationPath .'
    Write-Plain '        # the archive holds a chain_data directory. Move it here:'
    Write-Plain "        Move-Item chain_data '$chain'"
    Write-Plain ''
    Write-Plain '    Stop the node first if it is running, and open the file in a browser if the'
    Write-Plain '    download fails: a home or corporate content filter blocking the host is a common'
    Write-Plain '    cause, and it returns a web page rather than an archive.'
    Write-Plain "        $($script:BootstrapUrl)"
}

# Records the outcome, so fast sync failing never fails the install.
function Set-FastSyncFailed([string]$Message) {
    $script:FastSyncStatus = 'failed'
    Write-Warn $Message
    Show-BootstrapManualHelp
}

function Invoke-FastSync {
    $epicHome = $script:EpicMainHome
    $chain = Join-Path $epicHome 'chain_data'
    # Staged on the same volume as the target, so the final move is a rename rather than a
    # multi-gigabyte copy, and so a large archive does not fill the temp directory.
    $staging = Join-Path $epicHome '.fast-sync'
    $zip = Join-Path $staging 'bootstrap.zip'
    $stamp = Join-Path $staging 'bootstrap.url'

    Write-Plain ''
    Write-Info 'fast sync: fetching a chain snapshot so the node does not validate from genesis'
    Write-Info "source: $($script:BootstrapUrl)"

    if (Test-Path $chain) {
        Write-Plain ''
        Write-Warn "chain data already exists at $chain"
        Write-Plain '    Replacing it discards the chain you already have. Wallet files are not'
        Write-Plain '    touched either way, and a node that is currently running must be stopped first.'
        if (-not (Confirm-Action "Replace the existing chain data at $chain?")) {
            Write-Info 'keeping the existing chain data, skipping fast sync'
            $script:FastSyncStatus = 'skipped'
            return
        }
    }

    New-Item -ItemType Directory -Path $staging -Force | Out-Null

    $sizeMb = Get-BootstrapSizeMb
    if ($sizeMb) {
        $needed = [int]($sizeMb * 2.5)
        Write-Info "snapshot is about $sizeMb MiB, so about $needed MiB is needed to unpack it"
        try {
            $root = [System.IO.Path]::GetPathRoot($epicHome)
            $drive = Get-PSDrive -Name $root.TrimEnd(':\') -ErrorAction Stop
            $freeMb = [int]($drive.Free / 1MB)
            if ($freeMb -lt $needed) {
                Set-FastSyncFailed "not enough free disk space for the snapshot: $freeMb MiB available, about $needed MiB needed."
                return
            }
        } catch {
            Write-Warn 'could not check free space before downloading.'
        }
    } else {
        Write-Warn 'the server did not report a size, so free space cannot be checked in advance'
    }

    # Resuming a large download matters on a flaky link, but resuming blindly does not: a leftover
    # archive from an earlier run, or from a different URL, would be appended to or accepted as
    # complete. So the URL is recorded next to the file and resume only happens when it matches.
    $resume = $false
    if ((Test-Path $zip) -and (Test-Path $stamp) -and
        ((Get-Content -LiteralPath $stamp -Raw).Trim() -eq $script:BootstrapUrl)) {
        Write-Info "resuming the partial download already in $staging"
        $resume = $true
    } elseif (Test-Path $zip) {
        Remove-Item -LiteralPath $zip -Force
    }
    Set-Content -LiteralPath $stamp -Value $script:BootstrapUrl -Encoding ascii

    Write-Info 'downloading, which takes a while and shows progress'
    Write-Plain ''
    if (Test-Command 'curl.exe') {
        $curlArgs = @('--proto', '=https', '--tlsv1.2', '-fL', '--retry', '3', '--progress-bar')
        if ($resume) { $curlArgs += @('-C', '-') }
        $curlArgs += @('-o', $zip, $script:BootstrapUrl)
        & curl.exe @curlArgs
        if ($LASTEXITCODE -ne 0) {
            Set-FastSyncFailed "could not download the snapshot from $($script:BootstrapUrl)"
            return
        }
    } else {
        try {
            Invoke-Download -Url $script:BootstrapUrl -Destination $zip
        } catch {
            Set-FastSyncFailed "could not download the snapshot from $($script:BootstrapUrl)"
            return
        }
    }
    Write-Plain ''

    # A content filter, a proxy or an error page will happily arrive with a 200, so check the magic
    # bytes rather than trusting the extension.
    $magic = @([System.IO.File]::ReadAllBytes($zip) | Select-Object -First 2)
    if ($magic.Count -lt 2 -or $magic[0] -ne 0x50 -or $magic[1] -ne 0x4B) {
        Set-FastSyncFailed @"
what arrived from $($script:BootstrapUrl) is not a zip archive.
    A captive portal, a proxy or an ISP content filter returning a web page is the usual cause.
    The file is at $zip if you want to look at it.
"@
        return
    }

    Write-Info 'unpacking'
    $extracted = Join-Path $staging 'extracted'
    # Cleared first, so files left by an earlier failed attempt cannot be mistaken for the contents
    # of this archive.
    Remove-Item -LiteralPath $extracted -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $extracted -Force | Out-Null

    $progress = $global:ProgressPreference
    try {
        # Expand-Archive crawls with the progress bar enabled on PowerShell 5.1.
        $global:ProgressPreference = 'SilentlyContinue'
        if (Test-Command 'tar.exe') {
            # tar handles multi-gigabyte zips far better than Expand-Archive.
            & tar.exe -xf $zip -C $extracted
            if ($LASTEXITCODE -ne 0) {
                Set-FastSyncFailed "the snapshot downloaded but will not unpack, so it is probably truncated. Delete $zip and try again."
                return
            }
        } else {
            Expand-Archive -LiteralPath $zip -DestinationPath $extracted -Force
        }
    } catch {
        Set-FastSyncFailed "the snapshot downloaded but will not unpack, so it is probably truncated. Delete $zip and try again."
        return
    } finally {
        $global:ProgressPreference = $progress
    }

    $payload = Find-ChainPayload -Staging $extracted
    if (-not $payload) {
        Set-FastSyncFailed @"
unpacked the snapshot but found no chain database inside it.
    Expected a chain_data directory, or one containing any of: $($ChainMarkers -join ', ')
    The unpacked files are at $extracted if you want to move them by hand.
"@
        return
    }
    Write-Info "found the chain database at $payload"

    Install-ChainPayload -Payload $payload -ChainDir $chain -Staging $staging -Zip $zip
    Write-Info 'removed the archive and the staging directory'
    Write-Info "chain data is in place at $chain"
    $script:FastSyncStatus = 'ok'

    if ($script:ChainBackup) {
        Write-Plain ''
        Write-Info "your previous chain data was moved to $($script:ChainBackup) rather than deleted."
        Write-Info 'Delete it yourself once the node starts cleanly.'
    }
}

# ---------------------------------------------------------------------------
# PATH
# ---------------------------------------------------------------------------

function Add-ToUserPath([string]$Directory) {
    if (($env:PATH -split ';') -contains $Directory) {
        Write-Info "$Directory is already on PATH, leaving it alone"
        return
    }

    if ($script:NoModifyPath) {
        $script:PathNeedsAction = $true
        return
    }

    # Read with DoNotExpandEnvironmentNames, or an existing %USERPROFILE% in someone's PATH is
    # flattened to a literal path for every other application. setx is avoided because it
    # truncates at 1024 characters.
    $key = 'registry::HKEY_CURRENT_USER\Environment'
    $existing = (Get-Item -LiteralPath $key).GetValue('Path', '', 'DoNotExpandEnvironmentNames')
    $entries = $existing -split ';' | Where-Object { $_ -ne '' }

    if ($entries -contains $Directory) {
        Write-Info "$Directory is already in the user PATH"
    } else {
        $updated = (@($Directory) + $entries) -join ';'
        $kind = if ($updated -match '%') { 'ExpandString' } else { 'String' }
        Set-ItemProperty -LiteralPath $key -Name 'Path' -Value $updated -Type $kind
        Add-Receipt "path:$Directory"
        Write-Info "added $Directory to your user PATH"
        $script:PathNeedsReload = $true
    }

    $env:PATH = "$Directory;$env:PATH"

    # Nudge Explorer and any already-open shells to re-read the environment.
    try {
        $dummy = 'EPIC_INSTALL_REFRESH'
        [Environment]::SetEnvironmentVariable($dummy, '1', 'User')
        [Environment]::SetEnvironmentVariable($dummy, [NullString]::Value, 'User')
    } catch {
        # Cosmetic only. A new terminal picks the change up regardless.
    }
}

# ---------------------------------------------------------------------------
# Uninstaller
# ---------------------------------------------------------------------------

function Write-Uninstaller {
    $lines = [System.Collections.Generic.List[string]]::new()

    $lines.Add('# Generated by epic-script. Removes what the installer added, and nothing else.')
    $lines.Add('#')
    $lines.Add('#   powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Epic\install\uninstall.ps1"')
    $lines.Add('#   ... -PurgeData     also removes chain data and wallets')
    $lines.Add('#')
    $lines.Add('# Without -PurgeData your wallet seeds and chain data are left untouched.')
    $lines.Add('param([switch]$PurgeData)')
    $lines.Add('$ErrorActionPreference = ''Continue''')
    $lines.Add('')

    foreach ($line in Get-Content -LiteralPath $script:Receipt) {
        if ($line -like 'path:*') { continue }
        $lines.Add("Remove-Item -LiteralPath '$line' -Force -ErrorAction SilentlyContinue")
        $lines.Add("Write-Host 'removed $line'")
    }

    if (Test-Path $script:MinerHome) {
        $lines.Add("Remove-Item -LiteralPath '$($script:MinerHome)' -Recurse -Force -ErrorAction SilentlyContinue")
        $lines.Add("Write-Host 'removed $($script:MinerHome)'")
    }

    # Remove only our own PATH entry, by exact match, so an unrelated edit survives.
    $lines.Add('')
    $lines.Add('$key = ''registry::HKEY_CURRENT_USER\Environment''')
    $lines.Add('$existing = (Get-Item -LiteralPath $key).GetValue(''Path'', '''', ''DoNotExpandEnvironmentNames'')')
    $lines.Add("`$kept = `$existing -split ';' | Where-Object { `$_ -ne '' -and `$_ -ne '$($script:BinDir)' }")
    $lines.Add('$joined = $kept -join '';''')
    $lines.Add('$kind = if ($joined -match ''%'') { ''ExpandString'' } else { ''String'' }')
    $lines.Add('Set-ItemProperty -LiteralPath $key -Name ''Path'' -Value $joined -Type $kind')
    $lines.Add("Write-Host 'removed $($script:BinDir) from the user PATH'")

    $lines.Add('')
    $lines.Add('if ($PurgeData) {')
    $lines.Add('    Write-Host ''This deletes wallet seeds and cannot be undone.''')
    $lines.Add('    $c = Read-Host ''Type DELETE to confirm''')
    $lines.Add('    if ($c -eq ''DELETE'') {')
    # Chain data lives in %USERPROFILE%\.epic\<shortname>, and the shortnames are not the network
    # names: epic-server/core/src/global.rs:131 maps Mainnet to main, Floonet to floo, UserTesting
    # to user and AutomatedTesting to auto. Naming them floonet and usernet left every non-mainnet
    # chain and its wallets in place after a purge.
    $lines.Add("        foreach (`$d in @('main','floo','user','auto')) {")
    $lines.Add('            Remove-Item -LiteralPath (Join-Path $env:USERPROFILE ".epic\$d") -Recurse -Force -ErrorAction SilentlyContinue')
    $lines.Add('        }')
    $lines.Add("        Remove-Item -LiteralPath '$($script:SrcDir)' -Recurse -Force -ErrorAction SilentlyContinue")
    $lines.Add('        Write-Host ''removed chain data, wallets and sources''')
    $lines.Add('    } else { Write-Host ''left your data alone'' }')
    $lines.Add('} else {')
    $lines.Add("    Write-Host 'left chain data and wallets under `$env:USERPROFILE\.epic alone, and sources at $($script:SrcDir)'")
    $lines.Add('    Write-Host ''pass -PurgeData to remove those too''')
    $lines.Add('}')
    $lines.Add('')
    $lines.Add('Write-Host ''done. Open a new terminal so the PATH change takes effect.''')

    $path = Join-Path $script:MetaDir 'uninstall.ps1'

    # Out-File writes a BOM on PowerShell 5.1, which breaks some tooling, so write the bytes.
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllLines($path, $lines, $utf8NoBom)

    Write-Info "wrote $path"
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

# Warn when a different binary of the same name will win on PATH.
#
# Verification runs the installed binary by full path, so it reports success for something the user
# may never reach: an older epic.exe from an earlier download still answers to `epic`. Checked
# against the PATH the user's shell will have, not the one this run prepended to.
function Write-ShadowWarning([string]$Name) {
    $first = $null
    foreach ($dir in ($script:OrigPath -split ';')) {
        if (-not $dir) { continue }
        if (Test-FileAt $dir $Name) {
            $first = [System.IO.Path]::Combine($dir, $Name)
            break
        }
    }
    if (-not $first) { return }
    if ($first -eq (Join-Path $script:BinDir $Name)) { return }

    $other = $null
    try { $other = (& $first --version 2>$null | Select-Object -First 1) } catch { $other = $null }
    Write-Warn @"
$Name on your PATH is $first$(if ($other) { " ($other)" }), not the one just installed.
        That one wins, because its directory comes first. Remove it, or put $($script:BinDir)
        earlier in PATH, or call it by its full path.
"@
}

# An install is not finished because the copy succeeded. Run each binary and show its version.
function Test-Install {
    $failed = @()
    foreach ($name in Get-SelectedComponents) {
        $exe = if ($name -eq 'miner') {
            Join-Path $script:BinDir 'epic-miner.cmd'
        } else {
            Join-Path $script:BinDir $Sources[$name].Bin
        }

        try {
            $version = (& $exe --version 2>&1 | Select-Object -First 1)
            if ($LASTEXITCODE -ne 0) { throw 'nonzero exit' }
            Write-Ok $version
        } catch {
            $failed += $name
        }
    }

    if ($failed.Count -gt 0) {
        Stop-WithError @"
installed but could not run: $($failed -join ', ')
        Run the binary directly to see the loader or DLL error.
"@
    }

    foreach ($name in Get-SelectedComponents) {
        $leaf = if ($name -eq 'miner') { 'epic-miner.cmd' } else { $Sources[$name].Bin }
        Write-ShadowWarning $leaf
    }
}

function Show-NextSteps {
    Write-Plain ''
    Write-Info "installed to $($script:BinDir)"

    if ($script:PathNeedsReload) {
        Write-Plain ''
        Write-Plain 'Open a new terminal so the PATH change takes effect.'
    }
    if ($script:PathNeedsAction) {
        Write-Plain ''
        Write-Plain 'PATH was left alone as requested. Add it yourself:'
        Write-Plain "    `$env:PATH = '$($script:BinDir);' + `$env:PATH"
    }
    if ($script:RustWasInstalled) {
        Write-Plain ''
        Write-Plain 'rustup was installed. A new terminal will have cargo on PATH.'
    }

    Write-Plain ''
    if (Test-WantNode) {
        Write-Plain 'Node:   epic server config     writes epic-server.toml in the current directory'
        Write-Plain '        epic server run        starts syncing mainnet'
        if ($script:FastSyncStatus -eq 'ok') {
            Write-Plain "        The snapshot is in $(Join-Path $script:EpicMainHome 'chain_data'), which is where the"
            Write-Plain '        node looks by default. Running the node from a directory that has its own'
            Write-Plain "        epic-server.toml uses that config's db_root instead, and ignores it."
        } elseif ($script:FastSyncStatus -eq 'failed') {
            Write-Plain '        The snapshot could not be fetched, so the first run validates from'
            Write-Plain '        genesis and will take hours. That is normal and safe. Manual'
            Write-Plain '        bootstrap instructions were printed above.'
        }
    }
    if (Test-WantWallet) {
        Write-Plain 'Wallet: epic-wallet init       creates a wallet and prints a seed phrase.'
        Write-Plain '                               Write the seed down offline. It is the only backup.'
    }
    if (Test-WantMiner) {
        Write-Plain 'Miner:  epic-miner             runs against a node''s Stratum server on 3416.'
        Write-Plain "                               Config: $($script:MinerHome)\epic-miner.toml"
    }
    Write-Plain ''
    Write-Plain 'Docs:      https://devdocs.epiccash.com'
    Write-Plain "Uninstall: powershell -ExecutionPolicy Bypass -File `"$(Join-Path $script:MetaDir 'uninstall.ps1')`""
}

function Show-Plan {
    Write-Plain ''
    Write-Host '  Epic Cash' -NoNewline -ForegroundColor White
    Write-Host " source installer $InstallerVersion" -ForegroundColor DarkGray
    Write-Plain ''
    Write-Plain "  platform    windows $($script:HostArch)"
    Write-Plain "  building    $((Get-SelectedComponents) -join ' ')"
    foreach ($name in Get-SelectedComponents) {
        Write-Plain ("  {0,-12}{1} at {2}" -f $name, $Sources[$name].Repo, $Sources[$name].Ref)
    }
    if (Test-WantMiner) {
        Write-Plain '              the miner is a fork, because upstream does not compile on a current'
        Write-Plain "              toolchain. Upstream is $($Sources.miner.Upstream)"
    }
    if ($script:WithTor) { Write-Plain '  features    with-tor' }
    Write-Plain "  sources     $($script:SrcDir)"
    Write-Plain "  binaries    $($script:BinDir)"
    if (Test-WantMiner) { Write-Plain "  miner data  $($script:MinerHome)" }
    if ($script:FastSync) {
        Write-Plain "  fast sync   $($script:BootstrapUrl)"
        Write-Plain "              unpacked into $(Join-Path $script:EpicMainHome 'chain_data') after the build"
    }
    Write-Plain ''
    Write-Plain '  Compiling from source takes 10 to 30 minutes per component. No prebuilt binary is'
    Write-Plain '  downloaded, and nothing is installed outside your user profile.'
    Write-Plain ''
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

function Invoke-Main {
    $script:PathNeedsReload = $false
    $script:PathNeedsAction = $false
    $script:RustWasInstalled = $false
    $script:LibClangPath = $null
    $script:PerlPath = $null
    $script:CmakeNeedsPatch = $false
    $script:ChainBackup = $null
    $script:FastSyncStatus = 'not requested'

    Initialize-Style
    # Captured before Add-ToUserPath prepends, so the shadowing check asks what the user's own
    # shell would resolve rather than what this run arranged.
    $script:OrigPath = $env:PATH
    Assert-PowerShellVersion
    Resolve-Settings
    $script:HostArch = Get-HostArchitecture

    # Counted up front so the step numbers mean something. Four fixed steps, being the toolchain
    # check, Rust, the install and the verify, then one per component, plus the snapshot when it
    # was asked for.
    $script:StepTotal = 4 + @(Get-SelectedComponents).Count
    if ($script:FastSync) { $script:StepTotal++ }

    Show-Plan

    Write-Step 'Checking the toolchain'
    Invoke-Preflight

    if ($script:Check) {
        Write-Plain ''
        Write-Ok 'check complete, nothing was changed. Drop -Check to install.'
        Write-Plain ''
        return
    }

    Write-Plain ''
    if (-not (Confirm-Action 'Build and install the above?')) {
        Write-Info 'cancelled, nothing was changed'
        return
    }

    Write-Step 'Rust toolchain'
    Install-RustIfMissing

    foreach ($dir in @($script:SrcDir, $script:BinDir, $script:MetaDir, $script:LogDir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $script:Receipt = Join-Path $script:MetaDir 'receipt.txt'
    Set-Content -LiteralPath $script:Receipt -Value @() -Encoding ascii

    foreach ($name in Get-SelectedComponents) {
        Write-Step ([cultureinfo]::InvariantCulture.TextInfo.ToTitleCase($name))
        Build-Component -Name $name
    }

    Write-Step 'Installing'
    foreach ($name in Get-SelectedComponents) {
        if ($name -eq 'miner') { Install-Miner } else { Install-ComponentBinary -Name $name }
    }

    Add-ToUserPath -Directory $script:BinDir
    Write-Uninstaller

    Write-Step 'Verifying'
    Test-Install

    # After verification, so a failed build or a broken binary is reported before committing to a
    # multi-gigabyte download.
    if ($script:FastSync) {
        Write-Step 'Chain snapshot'
        Invoke-FastSync
    }

    Show-NextSteps
}

Invoke-Main
