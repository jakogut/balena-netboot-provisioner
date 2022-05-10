#!/usr/bin/env bash

set -eu

[[ $VERBOSE =~ on|On|Yes|yes|true|True ]] && set -x

BALENA_API_URL=${BALENA_API_URL:-balena-cloud.com}
OS_VERSION=${OS_VERSION:-2.95.12%2brev1}
DRY_RUN=${DRY_RUN:-true}
CLOBBER=${CLOBBER:-false}

function cleanup() {
   rm -f /var/tftp/.ready

   mountpoint /mnt && umount -R /mnt
}
trap 'cleanup' EXIT

while ! [ -f /certs/.ready ]; do sleep "$(( (RANDOM % 5) + 5 ))s"; done

# CA bundle to be consumed by cURL
# export CURL_CA_BUNDLE) or https://serverfault.com/questions/485597/default-ca-cert-bundle-location
cat < /certs/ca-bundle.pem | openssl x509 -noout -text

download_balenaos() {
	local fleet_id=${1}
	local api_key=${2}
	local version=${3}
	local output=$4
	local filetype=".gz"
	local local_filsz
	local req
	local remote_filsz
	local request_args=(
		--get
		--header "Authorization: Bearer ${api_key}"
		--data "version=${version}"
		--data "fileType=${filetype}"
		--data "appId=${fleet_id}"
		--fail
	)
	local_filsz=$(if [ -f "${output}".gz ]; then du -b "${output}.gz" | cut -f1; else echo -1; fi)
	remote_filsz=0
	req=$(curl "${BALENA_API_URL}/download" \
		--head \
		"${request_args[@]}") \
		&& remote_filsz=$(
			echo "${req}" \
			| grep -i content-length \
			| cut -d' ' -f2 \
			| tr -d '\r'
		)

	# Skip the download if the existing filesize matches the remote.
	# Unfortunately, the reported content-length from the image maker
	# is non-deterministic, often changing by several bytes every request.
	# Compute a delta and ensure it's below the threshold to work around this.
	local filsz_delta=$(( remote_filsz - local_filsz ))
	local filsz_delta_thresh=10
	if [ ! -f "${output}.gz" ] || [ "${filsz_delta#-}" -gt "${filsz_delta_thresh}" ]; then
		if ! curl "${BALENA_API_URL}/download" \
				"${request_args[@]}" \
				--output "${output}.gz"; then
			# remove the download if the request failed
			rm -f "${output}.gz"
		fi
	else
		echo "OS image already exists and size matches remote, skipping download"
	fi

	if [ ! -f "${output}.gz" ]; then
		echo "Image was not downloaded, exiting"
		exit 1;
	else
		[ ! -f "${output}" ] && gunzip -c "${output}.gz" > "${output}"
	fi

	# If the disk image is invalid, delete it
	if ! fdisk -l "${output}"; then
		rm "${output}*"
	fi
}

if [ -z "${FLEET_CONFIG}" ] || [[ ! "${FLEET_CONFIG}" = *:* ]]; then
    echo "FLEET_CONFIG must be a string with at least one fleetId and apiKey colon delimited"
    exit 1;
fi

IFS=: read -r fleet_id api_key <<< "${FLEET_CONFIG}"

asset_dir="/var/assets"
output_dir="${asset_dir}/${fleet_id}"
mkdir -p "${output_dir}"

dl_path="${output_dir}/downloaded.img"
download_balenaos "${fleet_id}" "${api_key}" "${OS_VERSION}" "${dl_path}"

script_dir="$(readlink -f "$(dirname "${0}")")"
# shellcheck disable=SC1091
source "${script_dir}/initramfs.sh"

mount_image_part() {
	local image_path=$1
	local part_number=$2
	local mountpoint=$3
	local sector_size
	local part_offset
	sector_size=$( \
		fdisk -l "${image_path}" \
		| grep "Sector size" \
		| cut -d: -f2 \
		| cut -d' ' -f2 )
	part_offset=$(
		fdisk -l "${image_path}" \
		| grep "${image_path}${part_number}" \
		| awk '{print $2}' )
	# accounts for partitions marked bootable
	if [ "${part_offset}" = "*" ]; then
		part_offset=$(
			fdisk -l "${image_path}" \
			| grep "${image_path}${part_number}" \
			| awk '{print $3}' )
	fi

	mount "${image_path}" \
		-o "offset=$((part_offset * sector_size))" \
		"${mountpoint}"
}

boot_part=1
mount_image_part "${dl_path}" "${boot_part}" /mnt/

