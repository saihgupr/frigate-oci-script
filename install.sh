#!/usr/bin/env bash

# Frigate OCI Script for Proxmox VE 9.1+
# Installs Frigate natively as an unprivileged OCI-based LXC container.

set -eo pipefail

# Parse command-line arguments
NON_INTERACTIVE=false
CUSTOM_MOUNT_HOST=""
CUSTOM_MOUNT_CONTAINER=""
CT_ID=""
CT_HOSTNAME=""
CLI_MEDIA_PATH=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes|--silent|--non-interactive)
            NON_INTERACTIVE=true
            shift
            ;;
        -d|--dry-run)
            DRY_RUN=true
            shift
            ;;
        --id)
            CT_ID="$2"
            shift 2
            ;;
        --hostname)
            CT_HOSTNAME="$2"
            shift 2
            ;;
        --mount)
            if [ -n "$2" ] && [[ "$2" == *":"* ]]; then
                CUSTOM_MOUNT_HOST=$(echo "$2" | cut -d: -f1)
                CUSTOM_MOUNT_CONTAINER=$(echo "$2" | cut -d: -f2)
            else
                error_exit "Invalid mount argument format. Use: --mount /host/path:/container/path"
            fi
            shift 2
            ;;
        --media-path)
            CLI_MEDIA_PATH="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Helper log functions
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }
log_success() { echo -e "${GREEN}[DONE]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
error_exit() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

run_cmd() {
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY RUN] Would execute:${NC} $*"
    else
        "$@"
    fi
}

# Set terminal title
echo -ne "\033]0;Frigate OCI Script\007"

echo -e "${GREEN}"
echo "============================================="
echo "             Frigate OCI Script              "
echo "============================================="
echo -e "${NC}"

# 1. System checks
if [ "$(id -u)" -ne 0 ]; then
    error_exit "This script must be run as root on your Proxmox VE host."
fi

if ! command -v pveversion &>/dev/null; then
    error_exit "Proxmox VE (pveversion) was not detected. This script must run on the PVE host."
fi

# Check PVE Version (Recommend PVE 9.1+, require PVE 8.2+)
PVE_VERSION=$(pveversion | cut -d/ -f2 | cut -d- -f1)
PVE_MAJOR=$(echo "$PVE_VERSION" | cut -d. -f1)
PVE_MINOR=$(echo "$PVE_VERSION" | cut -d. -f2)

log_info "Detected Proxmox VE version: $PVE_VERSION"

if [ "$PVE_MAJOR" -lt 8 ] || { [ "$PVE_MAJOR" -eq 8 ] && [ "$PVE_MINOR" -lt 2 ]; }; then
    error_exit "Proxmox VE 8.2+ is required for native OCI container template support."
fi

if [ "$PVE_MAJOR" -eq 8 ] || { [ "$PVE_MAJOR" -eq 9 ] && [ "$PVE_MINOR" -lt 1 ]; }; then
    log_warn "You are running Proxmox VE $PVE_VERSION. PVE 9.1+ is highly recommended for stable OCI features."
    if [ "$NON_INTERACTIVE" = false ]; then
        read -p "Do you want to proceed anyway? (y/N): " proceed_choice
        if [[ ! "$proceed_choice" =~ ^[Yy]$ ]]; then
            error_exit "Installation cancelled."
        fi
    fi
fi

# 2. Resource/Hardware Auto-Detection
log_step "Detecting hardware capabilities..."

# GPU Detection
GPU_TYPE="none"
if [ -c "/dev/dri/renderD128" ]; then
    if lspci 2>/dev/null | grep -iq "intel"; then
        GPU_TYPE="intel"
        log_success "Detected Intel iGPU (/dev/dri/renderD128)"
    elif lspci 2>/dev/null | grep -iq "amd"; then
        GPU_TYPE="amd"
        log_success "Detected AMD GPU (/dev/dri/renderD128)"
    else
        GPU_TYPE="vaapi"
        log_success "Detected Generic GPU (/dev/dri/renderD128)"
    fi
