#requires -Version 5.1

# ===========================
# Tarea 2: DHCP - Cliente Windows
# ===========================

function Write-Section {
  param([string]$Title)
  Write-Host ""
  Write-Host ("=== {0} ===" -f $Title)
}

function Assert-Admin {
  $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Ejecuta este script como Administrador."
  }
}

function Renew-ClientDhcp {
  Write-Section 'Liberar y renovar IP'
  ipconfig /release | Out-Null
  ipconfig /renew | Out-Null
  ipconfig /all
}

Assert-Admin
Renew-ClientDhcp
