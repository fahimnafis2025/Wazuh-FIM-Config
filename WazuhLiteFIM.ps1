# ==========================================
#   WAZUH AGENT "ONE-CLICK" SETUP
# ==========================================

# 1. AUTO-ELEVATE TO ADMIN (If not already run as Admin)
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    Exit
}

Clear-Host
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "      WAZUH AGENT CONFIGURATOR" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# 2. LOCATE OSSEC.CONF
$defaultPath = "C:\Program Files (x86)\ossec-agent\ossec.conf"
$confPath = Read-Host "Enter path to ossec.conf (Press Enter for default)"
if ([string]::IsNullOrWhiteSpace($confPath)) { $confPath = $defaultPath }

if (-not (Test-Path $confPath)) {
    Write-Error "File not found at: $confPath"
    Pause
    Exit
}

# Read content
$content = Get-Content $confPath -Raw

# 3. UPDATE WAZUH MANAGER IP
Write-Host "`n--- SERVER CONNECTION ---" -ForegroundColor Yellow
$currentIP = "Unknown"
if ($content -match "<address>(.*?)</address>") {
    $currentIP = $matches[1]
}
Write-Host "Current Manager IP: $currentIP"
$newIP = Read-Host "Enter NEW Manager IP (Press Enter to keep current)"

if (-not [string]::IsNullOrWhiteSpace($newIP)) {
    # Regex to find <address> inside <client> block more safely
    $content = $content -replace "(<client>[\s\S]*?<address>)(.*?)(</address>)", "${1}$newIP${3}"
    Write-Host "IP Address updated to: $newIP" -ForegroundColor Green
}

# 4. CUSTOMIZE FOLDERS
Write-Host "`n--- FOLDER MONITORING ---" -ForegroundColor Yellow
Write-Host "We will add the default 'Hacker Traps' (Startup, Tasks, HOSTS)."
$userIncludes = Read-Host "Add EXTRA folders to monitor? (comma separated, e.g. D:\Data)"
$userExcludes = Read-Host "Add EXTRA folders to IGNORE? (comma separated)"

# 5. BUILD THE NEW SYSCHECK BLOCK
$newSyscheckBlock = @"
  <syscheck>
    <disabled>no</disabled>
    <frequency>43200</frequency>

    <directories check_all="yes" realtime="yes">C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup</directories>
    <directories check_all="yes" realtime="yes">C:\Users\*\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup</directories>
    <directories check_all="yes" realtime="yes">C:\Windows\System32\Tasks</directories>
    <directories check_all="yes" realtime="yes">C:\Windows\System32\drivers\etc</directories>

"@

# Add User Inclusions
if (-not [string]::IsNullOrWhiteSpace($userIncludes)) {
    $folders = $userIncludes -split ","
    foreach ($f in $folders) {
        $f = $f.Trim()
        $newSyscheckBlock += "`n    <directories check_all=`"yes`" realtime=`"yes`">$f</directories>"
    }
}

$newSyscheckBlock += @"

    <directories recursion_level="0" restrict="regedit.exe$|system.ini$|win.ini$">%WINDIR%</directories>
    <directories recursion_level="0" restrict="at.exe$|attrib.exe$|cacls.exe$|cmd.exe$|eventcreate.exe$|ftp.exe$|lsass.exe$|net.exe$|net1.exe$|netsh.exe$|reg.exe$|regedt32.exe|regsvr32.exe|runas.exe|sc.exe|schtasks.exe|sethc.exe|subst.exe$">%WINDIR%\SysNative</directories>
    <directories recursion_level="0">%WINDIR%\SysNative\drivers\etc</directories>
    <directories recursion_level="0" restrict="WMIC.exe$">%WINDIR%\SysNative\wbem</directories>
    <directories recursion_level="0" restrict="powershell.exe$">%WINDIR%\SysNative\WindowsPowerShell\v1.0</directories>
    
    <ignore type="sregex">.log$|.tmp$|.png$|.jpg$</ignore>
    <ignore>C:\Windows\Temp</ignore>
    <ignore>C:\Users\*\AppData\Local\Google\Chrome\User Data</ignore>
    <ignore>C:\Users\*\AppData\Local\Microsoft\Edge\User Data</ignore>
"@

# Add User Exclusions
if (-not [string]::IsNullOrWhiteSpace($userExcludes)) {
    $folders = $userExcludes -split ","
    foreach ($f in $folders) {
        $f = $f.Trim()
        $newSyscheckBlock += "`n    <ignore>$f</ignore>"
    }
}

$newSyscheckBlock += @"
    <windows_registry>HKEY_LOCAL_MACHINE\Software\Classes\batfile</windows_registry>
    <windows_registry>HKEY_LOCAL_MACHINE\Software\Classes\cmdfile</windows_registry>
    <windows_registry>HKEY_LOCAL_MACHINE\Software\Classes\comfile</windows_registry>
    <windows_registry>HKEY_LOCAL_MACHINE\Software\Classes\exefile</windows_registry>
  </syscheck>
"@

# 6. SWAP THE CODE
Write-Host "`nBacking up ossec.conf..."
Copy-Item $confPath "$confPath.bak" -Force

# Replace old syscheck block using Regex (Deletes the old one entirely)
$pattern = "(?s)<syscheck>.*?</syscheck>"
if ($content -match $pattern) {
    Write-Host "Found existing configuration. Replacing..." -ForegroundColor Green
    $content = $content -replace $pattern, $newSyscheckBlock
} else {
    Write-Warning "Could not find <syscheck> block! Appending to end."
    $content = $content + "`n" + $newSyscheckBlock
}

Set-Content $confPath $content

# 7. RESTART SERVICE
Write-Host "`nRestarting Wazuh Service..." -ForegroundColor Cyan
try {
    Restart-Service -Name WazuhSvc -ErrorAction Stop
    Start-Sleep -Seconds 3
    $svc = Get-Service WazuhSvc
    if ($svc.Status -eq "Running") {
        Write-Host "SUCCESS: Agent is CONNECTED to $newIP and MONITORING." -ForegroundColor Green
    } else {
        Write-Error "FAILURE: Service stopped. Check config."
    }
} catch {
    Write-Error "CRITICAL: Could not restart service. $_"
}

Write-Host "`nPress any key to close..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")