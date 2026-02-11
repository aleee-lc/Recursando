#!/usr/bin/env bash
set -euo pipefail

# ===========================
# Diagnostico del sistema
# ===========================

# Obtener nombre del equipo
HOSTNAME=$(hostname)

# Obtener IPv4 activas (excluye loopback y direcciones sin uso)
mapfile -t IPV4_LIST < <(ip -o -4 addr show up scope global | awk '{print $4}' | cut -d/ -f1)

# Obtener espacio disponible en la particion raiz
DISK_INFO=$(df -h --output=avail,target / | awk 'NR==2 {print $1 " disponibles en " $2}')

# Mostrar resultados

echo "=== Diagnostico - Servidor Linux ==="
printf "Nombre del equipo: %s\n" "$HOSTNAME"

echo "Direcciones IPv4 activas:"
if [ ${#IPV4_LIST[@]} -eq 0 ]; then
  echo " - No se detectaron IPv4 activas"
else
  for ip in "${IPV4_LIST[@]}"; do
    echo " - $ip"
  done
fi

printf "Espacio en disco disponible: %s\n" "$DISK_INFO"
