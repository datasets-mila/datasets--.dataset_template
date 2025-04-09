#!/bin/bash

_SCRIPT_DIR=$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd -P)

_DATASETS_UTILS=$(git -C "${_SCRIPT_DIR}" rev-parse --show-toplevel)/.datasets_utils
git -C "${_DATASETS_UTILS}/.." submodule status | grep -Ev "^[-+].*\.datasets_utils.*" | grep ".*\.datasets_utils.*" >&2 || \
	git -C "${_DATASETS_UTILS}/.." submodule update --init .datasets_utils >&2

source "${_DATASETS_UTILS}/utils.sh" echo -n

function print_annex_checksum {
	local _CHECKSUM=MD5
	while [[ $# -gt 0 ]]
	do
		local _arg="$1"; shift
		case "${_arg}" in
			-c | --checksum) local _CHECKSUM="$1"; shift ;;
			-h | --help)
			>&2 echo "Options for ${FUNCNAME[0]} are:"
			>&2 echo "[-c | --checksum CHECKSUM] checksum to print (default: MD5)"
			exit 1
			;;
			--) break ;;
			*) >&2 echo "Unknown option [${_arg}]"; exit 3 ;;
		esac
	done

	for _file in "$@"
	do
		local _annex_file=`ls -l -- "${_file}" | grep -o ".git/annex/objects/.*/${_CHECKSUM}.*"`
		if [[ ! -f "${_annex_file}" ]]
		then
			continue
		fi
		local _checksum=`echo "${_annex_file}" | xargs basename`
		local _checksum=${_checksum##*--}
		echo "${_checksum%%.*}  ${_file}"
	done
}

function list {
	local _DATASET=
	while [[ $# -gt 0 ]]
	do
		local _arg="$1"; shift
		case "${_arg}" in
			-d | --dataset) local _DATASET="$1"; shift ;;
			-h | --help)
			>&2 echo "Options for ${FUNCNAME[0]} are:"
			>&2 echo "[-d | --dataset PATH] dataset location"
			git-annex list --help >&2
			exit 1
			;;
			--) break ;;
			*) >&2 echo "Unknown option [${_arg}]"; exit 3 ;;
		esac
	done

	if [[ ! -z "${_DATASET}" ]]
	then
		pushd "${_DATASET}" >/dev/null || exit 1
	fi

	git-annex list "$@" | { grep -o " .*" | grep -Eo "[^ ]+.*" || test $? = 1 ; }

	if [[ ! -z "${_DATASET}" ]]
	then
		popd >/dev/null
	fi
}

