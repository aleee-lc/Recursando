#requires -Version 5.1

# ===========================
# Tarea 2: DHCP - Servidor Windows
# ===========================

# Mensajes y control basico
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

# Validaciones IPv4
function Test-IPv4 {
  param([string]$Ip)
  $addr = $null
  if (-not [System.Net.IPAddress]::TryParse($Ip, [ref]$addr)) { return $false }
  return $addr.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
}

function Convert-IPv4ToUInt32 {
  param([string]$Ip)
  $bytes = [System.Net.IPAddress]::Parse($Ip).GetAddressBytes()
  [Array]::Reverse($bytes)
  return [BitConverter]::ToUInt32($bytes, 0)
}

function Convert-UInt32ToIPv4 {
  param([UInt32]$Value)
  $bytes = [BitConverter]::GetBytes($Value)
  [Array]::Reverse($bytes)
  return ($bytes -join '.')
}

function Convert-CidrToMaskInt {
  param([int]$Cidr)
  $mask = [UInt32]0
  for ($i = 0; $i -lt $Cidr; $i++) {
    $mask = $mask -bor ([UInt32]1 -shl (31 - $i))
  }
  return $mask
}

function Convert-CidrToMaskString {
  param([int]$Cidr)
  return (Convert-UInt32ToIPv4 -Value (Convert-CidrToMaskInt -Cidr $Cidr))
}

function Get-NetworkAddress {
  param([string]$Ip, [int]$Cidr)
  $mask = Convert-CidrToMaskInt -Cidr $Cidr
  $ipInt = Convert-IPv4ToUInt32 -Ip $Ip
  $netInt = $ipInt -band $mask
  return (Convert-UInt32ToIPv4 -Value $netInt)
}

function Test-IpInSubnet {
  param([string]$Ip, [string]$Network, [int]$Cidr)
  $mask = Convert-CidrToMaskInt -Cidr $Cidr
  $ipInt = Convert-IPv4ToUInt32 -Ip $Ip
  $netInt = Convert-IPv4ToUInt32 -Ip $Network
  return (($ipInt -band $mask) -eq ($netInt -band $mask))
}

# Lectura de parametros
function Read-IPv4 {
  param([string]$Prompt)
  while ($true) {
    $ip = Read-Host $Prompt
    if (Test-IPv4 $ip) { return $ip }
    Write-Host "IP invalida. Intenta de nuevo."
  }
}

function Read-Cidr {
  $default = '192.168.100.0/24'
  while ($true) {
    $input = Read-Host "Segmento de red (CIDR) [$default]"
    if ([string]::IsNullOrWhiteSpace($input)) { $input = $default }
    if ($input -match '^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[1-2][0-9]|3[0-2])$') {
      $ip = $input.Split('/')[0]
      $cidr = [int]$input.Split('/')[1]
      if (Test-IPv4 $ip) { return @($ip, $cidr) }
    }
    Write-Host "Valor invalido. Ejemplo: 192.168.100.0/24"
  }
}

function Read-Range {
  param([string]$Network, [int]$Cidr)
  while ($true) {
    $start = Read-IPv4 'Rango inicial'
    $end = Read-IPv4 'Rango final'
    if (-not (Test-IpInSubnet -Ip $start -Network $Network -Cidr $Cidr) -or
        -not (Test-IpInSubnet -Ip $end -Network $Network -Cidr $Cidr)) {
      Write-Host ("Las IPs deben pertenecer al segmento {0}/{1}" -f $Network, $Cidr)
      continue
    }
    if ((Convert-IPv4ToUInt32 $start) -gt (Convert-IPv4ToUInt32 $end)) {
      Write-Host "El rango inicial no puede ser mayor al final"
      continue
    }
    return @($start, $end)
  }
}

function Read-LeaseHours {
  while ($true) {
    $input = Read-Host 'Tiempo de concesion en horas [24]'
    if ([string]::IsNullOrWhiteSpace($input)) { $input = '24' }
    if ($input -match '^[0-9]+$' -and [int]$input -gt 0) { return [int]$input }
    Write-Host "Valor invalido. Usa un numero entero positivo."
  }
}

