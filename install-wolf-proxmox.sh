#!/bin/bash
# Instalación de Wolf (Games on Whales) en Proxmox
# Máximo Rendimiento - AMD RX 580 | Ryzen 5 4500 | 16GB RAM
# IP Servidor: 192.168.40.42
# LXC ID: 200

set -e

echo "=== PASO 1: Preparar Host Proxmox ==="
apt update
apt install -y firmware-amd-graphics

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
TEMPLATE=$(pveam available --section system | grep ubuntu-24.04 | head -1 | awk '{print $2}')
if [ -z "$TEMPLATE" ]; then
  echo "ERROR: No se encontró template. Ejecuta: pveam update"
  exit 1
fi

pveam download local "$TEMPLATE"

pct create 200 /var/lib/vz/template/cache/"$TEMPLATE" \
  --hostname wolf-gaming \
  --memory 14336 \
  --cores 6 \
  --rootfs local-lvm:64 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --unprivileged 0 \
  --features fuse=1,nesting=1

echo "=== PASO 3: Configurar GPU en LXC ==="
cat > /etc/pve/lxc/200.conf << 'EOF'
dev0: /dev/uinput
dev1: /dev/uhid
lxc.cgroup2.devices.allow: a
lxc.cap.drop:
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
lxc.mount.entry: /run/udev mnt/udev none bind,optional,create=dir
lxc.mount.entry: /dev mnt/dev none bind,optional,create=dir
EOF

echo "=== PASO 4: Iniciar LXC ==="
pct start 200
sleep 10

echo "=== PASO 5: Instalar Docker en LXC ==="
pct exec 200 -- bash -c '
apt update
apt install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable --now docker
'

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
      - /dev/:/dev/:rw
      - /run/udev:/run/udev:rw
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