function subdatasets {
	local _VAR=0
	while [[ $# -gt 0 ]]
	do
		local _arg="$1"; shift
		case "${_arg}" in
			--var) local _VAR=1 ;;
			-h | --help)
			>&2 echo "Options for ${FUNCNAME[0]} are:"
			>&2 echo "--var also list datasets variants"
			>&2 echo "then following --"
			datalad subdatasets --help
			exit 1
			;;
			--) break ;;
			*) >&2 echo "Unknown option [${_arg}]"; exit 3 ;;
		esac
	done

	if [[ ${_VAR} != 0 ]]
	then
		datalad subdatasets $@ | grep -o ": .* (dataset)" | grep -o " .* " | grep -o "[^ ]*" | \
		while read subds
		do
			echo ${subds}
			for _d in "${subds}.var"/*
			do
				if [[ -d "$_d" ]]
				then
					echo $_d
				fi
			done
		done
	else
		datalad subdatasets $@ | grep -o ": .* (dataset)" | grep -o " .* " | grep -o "[^ ]*"
	fi
}

function rclone_copy {
	local _REMOTE=
	local _GDRIVE_DIR_ID=
	while [[ $# -gt 0 ]]
	do
		local _arg="$1"; shift
		case "${_arg}" in
			--remote) local _REMOTE="$1"; shift
			echo "remote = [${_REMOTE}]"
			;;
			--root) local _GDRIVE_DIR_ID="$1"; shift
			echo "root = [${_GDRIVE_DIR_ID}]"
			;;
			-h | --help)
			>&2 echo "Options for ${FUNCNAME[0]} are:"
			>&2 echo "--root GDRIVE_DIR_ID Google Drive root directory id"
			exit 1
			;;
			--) break ;;
			*) >&2 echo "Unknown option [${_arg}]"; exit 3 ;;
		esac
	done

	for _src_w_dest in "$@"
	do
		local _src_w_dest=(${_src_w_dest[@]})
		local _src=${_src_w_dest[0]}
		local _dest=${_src_w_dest[1]}
		if [[ -z ${_GDRIVE_DIR_ID} ]]
		then
			rclone backend copyid ${_REMOTE}: ${_src} ${_dest}
		else
			rclone copy --progress --create-empty-src-dirs --copy-links \
				--drive-root-folder-id=${_GDRIVE_DIR_ID} ${_REMOTE}:${_src} ${_dest}
		fi
	done
}

function add_urls {
	local _STDIN=0
	while [[ $# -gt 0 ]]
	do
		_arg="$1"; shift
		case "${_arg}" in
			--stdin) local _STDIN=1 ;;
			-h | --help)
			>&2 echo "Options for ${FUNCNAME[0]} are:"
			>&2 echo "--stdin force read 'URL FILE' pairs from stdin instead of arguments"
			>&2 echo "'URL FILE'... STR 'URL FILE' pairs to add"
			exit 1
			;;
			*) local _files_url+=("${_arg}") ;;
		esac
	done

	if [[ ${#_files_url[@]} == 0 ]] || [[ ${_STDIN} == 1 ]]
	then
		while read file_url ; do echo "${file_url}" ; done
	else
		for file_url in "${_files_url[@]}" ; do echo "${file_url}" ; done
	fi | git-annex addurl --fast -c annex.largefiles=anything --raw --batch --with-files
	# Downloads should complete correctly but in multiprocesses the last git-annex
	# step most likely fails on a BGFS with the error "rename: resource busy
	# (Device or resource busy)"
	! git-annex get --fast -J8
	# Remove the last byte from each files to redownload only the last byte
	# and prevent the "download failed: ResponseBodyTooShort" error
	ls -l $(list) | grep -oE "\.git/[^']*" |
		cut -d'/' -f7 | xargs -n1 -- find .git/annex/tmp/ -name |
		while read f
		do
			newfsize=$(($(stat -c '%s' "${f}") - 1))
			chmod +w "${f}"
			truncate -s $newfsize "${f}"
		done
	# Retry incomplete downloads without multiprocesses
	git-annex get --fast --incomplete
	git-annex migrate --fast -c annex.largefiles=anything *
}

function add_files {
	local _NO_ANNEX=0
	local _STDIN=0
	local _MAX_FILES=20000
	while [[ $# -gt 0 ]]
	do
		_arg="$1"; shift
		case "${_arg}" in
			--no-annex) local _NO_ANNEX=1 ;;
			--stdin) local _STDIN=1 ;;
			--max-files) local _MAX_FILES="$1"; shift ;;
			-h | --help)
			>&2 echo "Options for ${FUNCNAME[0]} are:"
			>&2 echo "--no-annex do not add files under git-annex"
			>&2 echo "--stdin force read files from stdin instead of arguments"
			>&2 echo "FILE... STR files to add"
			exit 1
			;;
			*) local _dirs+=("${_arg}") ;;
		esac
	done

	function filter_dirs {
		# Sort dirs
		readarray -t _dirs < <(while read _dir ; do echo "${_dir}" ; done | \
			sort -u)

		if (( ${#_dirs[@]} > 0 ))
		then
			echo "${_dirs[0]}"
		fi

		local parent=${_dirs[0]}
		# Remove sub-dirs
		for (( i=1; i<${#_dirs[@]}; i++ ))
		do
			# if `${parent}' is a relative base of `${_dirs[i]}',
			# so if `${_dirs[i]}' is a sub-dir of `${parent}', the
			# output will start with a `/'
			if [[ "$(realpath --relative-base="${parent}" -- "${_dirs[i]}")" =~ ^/ ]]
			then
				echo "${_dirs[i]}"
				local parent=${_dirs[i]}
			fi
		done
	}

	# Sort directories and remove duplicates
	readarray -t _sorted_dirs < <(
	if [[ ${#_dirs[@]} == 0 ]] || [[ ${_STDIN} == 1 ]]
	then
		while read _dir ; do echo "${_dir}" ; done
	else
		for _dir in "${_dirs[@]}" ; do echo "${_dir}" ; done
	fi | filter_dirs)

	if (( ${_NO_ANNEX} != 1 ))
	then
		# Find and sort all files
		readarray -t _files < <(
		for _dir in "${_sorted_dirs[@]}" ; do echo "${_dir}" ; done |
			xargs -P8 -I'{}' find "{}" -type f | sort -u)
	fi

	if (( ${_NO_ANNEX} == 1 )) || (( ${#_files[@]} > ${_MAX_FILES} ))
	then
		# Too many files to have git/git-annex handle them. .gitignore
		# the parent directories them and compute stats instead
		for _dir in "${_sorted_dirs[@]}" ; do echo "${_dir}" ; done |
			tee -i \
			>(while read _dir
			do
				grep -E "^/?${_dir}/?$" .gitignore >/dev/null || echo "/${_dir%/}/"
			done >>.gitignore) |
			"${_SCRIPT_DIR}"/stats.sh
	else
		# Add files to git-annex
		for _file in "${_files[@]}" ; do echo "${_file}" ; done |
			git-annex add --batch
	fi
}

function unshare_mount {
	if [[ ${EUID} -ne 0 ]]
	then
		unshare -rm ./"${BASH_SOURCE[0]}" unshare_mount "$@" <&0
		exit $?
	fi

	if [[ -z ${_SRC} ]]
	then
		local _SRC=${PWD}
	fi
	while [[ $# -gt 0 ]]
	do
		local _arg="$1"; shift
		case "${_arg}" in
			--src) local _SRC="$1"; shift
			echo "src = [${_SRC}]"
			;;
			--dir) local _DIR="$1"; shift
			echo "dir = [${_DIR}]"
			;;
			--cd) local _CD=1
			echo "cd = [${_CD}]"
			;;
	                --) break ;;
			-h | --help | *)
			if [[ "${_arg}" != "-h" ]] && [[ "${_arg}" != "--help" ]]
			then
				>&2 echo "Unknown option [${_arg}]"
			fi
			>&2 echo "Options for ${FUNCNAME[0]} are:"
			>&2 echo "[--dir DIR] mount location"
			>&2 echo "[--src DIR] source dir (optional)"
			exit 1
			;;
		esac
	done

	mkdir -p ${_SRC}
	mkdir -p ${_DIR}

	local _SRC=$(cd "${_SRC}" && pwd -P)
	local _DIR=$(cd "${_DIR}" && pwd -P)

	mount -o bind ${_SRC} ${_DIR}
	exit_on_error_code "Could not mount directory"

	if [[ ! ${_CD} -eq 0 ]]
	then
		cd ${_DIR}
	fi

	unshare -U ${SHELL} -s "$@" <&0
}

function jug_exec {
	if [[ -z ${_jug_exec} ]]
	then
		local _jug_exec=${_SCRIPT_DIR}/jug_exec.py
	fi
	local _jug_argv=()
	while [[ $# -gt 0 ]]
	do
		local _arg="$1"; shift
		case "${_arg}" in
			--script | -s) local _jug_exec="$1"; shift ;;
			-h | --help)
			>&2 echo "Options for ${FUNCNAME[0]} are:"
			>&2 echo "[--script | -s JUG_EXEC] path to the jug wrapper script (default: '${_jug_exec}')"
			${_jug_exec} --help
			exit
			;;
			--) break ;;
			*) _jug_argv+=("${_arg}") ;;
		esac
	done
	# Remove trailing '/' in argv before sending to jug
	jug execute "${_jug_argv[@]%/}" ${_jug_exec} -- "${@%/}"
}

# function unshare_mount {
# 	if [[ ${EUID} -ne 0 ]]
# 	then
# 		unshare -rm ./"${BASH_SOURCE[0]}" unshare_mount "$@" <&0
# 		exit $?
# 	fi
#
# 	if [[ -z ${_SRC} ]]
# 	then
# 		local _SRC=${PWD}
# 	fi
# 	if [[ -z ${_DIR} ]]
# 	then
# 		local _DIR=${_PWD}
# 	fi
# 	while [[ $# -gt 0 ]]
# 	do
# 		local _arg="$1"; shift
# 		case "${_arg}" in
# 			--src) local _SRC="$1"; shift
# 			echo "src = [${_SRC}]"
# 			;;
# 			--upper) local _UPPER="$1"; shift
# 			echo "upper = [${_UPPER}]"
# 			;;
# 			--dir) local _DIR="$1"; shift
# 			echo "dir = [${_DIR}]"
# 			;;
# 			--wd) local _WD="$1"; shift
# 			echo "wd = [${_WD}]"
# 			;;
# 			--cd) local _CD=1
# 			echo "cd = [${_CD}]"
# 			;;
# 	                --) break ;;
# 			-h | --help | *)
# 			if [[ "${_arg}" != "-h" ]] && [[ "${_arg}" != "--help" ]]
# 			then
# 				>&2 echo "Unknown option [${_arg}]"
# 			fi
# 			>&2 echo "Options for ${FUNCNAME[0]} are:"
# 			>&2 echo "[--upper DIR] upper mount overlay"
# 			>&2 echo "[--wd DIR] overlay working directory"
# 			>&2 echo "[--src DIR] lower mount overlay (optional)"
# 			>&2 echo "[--dir DIR] mount location (optional)"
# 			exit 1
# 			;;
# 		esac
# 	done
#
# 	mkdir -p ${_SRC}
# 	mkdir -p ${_UPPER}
# 	mkdir -p ${_WD}
# 	mkdir -p ${_DIR}
#
# 	local _SRC=$(cd "${_SRC}" && pwd -P) || echo "${_SRC}"
# 	local _UPPER=$(cd "${_UPPER}" && pwd -P)
# 	local _WD=$(cd "${_WD}" && pwd -P)
# 	local _DIR=$(cd "${_DIR}" && pwd -P)
#
# 	mount -t overlay overlay -o lowerdir="${_SRC}",upperdir="${_UPPER}",workdir="${_WD}" "${_DIR}"
# 	exit_on_error_code "Could not mount overlay"
#
# 	if [[ ! ${_CD} -eq 0 ]]
# 	then
# 		cd ${_DIR}
# 	fi
#
# 	unshare -U ${SHELL} -s "$@" <&0
# }

if [[ ! -z "$@" ]]
then
	"$@"
fi
