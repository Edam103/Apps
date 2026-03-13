<#

.SYNOPSIS
PSAppDeployToolkit - This script performs the installation or uninstallation of an application(s).

.DESCRIPTION
- The script is provided as a template to perform an install, uninstall, or repair of an application(s).
- The script either performs an "Install", "Uninstall", or "Repair" deployment type.
- The install deployment type is broken down into 3 main sections/phases: Pre-Install, Install, and Post-Install.

The script imports the PSAppDeployToolkit module which contains the logic and functions required to install or uninstall an application.

.PARAMETER DeploymentType
The type of deployment to perform.

.PARAMETER DeployMode
Specifies whether the installation should be run in Interactive (shows dialogs), Silent (no dialogs), NonInteractive (dialogs without prompts) mode, or Auto (shows dialogs if a user is logged on, device is not in the OOBE, and there's no running apps to close)..

Silent mode is automatically set if it is detected that the process is not user interactive, no users are logged on, the device is in Autopilot mode, or there's specified processes to close that are currently running.

.PARAMETER SuppressRebootPassThru
Suppresses the 3010 return code (requires restart) from being passed back to the parent process (e.g. SCCM) if detected from an installation. If 3010 is passed back to SCCM, a reboot prompt will be triggered.

.PARAMETER TerminalServerMode
Changes to "user install mode" and back to "user execute mode" for installing/uninstalling applications for Remote Desktop Session Hosts/Citrix servers.

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
- 60000 - 68999: Reserved for built-in exit codes in Invoke-AppDeployToolkit.ps1, and Invoke-AppDeployToolkit.exe
- 69000 - 69999: Recommended for user customized exit codes in Invoke-AppDeployToolkit.ps1
- 70000 - 79999: Recommended for user customized exit codes in PSAppDeployToolkit.Extensions module.

.LINK
https://psappdeploytoolkit.com

#>

[CmdletBinding()]
param
(
    # Default is 'Install'.
    [Parameter(Mandatory = $false)]
    [ValidateSet('Install', 'Uninstall', 'Repair')]
    [System.String]$DeploymentType,

    # Default is 'Auto'. Don't hard-code this unless required.
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

# Zero-Config MSI support is provided when "AppName" is null or empty.
# By setting the "AppName" property, Zero-Config MSI will be disabled.
$adtSession = @{
    # App variables.
    AppVendor            = 'ojdkbuild open-source project'
    AppName              = 'ojdkbuild OpenJDK 17.0.3.0.6-1'
    AppVersion           = '17.0030.6.1'
    AppArch              = 'x64'
    AppLang              = 'EN'
    AppRevision          = '01'
    AppSuccessExitCodes  = @(0)
    AppRebootExitCodes   = @(1641, 3010)
    AppProcessesToClose  = @()
    AppScriptVersion     = '1.1.0'
    AppScriptDate        = '03/13/2026'
    AppScriptAuthor      = 'amasterson-adm'
    RequireAdmin         = $true

    # Install Titles (Only set here to override defaults set by the toolkit).
    InstallName          = ''
    InstallTitle         = ''

    # Script variables.
    DeployAppScriptFriendlyName = $MyInvocation.MyCommand.Name
    DeployAppScriptParameters   = $PSBoundParameters
    DeployAppScriptVersion      = '4.1.7'
}

##================================================
## MARK: Package-level constants
## These are available to all deployment functions below.
##================================================

# Destination directory for the JDK file copy (used as JAVA_HOME)
$Script:JavaDestPath     = 'C:\Temp\Openjdk17'

# Drop location for the WM_SETTINGCHANGE broadcast helper script
$Script:JavaHelperDir    = 'C:\ProgramData\OpenJDK17'
$Script:JavaHelperScript = 'C:\ProgramData\OpenJDK17\Invoke-RefreshJavaHome.ps1'

# Scheduled task name used to broadcast the env change at next user logon
$Script:RefreshTaskName  = 'OpenJDK17-RefreshJavaHome'

# MSI product code - used for uninstall/repair
$Script:ProductCode      = '{85C97C32-CFB2-43E7-9540-8040220D1E94}'

# Uninstall registry path for this product (used to resolve InstallLocation)
$Script:UninstallRegPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$Script:ProductCode"

# Master Wrapper detection key
$Script:DetectionKey     = 'HKLM\SOFTWARE\InstalledApps\ojdkbuild open-source project_ojdkbuild OpenJDK 17.0.3.0.6-1_17.0030.6.1'

##================================================
## MARK: Helper - Resolve installed JDK source path
## Called after MSI install to locate where the JDK was placed.
## Strategy:
##   1. Read InstallLocation from the Uninstall registry key (cleanest)
##   2. Scan C:\Program Files\ojdkbuild for a java-17* folder (WiX fallback -
##      WiX MSIs do not always populate InstallLocation)
##   3. Throw a terminating error so the deployment fails loudly rather than
##      silently copying nothing.
##================================================

function Resolve-JdkSourcePath
{
    [CmdletBinding()]
    [OutputType([System.String])]
    param ()

    Write-ADTLogEntry -Message 'Resolving installed JDK source path...'

    # Attempt 1 - Uninstall registry key InstallLocation
    $regPath = (Get-ItemProperty -Path $Script:UninstallRegPath -ErrorAction SilentlyContinue).InstallLocation
    if ($regPath)
    {
        $regPath = $regPath.TrimEnd('\')
        if (Test-Path -LiteralPath $regPath -PathType Container)
        {
            Write-ADTLogEntry -Message "JDK path resolved from registry: [$regPath]"
            return $regPath
        }
        Write-ADTLogEntry -Message "Registry InstallLocation [$regPath] does not exist on disk - falling back to filesystem scan." -Severity 2
    }
    else
    {
        Write-ADTLogEntry -Message 'InstallLocation not present in uninstall registry key - falling back to filesystem scan.' -Severity 2
    }

    # Attempt 2 - Filesystem scan under C:\Program Files\ojdkbuild
    $ojdkRoot = 'C:\Program Files\ojdkbuild'
    if (Test-Path -LiteralPath $ojdkRoot -PathType Container)
    {
        $candidate = Get-ChildItem -LiteralPath $ojdkRoot -Directory -Filter 'java-17*' -ErrorAction SilentlyContinue |
                     Sort-Object -Property Name -Descending |
                     Select-Object -First 1 -ExpandProperty FullName
        if ($candidate)
        {
            Write-ADTLogEntry -Message "JDK path resolved via filesystem scan: [$candidate]"
            return $candidate
        }
    }

    # All attempts exhausted
    throw "Unable to locate the installed JDK 17 directory. Ensure the MSI installed successfully before the Post-Install phase runs."
}

##================================================
## MARK: Helper - Create WM_SETTINGCHANGE broadcast task
## Drops a small PowerShell helper script to C:\ProgramData\OpenJDK17 and
## registers a per-user at-logon scheduled task. The task broadcasts
## WM_SETTINGCHANGE so that already-running processes (e.g. cmd.exe, IDEs)
## pick up the new JAVA_HOME without requiring a full logoff. The task
## self-deletes on first run.
##================================================

function Register-EnvRefreshTask
{
    [CmdletBinding()]
    param ()

    Write-ADTLogEntry -Message 'Registering JAVA_HOME environment refresh scheduled task...'

    # Create helper directory
    if (-not (Test-Path -LiteralPath $Script:JavaHelperDir -PathType Container))
    {
        New-Item -Path $Script:JavaHelperDir -ItemType Directory -Force | Out-Null
    }

    # Helper script content - broadcasts WM_SETTINGCHANGE then self-unregisters
    $helperContent = @'
# OpenJDK17 - Broadcast JAVA_HOME environment variable change to running processes.
# This script is created by the OpenJDK 17 PSADT package and self-deletes after one run.
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
    # Non-fatal; log to the event log if possible, then continue to self-cleanup.
    Write-EventLog -LogName Application -Source "Application" -EventId 9901 `
        -EntryType Warning -Message "OpenJDK17 EnvRefresh: $_" -ErrorAction SilentlyContinue
}
finally
{
    Unregister-ScheduledTask -TaskName 'OpenJDK17-RefreshJavaHome' -Confirm:$false -ErrorAction SilentlyContinue
}
'@

    $helperContent | Out-File -FilePath $Script:JavaHelperScript -Encoding UTF8 -Force

    # Build the scheduled task components - all splatted clearly to avoid line-continuation parsing errors
    $actionParams = @{
        Execute  = 'powershell.exe'
        Argument = "-NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Script:JavaHelperScript`""
    }
    $taskAction = New-ScheduledTaskAction @actionParams

    $taskTrigger = New-ScheduledTaskTrigger -AtLogOn

    $taskPrincipal = New-ScheduledTaskPrincipal -GroupId 'BUILTIN\Users' -RunLevel Limited

    $taskSettings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew -StartWhenAvailable

    $registerParams = @{
        TaskName    = $Script:RefreshTaskName
        Action      = $taskAction
        Trigger     = $taskTrigger
        Principal   = $taskPrincipal
        Settings    = $taskSettings
        Description = 'Broadcasts WM_SETTINGCHANGE so running processes see JAVA_HOME set by OpenJDK 17 package. Self-deletes after first execution.'
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
    ##--------------------------------------------
    $adtSession.InstallPhase = "Pre-$($adtSession.DeploymentType)"

    # Pre-create the destination directory so it is ready before any copy attempt.
    # Using New-Item with -Force is idempotent - safe to run on upgrade/repair.
    Write-ADTLogEntry -Message "Ensuring JDK destination directory exists: [$Script:JavaDestPath]"
    New-Item -Path $Script:JavaDestPath -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null

    ##--------------------------------------------
    ## Install
    ##--------------------------------------------
    $adtSession.InstallPhase = $adtSession.DeploymentType

    Start-ADTMsiProcess -Action 'Install' -FilePath 'ojdkbuild OpenJDK 17_17.0030.6.1_X64_wix_en-US.msi'

    ##--------------------------------------------
    ## Post-Install
    ##--------------------------------------------
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    # --- Step 1: Locate the installed JDK source directory ---
    $jdkSource = Resolve-JdkSourcePath

    # --- Step 2: Copy JDK files to C:\Temp\Openjdk17 ---
    # Clear existing contents first to guarantee a clean, consistent state
    # (handles re-runs and upgrades where partial files might be present).
    Write-ADTLogEntry -Message "Copying JDK files from [$jdkSource] to [$Script:JavaDestPath]..."
    try
    {
        if (Test-Path -LiteralPath $Script:JavaDestPath)
        {
            Get-ChildItem -LiteralPath $Script:JavaDestPath -Force -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction Stop
        }
        Copy-Item -Path "$jdkSource\*" -Destination $Script:JavaDestPath -Recurse -Force -ErrorAction Stop
        Write-ADTLogEntry -Message 'JDK files copied successfully.'
    }
    catch
    {
        Write-ADTLogEntry -Message "ERROR: Failed to copy JDK files - $_" -Severity 3
        throw
    }

    # --- Step 3: Set JAVA_HOME as a user environment variable for ALL profiles ---
    # Invoke-ADTAllUsersRegistryAction loads each user's NTUSER.dat (for offline
    # users) or writes directly to HKU\{SID} (for currently logged-on users),
    # covering all existing profiles. The Default User hive is also updated so
    # any new accounts created after this deployment inherit JAVA_HOME immediately.
    #
    # NOTE: Intune runs in SYSTEM context - this is the correct PSADT mechanism
    # to write HKCU values from SYSTEM without impersonation.
    Write-ADTLogEntry -Message "Setting JAVA_HOME user environment variable to [$Script:JavaDestPath] for all user profiles..."
    try
    {
        Invoke-ADTAllUsersRegistryAction -ScriptBlock {
            Set-ADTRegistryKey -Key 'HKCU\Environment' -Name 'JAVA_HOME' -Value 'C:\Temp\Openjdk17' -Type 'String' -SID $_.SID
        }
        Write-ADTLogEntry -Message 'JAVA_HOME set successfully across all user profiles.'
    }
    catch
    {
        Write-ADTLogEntry -Message "ERROR: Failed to set JAVA_HOME for all users - $_" -Severity 3
        throw
    }

    # --- Step 4: Register logon scheduled task (WM_SETTINGCHANGE broadcast) ---
    # This ensures that processes already running in an active user session
    # receive the environment change notification at next logon without a
    # full logoff cycle being required.
    # Failure here is non-fatal - JAVA_HOME registry write already succeeded.
    try
    {
        Register-EnvRefreshTask
    }
    catch
    {
        Write-ADTLogEntry -Message "WARNING: Could not register environment refresh scheduled task (non-fatal) - $_" -Severity 2
    }

    # --- Step 5: Master Wrapper detection key ---
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

    # Remove the refresh task before the MSI uninstall runs so there is
    # no risk of the task firing mid-uninstall on a machine with a live session.
    Write-ADTLogEntry -Message "Removing scheduled task [$Script:RefreshTaskName] if present..."
    Unregister-ScheduledTask -TaskName $Script:RefreshTaskName -Confirm:$false -ErrorAction SilentlyContinue

    ##--------------------------------------------
    ## Uninstall
    ##--------------------------------------------
    $adtSession.InstallPhase = $adtSession.DeploymentType

    Start-ADTMsiProcess -Action 'Uninstall' -ProductCode $Script:ProductCode

    ##--------------------------------------------
    ## Post-Uninstall
    ##--------------------------------------------
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    # --- Step 1: Remove JAVA_HOME user environment variable from ALL profiles ---
    Write-ADTLogEntry -Message 'Removing JAVA_HOME user environment variable from all user profiles...'
    try
    {
        Invoke-ADTAllUsersRegistryAction -ScriptBlock {
            Remove-ADTRegistryKey -Key 'HKCU\Environment' -Name 'JAVA_HOME' -SID $_.SID
        }
        Write-ADTLogEntry -Message 'JAVA_HOME removed from all user profiles.'
    }
    catch
    {
        Write-ADTLogEntry -Message "WARNING: Error removing JAVA_HOME from user profiles (non-fatal) - $_" -Severity 2
    }

    # --- Step 2: Remove JDK copy at C:\Temp\Openjdk17 ---
    if (Test-Path -LiteralPath $Script:JavaDestPath)
    {
        Write-ADTLogEntry -Message "Removing JDK copy at [$Script:JavaDestPath]..."
        Remove-Item -LiteralPath $Script:JavaDestPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- Step 3: Remove helper script directory ---
    if (Test-Path -LiteralPath $Script:JavaHelperDir)
    {
        Write-ADTLogEntry -Message "Removing helper directory [$Script:JavaHelperDir]..."
        Remove-Item -LiteralPath $Script:JavaHelperDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # --- Step 4: Master Wrapper detection key ---
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

    ##--------------------------------------------
    ## Repair
    ##--------------------------------------------
    $adtSession.InstallPhase = $adtSession.DeploymentType

    Start-ADTMsiProcess -Action 'Repair' -ProductCode $Script:ProductCode

    ##--------------------------------------------
    ## Post-Repair
    ##--------------------------------------------
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    # Re-run the copy and JAVA_HOME env steps in case they were lost or corrupted.
    # Resolve-JdkSourcePath will find the path again after the repair-reinstated MSI.
    $jdkSource = Resolve-JdkSourcePath

    Write-ADTLogEntry -Message "Re-copying JDK files from [$jdkSource] to [$Script:JavaDestPath]..."
    New-Item -Path $Script:JavaDestPath -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    Copy-Item -Path "$jdkSource\*" -Destination $Script:JavaDestPath -Recurse -Force -ErrorAction Stop
    Write-ADTLogEntry -Message 'JDK files re-copied successfully.'

    Write-ADTLogEntry -Message 'Re-setting JAVA_HOME for all user profiles...'
    Invoke-ADTAllUsersRegistryAction -ScriptBlock {
        Set-ADTRegistryKey -Key 'HKCU\Environment' -Name 'JAVA_HOME' -Value 'C:\Temp\Openjdk17' -Type 'String' -SID $_.SID
    }

    try { Register-EnvRefreshTask } catch { Write-ADTLogEntry -Message "WARNING: Could not re-register refresh task - $_" -Severity 2 }

    # Master Wrapper detection key
    Set-ADTRegistryKey -Key $Script:DetectionKey
}


##================================================
## MARK: Initialization
##================================================

# Set strict error handling across entire operation.
$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
$ProgressPreference    = [System.Management.Automation.ActionPreference]::SilentlyContinue
Set-StrictMode -Version 1

# Import the module and instantiate a new session.
try
{
    # Import the module locally if available, otherwise try to find it from PSModulePath.
    if (Test-Path -LiteralPath "$PSScriptRoot\PSAppDeployToolkit\PSAppDeployToolkit.psd1" -PathType Leaf)
    {
        Get-ChildItem -LiteralPath "$PSScriptRoot\PSAppDeployToolkit" -Recurse -File | Unblock-File -ErrorAction Ignore
        Import-Module -FullyQualifiedName @{ ModuleName = "$PSScriptRoot\PSAppDeployToolkit\PSAppDeployToolkit.psd1"; Guid = '8c3c366b-8606-4576-9f2d-4051144f7ca2'; ModuleVersion = '4.1.7' } -Force
    }
    else
    {
        Import-Module -FullyQualifiedName @{ ModuleName = 'PSAppDeployToolkit'; Guid = '8c3c366b-8606-4576-9f2d-4051144f7ca2'; ModuleVersion = '4.1.7' } -Force
    }

    # Open a new deployment session, replacing $adtSession with a DeploymentSession.
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

# Commence the actual deployment operation.
try
{
    # Import any found extensions before proceeding with the deployment.
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

    # Invoke the deployment and close out the session.
    & "$($adtSession.DeploymentType)-ADTDeployment"
    Close-ADTSession
}
catch
{
    # An unhandled error has been caught.
    $mainErrorMessage = "An unhandled error within [$($MyInvocation.MyCommand.Name)] has occurred.`n$(Resolve-ADTErrorRecord -ErrorRecord $_)"
    Write-ADTLogEntry -Message $mainErrorMessage -Severity 3

    ## Error details hidden from the user by default. Show a simple dialog with full stack trace:
    # Show-ADTDialogBox -Text $mainErrorMessage -Icon Stop -NoWait

    ## Or, a themed dialog with basic error message:
    # Show-ADTInstallationPrompt -Message "$($adtSession.DeploymentType) failed at line $($_.InvocationInfo.ScriptLineNumber), char $($_.InvocationInfo.OffsetInLine):`n$($_.InvocationInfo.Line.Trim())`n`nMessage:`n$($_.Exception.Message)" -ButtonRightText OK -Icon Error -NoWait

    Close-ADTSession -ExitCode 60001
}
