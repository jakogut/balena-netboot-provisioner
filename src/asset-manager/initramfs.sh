#!/bin/bash
find_hostapp() {
	BINDIR="$(find "$1" -name "busybox")"
	dirname "$(dirname "${BINDIR}")"
}

find_binary() {
	local rootdir=$2
	find "${rootdir}" -name "$1"
}

find_deps() {
	objdump -p "$1" 2>/dev/null \
		| grep NEEDED \
		| awk '{ print $2 }'
}

is_absolute() {
	[[ "$1" == /* ]]
}

install_binary() {
	local rootdir="${2}"
	local outdir="${3}"
	local path
	local deps
	local src
	local dest

	path="$(find_binary "$1" "${rootdir}")"
	if [ -z "${path}" ]; then
		echo "Unable to find binary: '${b}'"
		exit 1;
	fi

	deps="$(find_deps "${path}")"
	for d in ${deps}; do
		install_binary "${d}" "${rootdir}" "${outdir}"
	done

	src="$(
		if [ -L "${path}" ]; then
			link="$(readlink "${path}")"
			if is_absolute "${link}"; then
				echo "${rootdir}${link}"
			else
				readlink -f "${path}"
			fi
		else
			echo "${path}";
		fi)"
	dest="$(
		if [[ "${path}" == *.so* ]]; then
			echo "${outdir}/lib";
		else
			echo "${outdir}/bin";
		fi
	)"

	mkdir -p "${dest}"
	cp -v "${src}" "${dest}/${1}"
}

populate_initramfs() {
	local wanted_binaries=${1}
	local outdir="${2}"
	local hostapp_root="${3}"

	for b in ${wanted_binaries}; do
		install_binary "$b" "${hostapp_root}" "${outdir}"
	done
}

generate_initramfs() {
	local srcdir="${1}"
	local output="${2}"
	(cd "${srcdir}" || exit; find . | cpio -o -H newc | gzip) > "${output}"
}
