#!/usr/bin/env bash
export PATH="/usr/sbin:$PATH"

usage() {
cat << EOF
usage: $0 options

This script will download Ubuntu or Rocky Linux cloud images to Proxmox

OPTIONS:
   -i      VM ID (REQUIRED)*
   -h      Show this message
   -d      Storage Location
   -r      Release (e.g., ubuntu-focal, ubuntu-jammy, rocky8)
   -e      Remote Host
   -s      Remote Host VM ID (Required if remote host)
   -v      Verbose
EOF
}

STORAGE_POOL='local-zfs'
RELEASE='ubuntu-focal'
VM_ID=
VM_ID_SECONDARY=
REMOTE_HOST=
VERBOSE=

while getopts "h:d:r:i:e:s:v" OPTION; do
     case $OPTION in
         h)
             usage
             exit 1
             ;;
         d)
             STORAGE_POOL=$OPTARG
             ;;
         r)
             RELEASE=$OPTARG
             ;;
         i)
             VM_ID=$OPTARG
             ;;
         e)
             REMOTE_HOST=$OPTARG
             ;;
         s)
             VM_ID_SECONDARY=$OPTARG
             ;;
         ?)
             usage
             exit
             ;;
     esac
done

if [[ -z $VM_ID ]]; then
     usage
     exit 1
fi

if [[ ! -z $REMOTE_HOST && -z $VM_ID_SECONDARY ]]; then
     usage
     exit 1
fi

# Install necessary tools
apt-get update
apt-get install -y libguestfs-tools

# Download and prepare cloud image
cd /tmp
rm -f /tmp/*.img /tmp/*.qcow2 || true

case $RELEASE in

    ubuntu-*)
        VERSION=${RELEASE#ubuntu-}  # remove "ubuntu-" from the start of $RELEASE
        wget -q https://cloud-images.ubuntu.com/${VERSION}/current/${VERSION}-server-cloudimg-amd64.img
        IMAGE_NAME="${VERSION}-server-cloudimg-amd64.img"

        # Install qemu-guest-agent on the cloud image
        virt-customize -a ${IMAGE_NAME} --install qemu-guest-agent \
                --run-command "systemctl enable qemu-guest-agent" \
                --run-command "systemctl start qemu-guest-agent" \
                --run-command "mkdir -p /etc/cloud/cloud.cfg.d" \
                --run-command "echo -e 'datasource_list: [ NoCloud, None ]\npackage_update: false\npackage_upgrade: false\ncloud_final_modules:\n  - package-update-upgrade-install: {update: false, upgrade: false}\nruncmd:\n  - systemctl start qemu-guest-agent' > /etc/cloud/cloud.cfg.d/99-disable-updates.cfg"
        ;;

    rocky*)
        VERSION=${RELEASE#rocky}  # remove "rocky" from the start of $RELEASE
        wget -q https://dl.rockylinux.org/pub/rocky/${VERSION}/images/x86_64/Rocky-${VERSION}-GenericCloud.latest.x86_64.qcow2
        IMAGE_NAME="Rocky-${VERSION}-GenericCloud.latest.x86_64.qcow2"

        # Install qemu-guest-agent on the cloud image
        virt-customize -a ${IMAGE_NAME} --run-command "yum remove -y qemu-guest-agent || true" \
               --run-command "yum install -y qemu-guest-agent" \
               --run-command "systemctl enable qemu-guest-agent" \
               --run-command "restorecon -R -v /usr/bin/qemu-ga" \
               --run-command "sed -i 's/SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config" \
               --run-command "mkdir -p /etc/cloud/cloud.cfg.d" \
               --run-command "echo -e 'datasource_list: [ NoCloud, None ]\npackage_update: false\npackage_upgrade: false\ncloud_final_modules:\n  - package-update-upgrade-install: {update: false, upgrade: false}\nruncmd:\n  - systemctl start qemu-guest-agent' > /etc/cloud/cloud.cfg.d/99-disable-updates.cfg"

        ;;
    *)
        echo "Unsupported release: $RELEASE"
        exit 1
        ;;
esac


# Enable password authentication in the template
virt-customize -a ${IMAGE_NAME} --run-command "sed -i 's/.*PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config" || true

# Create Proxmox VM from cloud image
VM_NAME="${RELEASE}-cloudimg"

echo $VM_ID_SECONDARY

qm destroy $VM_ID
qm create $VM_ID --memory 2048 --net0 virtio,bridge=vmbr0
qm importdisk $VM_ID ${IMAGE_NAME} $STORAGE_POOL
qm set $VM_ID --scsihw virtio-scsi-pci --scsi0 $STORAGE_POOL:vm-$VM_ID-disk-0
qm set $VM_ID --scsihw virtio-scsi-pci --ide2 $STORAGE_POOL:vm-$VM_ID-cloudinit,media=cdrom
qm set $VM_ID --agent enabled=1,fstrim_cloned_disks=1
qm set $VM_ID --name $VM_NAME

# Create Cloud-Init Disk and configure boot
qm set $VM_ID --ide2 $STORAGE_POOL:cloudinit
qm set $VM_ID --boot c --bootdisk scsi0
qm set $VM_ID --serial0 socket --vga serial0

# Convert VM to template
qm template $VM_ID

if [[ ! -z $VM_ID_SECONDARY ]]; then
        ssh -tt $REMOTE_HOST qm destroy $VM_ID_SECONDARY
        qm clone $VM_ID $VM_ID_SECONDARY --full --name $VM_NAME
        qm migrate $VM_ID_SECONDARY $REMOTE_HOST
        ssh -tt $REMOTE_HOST qm template $VM_ID_SECONDARY
fi

# Clean up
rm -f ${IMAGE_NAME}
