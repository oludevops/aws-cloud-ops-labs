# IISLab-Setup: installs IIS + ASP.NET 4.8 and deploys the "Alerts" site.
# Re-running it removes the lab objects and rebuilds them, so it doubles as a reset.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

Write-Output '== 1. Installing IIS and ASP.NET 4.8 (first run takes 3-5 minutes) =='
$features = 'Web-Server', 'Web-Asp-Net45', 'Web-Mgmt-Console', 'Web-Http-Logging', 'Web-Request-Monitor', 'Web-Http-Tracing'
$result = Install-WindowsFeature -Name $features -IncludeManagementTools
Write-Output ('Install result: {0}; restart needed: {1}' -f $result.ExitCode, $result.RestartNeeded)
Import-Module WebAdministration

Write-Output '== 2. Removing any previous lab objects =='
foreach ($site in 'Alerts', 'Alerts-staging') {
    if (Test-Path "IIS:\Sites\$site") { Remove-Website -Name $site }
}
if (Test-Path 'IIS:\AppPools\AlertsPool') { Remove-WebAppPool -Name 'AlertsPool' }
if (Get-LocalUser -Name 'svc_alerts' -ErrorAction SilentlyContinue) { Remove-LocalUser -Name 'svc_alerts' }
Remove-Item -Path 'C:\inetpub\alerts', 'C:\inetpub\staging', 'C:\lab' -Recurse -Force -ErrorAction SilentlyContinue

Write-Output '== 3. Creating the service account the app pool runs as =='
# Real apps often run as a dedicated (domain) service account so they can reach
# file shares or SQL Server. That's what makes password rotation a classic outage.
$password = 'Lab#' + [guid]::NewGuid().ToString('N').Substring(0, 16) + 'Z9!'
$secure = ConvertTo-SecureString $password -AsPlainText -Force
New-LocalUser -Name 'svc_alerts' -Password $secure -PasswordNeverExpires -Description 'Identity for the AlertsPool application pool' | Out-Null
Add-LocalGroupMember -Group 'IIS_IUSRS' -Member 'svc_alerts'

Write-Output '== 4. Deploying release v1 of the Alerts site =='
New-Item -ItemType Directory -Path 'C:\inetpub\alerts', 'C:\lab\releases\v1' -Force | Out-Null

$page = @'
<%@ Page Language="C#" %>
<!DOCTYPE html>
<html>
<head><title>Alerts API (lab)</title></head>
<body>
<h1>Alerts API - release v1</h1>
<p>Status: healthy</p>
<p>Server time (UTC): <%= DateTime.UtcNow.ToString("u") %></p>
<p>Running as: <%= System.Security.Principal.WindowsIdentity.GetCurrent().Name %></p>
<p>.NET CLR version: <%= Environment.Version %></p>
</body>
</html>
'@

$config = @'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <system.web>
    <compilation debug="false" targetFramework="4.8" />
    <httpRuntime targetFramework="4.8" />
    <customErrors mode="Off" />
  </system.web>
</configuration>
'@

# The live site, plus a copy of the release kept for recovery
foreach ($dir in 'C:\inetpub\alerts', 'C:\lab\releases\v1') {
    Set-Content -Path (Join-Path $dir 'default.aspx') -Value $page -Encoding UTF8
    Set-Content -Path (Join-Path $dir 'web.config') -Value $config -Encoding UTF8
}
& icacls.exe 'C:\inetpub\alerts' /grant 'svc_alerts:(OI)(CI)RX' | Out-Null

Write-Output '== 5. Creating the AlertsPool application pool and the Alerts site =='
New-WebAppPool -Name 'AlertsPool' | Out-Null
Set-ItemProperty -Path 'IIS:\AppPools\AlertsPool' -Name managedRuntimeVersion -Value 'v4.0'
Set-ItemProperty -Path 'IIS:\AppPools\AlertsPool' -Name processModel -Value @{ userName = "$env:COMPUTERNAME\svc_alerts"; password = $password; identityType = 3 }
# Rapid-fail protection, set explicitly to the IIS defaults: 5 crashes in 5 minutes stops the pool
Set-ItemProperty -Path 'IIS:\AppPools\AlertsPool' -Name failure.rapidFailProtection -Value $true
Set-ItemProperty -Path 'IIS:\AppPools\AlertsPool' -Name failure.rapidFailProtectionMaxCrashes -Value 5
Set-ItemProperty -Path 'IIS:\AppPools\AlertsPool' -Name failure.rapidFailProtectionInterval -Value '00:05:00'

New-Website -Name 'Alerts' -Port 8080 -PhysicalPath 'C:\inetpub\alerts' -ApplicationPool 'AlertsPool' | Out-Null

Write-Output '== 6. Installing the C:\lab\Test-Site.ps1 helper =='
$tester = @'
# Usage:  C:\lab\Test-Site.ps1            (tests http://localhost:8080/)
#         C:\lab\Test-Site.ps1 -Url http://localhost/
# Prints the HTTP status and the page text, even for error responses.
param([string]$Url = 'http://localhost:8080/')
try {
    $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 30
    "HTTP $([int]$r.StatusCode) $($r.StatusDescription)"
    (($r.Content -replace '<[^>]+>', ' ') -replace '\s+', ' ').Trim()
}
catch {
    $resp = $_.Exception.Response
    if ($resp) {
        "HTTP $([int]$resp.StatusCode) $($resp.StatusDescription)"
        $body = (New-Object System.IO.StreamReader($resp.GetResponseStream())).ReadToEnd()
        $text = (($body -replace '<[^>]+>', ' ') -replace '\s+', ' ').Trim()
        $text.Substring(0, [Math]::Min(700, $text.Length))
    }
    else {
        "No HTTP response: $($_.Exception.Message)"
    }
}
'@
Set-Content -Path 'C:\lab\Test-Site.ps1' -Value $tester -Encoding UTF8

Write-Output '== 7. Smoke test (the first request compiles the page, so it can take ~15 seconds) =='
Start-Sleep -Seconds 3
& 'C:\lab\Test-Site.ps1'
Write-Output '== Setup complete =='
