<#

.SYNOPSIS
PSAppDeployToolkit - This script performs the installation or uninstallation of an application(s).

.DESCRIPTION
- Downloads NVM for Windows v1.2.2 installer from the GitHub releases CDN.
- Installs NVM silently to C:\ProgramData\nvm (system-wide, all users).
- Sets the Node.js symlink directory to C:\ProgramData\nodejs.
- Sets NVM_HOME and NVM_SYMLINK as SYSTEM environment variables.
- Appends %NVM_HOME% and %NVM_SYMLINK% to the system PATH.
- Installs Node.js 20 LTS via nvm install 20 and activates it via nvm use 20.
- Mirrors NVM_HOME and NVM_SYMLINK as user environment variables for all profiles.
- Appends %NVM_HOME% and %NVM_SYMLINK% to the user PATH for all profiles.
- Registers a logon scheduled task to broadcast WM_SETTINGCHANGE to running processes.
- Designed for Intune Win32 app deployment (runs as SYSTEM context).
- Compatible with PSADT v4.1.7 and v4.1.8+
- NOTE: This build has no pre-install Node.js conflict removal (test build).

.PARAMETER DeploymentType
The type of deployment to perform.

.PARAMETER DeployMode
Specifies whether the installation should be run in Interactive, Silent, NonInteractive, or Auto mode.

.PARAMETER SuppressRebootPassThru
Suppresses the 3010 return code from being passed back to the parent process.

.PARAMETER TerminalServerMode
Changes to user install mode for Remote Desktop Session Hosts/Citrix servers.

.PARAMETER DisableLogging
Disables logging to file for the script.

.EXAMPLE
powershell.exe -File Invoke-AppDeployToolkit.ps1

.EXAMPLE
powershell.exe -File Invoke-AppDeployToolkit.ps1 -DeployMode Silent

.EXAMPLE
powershell.exe -File Invoke-AppDeployToolkit.ps1 -DeploymentType Uninstall

.EXAMPLE
Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent

.INPUTS
None. You cannot pipe objects to this script.

.OUTPUTS
None. This script does not generate any output.

.NOTES
Toolkit Exit Code Ranges:
- 60000 - 68999: Reserved for built-in exit codes in Invoke-AppDeployToolkit.ps1
- 69000 - 69999: Recommended for user customized exit codes in Invoke-AppDeployToolkit.ps1
- 70000 - 79999: Recommended for user customized exit codes in PSAppDeployToolkit.Extensions module.

Build: 1.3.0-test (no pre-install Node.js conflict removal)
Use 1.2.0 for production deployments where winget Node.js may be present.

.LINK
https://github.com/coreybutler/nvm-windows
https://psappdeploytoolkit.com

#>

[CmdletBinding()]
param
(
    [Parameter(Mandatory = $false)]
    [ValidateSet('Install', 'Uninstall', 'Repair')]
    [System.String]$DeploymentType,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Auto', 'Interactive', 'NonInteractive', 'Silent')]
    [System.String]$DeployMode = 'Silent',

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.SwitchParameter]$SuppressRebootPassThru,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.SwitchParameter]$TerminalServerMode,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.SwitchParameter]$DisableLogging
)


##================================================
## MARK: Variables
##================================================

$adtSession = @{
    AppVendor            = 'Corey Butler'
    AppName              = 'NVM for Windows'
    AppVersion           = '1.2.2'
    AppArch              = 'x64'
    AppLang              = 'EN'
    AppRevision          = '01'
    AppSuccessExitCodes  = @(0)
    AppRebootExitCodes   = @(1641, 3010)
    AppProcessesToClose  = @()
    AppScriptVersion     = '1.3.0-test'
    AppScriptDate        = '03/13/2026'
    AppScriptAuthor      = 'amasterson-adm'
    RequireAdmin         = $true
    InstallName          = ''
    InstallTitle         = ''
    DeployAppScriptFriendlyName = $MyInvocation.MyCommand.Name
    DeployAppScriptParameters   = $PSBoundParameters
    DeployAppScriptVersion      = '4.1.7'
}


