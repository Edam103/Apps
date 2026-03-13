<#

.SYNOPSIS
PSAppDeployToolkit - This script performs the installation or uninstallation of an application(s).

.DESCRIPTION
- Downloads Apache Maven 3.9.14 binary zip from the Apache CDN.
- Extracts and copies the Maven files to C:\apache-maven-3.9.14.
- Sets MAVEN_HOME and JAVA_HOME as user-level environment variables for all profiles.
- Appends Maven bin directory to the user-level PATH for all profiles.
- Registers a logon scheduled task to broadcast WM_SETTINGCHANGE to running processes.
- Designed for Intune Win32 app deployment (runs as SYSTEM context).

The script imports the PSAppDeployToolkit module which contains the logic and functions required to install or uninstall an application.

.PARAMETER DeploymentType
The type of deployment to perform.

.PARAMETER DeployMode
Specifies whether the installation should be run in Interactive (shows dialogs), Silent (no dialogs),
NonInteractive (dialogs without prompts) mode, or Auto.

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

.LINK
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
    AppVendor            = 'Apache Software Foundation'
    AppName              = 'Apache Maven 3.9.14'
    AppVersion           = '3.9.14'
    AppArch              = 'x64'
    AppLang              = 'EN'
    AppRevision          = '01'
    AppSuccessExitCodes  = @(0)
    AppRebootExitCodes   = @(1641, 3010)
    AppProcessesToClose  = @()
    AppScriptVersion     = '1.0.0'
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
##================================================

# Maven version and download details
$Script:MavenVersion     = '3.9.14'
$Script:MavenZipName     = "apache-maven-$Script:MavenVersion-bin.zip"
$Script:MavenDownloadUrl = "https://dlcdn.apache.org/maven/maven-3/$Script:MavenVersion/binaries/$Script:MavenZipName"

# Where the zip will be staged during install
$Script:MavenStagingDir  = 'C:\Temp\MavenStaging'
$Script:MavenZipPath     = "$Script:MavenStagingDir\$Script:MavenZipName"

# Final installation directory (top-level Maven home)
$Script:MavenDestPath    = "C:\apache-maven-$Script:MavenVersion"

# The folder name that the zip extracts to internally (Apache standard convention)
$Script:MavenZipFolder   = "apache-maven-$Script:MavenVersion"

# Java destination path (set by OpenJDK 17 package - referenced here for JAVA_HOME consistency)
$Script:JavaDestPath     = 'C:\Temp\Openjdk17'

# Drop location for the WM_SETTINGCHANGE broadcast helper script
$Script:MavenHelperDir    = 'C:\ProgramData\ApacheMaven'
$Script:MavenHelperScript = 'C:\ProgramData\ApacheMaven\Invoke-RefreshMavenHome.ps1'

# Scheduled task name
$Script:RefreshTaskName   = 'ApacheMaven-RefreshEnvVars'

# Master Wrapper detection key
$Script:DetectionKey      = 'HKLM\SOFTWARE\InstalledApps\Apache Software Foundation_Apache Maven_3.9.14'


##================================================
## MARK: Helper - Download Maven zip
## Uses BITS for download with a curl/Invoke-WebRequest fallback.
## BITS is preferred for enterprise environments as it is bandwidth-aware
## and resumable. Falls back gracefully if BITS is unavailable (e.g. disabled
## on some hardened builds).
##================================================

