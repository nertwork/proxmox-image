#!/usr/bin/env bash
export PATH="/usr/sbin:$PATH"
usage()
{
cat << EOF
usage: $0 options

This script will download ubuntu cloud images to proxmox

OPTIONS:
   -i      VM ID (REQUIRED)*
   -h      Show this message
   -d      Storage Location
   -r      Release
   -e      Remote Host
   -s      Remote Host VM ID (Required if remote host)
   -v      Verbose
EOF
}

STORAGE_POOL='local-zfs'
RELEASE='focal'
VM_ID=
VM_ID_SECONDARY=
REMOTE_HOST=
VERBOSE=
while getopts “h:d:r:i:e:s:v” OPTION
do
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

if [[ -z $VM_ID ]]
then
     usage
     exit 1
fi

if [[ ! -z $REMOTE_HOST ]]
then
  if [[ -z $VM_ID_SECONDARY ]]
  then
     usage
     exit 1
  fi
fi

#Install qemu-guest-agent on Ubuntu Cloud Image
#This step will install qemu-guest-agent on the Ubuntu cloud image via virt-customize. The libguestfs-tools package must be installed on the system where the ubuntu cloudimg will be modified.
cd /tmp
rm /tmp/${RELEASE}-server-cloudimg-amd64.* || true

wget -q https://cloud-images.ubuntu.com/${RELEASE}/current/${RELEASE}-server-cloudimg-amd64.img

# Install libguestfs-tools on Proxmox server.
apt-get install libguestfs-tools
# Install qemu-guest-agent on Ubuntu image.
virt-customize -a ${RELEASE}-server-cloudimg-amd64.img --install qemu-guest-agent
# Enable password authentication in the template. Obviously, not recommended for except for testing.
virt-customize -a ${RELEASE}-server-cloudimg-amd64.img --run-command "sed -i 's/.*PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config" || true

#Create Proxmox VM from Ubuntu Cloud Image
# Set environment variables. Change these as necessary.
VM_NAME="ubuntu-${RELEASE}-cloudimg"

echo $VM_ID_SECONDARY

# Create Proxmox VM image from Ubuntu Cloud Image.
qm destroy $VM_ID
qm create $VM_ID --memory 2048 --net0 virtio,bridge=vmbr0
qm importdisk $VM_ID ${RELEASE}-server-cloudimg-amd64.img $STORAGE_POOL
qm set $VM_ID --scsihw virtio-scsi-pci --scsi0 $STORAGE_POOL:vm-$VM_ID-disk-0
qm set $VM_ID --scsihw virtio-scsi-pci --ide2 $STORAGE_POOL:vm-$VM_ID-cloudinit,media=cdrom
qm set $VM_ID --agent enabled=1,fstrim_cloned_disks=1
qm set $VM_ID --name $VM_NAME

# Create Cloud-Init Disk and configure boot.
qm set $VM_ID --ide2 $STORAGE_POOL:cloudinit
qm set $VM_ID --boot c --bootdisk scsi0
qm set $VM_ID --serial0 socket --vga serial0

#Convert VM to Template
qm template $VM_ID

if [[ ! -z $VM_ID_SECONDARY ]]
then
        ssh -tt $REMOTE_HOST qm destroy $VM_ID_SECONDARY
        qm clone $VM_ID $VM_ID_SECONDARY --full --name $VM_NAME
        qm migrate $VM_ID_SECONDARY $REMOTE_HOST
        ssh -tt $REMOTE_HOST qm template $VM_ID_SECONDARY
fi

#Clean Up
rm ${RELEASE}-server-cloudimg-amd64.img