##================================================
## MARK: Package-level constants
## Update NvmVersion only when upgrading NVM for Windows.
## NodeVersion controls which Node.js LTS is installed via nvm.
##================================================

# NVM for Windows version - update here only when upgrading
$Script:NvmVersion       = '1.2.2'

# Node.js major version to install via nvm (LTS channel)
$Script:NodeVersion      = '20'

# Download URL - GitHub releases CDN
$Script:NvmDownloadUrl   = "https://github.com/coreybutler/nvm-windows/releases/download/$Script:NvmVersion/nvm-setup.exe"

# Staging path for the downloaded installer (cleaned up post-install)
$Script:NvmStagingDir    = 'C:\Temp\NvmStaging'
$Script:NvmInstallerPath = "$Script:NvmStagingDir\nvm-setup.exe"

# NVM installation directory - system-wide under ProgramData (all users)
$Script:NvmHome          = 'C:\ProgramData\nvm'

# Node.js symlink directory - where the active Node.js version is linked
$Script:NvmSymlink       = 'C:\ProgramData\nodejs'

# NVM executable path post-install
$Script:NvmExe           = "$Script:NvmHome\nvm.exe"

# Drop location for WM_SETTINGCHANGE broadcast helper script
$Script:NvmHelperDir     = 'C:\ProgramData\NvmWindows'
$Script:NvmHelperScript  = 'C:\ProgramData\NvmWindows\Invoke-RefreshNvmEnv.ps1'

# Scheduled task name
$Script:RefreshTaskName  = 'NvmWindows-RefreshEnvVars'

# NVM Inno Setup uninstaller path
$Script:NvmUninstaller   = "$Script:NvmHome\unins000.exe"

# Master Wrapper detection key
$Script:DetectionKey     = 'HKLM\SOFTWARE\InstalledApps\Corey Butler_NVM for Windows_1.2.2'


##================================================
## MARK: Helper - Read user PATH directly from HKU hive
## Version-agnostic registry read - avoids Get-ADTRegistryKey
## parameter differences between PSADT v4.1.7 and v4.1.8.
##================================================

function Get-UserPathFromHku
{
    [CmdletBinding()]
    [OutputType([System.String])]
    param
    (
        [Parameter(Mandatory = $true)]
        [System.String]$Sid
    )

    try
    {
        $regPath = "Registry::HKEY_USERS\$Sid\Environment"
        if (Test-Path -LiteralPath $regPath)
        {
            $val = (Get-ItemProperty -LiteralPath $regPath -Name 'Path' -ErrorAction SilentlyContinue).Path
            return if ($val) { $val } else { '' }
        }
    }
    catch { }
    return ''
}


##================================================
## MARK: Helper - Write user PATH directly to HKU hive
## Writes as REG_EXPAND_SZ so %NVM_HOME% and %NVM_SYMLINK%
## resolve dynamically at user session start.
##================================================

function Set-UserPathInHku
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [System.String]$Sid,

        [Parameter(Mandatory = $true)]
        [System.String]$PathValue
    )

    $regPath = "Registry::HKEY_USERS\$Sid\Environment"

    if (-not (Test-Path -LiteralPath $regPath))
    {
        New-Item -Path $regPath -Force -ErrorAction SilentlyContinue | Out-Null
    }

    Set-ItemProperty -LiteralPath $regPath -Name 'Path' -Value $PathValue -Type ExpandString -ErrorAction Stop
}


##================================================
## MARK: Helper - Download NVM installer
## BITS preferred, Invoke-WebRequest fallback.
## Size check guards against CDN returning an HTML error page.
##================================================