elif lspci 2>/dev/null | grep -iq "nvidia" || [ -c "/dev/nvidiactl" ]; then
    GPU_TYPE="nvidia"
    log_success "Detected Nvidia GPU"
else
    log_info "No GPU detected for hardware acceleration."
fi

# Coral Detection
CORAL_TYPE="none"
if lspci 2>/dev/null | grep -iq "Google" || [ -c "/dev/apex_0" ]; then
    CORAL_TYPE="pcie"
    log_success "Detected Google Coral (PCIe)"
elif lsusb 2>/dev/null | grep -Ei "18d1:9302|1a6e:089a|Google Inc" &>/dev/null; then
    CORAL_TYPE="usb"
    log_success "Detected Google Coral (USB)"
else
    log_info "No Google Coral TPU detected."
fi

# Storage Detection
log_step "Scanning storage pools..."
# Get storages supporting vztmpl
TEMPLATE_STORAGES=$(pvesm status -content vztmpl 2>/dev/null | awk 'NR>1 {print $1}')
# Get storages supporting rootdir
ROOTFS_STORAGES=$(pvesm status -content rootdir 2>/dev/null | awk 'NR>1 {print $1}')

DEFAULT_TEMPLATE_STORAGE="local"
if ! echo "$TEMPLATE_STORAGES" | grep -q "^local$"; then
    DEFAULT_TEMPLATE_STORAGE=$(echo "$TEMPLATE_STORAGES" | head -n 1)
fi

DEFAULT_ROOTFS_STORAGE="local-lvm"
if ! echo "$ROOTFS_STORAGES" | grep -q "^local-lvm$"; then
    DEFAULT_ROOTFS_STORAGE=$(echo "$ROOTFS_STORAGES" | head -n 1)
fi

# 3. User Prompts for Configuration
echo ""
echo "--- Configuration ---"

NEXT_CTID=$(pvesh get /cluster/nextid 2>/dev/null || echo "100")
CLI_CT_ID="${CT_ID:-}"
CLI_CT_HOSTNAME="${CT_HOSTNAME:-}"

if [ "$NON_INTERACTIVE" = true ]; then
    log_info "Running in non-interactive/silent mode. Auto-applying all defaults."
    CT_ID="${CLI_CT_ID:-$NEXT_CTID}"
    CT_HOSTNAME="${CLI_CT_HOSTNAME:-frigate}"
    CT_CORES=4
    CT_RAM=4096
    CT_SWAP=0
    CT_DISK=10
    CT_STORAGE="$DEFAULT_ROOTFS_STORAGE"
    TEMPLATE_STORAGE="$DEFAULT_TEMPLATE_STORAGE"
    FRIGATE_IMAGE="ghcr.io/blakeblackshear/frigate:0.17.2"
    HOST_CONFIG_PATH="/opt/frigate/config"
    HOST_MEDIA_PATH="${CLI_MEDIA_PATH:-/opt/frigate/media}"
    NET_BRIDGE="vmbr0"
    NET_IP="dhcp"
    NET_GW=""
    configure_gpu="Y"
    configure_coral="Y"
    create_snapshot_choice="Y"
