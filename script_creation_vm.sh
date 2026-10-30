#!/bin/bash
set -Eeuo pipefail
export LC_ALL=C

# Configuration validée pour iris
LIBVIRT='qemu:///system'
VM='eisi-jacquemin-j3-srv01'
VM_USER='louise.jacquemin'

CPU=2
RAM=2048
DISK_GB=10

NET='eisi-jacquemin-net249'
BRIDGE='virbr249'
IP_VM='192.168.249.10'
GW='192.168.249.254'
DHCP_START='192.168.249.150'
DHCP_END='192.168.249.200'

BASE='/home/iris/eisi/louise.jacquemin'
POOL='pool-eisi-jacquemin-srv01'
POOL_DIR="$BASE/stockage/stockage-srv01"
ISO_DIR="$BASE/iso/iso-srv01"
IMAGE_DIR="$BASE/images"
IMAGE_NAME='debian-13-genericcloud-amd64.qcow2'
IMAGE_URL="https://cloud.debian.org/images/cloud/trixie/latest/$IMAGE_NAME"
SUMS_URL='https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS'
IMAGE="$IMAGE_DIR/$IMAGE_NAME"

# Nouveau volume 
VOLUME="$VM-v2.qcow2"
DISK="$POOL_DIR/$VOLUME"
MARKER="$BASE/$VM-v2.import-ok"
SEED="$ISO_DIR/$VM-seed.iso"

SSH_KEY="$BASE/ssh/srv01.pub"

INSTANCE_ID="$VM-001"
MODE="${1:---plan}"

log() { echo "[INFO] $*"; }
fail() { echo "[ERREUR] $*" >&2; exit 1; }
lv() { virsh -c "$LIBVIRT" "$@"; }

case "$MODE" in
    --plan|--deploy|--stop-after-pool) ;;
    *) fail 'Usage : script_creation_vm_corrige.sh [--plan|--deploy|--stop-after-pool]' ;;
esac

plan() {
    cat <<EOF
PLAN (aucune modification)
VM : $VM ($CPU vCPU, $RAM Mio, $DISK_GB Gio)
Utilisateur : $VM_USER
Réseau NAT : $NET / $BRIDGE
IP : $IP_VM/24 ; passerelle : $GW
DHCP : $DHCP_START - $DHCP_END
Pool : $POOL ($POOL_DIR)
Image : $IMAGE_URL (SHA-512)
Nouveau disque : $DISK
Ancien disque préservé : $POOL_DIR/$VM.qcow2
ISO cloud-init : $SEED
Clé publique : $SSH_KEY
EOF
}

if [[ "$MODE" == '--plan' ]]; then
    plan
    exit 0
fi

for cmd in virsh virt-install qemu-img xorriso curl sha512sum python3 stat awk id getent ip mktemp install; do
    command -v "$cmd" >/dev/null || fail "Commande absente : $cmd"
done
[[ -s "$SSH_KEY" ]] || fail 'Clé publique SSH absente'
[[ -d "$ISO_DIR" && -w "$ISO_DIR" ]] || fail 'Répertoire ISO inaccessible'
[[ -d "$IMAGE_DIR" && -w "$IMAGE_DIR" ]] || fail 'Répertoire images inaccessible'
[[ -d "$BASE" && -w "$BASE" ]] || fail 'Répertoire BASE inaccessible'
[[ ! -e "$POOL_DIR" || -d "$POOL_DIR" ]] || fail 'Chemin du pool invalide'
QEMU_GID=$(getent group libvirt-qemu | awk -F: '{print $3}')
[[ "$QEMU_GID" =~ ^[0-9]+$ ]] || fail 'Groupe libvirt-qemu introuvable'
USER_UID=$(id -u)
lv list --all >/dev/null
lv net-list --all >/dev/null
lv pool-list --all >/dev/null
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Vérification structurée des champs essentiels 
check_xml() {
    local kind="$1" file="$2"
    python3 - "$kind" "$file" "$BRIDGE" "$GW" "$DHCP_START" "$DHCP_END" "$POOL_DIR" "$CPU" "$RAM" "$DISK" "$SEED" "$NET" <<'PY'
import sys, xml.etree.ElementTree as ET
kind,path,bridge,gw,start,end,pooldir,cpu,ram,disk,seed,net=sys.argv[1:]
r=ET.parse(path).getroot()
def check(ok,msg):
    if not ok: sys.exit('Configuration différente : '+msg)
if kind=='network':
    f,b,ip=r.find('forward'),r.find('bridge'),r.find('ip')
    d=ip.find('dhcp/range') if ip is not None else None
    check(f is not None and f.get('mode')=='nat','NAT')
    check(b is not None and b.get('name')==bridge,'bridge')
    check(ip is not None and ip.get('address')==gw and ip.get('netmask')=='255.255.255.0','passerelle')
    check(d is not None and d.get('start')==start and d.get('end')==end,'DHCP')
elif kind=='pool':
    check(r.get('type')=='dir' and r.findtext('target/path')==pooldir,'pool')
elif kind=='vm':
    check(int(r.findtext('vcpu'))==int(cpu),'CPU')
    m=r.find('memory'); units={'KiB':1,'MiB':1024,'GiB':1048576}
    check(m is not None and int(m.text)*units.get(m.get('unit','KiB'),-1)==int(ram)*1024,'RAM')
    disks=[x.get('file') for x in r.findall('./devices/disk/source')]
    networks=[x.get('network') for x in r.findall('./devices/interface/source')]
    check(disk in disks and seed in disks and net in networks,'disque/ISO/réseau')
PY
}