function Get-NvmInstaller
{
    [CmdletBinding()]
    param ()

    Write-ADTLogEntry -Message "Downloading NVM for Windows v$Script:NvmVersion from [$Script:NvmDownloadUrl]..."

    New-Item -Path 'C:\Temp'             -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    New-Item -Path $Script:NvmStagingDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null

    if (Test-Path -LiteralPath $Script:NvmInstallerPath)
    {
        Remove-Item -LiteralPath $Script:NvmInstallerPath -Force -ErrorAction SilentlyContinue
    }

    $downloaded = $false

    # Attempt 1 - BITS (bandwidth-aware, resumable, enterprise-preferred)
    try
    {
        Import-Module BitsTransfer -ErrorAction Stop
        Start-BitsTransfer -Source $Script:NvmDownloadUrl -Destination $Script:NvmInstallerPath -ErrorAction Stop
        $downloaded = $true
        Write-ADTLogEntry -Message 'Download completed via BITS.'
    }
    catch
    {
        Write-ADTLogEntry -Message "BITS download failed, falling back to Invoke-WebRequest - $_" -Severity 2
    }

    # Attempt 2 - Invoke-WebRequest
    if (-not $downloaded)
    {
        try
        {
            $iwrParams = @{
                Uri             = $Script:NvmDownloadUrl
                OutFile         = $Script:NvmInstallerPath
                UseBasicParsing = $true
                TimeoutSec      = 300
                ErrorAction     = 'Stop'
            }
            Invoke-WebRequest @iwrParams
            $downloaded = $true
            Write-ADTLogEntry -Message 'Download completed via Invoke-WebRequest.'
        }
        catch
        {
            throw "Both BITS and Invoke-WebRequest failed to download NVM installer. Last error: $_"
        }
    }

    if (-not (Test-Path -LiteralPath $Script:NvmInstallerPath))
    {
        throw "Download appeared to succeed but installer was not found at [$Script:NvmInstallerPath]."
    }

    $fileSize = (Get-Item -LiteralPath $Script:NvmInstallerPath).Length
    if ($fileSize -lt 3MB)
    {
        throw "Downloaded file is suspiciously small ($fileSize bytes). The download may have failed or the GitHub release URL may have changed."
    }

    Write-ADTLogEntry -Message "NVM installer downloaded successfully. File size: $([math]::Round($fileSize / 1MB, 2)) MB"
}


##================================================
## MARK: Helper - Install NVM silently
## Inno Setup silent switches. /DIR and /NVMDIR set controlled
## enterprise paths under C:\ProgramData (system-wide, all users).
##================================================

function Install-NvmSilent
{
    [CmdletBinding()]
    param ()

    Write-ADTLogEntry -Message "Installing NVM for Windows silently to [$Script:NvmHome] with Node symlink at [$Script:NvmSymlink]..."

    $processParams = @{
        FilePath     = $Script:NvmInstallerPath
        ArgumentList = "/SP- /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /DIR=`"$Script:NvmHome`" /NVMDIR=`"$Script:NvmSymlink`""
        WindowStyle  = 'Hidden'
        Wait         = $true
        PassThru     = $true
    }

    $result = Start-Process @processParams
    Write-ADTLogEntry -Message "NVM installer exited with code: $($result.ExitCode)"

    if ($result.ExitCode -notin @(0))
    {
        throw "NVM installer returned unexpected exit code [$($result.ExitCode)]."
    }

    if (-not (Test-Path -LiteralPath $Script:NvmExe))
    {
        throw "Post-install validation failed: nvm.exe not found at [$Script:NvmExe]."
    }

    Write-ADTLogEntry -Message "NVM for Windows installed successfully. nvm.exe confirmed at [$Script:NvmExe]."
}


##================================================
## MARK: Helper - Set NVM system environment variables
## NVM_HOME and NVM_SYMLINK set at Machine scope via .NET.
## Both appended to system PATH using expandable %VAR% references.
## Must run BEFORE Install-NodeLts so nvm.exe resolves settings.txt.
##================================================

