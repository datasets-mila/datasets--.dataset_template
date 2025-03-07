#!/bin/bash
source scripts/utils.sh echo -n

# Saner programming env: these switches turn some bugs into errors
set -o errexit -o pipefail

# This script is meant to be used with the command 'datalad run'

_HELP=$(
	echo    "Options for $(basename "$0") are:"
	echo    "-d | --dataset PATH huggingface dataset"
	echo    "--revision STR huggingface dataset's revision"
	echo    "--name STR huggingface dataset's configuration name"
	echo -n "[--login] the dataset requires to login before download. If "
	echo -n "\$HF_TOKEN or \$HF_TOKEN_PATH are not set, an interactive "
	echo    "prompt will be used to login"
	echo    "--retry INT retry attempts before giving up"
)

_RETRY=0

while [[ $# -gt 0 ]]
do
	_arg="$1"; shift
	case "${_arg}" in
		-d | --dataset) _DATASET="$1"; shift ;;
		--revision) _REVISION="$1"; shift ;;
		--name) _NAME="$1"; shift ;;
		--login) _LOGIN=1 ;;
		--retry) _RETRY=$1; shift ;;
		-h | --help)
		>&2 echo "${_HELP}"
		exit 1
		;;
		--) break ;;
		*) >&2 echo "Unknown option [${_arg}]"; exit 3 ;;
	esac
done

# Download dataset
(
source scripts/env.sh echo -n
$(which uv) pip install -r scripts/requirements_download_huggingface.txt || \
	exit_on_error_code "Failed to install requirements: [uv] pip install"
)

if [[ ! -z "${HF_TOKEN_PATH}" ]]
then
	export HF_TOKEN=$(cat "${HF_TOKEN_PATH}")
fi

if [[ ${_LOGIN} == 1 ]] && [[ -z "${HF_TOKEN}" ]]
then
	_LOGIN="
from huggingface_hub import login
login()
"
else
	unset _LOGIN
fi

if [[ ! -z "${_NAME}" ]]
then
	_NAME=", name='${_NAME}'"
else
	unset _NAME
fi

[[ -d "hf_home/" ]] && chmod -R u+w hf_home/

_RETRY=$((_RETRY+1))
_ERR=0

while [[ $_RETRY -gt 0 ]]
do
	_RETRY=$((_RETRY-1))
	HF_HOME=$PWD/hf_home scripts/python3.sh -c "
${_LOGIN}
import datasets
datasets.load_dataset('${_DATASET}'${_NAME}, revision='${_REVISION}', keep_in_memory=False)
" && _RETRY=0 || _ERR=$?
done

exit_on_error_code --err ${_ERR} "Failed to download dataset ['${_DATASET}'${_NAME}, revision='${_REVISION}']"

# Remove cached source data
rm -rf hf_home/{hub/,modules/,stored_tokens,token}

# Remove locks and cache files & directories
find hf_home/ -name "*.lock" -delete
find hf_home/ -type d -name "__pycache__" -prune -exec rm -r '{}' '+'

for d in hf_home/
do
	echo "$d"
done | add_files --no-annex

# Verify dataset
if [[ -f md5sums ]]
then
	md5sum -c md5sums
fi
list -- --fast | while read f
do
	if [[ -z "$(echo "${f}" | grep -E "^bin/")" ]] &&
		[[ -z "$(grep -E " (\./)?${f//\./\\.}$" md5sums)" ]]
	then
		md5sum "${f}" >> md5sums
	fi
done
