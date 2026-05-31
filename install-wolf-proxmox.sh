#!/bin/bash
# Instalación de Wolf (Games on Whales) en Proxmox
# Máximo Rendimiento - AMD RX 580 | Ryzen 5 4500 | 16GB RAM
# IP Servidor: 192.168.40.42
# LXC ID: 200

echo ""
echo "╔═══════════════════════════════════════════════╗"
echo "║  Wolf (Games on Whales) - Instalador          ║"
echo "║  para Proxmox con GPU AMD                    ║"
echo "╚═══════════════════════════════════════════════╝"
echo ""

# Verificar que se ejecuta como root
if [ "$EUID" -ne 0 ]; then
  echo "ERROR: Ejecuta como root: sudo $0"
  exit 1
fi

# Verificar que es Proxmox
if [ ! -f /etc/pve/pve-enterprise.list ] && [ ! -f /etc/apt/sources.list.d/pve-enterprise.list ]; then
  echo "⚠ Esto no parece un servidor Proxmox. ¿Seguro que quieres continuar?"
fi

echo "=== PASO 1: Verificar GPU AMD ==="
echo "→ Buscando GPU AMD..."
RENDER_NODE=$(ls /dev/dri/renderD* 2>/dev/null | head -1)
if [ -n "$RENDER_NODE" ]; then
  echo "✓ GPU detectada: $RENDER_NODE"
  ls -la /dev/dri/
else
  echo "⚠ No se encontró /dev/dri/renderD*"
  echo "→ Verificando driver amdgpu..."
  if lsmod | grep -q amdgpu; then
    echo "✓ Driver amdgpu cargado. Esperando a que aparezca el nodo..."
    sleep 5
    RENDER_NODE=$(ls /dev/dri/renderD* 2>/dev/null | head -1)
    if [ -n "$RENDER_NODE" ]; then
      echo "✓ GPU detectada: $RENDER_NODE"
    else
      echo "⚠ El driver amdgpu está cargado pero no hay nodo render."
      echo "  Posibles causas: RX 580 no detectada, o usa otro driver (radeon)."
      echo "  Revisa: dmesg | grep -i amdgpu"
      echo "  Revisa: lspci -nnk | grep -A3 -i vga"
    fi
  else
    echo "⚠ Driver amdgpu NO cargado. Intentando cargarlo..."
    modprobe amdgpu 2>/dev/null && echo "✓ amdgpu cargado" || echo "⚠ No se pudo cargar amdgpu. ¿Está la RX 580 instalada?"
    sleep 3
    RENDER_NODE=$(ls /dev/dri/renderD* 2>/dev/null | head -1)
    if [ -n "$RENDER_NODE" ]; then
      echo "✓ GPU detectada: $RENDER_NODE"
    fi
  fi
fi
echo ""

cat > /etc/udev/rules.d/85-wolf-virtual-inputs.rules << 'EOF'
KERNEL=="uinput", SUBSYSTEM=="misc", MODE="0660", GROUP="input", OPTIONS+="static_node=uinput", TAG+="uaccess"
KERNEL=="uhid", GROUP="input", MODE="0660", TAG+="uaccess"
KERNEL=="hidraw*", ATTRS{name}=="Wolf PS5 (virtual) pad", GROUP="root", MODE="0660", ENV{ID_SEAT}="seat9"
SUBSYSTEMS=="input", ATTRS{name}=="Wolf X-Box One (virtual) pad", GROUP="root", MODE="0660", ENV{ID_SEAT}="seat9"
SUBSYSTEMS=="input", ATTRS{name}=="Wolf PS5 (virtual) pad", GROUP="root", MODE="0660", ENV{ID_SEAT}="seat9"
SUBSYSTEMS=="input", ATTRS{name}=="Wolf gamepad (virtual) motion sensors", GROUP="root", MODE="0660", ENV{ID_SEAT}="seat9"
SUBSYSTEMS=="input", ATTRS{name}=="Wolf Nintendo (virtual) pad", GROUP="root", MODE="0660", ENV{ID_SEAT}="seat9"
EOF

udevadm control --reload-rules && udevadm trigger

echo "=== PASO 2: Crear LXC Privilegiado ==="

# Verificar que el ID 200 no existe ya
if pct status 200 >/dev/null 2>&1; then
  echo "ERROR: El LXC 200 ya existe. Usa otro ID o elimínalo: pct destroy 200"
  exit 1
fi

# Detectar storage disponible
STORAGE=$(pvesm status | grep -v 'local ' | grep active | head -1 | awk '{print $1}')
if [ -z "$STORAGE" ]; then
  STORAGE="local"
fi
echo "✓ Usando storage: $STORAGE"

# Buscar o descargar template de Ubuntu 24.04
TEMPLATE=$(pveam available --section system | grep ubuntu-24.04 | head -1 | awk '{print $2}')
if [ -z "$TEMPLATE" ]; then
  echo "→ Actualizando lista de templates..."
  pveam update
  TEMPLATE=$(pveam available --section system | grep ubuntu-24.04 | head -1 | awk '{print $2}')
fi

if [ -z "$TEMPLATE" ]; then
  echo "ERROR: No se encontró template de Ubuntu 24.04. Verifica: pveam available --section system"
  exit 1
fi