else
    # Container ID
    read -p "Enter Container ID [100-999] (default: ${CLI_CT_ID:-$NEXT_CTID}): " CT_ID
    CT_ID=${CT_ID:-${CLI_CT_ID:-$NEXT_CTID}}

    # Hostname
    read -p "Enter Container Hostname (default: ${CLI_CT_HOSTNAME:-frigate}): " CT_HOSTNAME
    CT_HOSTNAME=${CT_HOSTNAME:-${CLI_CT_HOSTNAME:-frigate}}

    # CPU Cores
    read -p "Enter CPU Cores (default: 4): " CT_CORES
    CT_CORES=${CT_CORES:-4}

    # RAM
    read -p "Enter Memory (RAM) in MB (default: 4096): " CT_RAM
    CT_RAM=${CT_RAM:-4096}

    # Swap
    read -p "Enter Swap in MB (default: 0): " CT_SWAP
    CT_SWAP=${CT_SWAP:-0}

    # Disk Size
    read -p "Enter Disk Size in GB (default: 10): " CT_DISK
    CT_DISK=${CT_DISK:-10}

    # Rootfs storage
    echo "Available storage for Container Rootfs:"
    echo "$ROOTFS_STORAGES" | sed 's/^/  - /'
    read -p "Select Container Storage pool (default: $DEFAULT_ROOTFS_STORAGE): " CT_STORAGE
    CT_STORAGE=${CT_STORAGE:-$DEFAULT_ROOTFS_STORAGE}

    # Template storage
    echo "Available storage for OCI Image Template cache:"
    echo "$TEMPLATE_STORAGES" | sed 's/^/  - /'
    read -p "Select Template Storage pool (default: $DEFAULT_TEMPLATE_STORAGE): " TEMPLATE_STORAGE
    TEMPLATE_STORAGE=${TEMPLATE_STORAGE:-$DEFAULT_TEMPLATE_STORAGE}

    # Frigate Image
    read -p "Enter Frigate Image Tag (default: ghcr.io/blakeblackshear/frigate:0.17.2): " FRIGATE_IMAGE
    FRIGATE_IMAGE=${FRIGATE_IMAGE:-ghcr.io/blakeblackshear/frigate:0.17.2}

    # Host bind mounts
    read -p "Enter Host Config Path (default: /opt/frigate/config): " HOST_CONFIG_PATH
    HOST_CONFIG_PATH=${HOST_CONFIG_PATH:-/opt/frigate/config}

    read -p "Enter Host Media Path (default: /opt/frigate/media): " HOST_MEDIA_PATH
    HOST_MEDIA_PATH=${HOST_MEDIA_PATH:-/opt/frigate/media}

    # Confirm hardware profiles
    read -p "Configure GPU Passthrough ($GPU_TYPE)? (Y/n): " configure_gpu
    configure_gpu=${configure_gpu:-Y}

    if [ "$CORAL_TYPE" = "none" ]; then
        read -p "Configure Google Coral Passthrough ($CORAL_TYPE)? (y/N): " configure_coral
        configure_coral=${configure_coral:-N}
    else
        read -p "Configure Google Coral Passthrough ($CORAL_TYPE)? (Y/n): " configure_coral
        configure_coral=${configure_coral:-Y}
    fi

    # Network settings
    read -p "Enter Network Bridge (default: vmbr0): " NET_BRIDGE
    NET_BRIDGE=${NET_BRIDGE:-vmbr0}

    read -p "Enter IP Address (e.g. 192.168.1.204/24 or 'dhcp', default: dhcp): " NET_IP
    NET_IP=${NET_IP:-dhcp}

    NET_GW=""
    if [ "$NET_IP" != "dhcp" ]; then
        read -p "Enter Default Gateway (e.g. 192.168.1.1): " NET_GW
    fi

    # Post-Install Snapshot
    read -p "Create a post-installation snapshot of the container? (Y/n): " create_snapshot_choice
    create_snapshot_choice=${create_snapshot_choice:-Y}

    # Final confirmation
    echo ""
    read -p "Ready to begin the installation? (Y/n): " start_install_choice
    start_install_choice=${start_install_choice:-Y}
    if [[ ! "$start_install_choice" =~ ^[Yy]$ ]]; then
        error_exit "Installation cancelled by user."
    fi
fi

# Validation (applicable to both interactive and silent)
if [[ ! "$CT_ID" =~ ^[0-9]+$ ]] || [ "$CT_ID" -lt 100 ] || [ "$CT_ID" -gt 999 ]; then
    error_exit "Invalid Container ID. Must be between 100 and 999."
