<#
.SYNOPSIS
    Pulls device compliance data from ManageEngine Endpoint Central (SaaS/Cloud) and delivers to Drata.

.DESCRIPTION
    This script extracts data from ME Endpoint Central Cloud (US region) using the Zoho OAuth 2.0
    client credentials flow. A long-lived refresh token is stored as an environment variable; the
    script exchanges it for a short-lived access token at runtime and proactively refreshes it
    mid-run if the token nears expiry.

    It checks SOM Computers, Installed Software, and Patch status via the ME Cloud API.
    BitLocker and ScreenLock compliance are resolved from locally scheduled CSV exports
    (these two data points are not exposed by the ME REST API).
    The merged device payload is POSTed to the Drata Custom Device Connection API.

.PARAMETER LogDirectory
    Path where the script will write log files. Defaults to C:\DrataSync\logs\

.PARAMETER ReportDirectory
    Path where the exported ManageEngine CSV reports are saved. Defaults to C:\DrataSync\reports\
#>

[CmdletBinding()]
param (
    [string]$LogDirectory = "C:\DrataSync\logs\",
    [string]$ReportDirectory = "C:\DrataSync\reports\"
)

# ---------------------------------------------------------
# Configuration
# ---------------------------------------------------------

# Zoho OAuth 2.0 credentials for ManageEngine Endpoint Central Cloud.
# Generate a Client ID + Client Secret at https://api-console.zoho.com (US).
# Exchange the one-time authorization code for a refresh token once manually,
# then store all three values as Windows environment variables on the host.
# The refresh token does not expire unless revoked or unused for 6+ months.
$MeClientId      = $env:ME_CLIENT_ID
$MeClientSecret  = $env:ME_CLIENT_SECRET
$MeRefreshToken  = $env:ME_REFRESH_TOKEN

# ManageEngine Endpoint Central Cloud - United States region (fixed)
$MeServerUrl     = "https://endpointcentral.manageengine.com"
$ZohoAccountsUrl = "https://accounts.zoho.com"

$DrataApiToken   = $env:DRATA_API_TOKEN

# Array heuristics for Software Matching
$ApprovedAntivirus = @(
    "CrowdStrike", "Falcon", "Defender", "Sentinel", "Carbon Black",
    "SentinelOne", "Cylance", "Trend Micro", "Sophos", "McAfee"
)
$ApprovedPasswordManagers = @(
    "1Password", "LastPass", "Keeper", "Bitwarden", "Dashlane"
)
$MaxScreenLockTimeoutSeconds = 900

# File Paths
$LogFile          = Join-Path $LogDirectory "SyncRun_$(Get-Date -Format 'yyyyMMdd').log"
$BitLockerCsvPath = Join-Path $ReportDirectory "bitlocker_export.csv"
$ScreenLockCsvPath = Join-Path $ReportDirectory "screenlock_export.csv"

# ---------------------------------------------------------
# OAuth Token State (script-scoped; not exported)
# ---------------------------------------------------------
$script:MeAccessToken = $null
$script:MeTokenExpiry = [DateTime]::MinValue

# ---------------------------------------------------------
# Framework Functions
# ---------------------------------------------------------

Function Write-SyncLog {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]$Message,
        
        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )
    
    # Ensure log directory exists silently
    if (-not (Test-Path $LogDirectory)) {
        New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
    }

    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ssK"
    $LogEntry = "[$Timestamp] [$Level] $Message"
    
    # Output to stdout/stderror for trace ability
    if ($Level -eq "ERROR") {
        Write-Error $LogEntry
    } elseif ($Level -eq "WARN") {
        Write-Warning $LogEntry
    } else {
        Write-Host $LogEntry
    }
    
    # Append to rolling log file without locks
    Add-Content -Path $LogFile -Value $LogEntry
}

