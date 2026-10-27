param(
    [Parameter(Mandatory)][string]$CloudAccount,
    [Parameter(Mandatory)][string]$Server,
    [Parameter(Mandatory)][string]$User,
    [Parameter(Mandatory)][string]$Password,
    [string]$Domain = '',
    [string]$OutFile = 'managed-vms.csv',
    # Disables certificate validation for the rest of this PowerShell process.
    [switch]$Insecure
)

$ErrorActionPreference = 'Stop'
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
    $json.DeserializeObject((Invoke-WebRequest @params).Content)
}

# Log in
$login = @{ username = $User; password = $Password }
if ($Domain) { $login.domain = $Domain }
$refresh = (Invoke-Vra POST '/csp/gateway/am/api/login?access_token' $login)['refresh_token']
$script:token = (Invoke-Vra POST '/iaas/api/login' @{ refreshToken = $refresh })['token']

# Find the cloud account
$filter = [uri]::EscapeDataString("name eq '$($CloudAccount.Replace("'", "''"))'")
$account = (Invoke-Vra GET "/iaas/api/cloud-accounts?`$filter=$filter")['content'] | Select-Object -First 1
if (-not $account) { throw "Cloud account '$CloudAccount' not found" }
Write-Host "Cloud account: $($account['name']) ($($account['id']))"

# Ask the deployment service for managed (deployed or onboarded) vSphere machines
# only; discovered machines are filtered out on the server.
$OutFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutFile)
Set-Content -LiteralPath $OutFile -Encoding UTF8 -Value '"Name","Id","ExternalId","CloudAccount","CloudAccountId","PowerState","SyncStatus","Address","DeploymentId","ProjectId"'
Write-Host "Writing CSV: $OutFile"
$page = 0
$scanned = 0
$written = 0
do {
    $result = Invoke-Vra GET "/deployment/api/resources?resourceTypes=Cloud.vSphere.Machine&origin=DEPLOYED,ONBOARDED&size=200&page=$page"
    if (-not $result.ContainsKey('content') -or $null -eq $result['content']) {
        throw "Unexpected resources response on page ${page}: missing 'content'."
    }
    Write-Host "Page ${page}: received $($result['content'].Count) managed machines (all cloud accounts)."
    foreach ($res in $result['content']) {
        $scanned++
        # endpointId is the cloud account ID of the machine. All columns come from
        # the deployment resource: machines that are MISSING in vCenter no longer
        # have an IaaS machine record (/iaas/api/machines/{id} returns 404).
        $p = $res['properties']
        if ($p['endpointId'] -ne $account['id']) { continue }
        $syncStatus = $res['syncStatus']
        if ([string]::IsNullOrWhiteSpace($syncStatus)) {
            Write-Warning "No syncStatus found for machine '$($p['resourceName'])' ($($res['id']))."
            $syncStatus = 'MISSING'
        }
        [pscustomobject]@{
            Name         = $p['resourceName']
            Id           = $res['id']
            ExternalId   = $p['externalId']
            CloudAccount = $account['name']
            CloudAccountId = $account['id']
            PowerState   = $p['powerState']
            SyncStatus   = $syncStatus
            Address      = $p['address']
            DeploymentId = $res['deploymentId']
            ProjectId    = $res['projectId']
        } | Export-Csv -LiteralPath $OutFile -Append -NoTypeInformation -Encoding UTF8
        $written++
        Write-Host "Exported: $($p['resourceName']) ($syncStatus)"
    }
    $page++
} while ($result['content'].Count -gt 0 -and $result['last'] -ne $true)

Write-Host "Scanned $scanned managed machines; exported $written for '$CloudAccount' to $OutFile."
if ($written -eq 0) {
    Write-Warning 'No managed VMs returned for this cloud account. The CSV contains only headers. Check account association and the login user''s project/resource permissions.'
}