fi

if [ "$DRY_RUN" = false ] && pct status "$CT_ID" &>/dev/null; then
    error_exit "Container ID $CT_ID is already in use."
fi

if ! echo "$ROOTFS_STORAGES" | grep -q "^$CT_STORAGE$"; then
    error_exit "Storage pool '$CT_STORAGE' does not support container rootfs (rootdir)."
fi

if ! echo "$TEMPLATE_STORAGES" | grep -q "^$TEMPLATE_STORAGE$"; then
    error_exit "Storage pool '$TEMPLATE_STORAGE' does not support templates (vztmpl)."
fi

# 4. Pull OCI template
log_step "Pulling OCI image: $FRIGATE_IMAGE..."

# Normalize image tag for filename
SAFE_IMG_NAME=$(echo "$FRIGATE_IMAGE" | tr '/:' '-')
# Do NOT append .tar to filename as Proxmox does it automatically
OCI_TEMPLATE_NAME="${SAFE_IMG_NAME}"

# Check if template is already cached on host to bypass duplicate pull
# We query the storage path using a dummy volume ID with a standard extension (.tar.gz)
# because some Proxmox storage plugins fail to parse volume IDs ending in .tar via 'pvesm path'.
TEMPLATE_DIR_PATH=$(pvesm path "${TEMPLATE_STORAGE}:vztmpl/dummy.tar.gz" 2>/dev/null || echo "")
if [ -n "$TEMPLATE_DIR_PATH" ]; then
    TEMPLATE_PATH="$(dirname "$TEMPLATE_DIR_PATH")/${OCI_TEMPLATE_NAME}.tar"
else
    TEMPLATE_PATH=""
fi
PULL_REQUIRED=true

if [ -n "$TEMPLATE_PATH" ] && [ -f "$TEMPLATE_PATH" ]; then
    log_success "OCI Image is already cached on host at: $TEMPLATE_PATH"
    log_info "Skipping download and using existing template."
    PULL_REQUIRED=false
fi

if [ "$PULL_REQUIRED" = true ]; then
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would initiate pull through Proxmox OCI Registry api for $FRIGATE_IMAGE"
    else
        # Remove any existing/incomplete file at the template path to prevent "refusing to override existing file" error
        if [ -n "$TEMPLATE_PATH" ] && [ -f "$TEMPLATE_PATH" ]; then
            log_warn "Removing existing/incomplete template file at $TEMPLATE_PATH to allow a fresh pull..."
            rm -f "$TEMPLATE_PATH"
        fi

        log_info "Initiating pull through Proxmox OCI Registry api..."
        PVE_OUT=$(pvesh create "/nodes/localhost/storage/${TEMPLATE_STORAGE}/oci-registry-pull" \
            --reference "$FRIGATE_IMAGE" \
            --filename "$OCI_TEMPLATE_NAME" \
            --output-format json 2>/dev/null || echo "")

        UPID=$(echo "$PVE_OUT" | python3 -c 'import sys, json; print(json.load(sys.stdin))' 2>/dev/null || echo "")

        if [ -z "$UPID" ] || [[ ! "$UPID" =~ ^UPID: ]]; then
            # Fallback if JSON parsing failed or stdout returned raw string
            UPID=$(echo "$PVE_OUT" | grep -o 'UPID:[^[:space:]"]*' | head -n 1 || echo "")
        fi

        if [ -z "$UPID" ] || [[ ! "$UPID" =~ ^UPID: ]]; then
            error_exit "Failed to initiate OCI registry pull. PVE output: $UPID"
        fi

        log_info "Task started with UPID: $UPID"

        # Poll PVE task for completion
        while true; do
            task_status_json=$(pvesh get "/nodes/localhost/tasks/${UPID}/status" --output-format json 2>/dev/null || echo "")
            if [ -n "$task_status_json" ]; then
                status=$(echo "$task_status_json" | python3 -c 'import sys, json; print(json.load(sys.stdin).get("status", "running"))' 2>/dev/null || echo "running")
                exitstatus=$(echo "$task_status_json" | python3 -c 'import sys, json; print(json.load(sys.stdin).get("exitstatus", ""))' 2>/dev/null || echo "")
            else
                # Fallback raw parsing
                status="running"
                exitstatus=""
            fi
            
            if [ "$status" = "stopped" ]; then
                if [ "$exitstatus" = "OK" ]; then
                    log_success "OCI Image pulled and cached successfully as template."
                    break
                else
                    error_exit "Pull task failed with exit status: $exitstatus"
                fi
            fi
            echo -n "."
            sleep 3
        done
        echo ""
    fi