function Set-NvmSystemEnvironment
{
    [CmdletBinding()]
    param ()

    Write-ADTLogEntry -Message 'Setting NVM_HOME and NVM_SYMLINK as SYSTEM environment variables...'

    [System.Environment]::SetEnvironmentVariable('NVM_HOME',    $Script:NvmHome,    [System.EnvironmentVariableTarget]::Machine)
    [System.Environment]::SetEnvironmentVariable('NVM_SYMLINK', $Script:NvmSymlink, [System.EnvironmentVariableTarget]::Machine)
    Write-ADTLogEntry -Message "NVM_HOME=[$Script:NvmHome] and NVM_SYMLINK=[$Script:NvmSymlink] set at Machine scope."

    $systemPath   = [System.Environment]::GetEnvironmentVariable('PATH', [System.EnvironmentVariableTarget]::Machine)
    if (-not $systemPath) { $systemPath = '' }

    $entriesToAdd = @('%NVM_HOME%', '%NVM_SYMLINK%')
    $pathChanged  = $false

    foreach ($entry in $entriesToAdd)
    {
        if ($systemPath -notlike "*$entry*")
        {
            $systemPath  = if ($systemPath -ne '' -and $systemPath -notmatch ';$') { "$systemPath;$entry" } else { "$systemPath$entry" }
            $pathChanged = $true
            Write-ADTLogEntry -Message "Appended [$entry] to system PATH."
        }
        else
        {
            Write-ADTLogEntry -Message "[$entry] already present in system PATH - skipping."
        }
    }

    if ($pathChanged)
    {
        [System.Environment]::SetEnvironmentVariable('PATH', $systemPath, [System.EnvironmentVariableTarget]::Machine)
        Write-ADTLogEntry -Message 'System PATH updated.'
    }
}


##================================================
## MARK: Helper - Install Node.js 20 LTS via NVM
## Injects NVM_HOME into the current SYSTEM process environment so
## nvm.exe can locate settings.txt, then runs nvm install 20 and
## nvm use 20. Non-fatal - NVM is still deployed and detected even
## if the Node.js download fails (e.g. no internet at deploy time).
##================================================

function Install-NodeLts
{
    [CmdletBinding()]
    param ()

    Write-ADTLogEntry -Message "Installing Node.js $Script:NodeVersion LTS via NVM..."

    $env:NVM_HOME    = $Script:NvmHome
    $env:NVM_SYMLINK = $Script:NvmSymlink
    if ($env:PATH -notlike "*$Script:NvmHome*")
    {
        $env:PATH = "$Script:NvmHome;$Script:NvmSymlink;$env:PATH"
    }

    Write-ADTLogEntry -Message "Running: nvm install $Script:NodeVersion"
    $installResult = Start-Process -FilePath $Script:NvmExe -ArgumentList "install $Script:NodeVersion" -Wait -PassThru -WindowStyle Hidden
    Write-ADTLogEntry -Message "nvm install $Script:NodeVersion exited with code: $($installResult.ExitCode)"

    if ($installResult.ExitCode -ne 0)
    {
        Write-ADTLogEntry -Message "WARNING: nvm install returned code $($installResult.ExitCode). Attempting nvm use anyway." -Severity 2
    }

    Write-ADTLogEntry -Message "Running: nvm use $Script:NodeVersion"
    $useResult = Start-Process -FilePath $Script:NvmExe -ArgumentList "use $Script:NodeVersion" -Wait -PassThru -WindowStyle Hidden
    Write-ADTLogEntry -Message "nvm use $Script:NodeVersion exited with code: $($useResult.ExitCode)"

    $nodeExe = Join-Path -Path $Script:NvmSymlink -ChildPath 'node.exe'
    if (Test-Path -LiteralPath $nodeExe)
    {
        Write-ADTLogEntry -Message "Node.js $Script:NodeVersion LTS activated. node.exe confirmed at [$nodeExe]."
    }
    else
    {
        Write-ADTLogEntry -Message "WARNING: node.exe not found at [$nodeExe] after nvm use. Check NVM logs at [$Script:NvmHome]." -Severity 2
    }
}


##================================================
## MARK: Helper - Set NVM user environment variables for all profiles
## Uses direct HKU registry reads/writes (Get-UserPathFromHku /
## Set-UserPathInHku) for PATH operations - avoids Get-ADTRegistryKey
## parameter differences between PSADT v4.1.7 and v4.1.8.
##================================================

