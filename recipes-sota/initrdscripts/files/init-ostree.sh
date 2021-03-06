#!/bin/sh

#/*
#*init.sh , a script to init the ostree system in initramfs
#* 
#* Copyright (c) 2018 Wind River Systems, Inc.
#* 
#* This program is free software; you can redistribute it and/or modify
#* it under the terms of the GNU General Public License version 2 as
#* published by the Free Software Foundation.
#* 
#* This program is distributed in the hope that it will be useful,
#* but WITHOUT ANY WARRANTY; without even the implied warranty of
#* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
#* See the GNU General Public License for more details.
#* 
#* You should have received a copy of the GNU General Public License
#* along with this program; if not, write to the Free Software
#* Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307 USA
#* 
#*/ 

log_info() { echo "$0[$$]: $*" >&2; }
log_error() { echo "$0[$$]: ERROR $*" >&2; }

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/lib/ostree:/usr/lib64/ostree

ROOT_MOUNT="/sysroot"
MOUNT="/bin/mount"
UMOUNT="/bin/umount"
ROOT_DELAY="0"
OSTREE_SYSROOT=""
#OSTREE_LABEL_BOOT="otaboot"
OSTREE_BOOT_DEVICE="LABEL=otaboot"
OSTREE_LABEL_FLUXDATA="fluxdata"
SKIP_BOOT_DIFF=""
# The timeout (tenth of a second) for rootfs on low speed device
MAX_TIMEOUT_FOR_WAITING_LOWSPEED_DEVICE=60

# Copied from initramfs-framework. The core of this script probably should be
# turned into initramfs-framework modules to reduce duplication.
udev_daemon() {
	OPTIONS="/sbin/udev/udevd /sbin/udevd /lib/udev/udevd /lib/systemd/systemd-udevd"

	for o in $OPTIONS; do
		if [ -x "$o" ]; then
			echo $o
			return 0
		fi
	done

	return 1
}

_UDEV_DAEMON=`udev_daemon`

do_mount_fs() {
	echo "mounting FS: $*"
	[[ -e /proc/filesystems ]] && { grep -q "$1" /proc/filesystems || { log_error "Unknown filesystem"; return 1; } }
	[[ -d "$2" ]] || mkdir -p "$2"
	[[ -e /proc/mounts ]] && { grep -q -e "^$1 $2 $1" /proc/mounts && { log_info "$2 ($1) already mounted"; return 0; } }
	mount -t "$1" "$1" "$2"
}

early_setup() {

	do_mount_fs proc /proc
	do_mount_fs sysfs /sys
	mount -t devtmpfs none /dev
	do_mount_fs tmpfs /tmp
	do_mount_fs tmpfs /run

	$_UDEV_DAEMON --daemon
	udevadm trigger --action=add

	if [ -x /sbin/mdadm ]; then
		/sbin/mdadm -v --assemble --scan --auto=md
	fi
}

read_args() {
	[ -z "$CMDLINE" ] && CMDLINE=`cat /proc/cmdline`
	for arg in $CMDLINE; do
		optarg=`expr "x$arg" : 'x[^=]*=\(.*\)'`
		case $arg in
			ostree_root=*)
				OSTREE_ROOT_DEVICE=$optarg ;;
			root=*)
				ROOT_DEVICE=$optarg ;;
			rootdelay=*)
				ROOT_DELAY=$optarg ;;
			skip-boot-diff=*)
				SKIP_BOOT_DIFF=$optarg ;;
			rootflags=*)
				ROOT_FLAGS=$optarg ;;
			init=*)
				INIT=$optarg ;;
			ostree_boot=*)
				OSTREE_BOOT_DEVICE=$optarg ;;
			flux=*)
				OSTREE_LABEL_FLUXDATA=$optarg ;;
		esac
	done
}

expand_fluxdata() {

	fluxdata_label=$OSTREE_LABEL_FLUXDATA
	[ -z $fluxdata_label ] && echo "No fluxdata partition found." && return 0

	# expanding FLUXDATA
	datapart=$(blkid -s LABEL | grep "LABEL=\"$fluxdata_label\"" |head -n 1| awk -F: '{print $1}')

	# no fluxdata or fluxdata is a LUKS(expanding done at LUKS creation)
	[ -z ${datapart} ] && {
		datapart=$(blkid -s LABEL | grep "LABEL=\"luks$fluxdata_label\"" |head -n 1| awk -F: '{print $1}')
		[ -z ${datapart} ] && return 0
	}

	datadev=$(lsblk $datapart -n -o PKNAME | head -n 1)
	datadevnum=$(echo ${datapart} | sed 's/\(.*\)\(.\)$/\2/')

	disk_sect=`fdisk -l /dev/$datadev | head -1 |awk '{print $7}'`
	part_end=`fdisk -l /dev/$datadev | grep ^${datapart} | awk '{print $3}'`
	disk_end=$(expr $disk_sect - 1026)
	if [ $part_end -ge $disk_end ]; then
		echo "No fluxdata expansion." && return 0
	fi

	echo "Expanding partition for ${fluxdata_label} ..."
	parted -s /dev/$datadev -- resizepart $datadevnum 100%

	echo "Expanding FS for ${fluxdata_label} ..."
	resize2fs -f ${datapart}
}

fatal() {
	echo $1 >$CONSOLE
	echo >$CONSOLE
	sleep 5
	echo b > /proc/sysrq-trigger
	exec sh
}

#######################################

early_setup

read_args

[ -z "$CONSOLE" ] && CONSOLE="/dev/console"
[ -z "$INIT" ] && INIT="/sbin/init"

