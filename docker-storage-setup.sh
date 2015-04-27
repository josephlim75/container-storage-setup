#!/bin/bash

#--
# Copyright 2014 Red Hat, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#++

#  Purpose:  This script grows the root filesystem and sets up LVM volumes
#            for docker metadata and data.
#  Author:   Andy Grimm <agrimm@redhat.com>

set -e

# This section reads the config file (/etc/sysconfig/docker-storage-setup. 
# Currently supported options:
# DEVS: A quoted, space-separated list of devices to be used.  This currently
#       expects the devices to be unpartitioned drives.  If "VG" is not
#       specified, then use of the root disk's extra space is implied.
#
# VG:   The volume group to use for docker storage.  Defaults to the volume
#       group where the root filesystem resides.  If VG is specified and the
#       volume group does not exist, it will be created (which requires that
#       "DEVS" be nonempty, since we don't currently support putting a second
#       partition on the root disk).
#
# The options below should be specified as values acceptable to 'lvextend -L':
#
# ROOT_SIZE: The size to which the root filesystem should be grown.
#
# DATA_SIZE: The desired size for the docker data LV.  Defaults to using all
#            free space in the VG after the root LV and docker metadata LV
#            have been allocated/grown.
#
# Other possibilities: 
# * Support lvm raid setups for docker data?  This would not be very difficult
# if given multiple PVs and another variable; options could be just a simple
# "mirror" or "stripe", or something more detailed.

DATA_LV_NAME="docker-data"
META_LV_NAME="docker-meta"
POOL_LV_NAME="docker-pool"

# LVM thin pool expect some space free in volume group so that it can manage
# internal spare logical volume used for thin meta data repair. Currently
# we use .1% of VG size as meta volume size. So 2% of VG size should be
# good enough for spare volume.
DEFAULT_DATA_SIZE_PERCENT="98"

write_storage_config_file () {
  local storage_options

  if is_lvm_pool_mode;then
    storage_options="DOCKER_STORAGE_OPTIONS=--storage-opt dm.fs=xfs --storage-opt dm.thinpooldev=$POOL_DEVICE_PATH"
  else
    storage_options="DOCKER_STORAGE_OPTIONS=--storage-opt dm.fs=xfs --storage-opt dm.datadev=$DATA_LV_PATH --storage-opt dm.metadatadev=$META_LV_PATH"
  fi
cat <<EOF >/etc/sysconfig/docker-storage
$storage_options
EOF
}

# This is the existing mode where we setup lvm data and meta volumes ofr
# docker use
setup_lvm_data_meta_mode () {
  DATA_LV_PATH=/dev/$VG/$DATA_LV_NAME
  META_LV_PATH=/dev/$VG/$META_LV_NAME

  # Handle the unlikely case where /dev/$VG/docker-{data,meta} do not exist
  if [ ! -e /dev/$VG/$DATA_LV_NAME ] || [ ! -e /dev/$VG/$META_LV_NAME ]; then
    eval $( lvs --nameprefixes --noheadings -o lv_name,kernel_major,kernel_minor $VG | while read line; do
      eval $line
      if [ "$LVM2_LV_NAME" = "$DATA_LV_NAME" ]; then
        echo DATA_LV_PATH=/dev/mapper/$( cat /sys/dev/block/${LVM2_LV_KERNEL_MAJOR}:${LVM2_LV_KERNEL_MINOR}/dm/name )
      elif [ "$LVM2_LV_NAME" = "$META_LV_NAME" ]; then
        echo META_LV_PATH=/dev/mapper/$( cat /sys/dev/block/${LVM2_LV_KERNEL_MAJOR}:${LVM2_LV_KERNEL_MINOR}/dm/name )
      fi
    done )
  fi
}

create_lvm_thin_pool () {
  lvconvert -y --zero n --thinpool $VG/$DATA_LV_NAME --poolmetadata $VG/$META_LV_NAME
  if [ $? -ne 0 ];then
    echo "Converting $VG/docker-data and $VG/docker-meta to LVM thin pool failed. Exiting."
    exit 1
  fi
}

setup_lvm_thin_pool () {
  if ! lvm_pool_exists; then
    create_lvm_thin_pool
  fi

  # docker expects device mapper device and not lvm device. Do the conversion.
  eval $( lvs --nameprefixes --noheadings -o lv_name,kernel_major,kernel_minor $VG | while read line; do
    eval $line
    if [ "$LVM2_LV_NAME" = "$DATA_LV_NAME" ]; then
      echo POOL_DEVICE_PATH=/dev/mapper/$( cat /sys/dev/block/${LVM2_LV_KERNEL_MAJOR}:${LVM2_LV_KERNEL_MINOR}/dm/name )
    fi
    done )
}