echo "✓ Template: $TEMPLATE"
if [ ! -f "/var/lib/vz/template/cache/$TEMPLATE" ]; then
  echo "→ Descargando template..."
  pveam download "$STORAGE" "$TEMPLATE" || pveam download local "$TEMPLATE"
else
  echo "✓ Template ya descargado"
fi

echo "→ Creando LXC 200..."
pct create 200 "/var/lib/vz/template/cache/$TEMPLATE" \
  --hostname wolf-gaming \
  --memory 14336 \
  --cores 6 \
  --rootfs "$STORAGE":64 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --unprivileged 0 \
  --features fuse=1,nesting=1 || {
    echo "ERROR: Falló al crear LXC. ¿Ya existe? Prueba: pct destroy 200"
    exit 1
  }

echo "=== PASO 3: Configurar GPU en LXC ==="
if [ ! -f /etc/pve/lxc/200.conf ]; then
  echo "ERROR: No se encontró /etc/pve/lxc/200.conf"
  exit 1
fi

cat >> /etc/pve/lxc/200.conf << 'EOF'

# Wolf - GPU devices
dev0: /dev/uinput
dev1: /dev/uhid
lxc.cgroup2.devices.allow: a
lxc.cap.drop:
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
lxc.mount.entry: /run/udev mnt/udev none bind,optional,create=dir
lxc.mount.entry: /dev mnt/dev none bind,optional,create=dir
EOF

echo "✓ Configuración GPU añadida a LXC 200"

echo "=== PASO 4: Iniciar LXC ==="
pct start 200 && sleep 10 && echo "✓ LXC 200 iniciado" || {
  echo "ERROR: No se pudo iniciar LXC 200. Revisa: pct status 200"
  exit 1
}

echo "=== PASO 5: Instalar Docker en LXC ==="
pct exec 200 -- bash -c '
set -e
echo "→ Instalando dependencias..."
apt update -qq
apt install -y -qq ca-certificates curl gnupg

echo "→ Configurando repositorio Docker..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

echo "→ Instalando Docker..."
apt update -qq
apt install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable --now docker
echo "✓ Docker instalado"
' && echo "✓ Docker instalado en LXC" || {
  echo "ERROR: Falló instalación de Docker. Entra al LXC: pct enter 200"
  exit 1
}

echo "=== PASO 6: Configurar Wolf ==="
pct exec 200 -- bash -c '
mkdir -p /etc/wolf/cfg /opt/wolf

UUID=$(cat /proc/sys/kernel/random/uuid)

cat > /etc/wolf/cfg/config.toml << EOFCONF
hostname = "wolf"
support_hevc = true
config_version = 2
uuid = "${UUID}"
paired_clients = []
profiles = []
gstreamer = {}
EOFCONF

cat > /opt/wolf/docker-compose.yml << 'EOFDC'
version: "3"
services:
  wolf:
    image: ghcr.io/games-on-whales/wolf:stable
    environment:
      - WOLF_LOG_LEVEL=DEBUG
    volumes:
      - /etc/wolf/:/etc/wolf
      - /var/run/docker.sock:/var/run/docker.sock:rw
      - /mnt/dev:/dev:rw
      - /mnt/udev:/run/udev:rw
    device_cgroup_rules:
      - "c 13:* rmw"
    devices:
      - /dev/dri
      - /dev/uinput
      - /dev/uhid
    network_mode: host
    restart: unless-stopped
EOFDC
'

echo "=== PASO 7: Iniciar Wolf ==="
pct exec 200 -- bash -c 'cd /opt/wolf && docker compose up -d'
sleep 5

echo "=== PASO 8: Verificar instalación ==="
echo "→ Estado de Wolf:"
pct exec 200 -- bash -c 'cd /opt/wolf && docker compose ps' 2>/dev/null || echo "⚠ Wolf no está corriendo. Revisa: pct enter 200 && docker compose -f /opt/wolf/docker-compose.yml logs"

echo ""
echo "=========================================="
echo "  INSTALACIÓN COMPLETADA"
echo "=========================================="
echo ""
echo "Wolf Web UI:  http://192.168.40.42:47989"
echo ""
echo "=== VER LOGS ==="
echo "  pct exec 200 -- docker compose -f /opt/wolf/docker-compose.yml logs -f"
echo "  # O dentro del LXC: docker logs -f wolf"
echo ""
echo "=== EMPAREJAR MOONLIGHT ==="
echo "  1. Abre Moonlight y añade servidor: 192.168.40.42"
echo "  2. Te pedirá un PIN"
echo "  3. Obtén el link de pairing:"
echo "     pct exec 200 -- docker logs wolf 2>&1 | grep -o 'http[^ ]*pin/[^ ]*'"
echo "     # Ejemplo: http://192.168.40.42:47989/pin/#337327E8A6FC0C66"
echo "  4. Abre ese link en un navegador e ingresa el PIN"
echo ""
echo "=== ALIAS RECOMENDADOS (agrega a ~/.bashrc) ==="
echo "  alias wolf-logs='pct exec 200 -- docker compose -f /opt/wolf/docker-compose.yml logs -f'"
echo "  alias wolf-pin='pct exec 200 -- docker logs wolf 2>&1 | grep -o \"http[^ ]*pin/[^ ]*\" | head -1'"
echo ""
echo "=========================================="