check_existing() {
    if lv net-info "$NET" >/dev/null 2>&1; then
        lv net-dumpxml "$NET" > "$TMP/network.xml"
        check_xml network "$TMP/network.xml" || fail 'Réseau différent'
    elif ip link show "$BRIDGE" >/dev/null 2>&1; then
        fail "Pont $BRIDGE déjà utilisé"
    fi
    if lv pool-info "$POOL" >/dev/null 2>&1; then
        lv pool-dumpxml "$POOL" > "$TMP/pool.xml"
        check_xml pool "$TMP/pool.xml" || fail 'Pool différent'
    fi
    if lv dominfo "$VM" >/dev/null 2>&1; then
        lv dumpxml "$VM" > "$TMP/vm.xml"
        check_xml vm "$TMP/vm.xml" || fail 'VM existante avec un autre disque ou une autre configuration'
        [[ -f "$MARKER" && -f "$DISK" && -f "$SEED" ]] || fail 'VM existante : fichiers de suivi manquants'
    fi
    [[ ! -e "$DISK" || -f "$MARKER" ]] || fail 'Nouveau volume existant sans marqueur : arrêt de sécurité'
    [[ ! -f "$MARKER" || -f "$DISK" ]] || fail 'Marqueur présent mais disque absent'
    [[ ! -e "$SEED" || -f "$MARKER" ]] || fail 'ISO préexistant : vérifier manuellement avant de continuer'
}

create_network() {
    if ! lv net-info "$NET" >/dev/null 2>&1; then
        cat > "$TMP/network-new.xml" <<EOF
<network>
  <name>$NET</name>
  <forward mode='nat'/>
  <bridge name='$BRIDGE'/>
  <ip address='$GW' netmask='255.255.255.0'>
    <dhcp><range start='$DHCP_START' end='$DHCP_END'/></dhcp>
  </ip>
</network>
EOF
        lv net-define "$TMP/network-new.xml"
    fi
    local state
    state=$(lv net-info "$NET" | awk '/^Active:/ {print $2}')
    case "$state" in
        no) lv net-start "$NET" ;;
        yes) ;;
        *) fail "État réseau inattendu : $state" ;;
    esac
    lv net-autostart "$NET"
    log 'Réseau NAT prêt'
}

create_pool() {
    if ! lv pool-info "$POOL" >/dev/null 2>&1; then
        lv pool-define-as "$POOL" dir --target "$POOL_DIR"
    fi
    if [[ ! -d "$POOL_DIR" ]]; then
        lv pool-build "$POOL"
    fi
    local state
    state=$(lv pool-info "$POOL" | awk '/^State:/ {print $2}')
    if [[ "$state" != running ]]; then
        lv pool-start "$POOL"
    fi
    lv pool-autostart "$POOL"
    log 'Pool prêt'
}

get_image() {
    if [[ ! -s "$IMAGE" ]]; then
        curl -fL --retry 3 "$IMAGE_URL" -o "$IMAGE.part"
        mv "$IMAGE.part" "$IMAGE"
    fi
    curl -fL --retry 3 "$SUMS_URL" -o "$TMP/SHA512SUMS"
    awk -v n="$IMAGE_NAME" '$2==n || $2=="*"n {print}' "$TMP/SHA512SUMS" > "$TMP/check.sha512"
    [[ -s "$TMP/check.sha512" ]] || fail 'Empreinte SHA-512 introuvable'
    (cd "$IMAGE_DIR" && sha512sum --check "$TMP/check.sha512") || fail 'SHA-512 incorrect'
    cp "$TMP/SHA512SUMS" "$IMAGE_DIR/SHA512SUMS"
    [[ "$(qemu-img info --output=json "$IMAGE" | python3 -c 'import json,sys;print(json.load(sys.stdin)["format"])')" == qcow2 ]] || fail 'Image non QCOW2'
    log 'Image Debian vérifiée (SHA-512)'
}