lvm_data_volume_exists() {
  local lv_data lvname

  lv_data=$( lvs --noheadings -o lv_name $VG | sed -e 's/^ *//')
  for lvname in $lv_data; do
    if [ "$lvname" == "$DATA_LV_NAME" ]; then
	    return 0
    fi
  done

  return 1
}

lvm_metadata_volume_exists() {
  local lv_data lvname

  lv_data=$( lvs --noheadings -o lv_name $VG | sed -e 's/^ *//')
  for lvname in $lv_data; do
    if [ "$lvname" == "$META_LV_NAME" ]; then
	    return 0
    fi
  done

  return 1
}

# determines if one should use lvm pool mode or not.
should_use_lvm_pool_mode() {
  if [ "$SETUP_LVM_THIN_POOL" == "yes" ];then
    return 0
  fi

  # If pool already exists, then use lvm pool mode.
  if lvm_pool_exists; then
    return 0
  fi

  # Use lvm pool mode as default if user there is no docker-storage-setup
  # file present. Make sure that docker-data and docker-meta volumes are
  # not present (possible after upgrade).

  # docker-stroage-setup exists and user has not set pool mode. So don't
  # use it.
  if [ -e /etc/sysconfig/docker-storage-setup ];then
    return 1
  fi

  # It is possible that it is an upgrade and docker-storage-setup does
  # not exist. Make sure there are no data, metadata volume which
  # exist pre-upgrade.
  if lvm_data_volume_exists || lvm_metadata_volume_exists; then
    return 1
  fi

  # Use lvm pool mode by default.
  return 0
}

# Should return true either if SETUP_LVM_THIN_POOL=yes in config file.
is_lvm_pool_mode () {
  if [ "$USE_LVM_POOL_MODE" == "yes" ];then
    return 0
  fi

  return 1
}

lvm_pool_exists() {
  local lv_data
  local lvname lv lvsize

  lv_data=$( lvs --noheadings -o lv_name,lv_attr --separator , $VG | sed -e 's/^ *//')
  SAVEDIFS=$IFS
  for lv in $lv_data; do
  IFS=,
  read lvname lvattr <<< "$lv"
    # pool logical volume has "t" as first character in its attributes
    if [ "$lvname" == "$POOL_LV_NAME" ] && [[ $lvattr == t* ]]; then
            IFS=$SAVEDIFS
	    return 0
    fi
  done
  IFS=$SAVEDIFS

  return 1
}


if [ -e /etc/sysconfig/docker-storage-setup ]; then
  source /etc/sysconfig/docker-storage-setup
fi

# Determine if pool mode should be used on current setup or not.
if should_use_lvm_pool_mode; then
  USE_LVM_POOL_MODE=yes
fi

# In lvm thin pool mode, effectively data LV is named as pool LV. lvconvert
# takes the data lv name and uses it as pool lv name. And later even to
# resize the data lv, one has to use pool lv name.
#
# Note: lvm2 version should be same or higher than lvm2-2.02.112 for lvm
# thin pool functionality to work properly.
if is_lvm_pool_mode; then
  DATA_LV_NAME=$POOL_LV_NAME

  # If pool exits that means meta lv also exists. LVM tools rename meta
  # lv with suffix _tmeta. Reflect that here.
  if lvm_pool_exists; then
	META_LV_NAME=${POOL_LV_NAME}_tmeta
  else
	META_LV_NAME=${POOL_LV_NAME}meta
  fi
fi

# Read mounts
ROOT_DEV=$( awk '$2 ~ /^\/$/ && $1 !~ /rootfs/ { print $1 }' /proc/mounts )
ROOT_VG=$( lvs --noheadings -o vg_name $ROOT_DEV | sed -e 's/^ *//' -e 's/ *$//')
ROOT_PVS=$( pvs --noheadings -o pv_name,vg_name | awk "\$2 ~ /^$ROOT_VG\$/ { print \$1 }" )

VG_EXISTS=
if [ -z "$VG" ]; then
  VG=$ROOT_VG
  VG_EXISTS=1
else
  for vg_name in $( vgs --noheadings -o vg_name ); do
    if [ "$vg_name" == "$VG" ]; then
      VG_EXISTS=1
      break
    fi
  done
fi

if [ -z "$DEVS" ] && [ -z "$VG_EXISTS" ]; then
  echo "Specified volume group $VG does not exists, and no devices were specified" >&2
  exit 1
fi

PVS=
GROWPART=

