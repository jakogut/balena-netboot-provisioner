#!/usr/bin/env bash

set -eu

[[ $VERBOSE =~ on|On|Yes|yes|true|True ]] && set -x

BALENA_API_URL=${BALENA_API_URL:-balena-cloud.com}
OS_VERSION=${OS_VERSION:-2.95.12%2brev1}

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
	local remote_filsz
	local request_args=(
		--get
		--header "Authorization: Bearer ${api_key}"
		--data "version=${version}"
		--data "fileType=${filetype}"
		--data "appId=${fleet_id}"
	)
	local_filsz=$(du -b "${output}.gz" | cut -f1 || echo 0)
	remote_filsz=$(curl "${BALENA_API_URL}/download" \
			--head \
			"${request_args[@]}" \
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
	if [ "${filsz_delta#-}" -gt "${filsz_delta_thresh}" ]; then
		curl "${BALENA_API_URL}/download" \
			"${request_args[@]}" \
			--output "${output}.gz"
	else
		echo "OS image already exists and size matches remote, skipping download"
	fi

	[ -f "${output}" ] || gunzip -c "${output}.gz" > "${output}"
}

if [ -z "${FLEET_CONFIG}" ] || [[ ! "${FLEET_CONFIG}" = *:* ]]; then
    echo "FLEET_CONFIG must be a string with at least one fleetId and apiKey colon delimited"
    exit 1;
fi

IFS=: read -r fleet_id api_key <<< "${FLEET_CONFIG}"

asset_dir="/var/assets"
output_dir="${asset_dir}/${fleet_id}"
dl_path="${output_dir}/downloaded.img"
mkdir -p "${output_dir}"
download_balenaos "${fleet_id}" "${api_key}" "${OS_VERSION}" "${dl_path}"

script_dir="$(readlink -f "$(dirname "${0}")")"
# shellcheck disable=SC1091
source "${script_dir}/initramfs.sh"

roota_partition=2
sector_size=$( \
	fdisk -l "${dl_path}" \
	| grep "Sector size" \
	| cut -d: -f2 \
	| cut -d' ' -f2 )
roota_offset=$(
	fdisk -l "${dl_path}" \
	| grep "${dl_path}${roota_partition}" \
	| awk '{print $2}' )

mount "${dl_path}" -o "offset=$((roota_offset * sector_size))" /mnt

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

# copy dd and curl from the hostapp found at /mnt into the outdir
initramfs_srcdir="${asset_dir}/${fleet_id}/initramfs"
mkdir -p "${initramfs_srcdir}"
cp init "${initramfs_srcdir}/"
populate_initramfs "dd curl" "${initramfs_srcdir}" /mnt
generate_initramfs "${initramfs_srcdir}" "${asset_dir}/${fleet_id}/initramfs.img.gz"

# signal done
touch /var/tftp/.ready

sleep infinity