create_disk() {
    local virtual_size target_size actual_size source_hash disk_hash
    virtual_size=$(qemu-img info --output=json "$IMAGE" | python3 -c 'import json,sys;print(json.load(sys.stdin)["virtual-size"])')
    target_size=$((DISK_GB * 1024 * 1024 * 1024))
    (( target_size >= virtual_size )) || fail 'Disque cible trop petit'
    source_hash=$(sha512sum "$IMAGE" | awk '{print $1}')

    if [[ ! -f "$MARKER" ]]; then
        [[ ! -e "$DISK" ]] || fail 'Volume v2 déjà présent sans marqueur : inspection manuelle requise'
        cat > "$TMP/volume.xml" <<EOF
<volume>
  <name>$VOLUME</name>
  <capacity unit='bytes'>$virtual_size</capacity>
  <target>
    <format type='qcow2'/>
    <permissions>
      <mode>0660</mode>
      <owner>$USER_UID</owner>
      <group>$QEMU_GID</group>
    </permissions>
  </target>
</volume>
EOF
        lv vol-create "$POOL" "$TMP/volume.xml"
        [[ -r "$DISK" && -w "$DISK" ]] || fail 'Permissions du nouveau disque incorrectes'
        lv vol-upload "$VOLUME" "$IMAGE" --pool "$POOL"

        # Vérification exacte de l'import AVANT agrandissement.
        # Nécessite un espace temporaire d'environ la taille de l'image source.
        lv vol-download "$VOLUME" "$TMP/import-verification.qcow2" --pool "$POOL"
        disk_hash=$(sha512sum "$TMP/import-verification.qcow2" | awk '{print $1}')
        [[ "$disk_hash" == "$source_hash" ]] || fail 'Contenu importé différent de la source SHA-512'
        [[ "$(qemu-img info --output=json "$DISK" | python3 -c 'import json,sys;print(json.load(sys.stdin)["format"])')" == qcow2 ]] || fail 'Disque importé non QCOW2'
        rm -f "$TMP/import-verification.qcow2"

        if (( target_size > virtual_size )); then
            lv vol-resize "$VOLUME" "${DISK_GB}G" --pool "$POOL"
        fi
        actual_size=$(qemu-img info --output=json "$DISK" | python3 -c 'import json,sys;print(json.load(sys.stdin)["virtual-size"])')
        [[ "$actual_size" == "$target_size" ]] || fail 'Capacité finale incorrecte'
        printf 'volume=%s\nsource_sha512=%s\n' "$VOLUME" "$source_hash" > "$MARKER.tmp"
        mv "$MARKER.tmp" "$MARKER"
    else
        grep -Fxq "volume=$VOLUME" "$MARKER" || fail 'Marqueur volume incohérent'
        grep -Fxq "source_sha512=$source_hash" "$MARKER" || fail 'Image source différente du marqueur'
        [[ -r "$DISK" && -w "$DISK" ]] || fail 'Disque inaccessible'
        actual_size=$(qemu-img info --output=json "$DISK" | python3 -c 'import json,sys;print(json.load(sys.stdin)["virtual-size"])')
        [[ "$actual_size" == "$target_size" ]] || fail 'Taille du disque différente'
    fi
    lv pool-refresh "$POOL"
    log 'Nouveau disque prêt ; ancien disque préservé'
}

create_seed() {
    [[ -e "$SEED" ]] && return
    local key
    key=$(cat "$SSH_KEY")
    [[ "$key" == ssh-* || "$key" == ecdsa-* ]] || fail 'Clé SSH publique invalide'
    cat > "$TMP/meta-data" <<EOF
instance-id: $INSTANCE_ID
local-hostname: $VM
EOF
    cat > "$TMP/user-data" <<EOF
#cloud-config
hostname: $VM
manage_etc_hosts: true
users:
  - name: $VM_USER
    groups: [sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: true
    ssh_authorized_keys:
      - $key
ssh_pwauth: false
disable_root: true
growpart:
  mode: auto
  devices: ['/']
resize_rootfs: true
packages:
  - openssh-server
runcmd:
  - systemctl enable --now ssh
EOF
    cat > "$TMP/network-config" <<EOF
version: 2
ethernets:
  interface0:
    match:
      name: 'en*'
    dhcp4: false
    addresses: [$IP_VM/24]
    routes:
      - to: default
        via: $GW
    nameservers:
      addresses: [1.1.1.1]
EOF
    xorriso -as mkisofs -output "$TMP/seed.iso" -volid cidata -joliet -rock \
        "$TMP/user-data" "$TMP/meta-data" "$TMP/network-config"
    install -m 0644 "$TMP/seed.iso" "$SEED"
    log 'ISO cloud-init créé'
}

create_vm() {
    if ! lv dominfo "$VM" >/dev/null 2>&1; then
        virt-install --connect "$LIBVIRT" --name "$VM" \
            --memory "$RAM" --vcpus "$CPU" --import \
            --os-variant debian13 \
            --disk "path=$DISK,format=qcow2,bus=virtio" \
            --disk "path=$SEED,device=cdrom,readonly=on" \
            --network "network=$NET,model=virtio" \
            --graphics none --console pty,target_type=serial --noautoconsole
    fi
    lv autostart "$VM"
    if [[ "$(lv domstate "$VM")" != running ]]; then
        lv start "$VM"
    fi
    log "VM $VM démarrée"
}

check_existing
create_network
create_pool
if [[ "$MODE" == '--stop-after-pool' ]]; then
    log 'Arrêt volontaire après le pool (code 75)'
    exit 75
fi
get_image
create_disk
create_seed
create_vm
log 'À vérifier dans la VM : cloud-init status --wait ; ip route ; lsblk ; df -h /'
