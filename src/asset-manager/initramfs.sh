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

find_mod_deps() {
	module=$1
	rootdir=$2
	moddep_path="$(find "${rootdir}" -name modules.dep)"
	grep "/${module}.ko.*:" "${moddep_path}" | cut -d: -f2-
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

install_module() {
	local rootdir="${2}"
	local outdir="${3}"
	local kernel_dir
	local modules_dir
	local libdir
	local hostapp_root
	local path
	local outdir_abs

	kernel_dir=$(dirname "$(find "${rootdir}" -name modules.dep)")
	modules_dir="$(dirname "${kernel_dir}")"
	libdir="$(dirname "${modules_dir}")"
	hostapp_root="$(dirname "${libdir}")"

	path="$(cd "${hostapp_root}" && find . -name "${1}.ko*")"
	if [ -z "${path}" ]; then
		echo "Unable to find module: '${1}'"
		exit 1;
	fi

	deps="$(find_mod_deps "${1}" "${hostapp_root}")"
	echo "deps for module ${1}: ${deps}"
	for d in ${deps}; do
		dep="$(basename "${d}" | cut -d. -f1)"
		install_module "${dep}" "${rootdir}" "${outdir}"
	done

	outdir_abs="$(readlink -f "${outdir}")"
	(cd "${hostapp_root}" && cp -v --parents "${path}" "${outdir_abs}"/)
	(cd "${hostapp_root}" && cp -v --parents \
		"$(find . -name modules.dep)" \
		"${outdir_abs}")
}

populate_initramfs() {
	local wanted_binaries=${1}
	local wanted_modules=${2}
	local outdir="${3}"
	local root="${4}"

	for b in ${wanted_binaries}; do
		install_binary "$b" "${root}" "${outdir}"
	done

	for m in ${wanted_modules}; do
		install_module "$m" "${root}" "${outdir}"
	done
}

generate_initramfs() {
	local srcdir="${1}"
	local output="${2}"
	(cd "${srcdir}" || exit; find . | cpio -o -H newc | gzip) > "${output}"
}
