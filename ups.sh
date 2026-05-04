#!/bin/bash
set -u

# Emergency UPS Shutdown Script for Proxmox Cluster + Synology NAS
# RUNS ON: Node 1, where CyberPower pwrstatd / USB UPS is connected.

###############################################################################
# CONFIG
###############################################################################

# Other Proxmox nodes. Do NOT include Node 1 here.
PROXMOX_REMOTE_NODES=(
  "192.168.1.12"
  "192.168.1.13"
  "192.168.1.14"
)

# Optional iDRAC fallback per Proxmox node.
# Leave blank if you do not want to use iDRAC fallback.
#
# Format:
#   IDRAC_IPS["proxmox_node_ip"]="idrac_ip"
#
declare -A IDRAC_IPS
IDRAC_IPS["192.168.1.12"]="192.168.1.112"
IDRAC_IPS["192.168.1.13"]="192.168.1.113"
IDRAC_IPS["192.168.1.14"]="192.168.1.114"

# Set to 1 to use iDRAC graceful shutdown as an additional fallback.
# Set to 0 to disable iDRAC commands.
USE_IDRAC_FALLBACK=0

# iDRAC SSH user.
IDRAC_USER="root"

# NAS settings
NAS_IP="192.168.1.5"
NAS_USER="your_admin_user"

# Proxmox SSH settings
PVE_USER="root"
SSH_KEY="/root/.ssh/id_rsa"

# Timing
REMOTE_NODE_GRACE_SECONDS=90
NAS_SHUTDOWN_DISPATCH_SECONDS=10

###############################################################################
# SSH OPTIONS
###############################################################################

SSH_OPTS=(
  -i "$SSH_KEY"
  -o BatchMode=yes
  -o ConnectTimeout=5
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=1
  -o StrictHostKeyChecking=no
)

###############################################################################
# HELPERS
###############################################################################

LOG_TAG="ups-shutdown"

log() {
  echo "$1"
  logger -t "$LOG_TAG" "$1"
}

shutdown_remote_pve_node() {
  local node="$1"

  log "Sending shutdown sequence to Proxmox node $node"

  ssh "${SSH_OPTS[@]}" "$PVE_USER@$node" 'bash -s' <<'REMOTE_SHUTDOWN' &
set -u

logger -t ups-shutdown "UPS shutdown received: starting normal shutdown"

# Start normal shutdown first so guests/services get a chance to stop cleanly.
shutdown -h +1 "UPS low battery emergency shutdown" || true

# Give shutdown/systemd a chance to begin.
sleep 10

# These are here specifically for cases where Proxmox cluster/corosync transport
# gets wedged and blocks clean shutdown.
logger -t ups-shutdown "Stopping Proxmox cluster-related services as fallback"

systemctl stop pvestatd 2>/dev/null || true
systemctl stop pvedaemon 2>/dev/null || true
systemctl stop pveproxy 2>/dev/null || true
systemctl stop pve-ha-lrm 2>/dev/null || true
systemctl stop pve-ha-crm 2>/dev/null || true
systemctl stop pve-cluster 2>/dev/null || true
systemctl stop corosync 2>/dev/null || true

# Push systemd toward poweroff if the normal shutdown path is stuck.
logger -t ups-shutdown "Forcing systemd poweroff fallback"
systemctl poweroff --force || poweroff -f || shutdown -h now || true
REMOTE_SHUTDOWN
}

idrac_graceful_shutdown() {
  local node="$1"
  local idrac_ip="${IDRAC_IPS[$node]:-}"

  if [[ "$USE_IDRAC_FALLBACK" != "1" ]]; then
    return 0
  fi

  if [[ -z "$idrac_ip" ]]; then
    log "No iDRAC IP configured for $node, skipping iDRAC fallback"
    return 0
  fi

  log "Sending iDRAC graceful shutdown to $node via iDRAC $idrac_ip"

  ssh "${SSH_OPTS[@]}" "$IDRAC_USER@$idrac_ip" \
    "racadm serveraction graceshutdown || serveraction graceshutdown" &
}

shutdown_nas() {
  log "Sending poweroff command to Synology NAS at $NAS_IP"

  ssh "${SSH_OPTS[@]}" "$NAS_USER@$NAS_IP" \
    "sudo -n /sbin/poweroff || sudo -n /sbin/shutdown -h now" &

  local nas_pid=$!

  sleep "$NAS_SHUTDOWN_DISPATCH_SECONDS"

  if kill -0 "$nas_pid" 2>/dev/null; then
    log "NAS SSH command still running after dispatch window; continuing local shutdown anyway"
  else
    log "NAS shutdown command dispatched or SSH session exited"
  fi
}

local_node_shutdown() {
  log "Starting local Node 1 shutdown sequence"

  shutdown -h +1 "UPS low battery emergency shutdown" || true

  sleep 10

  log "Stopping local Proxmox cluster-related services as fallback"

  systemctl stop pvestatd 2>/dev/null || true
  systemctl stop pvedaemon 2>/dev/null || true
  systemctl stop pveproxy 2>/dev/null || true
  systemctl stop pve-ha-lrm 2>/dev/null || true
  systemctl stop pve-ha-crm 2>/dev/null || true
  systemctl stop pve-cluster 2>/dev/null || true
  systemctl stop corosync 2>/dev/null || true

  log "Powering off local Node 1"
  systemctl poweroff --force || poweroff -f || shutdown -h now
}

###############################################################################
# MAIN
###############################################################################

log "UPS LOW BATTERY: initiating emergency sequence from Node 1"

# 1. Send shutdown sequence to remote Proxmox nodes.
for NODE in "${PROXMOX_REMOTE_NODES[@]}"; do
  shutdown_remote_pve_node "$NODE"
done

# 2. Optional iDRAC fallback.
# This is extra insurance, not a replacement for OS shutdown.
if [[ "$USE_IDRAC_FALLBACK" == "1" ]]; then
  sleep 15
  for NODE in "${PROXMOX_REMOTE_NODES[@]}"; do
    idrac_graceful_shutdown "$NODE"
  done
fi

# 3. Wait for remote Proxmox nodes to stop guests and release NAS storage.
log "Waiting ${REMOTE_NODE_GRACE_SECONDS} seconds before shutting down NAS"
sleep "$REMOTE_NODE_GRACE_SECONDS"

# 4. Shut down Synology NAS.
shutdown_nas

# 5. Shut down local Proxmox node.
local_node_shutdown