function Set-NvmUserEnvironment
{
    [CmdletBinding()]
    param ()

    Write-ADTLogEntry -Message 'Setting NVM_HOME and NVM_SYMLINK user environment variables for all profiles...'

    Invoke-ADTAllUsersRegistryAction -ScriptBlock {

        $sid = $_.SID

        Set-ADTRegistryKey -Key 'HKCU\Environment' -Name 'NVM_HOME'    -Value 'C:\ProgramData\nvm'    -Type 'String' -SID $sid
        Set-ADTRegistryKey -Key 'HKCU\Environment' -Name 'NVM_SYMLINK' -Value 'C:\ProgramData\nodejs' -Type 'String' -SID $sid

        $currentPath  = Get-UserPathFromHku -Sid $sid
        $entriesToAdd = @('%NVM_HOME%', '%NVM_SYMLINK%')
        $newPath      = $currentPath
        $pathChanged  = $false

        foreach ($entry in $entriesToAdd)
        {
            if ($newPath -notlike "*$entry*")
            {
                $newPath     = if ($newPath -ne '' -and $newPath -notmatch ';$') { "$newPath;$entry" } else { "$newPath$entry" }
                $pathChanged = $true
            }
        }

        if ($pathChanged)
        {
            Set-UserPathInHku -Sid $sid -PathValue $newPath
            Write-ADTLogEntry -Message "User PATH updated with NVM entries for SID [$sid]."
        }
        else
        {
            Write-ADTLogEntry -Message "NVM PATH entries already present for SID [$sid] - skipping."
        }
    }

    Write-ADTLogEntry -Message 'NVM user environment variables set successfully across all user profiles.'
}


##================================================
## MARK: Helper - Remove NVM system environment variables
##================================================

