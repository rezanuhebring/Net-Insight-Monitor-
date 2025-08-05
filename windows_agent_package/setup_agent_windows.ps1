#Requires -Version 5.1
<#
.SYNOPSIS
    Automated setup for the Net-Insight Monitor Agent (Windows). V3 FINAL PRODUCTION VERSION.
.DESCRIPTION
    This script installs the agent, dependencies, and creates a recurring scheduled task.
    It prompts for necessary user input to automate the configuration process.
#>
param()

# --- Self-Elevation to Administrator ---
if (-Not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "This script requires Administrator privileges. Attempting to re-launch as Admin..."
    $arguments = "-ExecutionPolicy Bypass -File `"$($myInvocation.mycommand.definition)`""
    Start-Process powershell -Verb runAs -ArgumentList $arguments
    exit
}

# --- Pre-flight Checks and Configuration ---
Write-Host "Starting Net-Insight Monitor Agent Setup (Running as Administrator)..." -ForegroundColor Yellow

# --- Interactive User Input ---
Write-Host "`nPlease provide the following configuration details." -ForegroundColor Cyan
$centralApiUrl = Read-Host -Prompt "Enter the Central Server API URL (e.g., http://server.com/api/submit_metrics.php)"
$apiKey = Read-Host -Prompt "Enter the Agent API Key"
$agentIdentifier = Read-Host -Prompt "Enter a Unique Identifier for this agent (e.g., Branch-Office-PC-01)"
[int]$scheduleMinutes = Read-Host -Prompt "Enter the monitoring frequency in minutes (e.g., 15)"

# Validate inputs
if (-not ($centralApiUrl -like 'http*') -or -not $apiKey -or -not $agentIdentifier -or $scheduleMinutes -le 0) {
    Write-Error "Invalid input. URL must start with http/https, API key and Identifier cannot be empty, and frequency must be a positive number."
    Read-Host "Press Enter to exit"
    exit 1
}

# MODIFIED: Updated paths and names for the new project
$AgentSourcePath = Split-Path -Parent $MyInvocation.MyCommand.Path
$AgentInstallDir = "C:\NetInsightAgent"
$SpeedtestInstallDir = Join-Path $AgentInstallDir "speedtest"
$SpeedtestExePath = Join-Path $SpeedtestInstallDir "speedtest.exe"
$MonitorScriptName = "Monitor-InternetAgent.ps1"
$ConfigTemplateName = "agent_config.ps1.template"
$DestinationConfigPath = Join-Path $AgentInstallDir "agent_config.ps1"

# --- 1. Install Dependencies (Ookla Speedtest) ---
if (-not (Test-Path $SpeedtestExePath)) {
    Write-Host "Ookla Speedtest not found. Starting automatic installation..." -ForegroundColor Cyan
    $SpeedtestZipUrl = "https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-win64.zip"
    $TempZipPath = Join-Path $env:TEMP "speedtest.zip"
    try {
        Write-Host "- Downloading from $SpeedtestZipUrl..."; Invoke-WebRequest -Uri $SpeedtestZipUrl -OutFile $TempZipPath -UseBasicParsing -ErrorAction Stop
        Write-Host "- Unzipping to $SpeedtestInstallDir..."; New-Item -Path $SpeedtestInstallDir -ItemType Directory -Force | Out-Null; Expand-Archive -Path $TempZipPath -DestinationPath $SpeedtestInstallDir -Force -ErrorAction Stop
        Write-Host "- Cleaning up temporary files..."; Remove-Item $TempZipPath -Force
        Write-Host "Speedtest installation successful." -ForegroundColor Green
    } catch { Write-Error "Failed to download or install Speedtest: $($_.Exception.Message)"; Read-Host "Press Enter to exit"; exit 1 }
} else { Write-Host "Ookla Speedtest is already installed." }

# --- 2. Deploy Agent Scripts and Create Config from Input ---
if (-not (Test-Path $AgentInstallDir)) { New-Item -Path $AgentInstallDir -ItemType Directory -Force | Out-Null }
Write-Host "Copying agent scripts to '$AgentInstallDir'..."
try {
    Copy-Item -Path (Join-Path $AgentSourcePath $MonitorScriptName) -Destination (Join-Path $AgentInstallDir $MonitorScriptName) -Force -ErrorAction Stop
    Write-Host "- Copied $MonitorScriptName"
    
    # Create config file from template and user input
    Write-Host "Creating configuration file '$DestinationConfigPath'..." -ForegroundColor Magenta
    $configContent = Get-Content -Path (Join-Path $AgentSourcePath $ConfigTemplateName) | ForEach-Object {
        $_ -replace '<REPLACE_WITH_UNIQUE_ID>', $agentIdentifier `
           -replace '<REPLACE_WITH_YOUR_SERVER_URL>', $centralApiUrl `
           -replace '<PASTE_AGENT_API_KEY_HERE>', $apiKey
    }
    $configContent | Set-Content -Path $DestinationConfigPath -Force
    Write-Host "- Configuration created successfully." -ForegroundColor Green

} catch { Write-Error "Failed to copy agent files or create config: $($_.Exception.Message)"; Read-Host "Press Enter to exit"; exit 1 }

# --- 3. Add Speedtest Path to Agent Config ---
Write-Host "Verifying Speedtest path in agent configuration..."
try {
    $ConfigLine = "`n`$script:SPEEDTEST_EXE_PATH = `"$SpeedtestExePath`""
    Add-Content -Path $DestinationConfigPath -Value $ConfigLine
    Write-Host "Speedtest path configured successfully in '$DestinationConfigPath'." -ForegroundColor Green
} catch {
    Write-Error "Failed to update config file with Speedtest path. Error: $($_.Exception.Message)"
}

# --- 4. Accept License Terms Silently ---
Write-Host "Attempting to accept Speedtest license terms..."
try { & $SpeedtestExePath --accept-license --accept-gdpr | Out-Null }
catch { Write-Warning "Could not run speedtest.exe to accept license. This may be a temporary network issue. Error: $($_.Exception.Message)" }

# --- 5. Create/Update Scheduled Task ---
$TaskName = "NetInsightMonitorAgent" # MODIFIED: New task name
$TaskAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$AgentInstallDir\$MonitorScriptName`""
$TaskTrigger = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes $scheduleMinutes) -Once -At (Get-Date)
$TaskPrincipal = New-ScheduledTaskPrincipal -UserID "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$TaskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew
Write-Host "Registering scheduled task '$TaskName' to run every $scheduleMinutes minutes..."
try {
    Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false
    Register-ScheduledTask -TaskName $TaskName -Action $TaskAction -Trigger $TaskTrigger -Principal $TaskPrincipal -Settings $TaskSettings -ErrorAction Stop
    Write-Host "Scheduled task '$TaskName' created/updated successfully."
} catch { Write-Error "Failed to register task '$TaskName': $($_.Exception.Message)"; Write-Warning "You may need to create the task manually." }

# --- Final Instructions ---
$LogFilePath = Join-Path $AgentInstallDir "net_insight_agent_windows.log"
Write-Host "`nNet-Insight Monitor Agent Setup Complete." -ForegroundColor Green
Write-Host "--------------------------------------------------------------------"
Write-Host "The agent has been configured and the scheduled task is active." -ForegroundColor Yellow
Write-Host ""
Write-Host "To test the agent immediately, run this command in an Administrator PowerShell:"
Write-Host "   & `"$AgentInstallDir\$MonitorScriptName`""
Write-Host ""
Write-Host "To check the agent's log file for output:"
Write-Host "   Get-Content `"$LogFilePath`" -Tail 10 -Wait"
Write-Host ""
Write-Host "To change settings in the future, you can edit the config file:"
Write-Host "   notepad `"$DestinationConfigPath`""
Write-Host "--------------------------------------------------------------------"
Read-Host "Press Enter to exit"
