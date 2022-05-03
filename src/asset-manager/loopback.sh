#!/bin/bash

create_loopback() {
	local major=7
	local minor=$1
	local path="/dev/loop${minor}"
	if [ ! -f $1 ]; then
		mknod "${path}" b "${major}" "${minor}"
	fi
}

setup_loopback() {
	local image_path=${1}

	losetup --find \
		--partscan \
		--show \
		${image_path}
}

teardown_loopback() {
	local loopback_device=$1
	local mounts=$(mount | grep "${loopback_device}" | cut -d' ' -f1)
	for mount in ${mounts}; do
		umount -R "${mount}"
	done

	losetup --detach "${loopback_device}"
}