function Remove-NvmSystemEnvironment
{
    [CmdletBinding()]
    param ()

    Write-ADTLogEntry -Message 'Removing NVM_HOME and NVM_SYMLINK from SYSTEM environment...'

    [System.Environment]::SetEnvironmentVariable('NVM_HOME',    $null, [System.EnvironmentVariableTarget]::Machine)
    [System.Environment]::SetEnvironmentVariable('NVM_SYMLINK', $null, [System.EnvironmentVariableTarget]::Machine)

    $systemPath = [System.Environment]::GetEnvironmentVariable('PATH', [System.EnvironmentVariableTarget]::Machine)
    if ($systemPath)
    {
        $nvmEntries  = @('%NVM_HOME%', '%NVM_SYMLINK%', $Script:NvmHome, $Script:NvmSymlink)
        $cleanedPath = ($systemPath -split ';' | Where-Object { $_.TrimEnd('\') -notin ($nvmEntries | ForEach-Object { $_.TrimEnd('\') }) }) -join ';'
        $cleanedPath = $cleanedPath.TrimEnd(';')
        [System.Environment]::SetEnvironmentVariable('PATH', $cleanedPath, [System.EnvironmentVariableTarget]::Machine)
        Write-ADTLogEntry -Message 'NVM entries removed from system PATH.'
    }
}


##================================================
## MARK: Helper - Remove NVM user environment variables from all profiles
##================================================

function Remove-NvmUserEnvironment
{
    [CmdletBinding()]
    param ()

    Write-ADTLogEntry -Message 'Removing NVM_HOME, NVM_SYMLINK and PATH entries from all user profiles...'

    Invoke-ADTAllUsersRegistryAction -ScriptBlock {

        $sid = $_.SID

        Remove-ADTRegistryKey -Key 'HKCU\Environment' -Name 'NVM_HOME'    -SID $sid
        Remove-ADTRegistryKey -Key 'HKCU\Environment' -Name 'NVM_SYMLINK' -SID $sid

        $currentPath = Get-UserPathFromHku -Sid $sid
        if ($currentPath)
        {
            $nvmEntries  = @('%NVM_HOME%', '%NVM_SYMLINK%', 'C:\ProgramData\nvm', 'C:\ProgramData\nodejs')
            $cleanedPath = ($currentPath -split ';' | Where-Object { $_.TrimEnd('\') -notin ($nvmEntries | ForEach-Object { $_.TrimEnd('\') }) }) -join ';'
            $cleanedPath = $cleanedPath.TrimEnd(';')
            if ($cleanedPath -ne $currentPath)
            {
                Set-UserPathInHku -Sid $sid -PathValue $cleanedPath
            }
        }
    }

    Write-ADTLogEntry -Message 'NVM user environment variables removed from all user profiles.'
}


##================================================
## MARK: Helper - Register WM_SETTINGCHANGE broadcast task
## Drops helper script to C:\ProgramData\NvmWindows and registers
## an AtLogOn scheduled task for BUILTIN\Users (limited/non-elevated).
## Broadcasts WM_SETTINGCHANGE so running processes see new env vars
## without a full logoff. Task self-deletes after first run.
##================================================

function Register-EnvRefreshTask
{
    [CmdletBinding()]
    param ()

    Write-ADTLogEntry -Message 'Registering NVM environment refresh scheduled task...'

    if (-not (Test-Path -LiteralPath $Script:NvmHelperDir -PathType Container))
    {
        New-Item -Path $Script:NvmHelperDir -ItemType Directory -Force | Out-Null
    }

    $helperContent = @'
# NvmWindows - Broadcast environment variable changes to running processes.
# Created by the NVM for Windows PSADT package. Self-deletes after one run.
try
{
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class EnvRefresh
{
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
        uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);

    public static void Broadcast()
    {
        UIntPtr result;
        SendMessageTimeout(new IntPtr(0xFFFF), 0x001A, UIntPtr.Zero,
            "Environment", 0x0002, 5000, out result);
    }
}
"@ -ErrorAction Stop
    [EnvRefresh]::Broadcast()
}
catch
{
    Write-EventLog -LogName Application -Source "Application" -EventId 9903 `
        -EntryType Warning -Message "NvmWindows EnvRefresh: $_" -ErrorAction SilentlyContinue
}
finally
{
    Unregister-ScheduledTask -TaskName 'NvmWindows-RefreshEnvVars' -Confirm:$false -ErrorAction SilentlyContinue
}
'@

    $helperContent | Out-File -FilePath $Script:NvmHelperScript -Encoding UTF8 -Force

    $actionParams = @{
        Execute  = 'powershell.exe'
        Argument = "-NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Script:NvmHelperScript`""
    }
    $taskAction = New-ScheduledTaskAction @actionParams

    $taskTrigger   = New-ScheduledTaskTrigger -AtLogOn
    $taskPrincipal = New-ScheduledTaskPrincipal -GroupId 'BUILTIN\Users' -RunLevel Limited
    $taskSettings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew -StartWhenAvailable

    $registerParams = @{
        TaskName    = $Script:RefreshTaskName
        Action      = $taskAction
        Trigger     = $taskTrigger
        Principal   = $taskPrincipal
        Settings    = $taskSettings
        Description = 'Broadcasts WM_SETTINGCHANGE so running processes see NVM_HOME/NVM_SYMLINK set by NVM for Windows package. Self-deletes after first execution.'
        Force       = $true
        ErrorAction = 'Stop'
    }

    Register-ScheduledTask @registerParams | Out-Null
    Write-ADTLogEntry -Message "Scheduled task [$Script:RefreshTaskName] registered successfully."
}


##================================================
## MARK: Install
##================================================

function Install-ADTDeployment
{
    [CmdletBinding()]
    param ()

    ##--------------------------------------------
    ## Pre-Install
    ## NOTE: No Node.js conflict removal in this test build.
    ## Assumes the target machine is already clean.
    ##--------------------------------------------
    $adtSession.InstallPhase = "Pre-$($adtSession.DeploymentType)"

    Write-ADTLogEntry -Message 'Pre-Install: Ensuring staging directories exist...'
    New-Item -Path 'C:\Temp'             -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    New-Item -Path $Script:NvmStagingDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null

    ##--------------------------------------------
    ## Install
    ##--------------------------------------------
    $adtSession.InstallPhase = $adtSession.DeploymentType

    # Step 1 - Download NVM installer from GitHub releases CDN
    Get-NvmInstaller

    # Step 2 - Run silent NVM install to C:\ProgramData\nvm
    Install-NvmSilent

    # Step 3 - Set NVM_HOME / NVM_SYMLINK at Machine scope + update system PATH
    #          Must run BEFORE Install-NodeLts so nvm.exe can locate settings.txt
    Set-NvmSystemEnvironment

    # Step 4 - Install Node.js 20 LTS and activate it (non-fatal if no internet)
    try
    {
        Install-NodeLts
    }
    catch
    {
        Write-ADTLogEntry -Message "WARNING: Node.js $Script:NodeVersion installation via NVM encountered an error (non-fatal) - $_" -Severity 2
        Write-ADTLogEntry -Message "NVM is installed. Run manually: nvm install $Script:NodeVersion && nvm use $Script:NodeVersion" -Severity 2
    }

    # Step 5 - Clean up staging directory
    Write-ADTLogEntry -Message 'Cleaning up NVM staging directory...'
    Remove-Item -LiteralPath $Script:NvmStagingDir -Recurse -Force -ErrorAction SilentlyContinue

    ##--------------------------------------------
    ## Post-Install
    ##--------------------------------------------
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    # Step 6 - Mirror NVM_HOME and NVM_SYMLINK into all user profile HKCU
    try
    {
        Set-NvmUserEnvironment
    }
    catch
    {
        Write-ADTLogEntry -Message "ERROR: Failed to set NVM user environment variables - $_" -Severity 3
        throw
    }

    # Step 7 - Register logon task to broadcast env change to running processes
    try
    {
        Register-EnvRefreshTask
    }
    catch
    {
        Write-ADTLogEntry -Message "WARNING: Could not register environment refresh scheduled task (non-fatal) - $_" -Severity 2
    }

    # Step 8 - Master Wrapper detection key
    Set-ADTRegistryKey -Key $Script:DetectionKey
}


##================================================
## MARK: Uninstall
##================================================

function Uninstall-ADTDeployment
{
    [CmdletBinding()]
    param ()

    ##--------------------------------------------
    ## Pre-Uninstall
    ##--------------------------------------------
    $adtSession.InstallPhase = "Pre-$($adtSession.DeploymentType)"

    Write-ADTLogEntry -Message "Removing scheduled task [$Script:RefreshTaskName] if present..."
    Unregister-ScheduledTask -TaskName $Script:RefreshTaskName -Confirm:$false -ErrorAction SilentlyContinue

    ##--------------------------------------------
    ## Uninstall
    ##--------------------------------------------
    $adtSession.InstallPhase = $adtSession.DeploymentType

    if (Test-Path -LiteralPath $Script:NvmUninstaller)
    {
        Write-ADTLogEntry -Message "Running NVM uninstaller at [$Script:NvmUninstaller]..."
        $uninstallResult = Start-Process -FilePath $Script:NvmUninstaller -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' -Wait -PassThru -WindowStyle Hidden
        Write-ADTLogEntry -Message "NVM uninstaller exited with code: $($uninstallResult.ExitCode)"
    }
    else
    {
        Write-ADTLogEntry -Message "NVM uninstaller not found at [$Script:NvmUninstaller] - may have already been removed." -Severity 2
    }

    foreach ($path in @($Script:NvmHome, $Script:NvmSymlink))
    {
        if (Test-Path -LiteralPath $path)
        {
            Write-ADTLogEntry -Message "Removing residual directory [$path]..."
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    ##--------------------------------------------
    ## Post-Uninstall
    ##--------------------------------------------
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    try { Remove-NvmSystemEnvironment } catch { Write-ADTLogEntry -Message "WARNING: Error removing NVM system env vars (non-fatal) - $_" -Severity 2 }
    try { Remove-NvmUserEnvironment   } catch { Write-ADTLogEntry -Message "WARNING: Error removing NVM user env vars (non-fatal) - $_"   -Severity 2 }

    if (Test-Path -LiteralPath $Script:NvmHelperDir)
    {
        Remove-Item -LiteralPath $Script:NvmHelperDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Remove-ADTRegistryKey -Key $Script:DetectionKey
}


##================================================
## MARK: Repair
##================================================

function Repair-ADTDeployment
{
    [CmdletBinding()]
    param ()

    ##--------------------------------------------
    ## Pre-Repair
    ##--------------------------------------------
    $adtSession.InstallPhase = "Pre-$($adtSession.DeploymentType)"

    Write-ADTLogEntry -Message 'Pre-Repair: Ensuring staging directories exist...'
    New-Item -Path 'C:\Temp'             -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    New-Item -Path $Script:NvmStagingDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null

    ##--------------------------------------------
    ## Repair
    ##--------------------------------------------
    $adtSession.InstallPhase = $adtSession.DeploymentType

    Get-NvmInstaller
    Install-NvmSilent
    Set-NvmSystemEnvironment

    try { Install-NodeLts } catch { Write-ADTLogEntry -Message "WARNING: Node.js re-install via NVM encountered an error (non-fatal) - $_" -Severity 2 }

    Remove-Item -LiteralPath $Script:NvmStagingDir -Recurse -Force -ErrorAction SilentlyContinue

    ##--------------------------------------------
    ## Post-Repair
    ##--------------------------------------------
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    Set-NvmUserEnvironment

    try { Register-EnvRefreshTask } catch { Write-ADTLogEntry -Message "WARNING: Could not re-register refresh task - $_" -Severity 2 }

    Set-ADTRegistryKey -Key $Script:DetectionKey
}


##================================================
## MARK: Initialization
##================================================

$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
$ProgressPreference    = [System.Management.Automation.ActionPreference]::SilentlyContinue
Set-StrictMode -Version 1

try
{
    if (Test-Path -LiteralPath "$PSScriptRoot\PSAppDeployToolkit\PSAppDeployToolkit.psd1" -PathType Leaf)
    {
        Get-ChildItem -LiteralPath "$PSScriptRoot\PSAppDeployToolkit" -Recurse -File | Unblock-File -ErrorAction Ignore
        Import-Module -FullyQualifiedName @{ ModuleName = "$PSScriptRoot\PSAppDeployToolkit\PSAppDeployToolkit.psd1"; Guid = '8c3c366b-8606-4576-9f2d-4051144f7ca2'; ModuleVersion = '4.1.7' } -Force
    }
    else
    {
        Import-Module -FullyQualifiedName @{ ModuleName = 'PSAppDeployToolkit'; Guid = '8c3c366b-8606-4576-9f2d-4051144f7ca2'; ModuleVersion = '4.1.7' } -Force
    }

    $iadtParams = Get-ADTBoundParametersAndDefaultValues -Invocation $MyInvocation
    $adtSession = Remove-ADTHashtableNullOrEmptyValues -Hashtable $adtSession
    $adtSession = Open-ADTSession @adtSession @iadtParams -PassThru
}
catch
{
    $Host.UI.WriteErrorLine((Out-String -InputObject $_ -Width ([System.Int32]::MaxValue)))
    exit 60008
}


##================================================
## MARK: Invocation
##================================================

try
{
    Get-ChildItem -LiteralPath $PSScriptRoot -Directory | & {
        process
        {
            if ($_.Name -match 'PSAppDeployToolkit\..+$')
            {
                Get-ChildItem -LiteralPath $_.FullName -Recurse -File | Unblock-File -ErrorAction Ignore
                Import-Module -Name $_.FullName -Force
            }
        }
    }

    & "$($adtSession.DeploymentType)-ADTDeployment"
    Close-ADTSession
}
catch
{
    $mainErrorMessage = "An unhandled error within [$($MyInvocation.MyCommand.Name)] has occurred.`n$(Resolve-ADTErrorRecord -ErrorRecord $_)"
    Write-ADTLogEntry -Message $mainErrorMessage -Severity 3

    ## Error details hidden from the user by default. Show a simple dialog with full stack trace:
    # Show-ADTDialogBox -Text $mainErrorMessage -Icon Stop -NoWait

    ## Or, a themed dialog with basic error message:
    # Show-ADTInstallationPrompt -Message "$($adtSession.DeploymentType) failed at line $($_.InvocationInfo.ScriptLineNumber), char $($_.InvocationInfo.OffsetInLine):`n$($_.InvocationInfo.Line.Trim())`n`nMessage:`n$($_.Exception.Message)" -ButtonRightText OK -Icon Error -NoWait

    Close-ADTSession -ExitCode 60001
}