device_type="$(jq -r '.slug' /mnt/device-type.json || true)"
flasher="$( if [ -f /mnt/balena-image-flasher ]; then echo true; else echo false; fi )"
case "${device_type}" in
	raspberrypi3)
		;&
	raspberrypi3-64)
		;&
	fincm3)
		;&
	raspberrypi4-64)
		# copy Pi firmware
		cp -rf /mnt/*.dtb /var/tftp/
		cp -rf /mnt/overlays /var/tftp/
		cp /mnt/start*.elf /var/tftp
		cp /mnt/fixup*.dat /var/tftp
		;;
	*)
		;;
esac

initramfs_srcdir="${asset_dir}/${fleet_id}/initramfs"
mkdir -p "${initramfs_srcdir}"/{bin,boot,dev,etc,lib,mnt,proc,root}

if [ "${flasher}" = true ]; then
	cp /mnt/config.json "${initramfs_srcdir}/boot"
fi

umount /mnt

roota_part=2
mount_image_part "${dl_path}" "${roota_part}" /mnt/

image_path="${output_dir}/balenaos.img"
# Technically, this test will fail if there is more than one match, but we
# probably don't have to worry about that
# shellcheck disable=SC2144
if [ -f /mnt/opt/*.balenaos-img ]; then
	echo "Unwrapping flasher image"
	cp /mnt/opt/*.balenaos-img "${image_path}"
else
	echo "Non-flasher image, symlink downloaded.img -> balenaos.img"
	ln -sf downloaded.img "${image_path}"
fi

local_ip=$(ip route get 1 | awk '{print $NF;exit}')
nbsrv_domain="netboot.balena.local"

# initialize hosts file
cat > "${initramfs_srcdir}/etc/hosts" << EOF
${local_ip} ${nbsrv_domain}
EOF

cp init "${initramfs_srcdir}/"

# copy ca bundle for TLS
initramfs_certs_path="${initramfs_srcdir}/etc/ssl/certs"
mkdir -p "${initramfs_certs_path}"
cp /certs/ca-bundle.pem "${initramfs_certs_path}/ca-certificates.crt"

utils=(curl date)
modules=()

case "${device_type}" in
	raspberrypi3)
		;&
	fincm3)
		# RPi network adapter and Fin RTC
		modules+=(smsc95xx)
		cp ipconfig-arm "${initramfs_srcdir}/bin/ipconfig"
		;;
	raspberrypi3-64)
		;&
	raspberrypi4-64)
		cp ipconfig-aarch64 "${initramfs_srcdir}/bin/ipconfig"
		;;
	intel-nuc)
		;&
	genericx86-64-ext)
		cp ipconfig-amd64 "${initramfs_srcdir}/bin/ipconfig"
		;;
	*)
		;;
esac

# copy utilities from the hostapp into initramfs
populate_initramfs \
	"${utils[*]}" \
	"${modules[*]}" \
	"${initramfs_srcdir}" \
	/mnt
generate_initramfs "${initramfs_srcdir}" "${output_dir}/initramfs.img.gz"

install_boot_files() {
	local device_type=$1
	local kernel_img_type
	local kernel_dest
	local initramfs_dest
	local append
	local init_args
	local pxelinux_cfg_dir
	local serial_console=ttyS0
	append=(
		"ip=:::::eth0:dhcp"
		"console=tty0"
		"DRY_RUN=${DRY_RUN}"
		"CLOBBER=${CLOBBER}"
		"MODULES=${modules[*]}"
	)
	init_args=(
		"https://${nbsrv_domain}/${fleet_id}/balenaos.img"
	)
	case "${device_type}" in
		fincm3)
			serial_console=ttyAMA0
			append+=("console=${serial_console}")

			kernel_img_type=zImage
			kernel_dest=/var/tftp/zImage
			initramfs_dest=/var/tftp/initramfs.img.gz
			ln -sf zImage /var/tftp/kernel7.img

			echo "enable_uart=1" > /var/tftp/config.txt
			echo "initramfs initramfs.img.gz followkernel" >> /var/tftp/config.txt
			echo "${append[*]} -- ${init_args[*]}" > /var/tftp/cmdline.txt
			;;
		intel-nuc)
			;&
		genericx86-64-ext)
			kernel_img_type=bzImage
			kernel_dest=/var/tftp/syslinux/efi64
			initramfs_dest=/var/tftp/syslinux/efi64/initramfs.img.gz
			pxelinux_cfg_dir=/var/tftp/syslinux/efi64/pxelinux.cfg
			# syslinux grabs our initramfs over HTTP
			append+=("initrd=http://${local_ip}/syslinux/efi64/initramfs.img.gz")
			append+=("console=${serial_console}")

			mkdir -p "${pxelinux_cfg_dir}"
			ln -sf ../../pxelinux.cfg "${pxelinux_cfg_dir}/default"
			# Create pxelinux files for x86_64-efi and PC BIOS
			cp -rf /usr/share/syslinux/ /var/tftp/

			cat > /var/tftp/syslinux/pxelinux.cfg << EOF
DEFAULT flasher
LABEL flasher
	LINUX http://${local_ip}/syslinux/efi64/${kernel_img_type}
	APPEND ${append[@]} -- ${init_args[@]}
EOF


			;;
	esac

	cp "/mnt/boot/${kernel_img_type}" "${kernel_dest}"
	ln -sf "${output_dir}/initramfs.img.gz" "${initramfs_dest}"
}

echo "device_type: ${device_type}"
install_boot_files "${device_type}"

# signal done
touch /var/tftp/.ready

sleep infinity
