<#
.SYNOPSIS
Removes the deployments containing the VMs listed in a Get-ManagedVMs CSV
from Automation using the Delete day-2 action with Ignore Delete Failures.
.DESCRIPTION
WARNING: Delete removes the VM from vCenter if Automation can reach it. This is
only intended for cloud accounts that have lost their vCenter connection.
Targets whose cloud accounts do not report healthy = false are skipped, without
stopping other targets. Each VM must still belong to its CSV cloud account.
Health is Automation's last health-check result; confirm the vCenter really is
unreachable from Automation before using -Execute.
Deletes entire deployments with Ignore Delete Failures enabled.
The CSV SyncStatus column is ignored; machine status is checked live.
This removes ALL related resources from Automation, including
disks and networks, and may leave infrastructure behind for manual cleanup.
Every machine in a deployment must be listed in the CSV and pass the live
cloud-account check. All CSV machines in a deployment must name the same cloud
account, and every deployment resource must have a matching properties.endpointId.
Resources with unknown account membership block cleanup. -All does not bypass
these checks. Without -All, every machine must be MISSING.
Concurrency limits deployment requests rather than individual VM requests.
Up to -Concurrency (default 5) Delete requests run at the same time; each is
polled until it finishes or TimeoutSeconds passes. Per-deployment errors are appended
immediately to ErrorFile and processing continues. Existing error records are preserved.
Timeouts or polling errors do not cancel requests; check their RequestId in
Automation before retrying. Login, CSV, and error-log write failures stop execution.
Defaults to preview mode. Supply -Execute to perform the deletes.
Supply -Debug to trace REST methods, URLs, and HTTP results without logging
request/response bodies or authorization headers (which may contain secrets).
.EXAMPLE
.\Remove-VMs.ps1 -CsvFile .\managed-vms.csv -Server vra.example.com -User admin -Password 'password' -Domain example.com
.EXAMPLE
.\Remove-VMs.ps1 -CsvFile .\managed-vms.csv -Server vra.example.com -User admin -Password 'password' -Domain example.com -Insecure -Execute -Concurrency 10
.EXAMPLE
.\Remove-VMs.ps1 -CsvFile .\managed-vms.csv -Server vra.example.com -User admin -Password 'password' -All
Previews whole-deployment cleanup, including machines that are not MISSING.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CsvFile,
    [Parameter(Mandatory)][string]$Server,
    [Parameter(Mandatory)][string]$User,
    [Parameter(Mandatory)][string]$Password,
    [string]$Domain = '',
    [switch]$Execute,
    # Include deployments whose machines are not all MISSING.
    [switch]$All,
    [string]$ErrorFile = 'delete-errors.csv',
    [ValidateRange(1, 86400)][int]$TimeoutSeconds = 600,
    # Maximum number of Delete requests running at the same time.
    [ValidateRange(1, 100)][int]$Concurrency = 5,
    # Disables certificate validation for the rest of this PowerShell process.
    [switch]$Insecure
)

$ErrorActionPreference = 'Stop'
if ($PSBoundParameters['Debug']) { $DebugPreference = 'Continue' }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if ($Insecure) {
    Write-Warning 'SSL certificate validation is disabled for this PowerShell process.'
    if (-not ('VraCertificateValidation' -as [type])) {
        Add-Type @'
public static class VraCertificateValidation
{
    public static void Enable()
    {
        System.Net.ServicePointManager.ServerCertificateValidationCallback =
            delegate { return true; };
    }
}
'@
    }
    [VraCertificateValidation]::Enable()
}

# JavaScriptSerializer handles keys that differ only by case (ConvertFrom-Json in PS 5.1 does not)
Add-Type -AssemblyName System.Web.Extensions
$json = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$json.MaxJsonLength = [int]::MaxValue