function Get-MavenZip
{
    [CmdletBinding()]
    param ()

    Write-ADTLogEntry -Message "Downloading Apache Maven $Script:MavenVersion from [$Script:MavenDownloadUrl]..."

    # Ensure staging directory exists
    if (-not (Test-Path -LiteralPath $Script:MavenStagingDir -PathType Container))
    {
        New-Item -Path $Script:MavenStagingDir -ItemType Directory -Force | Out-Null
    }

    # Remove any previous partial download
    if (Test-Path -LiteralPath $Script:MavenZipPath)
    {
        Remove-Item -LiteralPath $Script:MavenZipPath -Force -ErrorAction SilentlyContinue
    }

    $downloaded = $false

    # Attempt 1 - BITS (bandwidth-aware, resumable, enterprise-friendly)
    try
    {
        Import-Module BitsTransfer -ErrorAction Stop
        Start-BitsTransfer -Source $Script:MavenDownloadUrl -Destination $Script:MavenZipPath -ErrorAction Stop
        $downloaded = $true
        Write-ADTLogEntry -Message 'Download completed via BITS.'
    }
    catch
    {
        Write-ADTLogEntry -Message "BITS download failed, falling back to Invoke-WebRequest - $_" -Severity 2
    }

    # Attempt 2 - Invoke-WebRequest (standard PowerShell)
    if (-not $downloaded)
    {
        try
        {
            $iwrParams = @{
                Uri             = $Script:MavenDownloadUrl
                OutFile         = $Script:MavenZipPath
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
            throw "Both BITS and Invoke-WebRequest failed to download Maven zip. Last error: $_"
        }
    }

    # Validate the file was actually saved and has a reasonable size (zip should be > 8 MB)
    if (-not (Test-Path -LiteralPath $Script:MavenZipPath))
    {
        throw "Download appeared to succeed but zip file was not found at [$Script:MavenZipPath]."
    }

    $fileSize = (Get-Item -LiteralPath $Script:MavenZipPath).Length
    if ($fileSize -lt 8MB)
    {
        throw "Downloaded file is suspiciously small ($fileSize bytes). The download may have failed or the URL may have changed."
    }

    Write-ADTLogEntry -Message "Maven zip downloaded successfully. File size: $([math]::Round($fileSize / 1MB, 2)) MB"
}


##================================================
## MARK: Helper - Extract and stage Maven files
## Extracts the zip to the staging directory and then moves the inner
## apache-maven-3.9.14 folder to the final destination C:\apache-maven-3.9.14.
## Clears the destination first for idempotency (safe re-runs/upgrades).
##================================================

function Install-MavenFiles
{
    [CmdletBinding()]
    param ()

    Write-ADTLogEntry -Message "Extracting Maven zip to staging directory [$Script:MavenStagingDir]..."

    # Clean any previous extraction in the staging area
    $extractedPath = Join-Path -Path $Script:MavenStagingDir -ChildPath $Script:MavenZipFolder
    if (Test-Path -LiteralPath $extractedPath)
    {
        Remove-Item -LiteralPath $extractedPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    try
    {
        Expand-Archive -LiteralPath $Script:MavenZipPath -DestinationPath $Script:MavenStagingDir -Force -ErrorAction Stop
        Write-ADTLogEntry -Message 'Zip extracted successfully.'
    }
    catch
    {
        throw "Failed to extract Maven zip - $_"
    }

    # Verify the expected folder exists inside the extraction
    if (-not (Test-Path -LiteralPath $extractedPath -PathType Container))
    {
        throw "Expected extracted folder [$extractedPath] was not found. The zip structure may have changed."
    }

    # Clear destination directory for a clean install/upgrade
    if (Test-Path -LiteralPath $Script:MavenDestPath)
    {
        Write-ADTLogEntry -Message "Clearing existing Maven destination [$Script:MavenDestPath]..."
        Get-ChildItem -LiteralPath $Script:MavenDestPath -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction Stop
    }
    else
    {
        New-Item -Path $Script:MavenDestPath -ItemType Directory -Force | Out-Null
    }

    # Copy extracted files to final destination
    Write-ADTLogEntry -Message "Copying Maven files to [$Script:MavenDestPath]..."
    Copy-Item -Path "$extractedPath\*" -Destination $Script:MavenDestPath -Recurse -Force -ErrorAction Stop
    Write-ADTLogEntry -Message 'Maven files copied to destination successfully.'

    # Validate mvn.cmd exists as a post-copy sanity check
    $mvnCmd = Join-Path -Path $Script:MavenDestPath -ChildPath 'bin\mvn.cmd'
    if (-not (Test-Path -LiteralPath $mvnCmd))
    {
        throw "Post-copy validation failed: [$mvnCmd] not found. The extracted zip may be corrupt or the directory structure has changed."
    }

    Write-ADTLogEntry -Message "Maven installation validated. mvn.cmd found at [$mvnCmd]."

    # Clean up staging directory after successful copy
    Write-ADTLogEntry -Message 'Cleaning up staging directory...'
    Remove-Item -LiteralPath $Script:MavenStagingDir -Recurse -Force -ErrorAction SilentlyContinue
}


##================================================
## MARK: Helper - Register WM_SETTINGCHANGE broadcast task
## Identical pattern to the OpenJDK 17 package - drops a helper script
## to C:\ProgramData\ApacheMaven and registers an AtLogOn scheduled task
## for BUILTIN\Users. The task broadcasts WM_SETTINGCHANGE so running
## processes (terminals, IDEs) see the new env vars without a full logoff.
## The task self-deletes after its first execution.
##================================================

function Register-EnvRefreshTask
{
    [CmdletBinding()]
    param ()

    Write-ADTLogEntry -Message 'Registering Maven environment refresh scheduled task...'

    if (-not (Test-Path -LiteralPath $Script:MavenHelperDir -PathType Container))
    {
        New-Item -Path $Script:MavenHelperDir -ItemType Directory -Force | Out-Null
    }

    $helperContent = @'
# ApacheMaven - Broadcast environment variable changes to running processes.
# Created by the Apache Maven 3.9.14 PSADT package. Self-deletes after one run.
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
    Write-EventLog -LogName Application -Source "Application" -EventId 9902 `
        -EntryType Warning -Message "ApacheMaven EnvRefresh: $_" -ErrorAction SilentlyContinue
}
finally
{
    Unregister-ScheduledTask -TaskName 'ApacheMaven-RefreshEnvVars' -Confirm:$false -ErrorAction SilentlyContinue
}
'@

    $helperContent | Out-File -FilePath $Script:MavenHelperScript -Encoding UTF8 -Force

    $actionParams = @{
        Execute  = 'powershell.exe'
        Argument = "-NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Script:MavenHelperScript`""
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
        Description = 'Broadcasts WM_SETTINGCHANGE so running processes see MAVEN_HOME/PATH set by Apache Maven package. Self-deletes after first execution.'
        Force       = $true
        ErrorAction = 'Stop'
    }

    Register-ScheduledTask @registerParams | Out-Null

    Write-ADTLogEntry -Message "Scheduled task [$Script:RefreshTaskName] registered successfully."
}


##================================================
## MARK: Helper - Set Maven user environment variables for all profiles
## Sets MAVEN_HOME and appends %MAVEN_HOME%\bin to the user PATH.
## Uses Invoke-ADTAllUsersRegistryAction to write HKCU from SYSTEM context.
##
## PATH handling strategy:
##   - Read existing user PATH value from HKCU\Environment
##   - Only append %MAVEN_HOME%\bin if it is not already present
##   - Use the expandable string type (REG_EXPAND_SZ) so %MAVEN_HOME%
##     resolves dynamically - consistent with Windows PATH conventions
##================================================

function Set-MavenUserEnvironment
{
    [CmdletBinding()]
    param ()

    Write-ADTLogEntry -Message 'Setting MAVEN_HOME and updating user PATH for all profiles...'

    Invoke-ADTAllUsersRegistryAction -ScriptBlock {

        # Set MAVEN_HOME
        Set-ADTRegistryKey -Key 'HKCU\Environment' -Name 'MAVEN_HOME' -Value 'C:\apache-maven-3.9.14' -Type 'String' -SID $_.SID

        # Read current user PATH (REG_EXPAND_SZ) - may not exist for some profiles
        $currentPath = (Get-ADTRegistryKey -Key 'HKCU\Environment' -Value 'Path' -SID $_.SID -ErrorAction SilentlyContinue)
        if (-not $currentPath) { $currentPath = '' }

        # Only add Maven bin to PATH if not already present (prevents duplicate entries on re-runs)
        $mavenBinEntry = '%MAVEN_HOME%\bin'
        if ($currentPath -notlike "*$mavenBinEntry*")
        {
            if ($currentPath -ne '' -and $currentPath -notmatch ';$')
            {
                $newPath = "$currentPath;$mavenBinEntry"
            }
            else
            {
                $newPath = "$currentPath$mavenBinEntry"
            }
            Set-ADTRegistryKey -Key 'HKCU\Environment' -Name 'Path' -Value $newPath -Type 'ExpandString' -SID $_.SID
        }
    }

    Write-ADTLogEntry -Message 'MAVEN_HOME and user PATH set successfully across all user profiles.'
}


##================================================
## MARK: Helper - Remove Maven user environment variables from all profiles
##================================================

function Remove-MavenUserEnvironment
{
    [CmdletBinding()]
    param ()

    Write-ADTLogEntry -Message 'Removing MAVEN_HOME and Maven PATH entry from all user profiles...'

    Invoke-ADTAllUsersRegistryAction -ScriptBlock {

        # Remove MAVEN_HOME
        Remove-ADTRegistryKey -Key 'HKCU\Environment' -Name 'MAVEN_HOME' -SID $_.SID

        # Strip %MAVEN_HOME%\bin from the user PATH
        $currentPath = (Get-ADTRegistryKey -Key 'HKCU\Environment' -Value 'Path' -SID $_.SID -ErrorAction SilentlyContinue)
        if ($currentPath)
        {
            $mavenBinEntry = '%MAVEN_HOME%\bin'
            $cleanedPath = ($currentPath -split ';' | Where-Object { $_ -ne $mavenBinEntry }) -join ';'
            $cleanedPath = $cleanedPath.TrimEnd(';')
            if ($cleanedPath -ne $currentPath)
            {
                Set-ADTRegistryKey -Key 'HKCU\Environment' -Name 'Path' -Value $cleanedPath -Type 'ExpandString' -SID $_.SID
            }
        }
    }

    Write-ADTLogEntry -Message 'MAVEN_HOME and Maven PATH entry removed from all user profiles.'
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

    # Pre-create destination directory
    Write-ADTLogEntry -Message "Ensuring Maven destination directory exists: [$Script:MavenDestPath]"
    New-Item -Path $Script:MavenDestPath -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null

    ##--------------------------------------------
    ## Install
    ##--------------------------------------------
    $adtSession.InstallPhase = $adtSession.DeploymentType

    # Step 1 - Download Maven zip
    Get-MavenZip

    # Step 2 - Extract and copy to C:\apache-maven-3.9.14
    Install-MavenFiles

    ##--------------------------------------------
    ## Post-Install
    ##--------------------------------------------
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    # Step 3 - Set MAVEN_HOME and update user PATH for all profiles
    try
    {
        Set-MavenUserEnvironment
    }
    catch
    {
        Write-ADTLogEntry -Message "ERROR: Failed to set Maven environment variables - $_" -Severity 3
        throw
    }

    # Step 4 - Register logon task to broadcast env change to running processes
    try
    {
        Register-EnvRefreshTask
    }
    catch
    {
        Write-ADTLogEntry -Message "WARNING: Could not register environment refresh scheduled task (non-fatal) - $_" -Severity 2
    }

    # Step 5 - Master Wrapper detection key
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

    # Remove refresh task before main uninstall
    Write-ADTLogEntry -Message "Removing scheduled task [$Script:RefreshTaskName] if present..."
    Unregister-ScheduledTask -TaskName $Script:RefreshTaskName -Confirm:$false -ErrorAction SilentlyContinue

    ##--------------------------------------------
    ## Uninstall
    ##--------------------------------------------
    $adtSession.InstallPhase = $adtSession.DeploymentType

    # Step 1 - Remove Maven files
    if (Test-Path -LiteralPath $Script:MavenDestPath)
    {
        Write-ADTLogEntry -Message "Removing Maven installation at [$Script:MavenDestPath]..."
        Remove-Item -LiteralPath $Script:MavenDestPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-ADTLogEntry -Message 'Maven installation directory removed.'
    }
    else
    {
        Write-ADTLogEntry -Message "Maven installation directory [$Script:MavenDestPath] not found - may have already been removed." -Severity 2
    }

    ##--------------------------------------------
    ## Post-Uninstall
    ##--------------------------------------------
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    # Step 2 - Remove MAVEN_HOME and PATH entry from all user profiles
    try
    {
        Remove-MavenUserEnvironment
    }
    catch
    {
        Write-ADTLogEntry -Message "WARNING: Error removing Maven environment variables from user profiles (non-fatal) - $_" -Severity 2
    }

    # Step 3 - Remove helper script directory
    if (Test-Path -LiteralPath $Script:MavenHelperDir)
    {
        Write-ADTLogEntry -Message "Removing helper directory [$Script:MavenHelperDir]..."
        Remove-Item -LiteralPath $Script:MavenHelperDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Step 4 - Remove staging directory if it somehow remains
    if (Test-Path -LiteralPath $Script:MavenStagingDir)
    {
        Remove-Item -LiteralPath $Script:MavenStagingDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Step 5 - Master Wrapper detection key
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

    # Re-download and re-copy Maven files in case the installation was corrupted
    Get-MavenZip
    Install-MavenFiles

    ##--------------------------------------------
    ## Post-Repair
    ##--------------------------------------------
    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"

    # Re-apply environment variables across all profiles
    Write-ADTLogEntry -Message 'Re-applying Maven environment variables for all user profiles...'
    Set-MavenUserEnvironment

    try { Register-EnvRefreshTask } catch { Write-ADTLogEntry -Message "WARNING: Could not re-register refresh task - $_" -Severity 2 }

    # Master Wrapper detection key
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
