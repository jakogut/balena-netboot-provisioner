#!/usr/bin/env bash

set -eu

[[ $VERBOSE =~ on|On|Yes|yes|true|True ]] && set -x

BALENA_API_URL=${BALENA_API_URL:-balena-cloud.com}
OS_VERSION=${OS_VERSION:-2.95.12%2brev1}

function cleanup() {
   rm -f /var/tftp/.ready
}
trap 'cleanup' EXIT

while ! [ -f /certs/.ready ]; do sleep "$(( (RANDOM % 5) + 5 ))s"; done

# CA bundle to be consumed by cURL
# export CURL_CA_BUNDLE) or https://serverfault.com/questions/485597/default-ca-cert-bundle-location
cat < /certs/ca-bundle.pem | openssl x509 -noout -text

# $1: fleet ID
# $2: API key
download_balenaos() {
    local fleet_id=${1}
    local api_key=${2}
    local version=${3}
    local filetype=${4:-.gz}
    local output_dir=${5:-/data/${fleet_id}/}
    curl "${BALENA_API_URL}/download" \
        --get \
        --header "Authorization: Bearer ${api_key}" \
        --data "version=${version}" \
        --data "fileType=${filetype}" \
        --data "appId=${fleet_id}" \
        --output "${output_dir}/balenaos.img"
}

if [ -z "${FLEET_CONFIG}" ] || [[ ! "${FLEET_CONFIG}" = *:* ]]; then
    echo "FLEET_CONFIG must be a string with at least one fleetId and apiKey colon delimited"
    exit 1;
fi

IFS=: read -r fleet_id api_key <<< "${FLEET_CONFIG}"

output_dir="/data/${fleet_id}"
mkdir -p "${output_dir}"
download_balenaos "${fleet_id}" "${api_key}" "${OS_VERSION}"

script_dir="$(readlink -f "$(dirname "${0}")")"
echo "script_dir: ${script_dir}"
# shellcheck disable=SC1091
source "${script_dir}loopback.sh"
# shellcheck disable=SC1091
source "${script_dir}initramfs.sh"

for i in {0..10}; do create_loopback "$i"; done
loopback_device=$(setup_loopback "${output_dir}/balenaos.img")
mount "${loopback_device}p2" /mnt

# signal done
touch /netboot/.ready

sleep infinity
