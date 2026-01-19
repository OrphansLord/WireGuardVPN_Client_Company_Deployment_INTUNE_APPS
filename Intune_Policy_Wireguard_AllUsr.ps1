<# 
    – WireGuard .conf installer (Intune)
    - Match *.conf named as name_surname.conf with device primary user
    - New profile policy: C:\Users\NAMESURNAME (uppercase, no underscore)
    - Copies .conf to WG config dir and installs tunnel as service
    - Logs to C:\ProgramData\COMPANY\WG\Logs\
#>

#region Config
$ConfSearchRoots = @(
    "C:\Users\*\Downloads",
    "C:\ProgramData\COMPANY\WG\Staging"
)
$WireGuardExe       = "C:\Program Files\WireGuard\wireguard.exe"
$WgConfigDestFolder = "C:\Program Files\WireGuard\Data\Configurations"
$LogDir             = "C:\ProgramData\COMPANY\WG\Logs"
New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
$LogFile = Join-Path $LogDir ("wg_deploy_{0}.csv" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
"Timestamp,ComputerName,PrimaryUserTag,SelectedConf,Result,Message" | Out-File -FilePath $LogFile -Encoding UTF8
#endregion

function Write-LogRow {
    param(
        [string]$PrimaryUserTag,
        [string]$SelectedConf,
        [string]$Result,
        [string]$Message
    )
    $row = '{0},{1},{2},{3},{4},"{5}"' -f (Get-Date -Format "s"), $env:COMPUTERNAME, $PrimaryUserTag, $SelectedConf, $Result, ($Message -replace '"','''')
    Add-Content -Path $LogFile -Value $row
}

function Test-AADJoined {
    try {
        $status = (dsregcmd /status) 2>$null
        return ($status -match "AzureAdJoined\s*:\s*YES")
    } catch { return $false }
}

function Get-PrimaryUserTag {
    # 1) Actual User/ Last logon
    $user = $null
    try {
        $user = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).UserName
    } catch {}

    if (-not $user) {
        # Last logon since register (fallback)
        try {
            $sid = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI' -ErrorAction Stop).LastLoggedOnUserSID
            if ($sid) {
                $profilePath = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -ErrorAction Stop).ProfileImagePath
                $leaf = Split-Path $profilePath -Leaf
                $user = "AzureAD\$leaf"
            }
        } catch {}
    }

    if (-not $user) { return $null }

    # Tag for the .conf: name_surname (lowkey, '_' by .-spaces)
    $leaf = $user.Split('\')[-1]
    $tagUnderscore = $leaf.ToLower() -replace '[\.\s-]','_'
    return $tagUnderscore
}

function Resolve-UserProfileFolder {
    param([string]$UserTagUnderscore)

    # New Policy: folder of profile = NAMESURNAME (without '_', in Uppercase)
    $flatUpper = ($UserTagUnderscore -replace '_','').ToUpper()  

    $usersRoot = 'C:\Users'
    $profileDir = Get-ChildItem $usersRoot -Directory -ErrorAction SilentlyContinue | Where-Object {
        (($_.Name).ToUpper() -eq $flatUpper) -or
        ((($_.Name -replace '_','').ToUpper()) -eq $flatUpper)
    } | Select-Object -First 1

    return $profileDir
}

function Find-ConfForUserTag {
    param([string]$UserTagUnderscore, [string[]]$SearchRoots)

    # Try 1: Downloads from resolved profile
    $profileDir = Resolve-UserProfileFolder -UserTagUnderscore $UserTagUnderscore
    if ($profileDir) {
        $candidate = Join-Path $profileDir.FullName ("Downloads\{0}.conf" -f $UserTagUnderscore)
        if (Test-Path $candidate) { return $candidate }
    }

    # Try 2: Global path (corporate staging / other downloads)
    $files = @()
    foreach ($root in $SearchRoots) {
        try {
            $files += Get-ChildItem -Path $root -Filter *.conf -Recurse -ErrorAction SilentlyContinue
        } catch {}
    }
    if ($files) {
        foreach ($f in $files) {
            $base = ($f.BaseName).ToLower() -replace '[\.\s-]','_'
            if ($base -eq $UserTagUnderscore) { return $f.FullName }
        }
    }
    return $null
}

try {
    # --- Pre-checks ---
    if ($env:COMPUTERNAME -notmatch '^COMPANY-') {
        Write-LogRow -PrimaryUserTag "" -SelectedConf "" -Result "Skipped" -Message "Hostname does not match COMPANY-*"
        exit 0
    }
    if (-not (Test-AADJoined)) {
        Write-LogRow -PrimaryUserTag "" -SelectedConf "" -Result "Skipped" -Message "Device not AzureAD joined"
        exit 0
    }
    if (-not (Test-Path $WireGuardExe)) {
        Write-LogRow -PrimaryUserTag "" -SelectedConf "" -Result "Failed" -Message "WireGuard not installed at $WireGuardExe"
        exit 1
    }
    New-Item -Path $WgConfigDestFolder -ItemType Directory -Force | Out-Null

    # --- Solve user and .conf ---
    $primaryUserTag = Get-PrimaryUserTag
    if (-not $primaryUserTag) {
        Write-LogRow -PrimaryUserTag "" -SelectedConf "" -Result "Failed" -Message "Cannot resolve primary user tag"
        exit 1
    }

    $confPath = Find-ConfForUserTag -UserTagUnderscore $primaryUserTag -SearchRoots $ConfSearchRoots
    if (-not $confPath) {
        Write-LogRow -PrimaryUserTag $primaryUserTag -SelectedConf "" -Result "Failed" -Message "No matching .conf found for user tag"
        exit 1
    }

    # --- Copy and install service ---
    $confName = Split-Path $confPath -Leaf
    $destPath = Join-Path $WgConfigDestFolder $confName
    Copy-Item -Path $confPath -Destination $destPath -Force

    # (Re)install as tunnel service
    # If it already exists, we reinstall it to refresh config
    $svcName = "WireGuardTunnel$([IO.Path]::GetFileNameWithoutExtension($confName))"
    $existing = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if ($existing) {
        try { & $WireGuardExe /uninstalltunnelservice ([IO.Path]::GetFileNameWithoutExtension($confName)) | Out-Null } catch {}
        Start-Sleep -Seconds 1
    }

    $p = Start-Process -FilePath $WireGuardExe -ArgumentList ("/installtunnelservice {0}" -f $confName) -Wait -PassThru
    if ($p.ExitCode -ne 0) {
        throw "wireguard.exe exited with code $($p.ExitCode)"
    }

    Start-Sleep -Seconds 2
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if ($null -eq $svc) { throw "Service $svcName not found after install." }
    if ($svc.Status -ne 'Running') { Start-Service $svcName -ErrorAction SilentlyContinue }

    Write-LogRow -PrimaryUserTag $primaryUserTag -SelectedConf $confPath -Result "Success" -Message "Copied to $destPath and installed as service $svcName"
    exit 0
}
catch {
    Write-LogRow -PrimaryUserTag $primaryUserTag -SelectedConf $confPath -Result "Failed" -Message $_.Exception.Message
    exit 1
}
