#requires -Version 5.1

# ===========================
# Diagnostico del sistema
# ===========================

# Definir rol del nodo
$role = 'Servidor Windows'

# Obtener nombre del equipo
$hostname = $env:COMPUTERNAME

# Obtener indices de interfaces IPv4 conectadas
$upInterfaces = Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue |
  Where-Object { $_.ConnectionState -eq 'Connected' } |
  Select-Object -ExpandProperty InterfaceIndex

# Obtener IPv4 activas validas (sin loopback ni 169.x.x.x)
$ipv4List = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
  Where-Object {
    $upInterfaces -contains $_.InterfaceIndex -and
    $_.IPAddress -notmatch '^169\.' -and
    $_.IPAddress -notmatch '^127\.'
  } |
  Select-Object -ExpandProperty IPAddress -Unique |
  Sort-Object

# Obtener espacio disponible en el disco del sistema
$systemDrive = ($env:SystemDrive).TrimEnd(':')
$drive = Get-PSDrive -Name $systemDrive -ErrorAction SilentlyContinue
$freeGb = if ($null -ne $drive) { [math]::Round($drive.Free / 1GB, 2) } else { $null }

# Mostrar resultados
Write-Host ("=== Diagnostico - {0} ===" -f $role)
Write-Host ("Nombre del equipo: {0}" -f $hostname)

Write-Host "Direcciones IPv4 activas:"
if ($ipv4List -and $ipv4List.Count -gt 0) {
  $ipv4List | ForEach-Object { Write-Host (" - {0}" -f $_) }
} else {
  Write-Host " - No se detectaron IPv4 activas"
}

if ($null -ne $freeGb) {
  Write-Host ("Espacio en disco disponible: {0} GB en {1}:" -f $freeGb, $systemDrive)
} else {
  Write-Host "Espacio en disco disponible: No se pudo determinar"
}
