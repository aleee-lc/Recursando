#!/usr/bin/env bash
set -euo pipefail

# ===========================
# Tarea 2: DHCP - Servidor Linux
# ===========================

# Mensajes y control basico
log() { printf '%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    err "Ejecuta este script como root (sudo)."
    exit 1
  fi
}

# Validaciones IPv4
is_valid_ipv4() {
  local ip=$1
  if [[ ! $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    return 1
  fi
  IFS='.' read -r o1 o2 o3 o4 <<<"$ip"
  for o in $o1 $o2 $o3 $o4; do
    if ((o < 0 || o > 255)); then
      return 1
    fi
  done
  return 0
}

ipv4_to_int() {
  IFS='.' read -r a b c d <<<"$1"
  echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

int_to_ipv4() {
  local ip_int=$1
  printf '%d.%d.%d.%d' \
    $(( (ip_int >> 24) & 255 )) \
    $(( (ip_int >> 16) & 255 )) \
    $(( (ip_int >> 8) & 255 )) \
    $(( ip_int & 255 ))
}

cidr_to_mask() {
  local cidr=$1
  local mask=$(( 0xFFFFFFFF << (32 - cidr) & 0xFFFFFFFF ))
  int_to_ipv4 "$mask"
}

network_address() {
  local ip=$1
  local cidr=$2
  local ip_int
  local mask
  ip_int=$(ipv4_to_int "$ip")
  mask=$(( 0xFFFFFFFF << (32 - cidr) & 0xFFFFFFFF ))
  int_to_ipv4 $(( ip_int & mask ))
}

ip_in_subnet() {
  local ip=$1
  local net=$2
  local cidr=$3
  local ip_int
  local net_int
  local mask
  ip_int=$(ipv4_to_int "$ip")
  net_int=$(ipv4_to_int "$net")
  mask=$(( 0xFFFFFFFF << (32 - cidr) & 0xFFFFFFFF ))
  [[ $(( ip_int & mask )) -eq $(( net_int & mask )) ]]
}

# Lectura de parametros
read_cidr() {
  local default="192.168.100.0/24"
  local input
  local ip
  local cidr
  while true; do
    read -r -p "Segmento de red (CIDR) [$default]: " input
    input=${input:-$default}
    if [[ $input =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[1-2][0-9]|3[0-2])$ ]]; then
      ip=${input%/*}
      cidr=${input#*/}
      if is_valid_ipv4 "$ip"; then
        echo "$ip/$cidr"
        return 0
      fi
    fi
    log "Valor invalido. Ejemplo: 192.168.100.0/24"
  done
}

read_ipv4() {
  local prompt=$1
  local ip
  while true; do
    read -r -p "$prompt: " ip
    if is_valid_ipv4 "$ip"; then
      echo "$ip"
      return 0
    fi
    log "IP invalida. Intenta de nuevo."
  done
}

read_range() {
  local net=$1
  local cidr=$2
  local start
  local end
  while true; do
    start=$(read_ipv4 "Rango inicial")
    end=$(read_ipv4 "Rango final")
    if ! ip_in_subnet "$start" "$net" "$cidr" || ! ip_in_subnet "$end" "$net" "$cidr"; then
      log "Las IPs deben pertenecer al segmento $net/$cidr"
      continue
    fi
    if (( $(ipv4_to_int "$start") > $(ipv4_to_int "$end") )); then
      log "El rango inicial no puede ser mayor al final"
      continue
    fi
    echo "$start|$end"
    return 0
  done
}

read_lease_hours() {
  local input
  while true; do
    read -r -p "Tiempo de concesion en horas [24]: " input
    input=${input:-24}
    if [[ $input =~ ^[0-9]+$ ]] && (( input > 0 )); then
      echo "$input"
      return 0
    fi
    log "Valor invalido. Usa un numero entero positivo."
  done
}

select_interface() {
  mapfile -t ifaces < <(ip -o -4 addr show up | awk '{print $2}' | sort -u)
  if [ ${#ifaces[@]} -eq 0 ]; then
    read -r -p "No se detecto interfaz activa. Escribe el nombre de la interfaz: " iface
    echo "$iface"
    return 0
  fi

  log "Interfaces activas detectadas:"
  local i=1
  for iface in "${ifaces[@]}"; do
    log " $i) $iface"
    i=$((i + 1))
  done

  local choice
  while true; do
    read -r -p "Selecciona interfaz [1]: " choice
    choice=${choice:-1}
    if [[ $choice =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#ifaces[@]} )); then
      echo "${ifaces[$((choice - 1))]}"
      return 0
    fi
    log "Seleccion invalida."
  done
}

# Instalacion y configuracion
ensure_installed() {
  if dpkg -s isc-dhcp-server >/dev/null 2>&1; then
    log "isc-dhcp-server ya esta instalado."
    return 0
  fi
  log "Instalando isc-dhcp-server..."
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y isc-dhcp-server
}

set_interfacesv4() {
  local iface=$1
  local file="/etc/default/isc-dhcp-server"
  if grep -q '^INTERFACESv4=' "$file" 2>/dev/null; then
    sed -i "s/^INTERFACESv4=.*/INTERFACESv4=\"$iface\"/" "$file"
  else
    echo "INTERFACESv4=\"$iface\"" >> "$file"
  fi
}

write_config() {
  local scope_name=$1
  local net=$2
  local cidr=$3
  local range_start=$4
  local range_end=$5
  local lease_seconds=$6
  local gateway=$7
  local dns=$8
  local netmask
  netmask=$(cidr_to_mask "$cidr")

  cat > /etc/dhcp/dhcpd.conf <<EOF
# ==========================================
# DHCP Server - Configuracion automatizada
# Ambito: $scope_name
# Archivo: /etc/dhcp/dhcpd.conf
# ==========================================

default-lease-time $lease_seconds;
max-lease-time $lease_seconds;
authoritative;

subnet $net netmask $netmask {
  range $range_start $range_end;
  option routers $gateway;
  option domain-name-servers $dns;
  option subnet-mask $netmask;
}
EOF
}

validate_config() {
  dhcpd -t -cf /etc/dhcp/dhcpd.conf
}

restart_service() {
  systemctl enable --now isc-dhcp-server
  systemctl restart isc-dhcp-server
}

# Monitoreo
show_status() {
  log "Estado del servicio:"
  systemctl --no-pager --full status isc-dhcp-server | sed -n '1,10p'
}

show_leases() {
  local leases_file="/var/lib/dhcp/dhcpd.leases"
  log "Concesiones activas:"
  if [ ! -f "$leases_file" ]; then
    log " - No se encontro $leases_file"
    return 0
  fi

  awk '
    /^lease / { ip=$2 }
    /binding state active/ { active=1 }
    /hardware ethernet/ { mac=$3 }
    /client-hostname/ {
      gsub(/[";]/, "", $2);
      hostname=$2
    }
    /ends / { ends=$2" "$3 }
    /^}/ {
      if (active) {
        printf " - IP: %s | MAC: %s | Hostname: %s | Expira: %s\n", ip, mac, hostname, ends
      }
      active=0; mac=""; hostname=""; ends=""
    }
  ' "$leases_file"
}

main() {
  require_root
  log "=== Tarea 2: Automatizacion DHCP (Linux) ==="

  ensure_installed

  local scope_name
  local cidr_input
  local net_ip
  local cidr
  local net
  local range
  local range_start
  local range_end
  local lease_hours
  local lease_seconds
  local gateway
  local dns
  local iface

  read -r -p "Nombre descriptivo del ambito (Scope): " scope_name
  scope_name=${scope_name:-"Scope-DHCP"}

  cidr_input=$(read_cidr)
  net_ip=${cidr_input%/*}
  cidr=${cidr_input#*/}
  net=$(network_address "$net_ip" "$cidr")
  if [ "$net_ip" != "$net" ]; then
    log "Nota: se ajusto la red a $net/$cidr"
  fi

  range=$(read_range "$net" "$cidr")
  range_start=${range%|*}
  range_end=${range#*|}

  lease_hours=$(read_lease_hours)
  lease_seconds=$((lease_hours * 3600))

  gateway=$(read_ipv4 "Puerta de enlace (Gateway)")
  if ! ip_in_subnet "$gateway" "$net" "$cidr"; then
    err "La puerta de enlace no pertenece al segmento $net/$cidr"
    exit 1
  fi

  dns=$(read_ipv4 "DNS (IP del servidor de la practica 1)")
  if ! ip_in_subnet "$dns" "$net" "$cidr"; then
    err "El DNS no pertenece al segmento $net/$cidr"
    exit 1
  fi

  iface=$(select_interface)

  write_config "$scope_name" "$net" "$cidr" "$range_start" "$range_end" "$lease_seconds" "$gateway" "$dns"
  set_interfacesv4 "$iface"

  log "Validando configuracion..."
  validate_config

  log "Reiniciando servicio..."
  restart_service

  show_status
  show_leases

  log "Listo."
}

main "$@"