fi

# 5. Create container
log_step "Creating LXC Container $CT_ID..."
# Note that we append .tar to reference the downloaded file
if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Would create LXC container $CT_ID using template ${TEMPLATE_STORAGE}:vztmpl/${OCI_TEMPLATE_NAME}.tar"
else
    # Build net0 configuration
    NET0_CONF="name=eth0,bridge=$NET_BRIDGE,ip=$NET_IP"
    if [ "$NET_IP" != "dhcp" ]; then
        if [ -n "$NET_GW" ]; then
            NET0_CONF="${NET0_CONF},gw=${NET_GW}"
        fi
    fi
    NET0_CONF="${NET0_CONF},host-managed=1"

    pct create "$CT_ID" "${TEMPLATE_STORAGE}:vztmpl/${OCI_TEMPLATE_NAME}.tar" \
        --hostname "$CT_HOSTNAME" \
        --cores "$CT_CORES" \
        --memory "$CT_RAM" \
        --swap "$CT_SWAP" \
        --rootfs "${CT_STORAGE}:${CT_DISK}" \
        --net0 "$NET0_CONF" \
        --onboot 1 \
        --ostype unmanaged \
        --unprivileged 1 || error_exit "Failed to create container."

    log_success "LXC Container $CT_ID created."
fi

# 6. Setup Host directories and config
log_step "Preparing host directories and initial config..."
if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Would create host directories $HOST_CONFIG_PATH and $HOST_MEDIA_PATH"
    log_info "[DRY RUN] Would create default config.yml at $HOST_CONFIG_PATH/config.yml"
    log_info "[DRY RUN] Would chown/chmod directories for unprivileged user (UID 100000)"
else
    mkdir -p "$HOST_CONFIG_PATH" "$HOST_MEDIA_PATH"

    if [ ! -f "$HOST_CONFIG_PATH/config.yml" ]; then
        log_info "Creating default minimal config.yml..."
        cat > "$HOST_CONFIG_PATH/config.yml" << EOF
# Minimal config generated by installer
mqtt:
  enabled: false

detectors:
  ov:
    type: openvino
    device: CPU
    model:
      path: /openvino-model/ssdlite_mobilenet_v2.xml

cameras:
  dummy_camera:
    enabled: false
    ffmpeg:
      inputs:
        - path: rtsp://127.0.0.1:554/live/dummy
          roles:
            - detect
EOF
        log_success "Created template at $HOST_CONFIG_PATH/config.yml"
    else
        log_info "Existing config.yml found. Keeping it."
    fi

    # Ensure correct permissions on host directories for unprivileged access
    # LXC unprivileged container starts root mapped to host UID 100000 by default.
    # Make the host mount paths readable/writable by UID 100000.
    log_info "Adjusting directory permissions for unprivileged mappings (UID 100000)..."
    chown -R 100000:100000 "$HOST_CONFIG_PATH" "$HOST_MEDIA_PATH"
    chmod -R 775 "$HOST_CONFIG_PATH" "$HOST_MEDIA_PATH"
fi

