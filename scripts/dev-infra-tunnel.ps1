<#
.SYNOPSIS
    Opens an SSH tunnel from this machine to the Ragenta dev-infra VM.

.DESCRIPTION
    Forwards the infrastructure ports so that localhost on this machine reaches
    the VM's containers. With the tunnel up, ragenta-backend keeps using
    localhost connection strings and nothing has to run in Docker locally.

    Runs in the foreground; press Ctrl+C to close the tunnel.

.EXAMPLE
    .\dev-infra-tunnel.ps1 -VmHost 203.0.113.10 -User ubuntu

.EXAMPLE
    .\dev-infra-tunnel.ps1 -VmHost ragenta-dev -Ports 5432,6379
    # 'ragenta-dev' being a Host entry in ~/.ssh/config
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$VmHost,

    [string]$User,

    [string]$IdentityFile,

    # postgres, redis, minio api, minio console, qdrant
    [int[]]$Ports = @(5432, 6379, 9000, 9001, 6333)
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
    throw "ssh was not found. Install the Windows OpenSSH client or run this from Git Bash."
}

$busy = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
    Where-Object { $Ports -contains $_.LocalPort } |
    Select-Object -ExpandProperty LocalPort -Unique

if ($busy) {
    throw "Port(s) $($busy -join ', ') are already in use locally. Stop the local Docker stack (docker compose down in ragenta-backend) or pass a shorter -Ports list."
}

$target = if ($User) { "$User@$VmHost" } else { $VmHost }

$sshArgs = @('-N', '-o', 'ExitOnForwardFailure=yes', '-o', 'ServerAliveInterval=30')
if ($IdentityFile) { $sshArgs += @('-i', $IdentityFile) }
foreach ($port in $Ports) { $sshArgs += @('-L', "127.0.0.1:${port}:127.0.0.1:${port}") }
$sshArgs += $target

Write-Host "Tunnelling $($Ports -join ', ') to $target - Ctrl+C to close."
& ssh @sshArgs