function Invoke-Vra($Method, $Path, $Body) {
    $params = @{ Method = $Method; Uri = "https://$Server$Path"; ContentType = 'application/json'; UseBasicParsing = $true }
    if ($script:token) { $params.Headers = @{ Authorization = "Bearer $script:token" } }
    if ($Body) { $params.Body = $json.Serialize($Body) }
    Write-Debug "REST request: $Method $($params.Uri)"
    try {
        $response = Invoke-WebRequest @params
    } catch {
        if ($null -ne $_.Exception.Response) {
            Write-Debug "REST failed: $Method $($params.Uri) -> HTTP $([int]$_.Exception.Response.StatusCode)"
        } else {
            Write-Debug "REST failed: $Method $($params.Uri) -> no HTTP response"
        }
        throw
    }
    Write-Debug "REST response: $Method $($params.Uri) -> HTTP $([int]$response.StatusCode)"
    # DELETE and PUT may succeed without returning JSON.
    if (-not [string]::IsNullOrWhiteSpace($response.Content)) {
        $json.DeserializeObject($response.Content)
    }
}

$vms = @(Import-Csv -LiteralPath $CsvFile)
if ($vms.Count -eq 0) { throw "CSV '$CsvFile' contains no VMs." }
$ids = @{}
foreach ($vm in $vms) {
    if ([string]::IsNullOrWhiteSpace($vm.Id) -or [string]::IsNullOrWhiteSpace($vm.DeploymentId) -or
        [string]::IsNullOrWhiteSpace($vm.CloudAccountId)) {
        throw 'Each CSV row must have an Id, DeploymentId and CloudAccountId from Get-ManagedVMs.'
    }
    if ($ids.ContainsKey($vm.Id)) { throw "Duplicate VM Id '$($vm.Id)' in CSV." }
    $ids[$vm.Id] = $true
}

# Log in
$script:token = $null # Discard any token retained by a previous dot-sourced run.
$login = @{ username = $User; password = $Password }
if ($Domain) { $login.domain = $Domain }
$refresh = (Invoke-Vra POST '/csp/gateway/am/api/login?access_token' $login)['refresh_token'] 
$script:token = (Invoke-Vra POST '/iaas/api/login' @{ refreshToken = $refresh })['token']

# Skip targets on accounts that do not report a disconnected vCenter.
$blockedAccounts = @{}
foreach ($accountId in @($vms | Select-Object -ExpandProperty CloudAccountId -Unique)) {
    $account = Invoke-Vra GET "/iaas/api/cloud-accounts/$([uri]::EscapeDataString($accountId))"
    Write-Host "Cloud account: $($account['name']) ($accountId) healthy=$($account['healthy'])"
    if ($account['healthy'] -ne $false) { $blockedAccounts[$accountId] = "$($account['name']) ($accountId)" }
}

$ErrorFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ErrorFile)
if ($Execute) {
    if ($ErrorFile -eq $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($CsvFile)) {
        throw 'ErrorFile must not be the input CSV.'
    }
    $columns = '"TimestampUtc","Server","Name","Id","DeploymentId","RequestId","Status","Error"'
    if (-not (Test-Path -LiteralPath $ErrorFile) -or (Get-Item -LiteralPath $ErrorFile).Length -eq 0) {
        Set-Content -LiteralPath $ErrorFile -Encoding UTF8 -Value $columns
    } elseif ((Get-Content -LiteralPath $ErrorFile -TotalCount 1) -ne $columns) {
        throw "ErrorFile '$ErrorFile' has an unexpected CSV header. Choose another path."
    }
    Write-Host "Error log: $ErrorFile"
}
$deleted = 0
$alreadyDeleted = 0
$skipped = 0
$healthSkipped = 0
$failed = 0
$inFlight = New-Object System.Collections.Generic.List[object]

function Write-DeleteError($Vm, $RequestId, $Status, $Message) {
    $script:failed++
    [pscustomobject]@{
        TimestampUtc = [DateTime]::UtcNow.ToString('o')
        Server = $Server
        Name = $Vm.Name
        Id = $Vm.Id
        DeploymentId = $Vm.DeploymentId
        RequestId = $RequestId
        Status = $Status
        Error = $Message
    } | Export-Csv -LiteralPath $ErrorFile -Append -NoTypeInformation -Encoding UTF8
    Write-Warning "Delete failed for '$($Vm.Name)' ($($Vm.Id)): $Message"
}

function Get-ErrorText($ErrorRecord) {
    $message = $ErrorRecord.Exception.Message
    if ($ErrorRecord.ErrorDetails.Message) { $message += " $($ErrorRecord.ErrorDetails.Message)" }
    $message
}

