#!/bin/bash
set -e

DISK="/dev/sda"
EFI_SIZE="1G"
HOSTNAME="archvm"
USERNAME="usuario"
PASSWORD="changeme"
LOCALE="es_AR.UTF-8"
KEYMAP="es-winkeys"
TIMEZONE="America/Argentina/Buenos_Aires"

echo "[1/8] Formateando disco $DISK..."
sgdisk --zap-all "$DISK"
sgdisk -n1:0:+$EFI_SIZE -t1:ef00 "$DISK"
sgdisk -n2:0:0 -t2:8300 "$DISK"

EFI_PART="${DISK}1"
LUKS_PART="${DISK}2"

echo "[2/8] Configurando LUKS + Btrfs..."
echo -n "$PASSWORD" | cryptsetup luksFormat "$LUKS_PART" -
echo -n "$PASSWORD" | cryptsetup open "$LUKS_PART" cryptroot -

mkfs.fat -F32 "$EFI_PART"
mkfs.btrfs /dev/mapper/cryptroot

mount /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/@
umount /mnt

# ⚙️ Opciones optimizadas para SSD: noatime, compress=zstd, discard=async, ssd
mount -o noatime,compress=zstd,ssd,discard=async,subvol=@ /dev/mapper/cryptroot /mnt
mkdir -p /mnt/boot/efi
mount "$EFI_PART" /mnt/boot/efi

echo "[3/8] Instalando base del sistema..."
pacstrap /mnt base linux-hardened linux-firmware btrfs-progs vim sudo grub efibootmgr networkmanager

echo "[4/8] Configurando sistema..."
genfstab -U /mnt >> /mnt/etc/fstab

arch-chroot /mnt /bin/bash <<EOF
echo "$HOSTNAME" > /etc/hostname
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

echo "$LOCALE UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

echo "[5/8] Instalando GRUB con soporte LUKS + EFI..."
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect keyboard keymap modconf block encrypt filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -p linux-hardened

echo -e "$PASSWORD\n$PASSWORD" | passwd root

useradd -m -G wheel $USERNAME
echo -e "$PASSWORD\n$PASSWORD" | passwd $USERNAME
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

UUID=\$(blkid -s UUID -o value $LUKS_PART)
cat <<GRUBCFG > /etc/default/grub
GRUB_DEFAULT=0
GRUB_TIMEOUT=3
GRUB_DISTRIBUTOR="Arch"
GRUB_CMDLINE_LINUX="cryptdevice=UUID=\$UUID:cryptroot root=/dev/mapper/cryptroot"
GRUB_PRELOAD_MODULES="part_gpt part_msdos"
GRUB_ENABLE_CRYPTODISK=y
GRUBCFG

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Arch
grub-mkconfig -o /boot/grub/grub.cfg

systemctl enable NetworkManager
EOF

echo "[6/8] ¡Instalación completada! Puedes reiniciar."