Function Get-MEAccessToken {
    <#
    Exchanges the stored OAuth refresh token for a new short-lived access token.
    Stores the token and its expiry in script-scoped variables. A 120-second
    buffer is applied so callers never use a token that is about to expire.
    #>
    Write-SyncLog "Requesting new OAuth access token from Zoho..."

    $TokenUrl = "$ZohoAccountsUrl/oauth/v2/token"
    $Body = @{
        grant_type    = "refresh_token"
        client_id     = $MeClientId
        client_secret = $MeClientSecret
        refresh_token = $MeRefreshToken
    }

    try {
        $Response = Invoke-RestMethod -Uri $TokenUrl -Method POST `
                        -Body $Body `
                        -ContentType "application/x-www-form-urlencoded" `
                        -ErrorAction Stop

        if ([string]::IsNullOrWhiteSpace($Response.access_token)) {
            throw "Zoho token endpoint returned no access_token. Full response: $($Response | ConvertTo-Json -Compress)"
        }

        $script:MeAccessToken = $Response.access_token

        # Apply a 120-second safety buffer before the stated expiry (default 3600 s)
        $ExpiresIn = if ($Response.expires_in -gt 0) { [int]$Response.expires_in } else { 3600 }
        $script:MeTokenExpiry = (Get-Date).AddSeconds($ExpiresIn - 120)

        Write-SyncLog "OAuth access token acquired. Effective lifetime: $($ExpiresIn - 120) seconds."
    } catch {
        Write-SyncLog "FATAL: Failed to acquire ManageEngine OAuth access token: $_" -Level "ERROR"
        throw
    }
}

Function Invoke-MEWebRequest {
    <#
    Issues an authenticated GET request to the ManageEngine Cloud API.
    Proactively refreshes the Zoho OAuth access token when it is at or past
    its buffered expiry so individual API calls never fail due to a stale token.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Endpoint
    )

    # Refresh proactively if token is absent or within the safety buffer
    if (-not $script:MeAccessToken -or (Get-Date) -ge $script:MeTokenExpiry) {
        Get-MEAccessToken
    }

    $Uri = "$MeServerUrl$Endpoint"
    $Headers = @{
        "Authorization" = "Zoho-oauthtoken $($script:MeAccessToken)"
        "Content-Type"  = "application/json"
    }

    try {
        $Response = Invoke-RestMethod -Uri $Uri -Method GET -Headers $Headers -ErrorAction Stop
        return $Response
    } catch {
        Write-SyncLog -Message "API call failed for URI: $Uri. Error: $_" -Level "ERROR"
        return $null
    }
}

# ---------------------------------------------------------
# API Data Retrieval
# ---------------------------------------------------------

Function Get-MEComputers {
    Write-SyncLog "Fetching computers from ManageEngine SOM API..."
    $AllComputers = @()
    $Page = 1
    $PageLimit = 100
    
    while ($true) {
        $Response = Invoke-MEWebRequest -Endpoint "/api/1.4/som/computers?page=$Page&pagelimit=$PageLimit"
        
        if (-not $Response -or -not $Response.message_response) {
            break
        }
        
        $Computers = $Response.message_response.som_computers
        if (-not $Computers -or $Computers.Count -eq 0) {
            break
        }
        
        $AllComputers += $Computers
        $Total = $Response.message_response.total
        
        # Paginate limit escape clause
        if ($AllComputers.Count -ge $Total) {
            break
        }
        $Page++
    }
    
    Write-SyncLog "Successfully retrieved $($AllComputers.Count) managed computers."
    return $AllComputers
}

Function Get-MEInstalledSoftware {
    param([int]$ResourceId)
    
    $HasAntivirus = $false
    $HasPasswordManager = $false
    
    $Response = Invoke-MEWebRequest -Endpoint "/api/1.4/inventory/computerinstalledsoftware?resid=$ResourceId"
    if ($Response -and $Response.message_response -and $Response.message_response.software) {
        $SoftwareList = $Response.message_response.software
        
        foreach ($Soft in $SoftwareList) {
            $SoftName = $Soft.software_name
            if ([string]::IsNullOrWhiteSpace($SoftName)) { continue }
            
            # Check AV Patterns
            foreach ($AV in $ApprovedAntivirus) {
                if ($SoftName -match [regex]::Escape($AV)) {
                    $HasAntivirus = $true
                    break
                }
            }
            
            # Check PM Patterns
            foreach ($PM in $ApprovedPasswordManagers) {
                if ($SoftName -match [regex]::Escape($PM)) {
                    $HasPasswordManager = $true
                    break
                }
            }
        }
    }
    
    return [PSCustomObject]@{
        AntivirusPresent       = $HasAntivirus
        PasswordManagerPresent = $HasPasswordManager
    }
}

Function Get-MEPatchCompliant {
    param([int]$ResourceId)
    
    # A device is considered compliant (autoUpdate: true) if zero missing critical patches
    $IsCompliant = $false
    
    $Response = Invoke-MEWebRequest -Endpoint "/api/1.4/patch/allsystemdetails?resid=$ResourceId"
    if ($Response -and $Response.message_response -and $Response.message_response.allsystemdetails) {
        $Details = $Response.message_response.allsystemdetails
        
        # We target missing_patches count.
        # Fallback: if 'missing_patches' count is 0, AutoUpdate is compliant
        $Missing = $Details.missing_patches
        if ($Missing -gt 0) {
            $IsCompliant = $false
        } else {
            $IsCompliant = $true
        }
    }
    
    return $IsCompliant
}

# ---------------------------------------------------------
# Offline CSV Processing
# ---------------------------------------------------------

Function Get-MEOfflineCSVData {
    Write-SyncLog "Parsing offline CSV Report data for missing API modules..."
    $DataMap = @{}
    
    # 1. BitLocker CSV Import Logic
    if (Test-Path $BitLockerCsvPath) {
        try {
            $BLData = Import-Csv -Path $BitLockerCsvPath
            foreach ($Row in $BLData) {
                $CompName = $Row."Computer Name"
                if ([string]::IsNullOrWhiteSpace($CompName)) { continue }
                
                $IsProtected = $false
                if ($Row."Protection Status" -eq "Protected") {
                    $IsProtected = $true
                }
                
                if (-not $DataMap.ContainsKey($CompName)) {
                    $DataMap[$CompName] = @{ DiskEncrypted=$false; ScreenLockCompliant=$false }
                }
                $DataMap[$CompName].DiskEncrypted = $IsProtected
            }
            Write-SyncLog "Parsed BitLocker data efficiently from CSV."
        } catch {
            Write-SyncLog "Error parsing BitLocker CSV: $_" -Level "ERROR"
        }
    } else {
        Write-SyncLog "BitLocker CSV not found at $BitLockerCsvPath. Defaults applied." -Level "WARN"
    }
    
    # 2. ScreenLock CSV Import Logic
    if (Test-Path $ScreenLockCsvPath) {
        try {
            $SLData = Import-Csv -Path $ScreenLockCsvPath
            foreach ($Row in $SLData) {
                $CompName = $Row."Computer Name"
                if ([string]::IsNullOrWhiteSpace($CompName)) { continue }
                
                $IsCompliant = $false
                # Validate the Idle Timeout
                $TimeoutStr = $Row."Idle Timeout"
                if ([int]::TryParse($TimeoutStr, [ref]$null)) {
                    $Timeout = [int]$TimeoutStr
                    if ($Timeout -gt 0 -and $Timeout -le $MaxScreenLockTimeoutSeconds) {
                        $IsCompliant = $true
                    }
                }
                
                if (-not $DataMap.ContainsKey($CompName)) {
                    $DataMap[$CompName] = @{ DiskEncrypted=$false; ScreenLockCompliant=$false }
                }
                $DataMap[$CompName].ScreenLockCompliant = $IsCompliant
            }
            Write-SyncLog "Parsed ScreenLock data efficiently from CSV."
        } catch {
            Write-SyncLog "Error parsing ScreenLock CSV: $_" -Level "ERROR"
        }
    } else {
        Write-SyncLog "ScreenLock CSV not found at $ScreenLockCsvPath. Defaults applied." -Level "WARN"
    }

    return $DataMap
}

# ---------------------------------------------------------
# Main Execution / Orchestration
# ---------------------------------------------------------
try {
    Write-SyncLog "=== Starting ManageEngine to Drata Sync (Cloud) ==="

    if (-not $MeClientId -or -not $MeClientSecret -or -not $MeRefreshToken -or -not $DrataApiToken) {
        throw "Missing required environment variables. Ensure ME_CLIENT_ID, ME_CLIENT_SECRET, ME_REFRESH_TOKEN, and DRATA_API_TOKEN are configured."
    }

    # Acquire an access token eagerly so auth failures surface before any data work begins
    Get-MEAccessToken

    $OfflineDataHash = Get-MEOfflineCSVData
    $Computers = Get-MEComputers
    
    if (-not $Computers -or $Computers.Count -eq 0) {
        Write-SyncLog "No computers retrieved from ManageEngine. Ending sync instance." -Level "WARN"
        exit
    }
    
    $HttpPushHeaders = @{
        "Authorization" = "Bearer $DrataApiToken"
        "Content-Type"  = "application/json"
    }
    
    $SuccessCount = 0
    $FailureCount = 0
    
    # Process and Normalize Devices
    foreach ($Comp in $Computers) {
        $ResId = $Comp.resource_id
        $CompName = $Comp.resource_name
        
        Write-SyncLog "Processing Device: $CompName (ID: $ResId)"
        
        # Resolve Email
        # ownerEmailID is fallback to agent_logged_on_users
        $UserEmail = $Comp.ownerEmailID
        if ([string]::IsNullOrWhiteSpace($UserEmail)) {
            $UserEmail = $Comp.agent_logged_on_users
        }
        
        if ([string]::IsNullOrWhiteSpace($UserEmail)) {
            Write-SyncLog "Skipping $CompName: User Email missing." -Level "WARN"
            $FailureCount++
            continue
        }
        
        # Resolve Serial Number
        $SerialNumber = $Comp.servicetag
        if ([string]::IsNullOrWhiteSpace($SerialNumber)) {
            $SerialNumber = [string]$ResId   # resource_id is numeric in JSON; cast to string before .Trim()
        }

        # Resolve OS name string
        $OsVersionStr = $Comp.os_version
        if ([string]::IsNullOrWhiteSpace($OsVersionStr)) {
            $OsVersionStr = $Comp.os_name
        }
        if ([string]::IsNullOrWhiteSpace($OsVersionStr)) {
            $OsVersionStr = ""
        }
        
        # Dynamic API Lookups
        $SoftwareCompliant = Get-MEInstalledSoftware -ResourceId $ResId
        $AutoUpdateStatus = Get-MEPatchCompliant -ResourceId $ResId
        
        # Offline CSV Lookups
        $DiskEncryptionStatus = $false
        $ScreenLockStatus = $false
        
        if ($OfflineDataHash.ContainsKey($CompName)) {
            $DiskEncryptionStatus = $OfflineDataHash[$CompName].DiskEncrypted
            $ScreenLockStatus     = $OfflineDataHash[$CompName].ScreenLockCompliant
        }
        
        # Flat Payload Generation
        $PayloadObj = @{
            serialNumber    = $SerialNumber.Trim()
            email           = $UserEmail.Trim()
            osVersion       = $OsVersionStr.Trim()
            diskEncryption  = [bool]$DiskEncryptionStatus
            screenLock      = [bool]$ScreenLockStatus
            autoUpdate      = [bool]$AutoUpdateStatus
            antivirus       = [bool]$SoftwareCompliant.AntivirusPresent
            passwordManager = [bool]$SoftwareCompliant.PasswordManagerPresent
        }
        
        # Compress removes extra white space required for enterprise efficiency
        $JsonPayload = $PayloadObj | ConvertTo-Json -Compress
        
        # Push Device Model to Drata Hub
        try {
            $Response = Invoke-RestMethod -Uri "https://app.drata.com/api/pull/v1/devices" `
                                          -Method POST `
                                          -Headers $HttpPushHeaders `
                                          -Body $JsonPayload `
                                          -ErrorAction Stop
            
            Write-SyncLog "Successfully synced $CompName to Drata Platform."
            $SuccessCount++
        } catch {
            Write-SyncLog "RestException: Failed pushing $CompName. HTTP Code: $($_.Exception.Response.StatusCode.value__)" -Level "ERROR"
            $FailureCount++
        }
    }
    
    Write-SyncLog "Sync run complete. Success: $SuccessCount, Failed/Skipped: $FailureCount"
    Write-SyncLog "=== End of Sync ==="
} catch {
    Write-SyncLog "FATAL SCRIPT EXCEPTION: $_" -Level "ERROR"
    exit 1
}
