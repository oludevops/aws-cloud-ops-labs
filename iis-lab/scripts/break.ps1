# IISLab-Break: injects one fault into the Alerts site.
# Errors are hidden on purpose: finding them is your job.
$ErrorActionPreference = 'SilentlyContinue'
Import-Module WebAdministration
$Scenario = '{{ Scenario }}'
Write-Output "Injecting fault: $Scenario"

function Send-Traffic([string]$Url) {
    try { Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 20 | Out-Null } catch { }
}

switch ($Scenario) {

    '1-stopped-pool' {
        Stop-WebAppPool -Name 'AlertsPool'
    }

    '2-crash-loop' {
        # A bad release goes out: the new page kills the worker process on every request.
        $bad = @'
<%@ Page Language="C#" %>
<%
    System.Environment.FailFast("AlertsApi v2: fatal error while loading sensor configuration");
%>
'@
        Set-Content -Path 'C:\inetpub\alerts\default.aspx' -Value $bad -Encoding UTF8
        # Customer traffic arrives. Each request crashes w3wp.exe.
        1..7 | ForEach-Object { Send-Traffic 'http://localhost:8080/'; Start-Sleep -Seconds 3 }
    }

    '3-bad-identity' {
        # Security policy rotates the service account password.
        # Nobody updates the application pool, which still holds the old one.
        $rotated = 'Rot#' + [guid]::NewGuid().ToString('N').Substring(0, 16) + 'Q7!'
        Set-LocalUser -Name 'svc_alerts' -Password (ConvertTo-SecureString $rotated -AsPlainText -Force)
        # Nothing breaks until the pool restarts (a recycle, a reboot, patching...)
        Stop-WebAppPool -Name 'AlertsPool'
        Start-Sleep -Seconds 3
        Start-WebAppPool -Name 'AlertsPool'
        Send-Traffic 'http://localhost:8080/'
    }

    '4-port-conflict' {
        # During a maintenance window someone stands up a staging copy on the same port.
        New-Item -ItemType Directory -Path 'C:\inetpub\staging' -Force | Out-Null
        Set-Content -Path 'C:\inetpub\staging\default.htm' -Value '<html><body><h1>STAGING BUILD - internal testing only</h1></body></html>' -Encoding UTF8
        Stop-Website -Name 'Alerts'
        New-Website -Name 'Alerts-staging' -Port 8080 -PhysicalPath 'C:\inetpub\staging' -ApplicationPool 'DefaultAppPool' | Out-Null
        Start-Website -Name 'Alerts-staging'
        # Maintenance ends and the real site is started again...
        Start-Website -Name 'Alerts'
    }

    '5-bad-config' {
        # A deployment ships a web.config damaged in a bad merge.
        $broken = @'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <system.web>
    <compilation debug="false" targetFramework="4.8" />
    <httpRuntime targetFramework="4.8" />
    <customErrors mode="Off" />
</configuration>
'@
        Set-Content -Path 'C:\inetpub\alerts\web.config' -Value $broken -Encoding UTF8
    }
}

Write-Output 'Fault injected. Open a session and find out what is wrong.'