# 7. Configure LXC container parameters
LXC_CONF="/etc/pve/lxc/${CT_ID}.conf"
if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Would write LXC container configurations to $LXC_CONF (mounts, GPU passthrough, Coral passthrough)"
else
    log_step "Configuring container settings in $LXC_CONF..."

    # Add bind mounts using low-level lxc.mount.entry to allow Proxmox LXC Snapshots
    echo "" >> "$LXC_CONF"
    echo "# Frigate Host Bind Mounts (LXC native layout to support snapshots)" >> "$LXC_CONF"
    echo "lxc.mount.entry: $HOST_CONFIG_PATH config none bind,optional,create=dir 0 0" >> "$LXC_CONF"
    echo "lxc.mount.entry: $HOST_MEDIA_PATH media/frigate none bind,optional,create=dir 0 0" >> "$LXC_CONF"

    # Add custom external storage bind mount if configured
    if [ -n "$CUSTOM_MOUNT_HOST" ] && [ -n "$CUSTOM_MOUNT_CONTAINER" ]; then
        CLEAN_CONTAINER_PATH=$(echo "$CUSTOM_MOUNT_CONTAINER" | sed 's/^\///')
        log_info "Configuring custom external mount: $CUSTOM_MOUNT_HOST -> /$CLEAN_CONTAINER_PATH"
        echo "lxc.mount.entry: $CUSTOM_MOUNT_HOST $CLEAN_CONTAINER_PATH none bind,create=dir" >> "$LXC_CONF"
    fi

    # Add GPU Passthrough
    if [[ "$configure_gpu" =~ ^[Yy]$ && "$GPU_TYPE" != "none" ]]; then
        log_info "Configuring $GPU_TYPE hardware acceleration passthrough..."
        echo "" >> "$LXC_CONF"
        echo "# Frigate Hardware Acceleration" >> "$LXC_CONF"
        
        if [[ "$GPU_TYPE" =~ ^(intel|amd|vaapi)$ ]]; then
            # Map all DRI devices under /dev/dri/ to support QSV surface allocation
            dev_slot=0
            for dev in /dev/dri/*; do
                if [ -c "$dev" ]; then
                    dev_gid=$(stat -c '%g' "$dev" 2>/dev/null || echo "0")
                    echo "dev${dev_slot}: $dev,gid=$dev_gid,mode=0666" >> "$LXC_CONF"
                    log_success "Mapped $dev (GID $dev_gid) to dev${dev_slot}"
                    dev_slot=$((dev_slot + 1))
                fi
            done
            echo "lxc.apparmor.profile: unconfined" >> "$LXC_CONF"
            
        elif [ "$GPU_TYPE" = "nvidia" ]; then
            echo "lxc.apparmor.profile: unconfined" >> "$LXC_CONF"
            nvidia_devs=("/dev/nvidia0" "/dev/nvidiactl" "/dev/nvidia-modeset" "/dev/nvidia-uvm" "/dev/nvidia-uvm-tools")
            dev_slot=0
            for dev in "${nvidia_devs[@]}"; do
                if [ -c "$dev" ]; then
                    dev_gid=$(stat -c '%g' "$dev" 2>/dev/null || echo "0")
                    echo "dev${dev_slot}: $dev,gid=$dev_gid" >> "$LXC_CONF"
                    dev_slot=$((dev_slot + 1))
                fi
            done
            log_success "Mapped Nvidia devices and set AppArmor unconfined."
        fi
    fi

    # Add Coral Passthrough
    if [[ "$configure_coral" =~ ^[Yy]$ && "$CORAL_TYPE" != "none" ]]; then
        log_info "Configuring Coral ($CORAL_TYPE) passthrough..."
        echo "" >> "$LXC_CONF"
        echo "# Frigate Coral TPU Passthrough" >> "$LXC_CONF"
        
        if [ "$CORAL_TYPE" = "pcie" ]; then
            APEX_GID=$(stat -c '%g' /dev/apex_0 2>/dev/null || echo "0")
            echo "dev2: /dev/apex_0,gid=$APEX_GID" >> "$LXC_CONF"
            log_success "Mapped /dev/apex_0 (GID $APEX_GID) for PCIe Coral."
        elif [ "$CORAL_TYPE" = "usb" ]; then
            cat >> "$LXC_CONF" << EOF
lxc.cgroup2.devices.allow: c 189:* rwm
lxc.mount.entry: /dev/bus/usb dev/bus/usb none bind,optional,create=dir
EOF
            log_success "Configured USB bus passthrough for USB Coral."
        fi
    fi

    # Create and register network hookscript to solve IPv6 and loopback issues on unprivileged OCI
    log_step "Creating background network hookscript..."
    SNIPPETS_DIR="/var/lib/vz/snippets"
    mkdir -p "$SNIPPETS_DIR"
    HOOKSCRIPT_PATH="${SNIPPETS_DIR}/ct${CT_ID}-network.sh"

    if [ "$NET_IP" = "dhcp" ]; then
        NET_CMD="nsenter -t \"\\\$CT_PID\" -n dhclient eth0 2>/dev/null || nsenter -t \"\\\$CT_PID\" -n udhcpc -i eth0 2>/dev/null"
    else
        NET_CMD="nsenter -t \"\\\$CT_PID\" -n ip addr add $NET_IP dev eth0 2>/dev/null
        nsenter -t \"\\\$CT_PID\" -n ip route add default via $NET_GW 2>/dev/null"
    fi

    cat > "$HOOKSCRIPT_PATH" << EOF
#!/bin/bash
# Proxmox hookscript: configure network and flush IPv6 for CT \${CT_ID}

VMID="\\\$1"
PHASE="\\\$2"

if [ "\\\$VMID" != "$CT_ID" ] || [ "\\\$PHASE" != "post-start" ]; then
    exit 0
fi

# Run in background via setsid to release PVE startup task immediately
setsid bash -c '
    for i in {1..50}; do
        CT_PID=\\\$(lxc-info -n $CT_ID -p -H 2>/dev/null)
        if [ -n "\\\$CT_PID" ]; then
            break
        fi
        sleep 0.05
    done
    if [ -n "\\\$CT_PID" ]; then
        echo \"ct\${CT_ID}-network: configuring network inside PID \\\$CT_PID...\"
        nsenter -t \"\\\$CT_PID\" -n sysctl -w net.ipv6.conf.all.disable_ipv6=1
        nsenter -t \"\\\$CT_PID\" -n sysctl -w net.ipv6.conf.default.disable_ipv6=1
        nsenter -t \"\\\$CT_PID\" -n sysctl -w net.ipv6.conf.eth0.disable_ipv6=1
        nsenter -t \"\\\$CT_PID\" -n ip link set lo up
        nsenter -t \"\\\$CT_PID\" -n ip link set eth0 up
        $NET_CMD
        echo \"ct\${CT_ID}-network: network configured successfully\"
    fi
' > /var/log/ct\${CT_ID}-network.log 2>&1 &

exit 0
EOF

    chmod +x "$HOOKSCRIPT_PATH"
    echo "hookscript: local:snippets/ct${CT_ID}-network.sh" >> "$LXC_CONF"
    log_success "Hookscript configured and registered in $LXC_CONF"
fi


# 8. Start Container
log_step "Starting Frigate container $CT_ID..."
if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Would start container $CT_ID"
else
    pct start "$CT_ID" || log_warn "Failed to start container automatically. Try running 'pct start $CT_ID' manually."
fi

# 9. Create Proxmox summary dashboard notes
log_step "Creating Proxmox summary dashboard..."
IP_ADDRESS=""
# Wait up to 5 seconds for IP address allocation if container started successfully
if [ "$DRY_RUN" = false ] && pct status "$CT_ID" | grep -q "running"; then
    for i in {1..5}; do
        IP_ADDRESS=$(pct exec "$CT_ID" -- hostname -I | awk '{print $1}' 2>/dev/null || echo "")
        if [ -n "$IP_ADDRESS" ]; then
            break
        fi
        sleep 1
    done
fi
IP_ADDRESS=${IP_ADDRESS:-"<IP_ADDRESS>"}

CORAL_LINE=""
if [ "$CORAL_TYPE" != "none" ]; then
    CORAL_LINE="- Coral Detector: ${CORAL_TYPE}\\n"
fi

MOUNT_LINE=""
if [ -n "$CUSTOM_MOUNT_HOST" ] && [ -n "$CUSTOM_MOUNT_CONTAINER" ]; then
    CLEAN_CONTAINER_PATH=$(echo "$CUSTOM_MOUNT_CONTAINER" | sed 's/^\///')
    MOUNT_LINE="- External Mount: ${CUSTOM_MOUNT_HOST} -> /${CLEAN_CONTAINER_PATH}\\n"
fi

DESCRIPTION=$(echo -e "# Frigate OCI Script

**Quick Access**
| Service | URL |
| :--- | :--- |
| Web UI & API (Unauthenticated) | http://${IP_ADDRESS}:5000 |
| Web UI & API (Recommended) | https://${IP_ADDRESS}:8971 |
| go2rtc API | http://${IP_ADDRESS}:1984 |

*Note: Port 8971 is the secure WebUI and API port and is recommended to be used in every case. Port 5000 is unauthenticated.*

**Hardware Profile**
- GPU Acceleration: ${GPU_TYPE}
${CORAL_LINE}- Resources: ${CT_RAM}MB RAM / ${CT_CORES} CPU Cores

**File Locations**
- Configuration: ${HOST_CONFIG_PATH}/config.yml
- Media Storage: ${HOST_MEDIA_PATH}
${MOUNT_LINE}
---
GitHub: [saihgupr/frigate-oci-script](https://github.com/saihgupr/frigate-oci-script)

Support: [Buy me a coffee](https://ko-fi.com/saihgupr)")

if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Would set description for container $CT_ID to:"
    echo "$DESCRIPTION" | sed 's/^/  /'
else
    if pct set "$CT_ID" --description "$DESCRIPTION" &>/dev/null; then
        log_success "Proxmox summary dashboard notes created for container $CT_ID"
    else
        log_warn "Failed to set Proxmox summary dashboard notes."
    fi
fi

# 9.5 Create Post-Installation Snapshot
if [[ "$create_snapshot_choice" =~ ^[Yy]$ ]]; then
    log_step "Creating post-installation snapshot..."
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would create snapshot 'post_install' for container $CT_ID"
    else
        if pct snapshot "$CT_ID" "post_install" --description "Clean post-installation baseline"; then
            log_success "Post-installation snapshot 'post_install' created."
        else
            log_warn "Failed to create post-installation snapshot."
        fi
    fi
fi

# 10. Finished
echo ""
echo -e "${GREEN}============================================="
echo "   Installation Completed Successfully!      "
echo "============================================="
echo -e "${NC}"
echo "Container ID:   $CT_ID"
echo "Hostname:       $CT_HOSTNAME"
echo "Image Tag:      $FRIGATE_IMAGE"
echo "Config Path:    $HOST_CONFIG_PATH/config.yml"
echo "Media Path:     $HOST_MEDIA_PATH"
echo ""
echo -e "Web UI & API (Unauthenticated): http://${IP_ADDRESS}:5000"
echo -e "Web UI & API (Recommended):     https://${IP_ADDRESS}:8971"
echo -e "go2rtc Web UI:                  http://${IP_ADDRESS}:1984"
echo ""
echo -e "${YELLOW}NOTE: Port 8971 is the secure (authenticated/TLS) WebUI and API port and is recommended to be used in every case.${NC}"
echo ""
echo "Enjoy your Docker-less Frigate setup!"
