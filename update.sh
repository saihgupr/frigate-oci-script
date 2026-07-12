#!/usr/bin/env bash

# Frigate OCI Script Updater for Proxmox VE 9.1+
# Automates the lifecycle of updating native OCI container templates.

set -eo pipefail

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

# Set terminal title
echo -ne "\033]0;Frigate OCI Script Updater\007"

echo -e "${GREEN}"
echo "============================================="
echo "         Frigate OCI Script Updater          "
echo "============================================="
echo -e "${NC}"

# System checks
if [ "$(id -u)" -ne 0 ]; then
    error_exit "This script must be run as root on your Proxmox VE host."
fi

# Parse arguments
CT_ID=""
VERSION=""
TEMPLATE_STORAGE=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--id|--container)
            CT_ID="$2"
            shift 2
            ;;
        -v|--version)
            VERSION="$2"
            shift 2
            ;;
        -t|--template-storage)
            TEMPLATE_STORAGE="$2"
            shift 2
            ;;
        -d|--dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            if [[ "$1" =~ ^[0-9]+$ ]] && [ -z "$CT_ID" ]; then
                CT_ID="$1"
            elif [ -z "$VERSION" ] && [[ ! "$1" =~ ^- ]]; then
                VERSION="$1"
            fi
            shift
            ;;
    esac
done

# Fallback to interactive prompts if not provided
if [ -z "$CT_ID" ]; then
    read -p "Enter Frigate Container ID: " CT_ID
fi

if [ -z "$TEMPLATE_STORAGE" ]; then
    TEMPLATE_STORAGES=$(pvesm status -content vztmpl 2>/dev/null | awk 'NR>1 {print $1}')
    if echo "$TEMPLATE_STORAGES" | grep -q "^local$"; then
        TEMPLATE_STORAGE="local"
    else
        TEMPLATE_STORAGE=$(echo "$TEMPLATE_STORAGES" | head -n 1)
    fi
fi

if [ -z "$VERSION" ]; then
    read -p "Enter new Frigate Version Tag (e.g., 0.17.2, or press Enter for latest stable): " VERSION
    VERSION=${VERSION:-latest}
fi