# Instalacion y configuracion
function Ensure-DhcpInstalled {
  $feature = Get-WindowsFeature -Name DHCP
  if (-not $feature.Installed) {
    Write-Host "Instalando rol DHCP..."
    Install-WindowsFeature -Name DHCP -IncludeManagementTools | Out-Null
  } else {
    Write-Host "Rol DHCP ya esta instalado."
  }
  Import-Module DhcpServer
}

function Configure-DhcpScope {
  param(
    [string]$ScopeName,
    [string]$Network,
    [int]$Cidr,
    [string]$StartRange,
    [string]$EndRange,
    [int]$LeaseHours,
    [string]$Gateway,
    [string]$Dns
  )

  $mask = Convert-CidrToMaskString -Cidr $Cidr
  $scopeId = Get-NetworkAddress -Ip $Network -Cidr $Cidr
  $lease = New-TimeSpan -Hours $LeaseHours

  $existing = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue | Where-Object { $_.ScopeId -eq $scopeId }
  if ($null -eq $existing) {
    Add-DhcpServerv4Scope -Name $ScopeName -StartRange $StartRange -EndRange $EndRange -SubnetMask $mask -State Active -LeaseDuration $lease | Out-Null
  } else {
    Set-DhcpServerv4Scope -ScopeId $scopeId -Name $ScopeName -StartRange $StartRange -EndRange $EndRange -State Active -LeaseDuration $lease | Out-Null
  }

  Set-DhcpServerv4OptionValue -ScopeId $scopeId -Router $Gateway -DnsServer $Dns | Out-Null

  return $scopeId
}

# Monitoreo
function Show-DhcpStatus {
  Write-Section 'Estado del servicio DHCP'
  $svc = Get-Service -Name DHCPServer -ErrorAction SilentlyContinue
  if ($null -eq $svc) {
    Write-Host 'Servicio DHCPServer no encontrado.'
  } else {
    Write-Host ("Estado: {0}" -f $svc.Status)
  }
}

function Show-DhcpLeases {
  param([string]$ScopeId)
  Write-Section 'Concesiones activas'
  $leases = Get-DhcpServerv4Lease -ScopeId $ScopeId -ErrorAction SilentlyContinue
  if ($leases) {
    $leases | Select-Object IPAddress, ClientId, HostName, AddressState, LeaseExpiryTime | Format-Table -AutoSize
  } else {
    Write-Host 'No hay concesiones activas.'
  }
}

# Flujo principal
function Main {
  Assert-Admin

  Write-Section 'Tarea 2: Automatizacion DHCP (Windows Server)'
  Ensure-DhcpInstalled

  $scopeName = Read-Host 'Nombre descriptivo del ambito (Scope)'
  if ([string]::IsNullOrWhiteSpace($scopeName)) { $scopeName = 'Scope-DHCP' }

  $cidrResult = Read-Cidr
  $netIp = $cidrResult[0]
  $cidr = $cidrResult[1]
  $network = Get-NetworkAddress -Ip $netIp -Cidr $cidr
  if ($netIp -ne $network) {
    Write-Host ("Nota: se ajusto la red a {0}/{1}" -f $network, $cidr)
  }

  $range = Read-Range -Network $network -Cidr $cidr
  $rangeStart = $range[0]
  $rangeEnd = $range[1]

  $leaseHours = Read-LeaseHours

  $gateway = Read-IPv4 'Puerta de enlace (Gateway)'
  if (-not (Test-IpInSubnet -Ip $gateway -Network $network -Cidr $cidr)) {
    throw ("La puerta de enlace no pertenece al segmento {0}/{1}" -f $network, $cidr)
  }

  $dns = Read-IPv4 'DNS (IP del servidor de la practica 1)'
  if (-not (Test-IpInSubnet -Ip $dns -Network $network -Cidr $cidr)) {
    throw ("El DNS no pertenece al segmento {0}/{1}" -f $network, $cidr)
  }

  $scopeId = Configure-DhcpScope -ScopeName $scopeName -Network $network -Cidr $cidr -StartRange $rangeStart -EndRange $rangeEnd -LeaseHours $leaseHours -Gateway $gateway -Dns $dns

  Start-Service -Name DHCPServer -ErrorAction SilentlyContinue | Out-Null
  Show-DhcpStatus
  Show-DhcpLeases -ScopeId $scopeId
}

Main
