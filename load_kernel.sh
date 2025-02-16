#!/bin/bash
set -euo pipefail

# ========= Configuration Variables =========
VM_NAME="fedora-vm"
DISK_IMAGE="fedora_vm.qcow2"
# Fedora Cloud Base image (adjust URL as needed)
CLOUD_IMAGE="Fedora-Cloud-Base-38-1.6.x86_64.qcow2"
CLOUD_IMAGE_URL="https://download.fedoraproject.org/pub/fedora/linux/releases/38/Cloud/x86_64/images/${CLOUD_IMAGE}"
CLOUD_INIT_ISO="seed.iso"
OUT_DIR="$(pwd)/out"    # Directory containing compiled kernel artifacts (from Docker build)
SSH_USER="user"
SSH_PASS="fedora"        # Default password (set in cloud-init below)

# VM resources
RAM_MB=20480            # 20GB RAM
VCPUS=16                # 16 vCPUs
DISK_SIZE="35G"         # Disk image size

# ========= Helper Functions =========
log() {
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] $*"
}

# ========= 1. Prepare the VM Disk and Cloud Image =========

# If the disk image doesn't exist, create it using the Fedora Cloud image as backing file.
if [ ! -f "$DISK_IMAGE" ]; then
    log "Disk image '$DISK_IMAGE' not found; creating a new 35GB disk image..."
    if [ ! -f "$CLOUD_IMAGE" ]; then
        log "Downloading Fedora Cloud image..."
        wget -O "$CLOUD_IMAGE" "$CLOUD_IMAGE_URL" || { log "Error downloading Fedora Cloud image"; exit 1; }
    fi
    log "Creating qcow2 disk with backing file..."
    # Specify backing file format with -F
    qemu-img create -f qcow2 -b "$CLOUD_IMAGE" -F qcow2 "$DISK_IMAGE" "$DISK_SIZE" || { log "Error creating disk image"; exit 1; }
fi

# ========= 2. Create Cloud-Init ISO =========
if [ ! -f "$CLOUD_INIT_ISO" ]; then
    log "Creating cloud-init ISO for initial VM configuration..."
    mkdir -p cloudinit
    # Generate user-data (configures a user with sudo privileges and SSH password auth enabled)
    cat > cloudinit/user-data <<EOF
#cloud-config
users:
  - name: ${SSH_USER}
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: wheel
    shell: /bin/bash
    ssh_pwauth: True
    lock_passwd: false
    passwd: $(openssl passwd -6 ${SSH_PASS})
chpasswd:
  list: |
    ${SSH_USER}:${SSH_PASS}
  expire: False
ssh_pwauth: True
EOF

    # Minimal meta-data
    cat > cloudinit/meta-data <<EOF
instance-id: ${VM_NAME}
local-hostname: ${VM_NAME}
EOF

    # Create the ISO (requires genisoimage; if not available, try mkisofs)
    genisoimage -output "${CLOUD_INIT_ISO}" -volid cidata -joliet -rock cloudinit/user-data cloudinit/meta-data \
        || { log "Error creating cloud-init ISO"; exit 1; }
    rm -rf cloudinit
fi

# ========= 3. Launch the QEMU VM =========
log "Launching QEMU VM with ${RAM_MB}MB RAM and ${VCPUS} vCPUs..."

# Launch QEMU in background (using -nographic so it runs in the current terminal)
qemu-system-x86_64 \
    -enable-kvm \
    -m ${RAM_MB} \
    -smp ${VCPUS} \
    -drive file="${DISK_IMAGE}",format=qcow2 \
    -cdrom "${CLOUD_INIT_ISO}" \
    -boot d \
    -net user,hostfwd=tcp::2222-:22 \
    -net nic \
    -fsdev local,id=host_out,path="${OUT_DIR}",security_model=passthrough \
    -device virtio-9p-pci,fsdev=host_out,mount_tag=host_out \
    -nographic &

VM_PID=$!
log "VM launched (PID ${VM_PID})."

# ========= 4. Wait for SSH Access =========
log "Waiting for SSH on port 2222..."
for i in {1..30}; do
    if nc -z localhost 2222; then
        log "SSH is available!"
        break
    fi
    sleep 10
done

if ! nc -z localhost 2222; then
    log "Error: SSH did not become available. Exiting."
    exit 1
fi

# ========= 5. Install the Custom Kernel in the VM =========
log "Connecting via SSH to install the custom kernel..."
ssh -o StrictHostKeyChecking=no -p 2222 ${SSH_USER}@localhost <<'REMOTE_EOF'
set -euo pipefail
log() { echo "[$(date +"%Y-%m-%d %H:%M:%S")] $*"; }

log "Ensuring shared folder is mounted..."
if ! mountpoint -q /host_out; then
    sudo mkdir -p /host_out
    sudo mount -t 9p -o trans=virtio host_out /host_out || { log "Error mounting shared folder"; exit 1; }
fi

log "Verifying compiled kernel artifacts exist in /host_out/kernel_artifacts..."
if [ ! -f /host_out/kernel_artifacts/bzImage ]; then
    log "Error: Kernel image not found at /host_out/kernel_artifacts/bzImage"
    exit 1
fi

# Determine kernel version from the modules directory name
KVER=$(ls /host_out/kernel_artifacts/lib/modules 2>/dev/null | head -n 1)
if [ -z "$KVER" ]; then
    log "Error: Could not detect kernel version from /host_out/kernel_artifacts/lib/modules"
    exit 1
fi
log "Detected custom kernel version: $KVER"

log "Copying new kernel image to /boot/vmlinuz-custom..."
sudo cp /host_out/kernel_artifacts/bzImage /boot/vmlinuz-custom

log "Installing kernel modules..."
sudo mkdir -p /lib/modules/$KVER
sudo cp -r /host_out/kernel_artifacts/lib/modules/$KVER/* /lib/modules/$KVER/

log "Generating initramfs for the new kernel..."
sudo dracut -f /boot/initramfs-custom.img $KVER

log "Adding new kernel entry to GRUB via grubby..."
sudo grubby --add-kernel=/boot/vmlinuz-custom --initrd=/boot/initramfs-custom.img --title="Custom Kernel $KVER" || {
    log "grubby failed; updating GRUB configuration manually..."
    sudo grub2-mkconfig -o /boot/grub2/grub.cfg
}

log "Verifying new GRUB entry..."
if sudo grubby --default-kernel | grep -q "vmlinuz-custom"; then
    log "Custom kernel is now set as the default."
else
    log "Custom kernel added. Please review GRUB configuration if needed."
fi

log "Kernel installation complete. You may reboot the VM to boot into the new kernel."
REMOTE_EOF

log "Kernel installation completed inside the VM."
log "You can SSH into the VM using: ssh -p 2222 ${SSH_USER}@localhost"
log "To reboot the VM and test the new kernel, SSH into the VM and run: sudo reboot"
log "The VM will persist between reboots. To stop the VM, kill the process with PID ${VM_PID}."