# Polls every in-flight request once and removes the finished ones.
function Update-Requests {
    foreach ($item in $inFlight.ToArray()) {
        $status = 'POLLING_ERROR'
        try {
            $request = Invoke-Vra GET "/deployment/api/requests/$([uri]::EscapeDataString($item.RequestId))"
            if ($null -eq $request -or [string]::IsNullOrWhiteSpace($request['status'])) {
                throw 'Request response has no status.'
            }
            $status = $request['status']
            Write-Host "Request $($item.RequestId) ($($item.Vm.Name)): $status"
            if ($status -eq 'SUCCESSFUL') {
                $script:deleted++
                Write-Host "Deleted: $($item.Vm.Name) ($($item.Vm.Id))"
                [void]$inFlight.Remove($item)
            } elseif ($status -in @('FAILED', 'CANCELLED', 'CANCELED')) {
                throw "Delete request ${status}: $($request['details'])"
            } elseif ([DateTime]::UtcNow -ge $item.Deadline) {
                $status = 'TIMEOUT'
                throw "Timed out after $TimeoutSeconds seconds. Request may still be running; check Automation before retrying."
            }
        } catch {
            [void]$inFlight.Remove($item)
            Write-DeleteError $item.Vm $item.RequestId $status (Get-ErrorText $_)
        }
    }
}

# Waits until fewer than $Limit requests are in flight.
function Wait-Requests([int]$Limit) {
    while ($inFlight.Count -ge $Limit -and $inFlight.Count -gt 0) {
        Update-Requests
        if ($inFlight.Count -ge $Limit -and $inFlight.Count -gt 0) { Start-Sleep -Seconds 5 }
    }
}

$targets = @($vms | Group-Object DeploymentId | ForEach-Object {
    [pscustomobject]@{
        Name = "Deployment $($_.Name)"
        Id = $_.Name
        DeploymentId = $_.Name
        Machines = @($_.Group)
    }
})

