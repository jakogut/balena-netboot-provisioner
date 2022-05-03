#!/bin/bash
find_root() {
	BINDIR="$(find "$1" -name "busybox")"
	dirname "$(dirname "${BINDIR}")"
}

ROOTDIR="$(find_root "$1")"

find_binary() {
	find "${ROOTDIR}" -name "$1"
}

find_deps() {
	objdump -p "$1" 2>/dev/null \
		| grep NEEDED \
		| awk '{ print $2 }'
}

WANTED_BINARIES="dd curl"

is_absolute() {
	[[ "$1" == /* ]]
}

install_binary() {
	local path
	local deps
	local src
	local dest

	path="$(find_binary "$1")"
	if [ -z "${path}" ]; then
		echo "Unable to find binary: '${b}'"
		exit 1;
	fi

	deps="$(find_deps "${path}")"
	for d in ${deps}; do
		install_binary "${d}"
	done

	src="$(
		if [ -L "${path}" ]; then
			link="$(readlink "${path}")"
			if is_absolute "${link}"; then
				echo "${ROOTDIR}${link}"
			else
				readlink -f "${path}"
			fi
		else
			echo "${path}";
		fi)"
	dest="$(if [[ "${path}" == *.so* ]]; then echo initramfs/lib; else echo initramfs/bin; fi)"
	cp -v "${src}" "${dest}/${1}"
}

mkdir -p initramfs/{bin,lib}

for b in ${WANTED_BINARIES}; do
	install_binary "$b"
done
