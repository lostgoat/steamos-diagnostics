#!/bin/bash

# Copyright © Valve Corporation, 2024

declare -r CACHE=~/diagnostics
declare -r BLOCKDEVS=${CACHE}/blockinfo.txt
declare -r STORAGE=${CACHE}/storage.json
declare -r OFFLOAD=.steamos/offload
declare -r SMART=${CACHE}/smart

mkdir -p $CACHE/mnt
echo > $BLOCKDEVS

_log () { echo "$@" >&2; }

copy_efi_fs ()
{
    sudo mount -o ro /dev/$2 $CACHE/mnt
    _log "Copying $1 (/dev/$2) data"
    cp -a $CACHE/mnt $CACHE/"$2"-"$1"
    sudo umount $CACHE/mnt
    sleep 3
}

list_packages ()
{
    sudo mount -o ro /dev/$2 $CACHE/mnt
    _log "Listing installed packages on $1"

    find $CACHE/mnt/usr/lib/holo/pacmandb/local/ \
         -mindepth 1 -maxdepth 1 -name '[a-z]'\* | \
        sed -re 's/^.*\///' > $CACHE/"$2"-"$1".packages.txt

    _log "Recording OS version on $1"
    cp $CACHE/mnt/etc/os-release $CACHE/"$2-$1".os-release.txt

    sudo umount $CACHE/mnt
    sleep 3
}

recover_logs ()
{
    _log "Capturing fsck information for /dev/$1"
    sudo fsck.ext4 -r -f -n -v /dev/$1 > $CACHE/fsck.$1.txt

    _log "Trying to access filesystem on /dev/$1"
    sudo mount -o ro /dev/$1 $CACHE/mnt

    _log "Copying /var/log from /dev/$1 to $CACHE/var-log-$1.tar"
    (cd $CACHE/mnt/$OFFLOAD/var/log && \
     sudo tar -caf $CACHE/var-log-"$1".tar .)
    
    _log "Recursive listing of /dev/$1"
    (cd $CACHE/mnt && sudo ls -alR .) > $CACHE/ls-alR.$1.txt
    
    sudo umount $CACHE/mnt
    sleep 3
}

############################################################################
# all lsblk data
_log "Storing block device information"
lsblk -J -d -O > $STORAGE

############################################################################
# firmware etc
_log "Recording Firmware versions"
amd_system_info > $CACHE/amd_system_info.txt

############################################################################
# smart
_log "Storing SMART status"
while read dev
do
    sudo smartctl --all /dev/$dev > ${SMART}.txt
    sudo smartctl -j --all /dev/$dev > ${SMART}.json
done < <(lsblk -dran -o name | grep -v ^sda)

############################################################################
# journal from recovery image
journalctl > $CACHE/recovery-image-journal.txt

############################################################################
# efi and esp data, contents of /var/log
while read dev partlabel fstype partuuid fsuuid
do
    echo "$dev $partlabel $fstype $partuuid $fsuuid" >> $BLOCKDEVS
    case $dev in sda*) continue ;; esac
    case $partlabel in
        esp|efi*) copy_efi_fs   "$partlabel" $dev ;;
        rootfs-*) list_packages "$partlabel" $dev ;; 
        home*)    recover_logs  $dev ;;
    esac
done < <(lsblk -ro name,partlabel,fstype,partuuid,uuid)

_log "Compressing $CACHE to $CACHE.tar.xz"
tar -caf $CACHE.tar.xz $CACHE
_log "$CACHE.tar.xz is ready"

rm -r $CACHE


############################################################################