foreach ($vm in $targets) {
    $blocked = @($vm.Machines | Select-Object -ExpandProperty CloudAccountId -Unique |
        Where-Object { $blockedAccounts.ContainsKey($_) } |
        ForEach-Object { $blockedAccounts[$_] })
    if ($blocked.Count -gt 0) {
        $healthSkipped++
        Write-Warning "Skipping '$($vm.Name)' ($($vm.Id)): cloud account health is not false: $($blocked -join ', '). Delete could remove actual infrastructure. Continuing with other targets."
        continue
    }
    $requestId = ''
    $status = 'STATUS_ERROR'
    try {
        $resourcePath = '/deployment/api/deployments/' + [uri]::EscapeDataString($vm.DeploymentId)
        try {
            $null = Invoke-Vra GET $resourcePath
        } catch {
            if ($null -ne $_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) {
                $alreadyDeleted++
                Write-Host "Deployment $($vm.DeploymentId) was already deleted."
                continue
            }
            throw
        }
        $resources = @()
        $page = 0
        do {
            $result = Invoke-Vra GET "$resourcePath/resources?size=200&page=$page"
            if ($null -eq $result -or -not $result.ContainsKey('content') -or $null -eq $result['content']) {
                throw 'Deployment resources response has no content; cannot verify machine coverage.'
            }
            $resources += $result['content']
            $page++
        } while ($result['content'].Count -gt 0 -and $result['last'] -ne $true)
        $accountIds = @($vm.Machines | Select-Object -ExpandProperty CloudAccountId -Unique)
        if ($accountIds.Count -ne 1) {
            throw 'CSV machines in this deployment reference multiple cloud accounts; refusing cleanup.'
        }
        $targetAccountId = $accountIds[0]
        foreach ($deploymentResource in $resources) {
            $resourceId = $deploymentResource['id']
            $properties = $deploymentResource['properties']
            if ($null -eq $properties -or [string]::IsNullOrWhiteSpace($properties['endpointId'])) {
                throw "Cannot verify cloud account for resource '$resourceId' ($($deploymentResource['type'])); refusing cleanup."
            }
            if ($properties['endpointId'] -ne $targetAccountId) {
                throw "Resource '$resourceId' ($($deploymentResource['type'])) belongs to cloud account '$($properties['endpointId'])', not '$targetAccountId'; refusing cleanup."
            }
        }
        $machines = @($resources | Where-Object { $_['type'] -match '(^|\.)Machine$' })
        if ($machines.Count -eq 0) { throw 'No machines found in deployment; refusing cleanup.' }
        foreach ($machine in $machines) {
            if (-not ($vm.Machines | Where-Object { $_.Id -eq $machine['id'] })) {
                throw "Deployment contains machine '$($machine['id'])' not listed in the CSV; refusing cleanup."
            }
        }
        foreach ($row in $vm.Machines) {
            if (-not ($machines | Where-Object { $_['id'] -eq $row.Id })) {
                throw "CSV machine '$($row.Id)' not found in deployment; refusing cleanup."
            }
        }
        $notMissing = $false
        foreach ($row in $vm.Machines) {
            $resource = Invoke-Vra GET "$resourcePath/resources/$([uri]::EscapeDataString($row.Id))"
            if ($resource['properties']['endpointId'] -ne $row.CloudAccountId) {
                throw "Machine '$($row.Id)' no longer belongs to cloud account '$($row.CloudAccountId)'."
            }
            $liveStatus = $resource['syncStatus']
            if ([string]::IsNullOrWhiteSpace($liveStatus)) { $liveStatus = 'MISSING' }
            Write-Host "Machine: $($row.Name) syncStatus=$liveStatus"
            if ($liveStatus -ne 'MISSING') { $notMissing = $true }
        }
        $syncStatus = if ($notMissing) { 'NOT_ALL_MISSING' } else { 'MISSING' }
        if (-not $All -and $syncStatus -ne 'MISSING') {
            $skipped++
            Write-Host "Skipping: $($vm.Name) ($($vm.Id)) syncStatus=$syncStatus (not MISSING; use -All to include)."
            continue
        }
        if (-not $Execute) {
            Write-Host "Preview: Would invoke the Delete day-2 action for $($vm.Name) ($($vm.Id)) syncStatus=$syncStatus on $Server."
            continue
        }
        Write-Host "Deleting: $($vm.Name) ($($vm.Id)) syncStatus=$syncStatus"
        $status = 'SUBMISSION_ERROR'
        $actions = Invoke-Vra GET "$resourcePath/actions"
        $action = $actions | Where-Object { $_['name'] -eq 'Delete' -and $_['valid'] -eq $true } | Select-Object -First 1
        if ($null -eq $action -or [string]::IsNullOrWhiteSpace($action['id'])) {
            throw 'No valid Delete day-2 action is available for this resource.'
        }
        $inputs = @{ ignoreDeleteFailures = $true }
        $request = Invoke-Vra POST "$resourcePath/requests" @{ actionId = $action['id']; inputs = $inputs }
        if ($null -eq $request -or [string]::IsNullOrWhiteSpace($request['id'])) {
            throw 'Submission returned no request ID. Check Automation before retrying; the request may have been accepted.'
        }
        $requestId = $request['id']
        Write-Host "Request: $requestId ($($vm.Name))"
        $inFlight.Add(@{
            Vm = $vm
            RequestId = $requestId
            Deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        })
    } catch {
        $message = Get-ErrorText $_
        if ($Execute) {
            Write-DeleteError $vm $requestId $status $message
        } else {
            $failed++
            Write-Warning "Status check failed for '$($vm.Name)' ($($vm.Id)): $message"
        }
    }
    Wait-Requests $Concurrency
}
Wait-Requests 1
if ($Execute) {
    Write-Host "Deleted $deleted of $($targets.Count) deployments; $alreadyDeleted already deleted; $skipped skipped (not MISSING); $healthSkipped skipped (account health); $failed errors. Error log: $ErrorFile"
} else {
    $eligible = $targets.Count - $skipped - $failed - $alreadyDeleted - $healthSkipped
    Write-Host "Preview complete: $eligible of $($targets.Count) deployments would be deleted; $alreadyDeleted already deleted; $skipped skipped (not MISSING); $healthSkipped skipped (account health); $failed status errors. No changes made. Supply -Execute to delete them."
}