if [ "$VERSION" = "latest" ]; then
    log_step "Fetching latest stable Frigate release tag from GitHub..."
    LATEST_TAG=$(curl -s https://api.github.com/repos/blakeblackshear/frigate/releases/latest | python3 -c "import sys, json; print(json.load(sys.stdin).get('tag_name', '').lstrip('v'))" 2>/dev/null || echo "")
    if [ -n "$LATEST_TAG" ]; then
        VERSION="$LATEST_TAG"
        log_success "Found latest stable version: $VERSION"
    else
        log_warn "Failed to fetch latest version from GitHub. Defaulting to 0.17.2"
        VERSION="0.17.2"
    fi
fi

# Verify container exists
if ! pct status "$CT_ID" &>/dev/null; then
    error_exit "Container ID $CT_ID does not exist on this Proxmox host."
fi

# Pull the new template FIRST before making any destructive changes
FRIGATE_IMAGE="ghcr.io/blakeblackshear/frigate:$VERSION"
SAFE_IMG_NAME=$(echo "$FRIGATE_IMAGE" | tr '/:' '-')
# Do NOT append .tar to filename as Proxmox does it automatically
OCI_TEMPLATE_NAME="${SAFE_IMG_NAME}"

log_step "Pulling OCI image: $FRIGATE_IMAGE..."
log_info "Initiating pull through Proxmox OCI Registry API..."

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
        log_info "[DRY RUN] Would pull OCI image $FRIGATE_IMAGE and cache as ${TEMPLATE_STORAGE}:vztmpl/${OCI_TEMPLATE_NAME}.tar"
    else
        # Remove any existing/incomplete file at the template path to prevent "refusing to override existing file" error
        if [ -n "$TEMPLATE_PATH" ] && [ -f "$TEMPLATE_PATH" ]; then
            log_warn "Removing existing/incomplete template file at $TEMPLATE_PATH to allow a fresh pull..."
            rm -f "$TEMPLATE_PATH"
        fi

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
            error_exit "Failed to initiate OCI registry pull. Please check network/PVE API."
        fi

        log_info "Task started with UPID: $UPID. Downloading..."

        # Poll task for completion
        while true; do
            task_status_json=$(pvesh get "/nodes/localhost/tasks/${UPID}/status" --output-format json 2>/dev/null || echo "")
            if [ -n "$task_status_json" ]; then
                status=$(echo "$task_status_json" | python3 -c 'import sys, json; print(json.load(sys.stdin).get("status", "running"))' 2>/dev/null || echo "running")
                exitstatus=$(echo "$task_status_json" | python3 -c 'import sys, json; print(json.load(sys.stdin).get("exitstatus", ""))' 2>/dev/null || echo "")
            else
                status="running"
                exitstatus=""
            fi
            
            if [ "$status" = "stopped" ]; then
                if [ "$exitstatus" = "OK" ]; then
                    log_success "OCI Image pulled and cached successfully."
                    break
                else
                    error_exit "OCI pull task failed (exit status: $exitstatus). Upgrade aborted. Your container is untouched."
                fi
            fi
            echo -n "."
            sleep 3
        done
        echo ""
    fi
fi

# Parse resource configurations
LXC_CONF="/etc/pve/lxc/${CT_ID}.conf"
log_step "Parsing current container configuration..."
CT_HOSTNAME=$(grep "^hostname:" "$LXC_CONF" | head -n 1 | cut -d: -f2- | xargs || echo "frigate-update-temp")
CT_CORES=$(grep "^cores:" "$LXC_CONF" | head -n 1 | cut -d: -f2- | xargs || echo "4")
CT_RAM=$(grep "^memory:" "$LXC_CONF" | head -n 1 | cut -d: -f2- | xargs || echo "4096")
CT_SWAP=$(grep "^swap:" "$LXC_CONF" | head -n 1 | cut -d: -f2- | xargs || echo "512")
CT_UNPRIV=$(grep "^unprivileged:" "$LXC_CONF" | head -n 1 | cut -d: -f2- | xargs || echo "1")

OLD_ROOTFS=$(grep "^rootfs:" "$LXC_CONF" | head -n 1 | cut -d: -f2- | xargs)
CT_STORAGE=$(echo "$OLD_ROOTFS" | cut -d: -f1)
CT_DISK_SIZE=$(echo "$OLD_ROOTFS" | grep -o "size=[^,]*" | head -n 1 | cut -d= -f2 | tr -d 'Gg')
CT_DISK_SIZE=${CT_DISK_SIZE:-10}

log_info "Configuration loaded: Hostname=$CT_HOSTNAME, Cores=$CT_CORES, RAM=$CT_RAM, Storage=$CT_STORAGE, DiskSize=${CT_DISK_SIZE}G"

# Allocate temporary container ID
TEMP_ID=$(pvesh get /cluster/nextid 2>/dev/null | python3 -c 'import sys, json; print(json.load(sys.stdin))' 2>/dev/null || pvesh get /cluster/nextid --output-format text | awk '{print $NF}' || echo "")
if [ -z "$TEMP_ID" ] || [ "$TEMP_ID" = "$CT_ID" ]; then
    TEMP_ID=$((CT_ID + 100))
    while pct status "$TEMP_ID" &>/dev/null; do
        TEMP_ID=$((TEMP_ID + 1))
    done
fi

# Take a safety snapshot on active container
CLEAN_VERSION=$(echo "$VERSION" | tr '.-' '__')
SNAPSHOT_NAME="pre_to_${CLEAN_VERSION}"
log_step "Taking safety snapshot: $SNAPSHOT_NAME..."
if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Would create snapshot '$SNAPSHOT_NAME' for container $CT_ID"
else
    if pct snapshot "$CT_ID" "$SNAPSHOT_NAME" --description "Before update to $VERSION"; then
        log_success "Snapshot $SNAPSHOT_NAME created."
    else
        log_warn "Failed to create snapshot. Proceeding without safety rollback point."
    fi
fi

# Stop existing container if running
WAS_RUNNING=false
if pct status "$CT_ID" | grep -q "running"; then
    WAS_RUNNING=true
    log_step "Stopping container $CT_ID..."
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would stop container $CT_ID"
    else
        pct stop "$CT_ID"
    fi
fi

# Create temporary container
log_step "Creating temporary container $TEMP_ID from new template..."
if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Would create temporary container $TEMP_ID using template ${TEMPLATE_STORAGE}:vztmpl/${OCI_TEMPLATE_NAME}.tar"
else
    pct create "$TEMP_ID" "${TEMPLATE_STORAGE}:vztmpl/${OCI_TEMPLATE_NAME}.tar" \
        --hostname "frigate-update-temp" \
        --cores 1 \
        --memory 512 \
        --swap 512 \
        --rootfs "${CT_STORAGE}:${CT_DISK_SIZE}" \
        --net0 "name=eth0,bridge=vmbr0,ip=dhcp" \
        --ostype unmanaged \
        --unprivileged "$CT_UNPRIV" || error_exit "Failed to create temporary container."
fi

# Mount both containers
if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Would mount container $CT_ID and $TEMP_ID"
else
    log_step "Mounting filesystems..."
    pct mount "$CT_ID" || error_exit "Failed to mount target container."
    pct mount "$TEMP_ID" || { pct unmount "$CT_ID"; pct destroy "$TEMP_ID"; error_exit "Failed to mount source container."; }
fi

M_OLD="/var/lib/lxc/${CT_ID}/rootfs"
M_NEW="/var/lib/lxc/${TEMP_ID}/rootfs"

# Parse mount configs for excludes
excludes=()
# Parse standard Proxmox mount points (mpN)
while IFS= read -r line; do
    [[ "$line" =~ ^mp[0-9]+: ]] || continue
    cpath=""
    if [[ "$line" =~ ,mp=([^,]+) ]]; then
        cpath="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ mp=([^,]+) ]]; then
        cpath="${BASH_REMATCH[1]}"
    fi
    [[ -n "$cpath" ]] || continue
    rel="${cpath#/}"
    excludes+=( --exclude="/${rel}" --exclude="/${rel%/}/" )
done < <(grep -E '^mp[0-9]+:' "$LXC_CONF" || true)

# Parse low-level lxc.mount.entry
while IFS= read -r line; do
    [[ "$line" =~ ^lxc\.mount\.entry: ]] || continue
    fields=($line)
    guest_path="${fields[2]}"
    [[ -n "$guest_path" ]] || continue
    rel="${guest_path#/}"
    excludes+=( --exclude="/${rel}" --exclude="/${rel%/}/" )
done < <(grep -E '^lxc\.mount\.entry:' "$LXC_CONF" || true)

# Sync files
log_step "Syncing files from new template to active container..."
log_info "Excludes: ${excludes[*]}"
if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Would sync files from temporary container mount to active container mount using rsync"
else
    rsync -aHAX --delete "${excludes[@]}" "${M_NEW}/" "${M_OLD}/"
    log_success "Sync completed successfully."
fi

# Unmount filesystems
if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Would unmount filesystems for container $TEMP_ID and $CT_ID"
else
    log_step "Unmounting filesystems..."
    pct unmount "$TEMP_ID" || true
    pct unmount "$CT_ID" || true
fi

# Sync entrypoint configuration if changed
if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Would check and sync entrypoint config between temporary container $TEMP_ID and active container $CT_ID"
else
    NEW_EP=$(pct config "$TEMP_ID" | grep -a "^entrypoint:" | head -n 1 | cut -d: -f2- | xargs || echo "")
    OLD_EP=$(pct config "$CT_ID" | grep -a "^entrypoint:" | head -n 1 | cut -d: -f2- | xargs || echo "")
    if [ -n "$NEW_EP" ] && [ "$NEW_EP" != "$OLD_EP" ]; then
        log_step "Syncing entrypoint configuration..."
        pct set "$CT_ID" --entrypoint "$NEW_EP"
    elif [ -z "$NEW_EP" ] && [ -n "$OLD_EP" ]; then
        log_step "Clearing entrypoint configuration..."
        pct set "$CT_ID" --delete entrypoint
    fi
fi

# Destroy temporary container
log_step "Destroying temporary container $TEMP_ID..."
if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Would destroy temporary container $TEMP_ID"
else
    pct destroy "$TEMP_ID" || log_warn "Failed to destroy temporary container."
fi

# Start updated container
if [ "$WAS_RUNNING" = true ]; then
    log_step "Starting updated container $CT_ID..."
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would start container $CT_ID"
    else
        pct start "$CT_ID" || log_warn "Failed to start container automatically. Try running 'pct start $CT_ID' manually."
    fi
fi

# Update Proxmox summary dashboard notes
log_step "Updating Proxmox summary dashboard..."
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

# Read details for dashboard
GPU_TYPE="none"
if grep -q "nvidia" "$LXC_CONF"; then
    GPU_TYPE="nvidia"
elif grep -q "render" "$LXC_CONF"; then
    GPU_TYPE="intel/amd/vaapi"
fi

CORAL_LINE=""
if grep -q "apex" "$LXC_CONF"; then
    CORAL_LINE="- Coral Detector: PCIe\\n"
elif grep -q "usb" "$LXC_CONF"; then
    CORAL_LINE="- Coral Detector: USB\\n"
fi

# Detect bind mounts
CONFIG_VAL=$(grep "lxc.mount.entry" "$LXC_CONF" | grep -i "config " || echo "")
MEDIA_VAL=$(grep "lxc.mount.entry" "$LXC_CONF" | grep -i "media/frigate " || echo "")
CUSTOM_VAL=$(grep "lxc.mount.entry" "$LXC_CONF" | grep -vE "config |media/frigate |/dev/bus/usb" || echo "")

HOST_CONFIG_PATH=$(echo "$CONFIG_VAL" | awk '{print $2}' || echo "/opt/frigate/config")
HOST_MEDIA_PATH=$(echo "$MEDIA_VAL" | awk '{print $2}' || echo "/opt/frigate/media")

MOUNT_LINE=""
if [ -n "$CUSTOM_VAL" ]; then
    CUSTOM_HOST_M=$(echo "$CUSTOM_VAL" | awk '{print $2}')
    CUSTOM_CONT_M=$(echo "$CUSTOM_VAL" | awk '{print $3}')
    MOUNT_LINE="- External Mount: ${CUSTOM_HOST_M} -> /${CUSTOM_CONT_M}\\n"
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
    log_info "[DRY RUN] Would update dashboard notes for container $CT_ID to:"
    echo "$DESCRIPTION" | sed 's/^/  /'
else
    if pct set "$CT_ID" --description "$DESCRIPTION" &>/dev/null; then
        log_success "Proxmox summary dashboard notes updated for container $CT_ID"
    else
        log_warn "Failed to update Proxmox summary dashboard notes."
    fi
fi

# Finished
echo ""
echo -e "${GREEN}============================================="
echo "   Frigate Container Updated Successfully!   "
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
echo "Verify Frigate status using:"
echo "      pct enter $CT_ID"
echo ""