if [ -n "$DEVS" ] ; then
  for dev in $DEVS; do
    if expr match $dev ".*[0-9]"; then
      echo "Partition specification unsupported at this time." >&2
      exit 1
    fi
    if [[ $dev != /dev/* ]]; then
      dev=/dev/$dev
    fi
    # Use a single partition of a whole device
    # TODO:
    #   * Consider gpt, or unpartitioned volumes
    #   * Error handling when partition(s) already exist
    #   * Deal with loop/nbd device names. See growpart code
    PARTS=$( awk "\$4 ~ /"$( basename $dev )"[0-9]/ { print \$4 }" /proc/partitions )
    if [ -n "$PARTS" ]; then
      echo "$dev has partitions: $PARTS"
      exit 1
    fi
    size=$(( $( awk "\$4 ~ /"$( basename $dev )"/ { print \$3 }" /proc/partitions ) * 2 - 2048 ))
    cat <<EOF | sfdisk $dev
unit: sectors

${dev}1 : start=     2048, size=  ${size}, Id=8e
EOF
    pvcreate ${dev}1
    PVS="$PVS ${dev}1"
  done

  if [ -z "$VG_EXISTS" ]; then
    vgcreate $VG $PVS
  else
    # TODO:
    #   * Error handling when PV is already part of a VG
    vgextend $VG $PVS
  fi
  GROWPART=1
elif [ "$ROOT_VG" == "$VG" ]; then
  GROWPART=1
fi

# Note that growpart is only variable here because we may someday support
# using separate partitions on the same disk.  Today we fail early in that
# case.  Also note that the way we are doing this, it should support LVM
# RAID for the root device.  In the mirrored or striped case, we are growing
# partitions on all disks, so as long as they match, growing the LV should
# also work.
if [ -n "$GROWPART" ]; then
  for pv in $ROOT_PVS; do
    # Split device & partition.  Ick.
    growpart $( echo $pv | sed -r 's/([^0-9]*)([0-9]+)/\1 \2/' ) || true
    pvresize $pv
  done
fi

# NB: We are growing root here first, because when root and docker share a
# disk, we'll default to giving docker "everything else."  This will be a
# problem if someone tries to assign root a value like"100%FREE".

if [ -n "$ROOT_SIZE" ]; then
  # TODO: Error checking if specified size is <= current size
  lvextend -L $ROOT_SIZE $ROOT_DEV || true
fi

# Reserve 0.1% of the free space in the VG for docker metadata.
# Calculating the based on actual data size might be better, but is
# more difficult do to the range of possible inputs.
VG_SIZE=$( vgs --noheadings --nosuffix --units s -o vg_size $VG )
LV_DATA=$( lvs -a --noheadings -o lv_name,lv_size --units s --nosuffix --separator , $VG | sed -e 's/^ *//')
SAVEDIFS=$IFS
for LV in $LV_DATA; do
  IFS=,
  read LVNAME LVSIZE <<< "$LV"
  if [ "$LVNAME" == "$META_LV_NAME" ]; then
    META_LV_SIZE=$LVSIZE
  elif [ "$LVNAME" == "[$META_LV_NAME]" ]; then
    META_LV_SIZE=$LVSIZE
  elif [ "$LVNAME" == "$DATA_LV_NAME" ]; then
    DATA_LV_SIZE=$LVSIZE
  fi
done
IFS=$SAVEDIFS

META_SIZE=$(( $VG_SIZE / 1000 + 1 ))
if [ ! -n "$META_LV_SIZE" ]; then
  lvcreate -L ${META_SIZE}s -n $META_LV_NAME $VG
fi

# FIXME: The code below all becomes very strange when you consider
# the case of a reboot.  If the config file is using "+N%FREE" specifications,
# it will grow on each reboot until the VG is practically full.

if [ -n "$DATA_LV_SIZE" ]; then
  # TODO: Figure out failure cases other than when the requested 
  # size is larger than the current size.  For now, we just let
  # lvextend fail.
  if [ -n "$DATA_SIZE" ]; then
    if [[ $DATA_SIZE == *%* ]]; then
      lvextend -l $DATA_SIZE $VG/$DATA_LV_NAME || true
    else
      lvextend -L $DATA_SIZE $VG/$DATA_LV_NAME || true
    fi
  fi
elif [ -n "$DATA_SIZE" ]; then
  # TODO: Error handling when DATA_SIZE > available space.
  if [[ $DATA_SIZE == *%* ]]; then
    lvcreate -l $DATA_SIZE -n $DATA_LV_NAME $VG
  else
    lvcreate -L $DATA_SIZE -n $DATA_LV_NAME $VG
  fi
else
  lvcreate -l "$DEFAULT_DATA_SIZE_PERCENT%FREE" -n $DATA_LV_NAME $VG
fi

# Set up lvm thin pool LV
if is_lvm_pool_mode;then
  setup_lvm_thin_pool
else
  setup_lvm_data_meta_mode
fi

write_storage_config_file
