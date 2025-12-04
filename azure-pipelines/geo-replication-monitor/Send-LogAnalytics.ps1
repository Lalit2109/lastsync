<# 
    Script: Send-LogAnalytics.ps1

    Purpose:
      - Optional module to send storage account monitoring data to Log Analytics
      - Can be called from the main monitoring script

    Usage:
      . .\Send-LogAnalytics.ps1
      Send-ToLogAnalytics -WorkspaceId $workspaceId -SharedKey $sharedKey -Data $results -LogType "InfraMonitoring"
#>

# Function to send data to Log Analytics using Data Collector API
function Send-ToLogAnalytics {
    param(
        [Parameter(Mandatory = $true)]
        [string] $WorkspaceId,
        
        [Parameter(Mandatory = $true)]
        [string] $SharedKey,
        
        [Parameter(Mandatory = $true)]
        [array] $Data,
        
        [Parameter(Mandatory = $true)]
        [string] $LogType
    )
    
    if (-not $Data -or $Data.Count -eq 0) {
        Write-Warning "No data provided to send to Log Analytics"
        return $false
    }
    
    # Build the API endpoint
    $uri = "https://$WorkspaceId.ods.opinsights.azure.com/api/logs?api-version=2016-04-01"
    
    # Create the signature
    $date = [DateTime]::UtcNow.ToString("r")
    $jsonBody = $Data | ConvertTo-Json -Depth 10
    $contentLength = [System.Text.Encoding]::UTF8.GetByteCount($jsonBody)
    
    $stringToSign = "POST`n$contentLength`napplication/json`nx-ms-date:$date`n/api/logs"
    $bytesToSign = [System.Text.Encoding]::UTF8.GetBytes($stringToSign)
    $keyBytes = [System.Convert]::FromBase64String($SharedKey)
    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = $keyBytes
    $signature = [System.Convert]::ToBase64String($hmac.ComputeHash($bytesToSign))
    $authSignature = "SharedKey $WorkspaceId`:$signature"
    
    # Build headers
    $headers = @{
        "Authorization" = $authSignature
        "Log-Type" = $LogType
        "x-ms-date" = $date
        "Content-Type" = "application/json"
        "time-generated-field" = "TimeGenerated"
    }
    
    try {
        $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $jsonBody -ErrorAction Stop
        Write-Host "Successfully sent $($Data.Count) records to Log Analytics workspace $WorkspaceId"
        return $true
    }
    catch {
        Write-Warning "Failed to send data to Log Analytics: $_"
        return $false
    }
}

# Export the function
Export-ModuleMember -Function Send-ToLogAnalytics