udevadm settle --timeout=3

mkdir -p $ROOT_MOUNT/

sleep ${ROOT_DELAY}

[ -z $OSTREE_ROOT_DEVICE ] && fatal "No OSTREE root device specified, please add 'ostree_root=LABEL=xyz' in bootline!" || {
	echo "Waiting for low speed devices to be ready ..."
	OSTREE_LABEL_ROOT=$(echo $OSTREE_ROOT_DEVICE | cut -f 2 -d'=')
	retry=0
	# For LUKS, we might wait for MAX_TIMEOUT_FOR_WAITING_LOWSPEED_DEVICE/10s
	while [ $retry -lt $MAX_TIMEOUT_FOR_WAITING_LOWSPEED_DEVICE ] ; do
		retry=$(($retry+1))
		blkid -t LABEL=$OSTREE_LABEL_ROOT && break
		blkid -t LABEL=luks$OSTREE_LABEL_ROOT && break
		#echo "sleep to wait for $OSTREE_ROOT_DEVICE"
		sleep 0.1
	done
}
try_to_mount_rootfs() {
	local mount_flags="rw,noatime,iversion"
	mount_flags="${mount_flags},${ROOT_FLAGS}"

	mount -o $mount_flags "${OSTREE_ROOT_DEVICE}" "${ROOT_MOUNT}" 2>/dev/null && return 0
}

expand_fluxdata

[ -x /init.luks-ostree ] && {
	/init.luks-ostree $OSTREE_LABEL_ROOT $OSTREE_LABEL_FLUXDATA && echo "LUKS init done." || fatal "Couldn't init LUKS, dropping to shell"
}

echo "Waiting for root device to be ready..."
while [ 1 ] ; do
	try_to_mount_rootfs && break
	sleep 0.1
done

if [ ! -d "${ROOT_MOUNT}/boot" ] ; then
	mkdir -p ${ROOT_MOUNT}/boot
fi

echo "Waiting for boot device to be ready..."
while [ 1 ] ; do
	mount "${OSTREE_BOOT_DEVICE}" "${ROOT_MOUNT}/boot" && break
	sleep 0.1
done

OSTREE_DEPLOY=`ostree-prepare-root ${ROOT_MOUNT} | awk -F ':' '{print $2}'`

if [ -z ${OSTREE_DEPLOY} ]; then
	echo "Unable to deploy ostree ${ROOT_MOUNT}"
	fatal
fi

sed "/LABEL=otaboot[\t ]*\/boot[\t ]/s/LABEL=otaboot/${OSTREE_BOOT_DEVICE}/g" -i ${ROOT_MOUNT}/etc/fstab
sed "/LABEL=otaboot_b[\t ]*\/boot[\t ]/s/LABEL=otaboot_b/${OSTREE_BOOT_DEVICE}/g" -i ${ROOT_MOUNT}/etc/fstab
sed "/LABEL=fluxdata[\t ]*\/var[\t ]/s/LABEL=fluxdata/LABEL=${OSTREE_LABEL_FLUXDATA}/g" -i ${ROOT_MOUNT}/etc/fstab

udevadm control -e

cd $ROOT_MOUNT
for x in dev proc sys; do
	log_info "Moving /$x to new rootfs"
	mount --move "/$x" "$x"
done

# If we pass args to bash, it will assume they are text files
# to source and run.
if [ "$INIT" == "/bin/bash" ] || [ "$INIT" == "/bin/sh" ]; then
	CMDLINE=""
fi

# Start checking ostree contents
mount -t proc none /proc

# Check for skip-boot-diff
if [ "${SKIP_BOOT_DIFF}" != "" ] ; then
	skip="${SKIP_BOOT_DIFF}"
else
	skip=`ostree config --repo=/sysroot/ostree/repo get upgrade.skip-boot-diff 2> /dev/null`
fi

if [ "$skip" = "" ] ; then
	skip=0
fi

if [ ${skip} -lt 1 ] ; then

	/usr/bin/ostree fsck --repo=/sysroot/ostree/repo
	if [ $? -ne 0 ]; then
		echo "Ostree repo is damaged..."
		fatal
	fi
fi

if [ ${skip} -lt 2 ] ; then

	ostree_ref="${OSTREE_DEPLOY##*/}"
	ostree_ref="${ostree_ref%%.*}"

	if [ -z "${ostree_ref}" ]; then
		echo "No ostree ref found"
		#fatal
		exec sh
	fi

	log_info "Checking ostree ${ostree_ref} contents... with ${OSTREE_DEPLOY}"

	/usr/bin/ostree diff --repo=/sysroot/ostree/repo ${ostree_ref} ${OSTREE_DEPLOY}| grep "[MD] */usr/"

	if [ $? -eq 0 ]; then
		echo "Ostree deploy content is corrupted..."
		fatal
	fi
fi

umount /proc

# !!! The Big Fat Warnings !!!
#
# The IMA policy may enforce appraising the executable and verifying the
# signature stored in xattr. However, ramfs doesn't support xattr, and all
# other initializations must *NOT* be placed after IMA initialization!
[ -x /init.ima ] && /init.ima $ROOT_MOUNT && {
	# switch_root is an exception. We call it in the real rootfs and it
	# should be already signed properly.
	switch_root="usr/sbin/switch_root.static"
} || {
	switch_root="switch_root"
}

exec $switch_root $ROOT_MOUNT $INIT $CMDLINE || fatal "Couldn't switch_root, dropping to shell"
