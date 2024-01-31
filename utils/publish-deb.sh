#!/usr/bin/env bash

# pre-set
set -euo pipefail
set -x

env

# =======================================
# Runtime default config
# =======================================
VAR_FREIGHT_UTILS_VERSION=${VAR_FREIGHT_UTILS_VERSION:-v0.3.13}
VAR_DEB_WORKBENCH_DIR=${VAR_DEB_WORKBENCH_DIR:-/tmp/output}
VAR_GPG_PRIV_KET=${VAR_GPG_PRIV_KET:-/tmp/deb-gpg-publish.private}
VAR_GPG_PASSPHRASE=${VAR_GPG_PASSPHRASE:-/tmp/deb-gpg-publish.passphrase}

COS_REGION=${COS_REGION:-"ap-guangzhou"}
COS_GLOBAL_REGION=${COS_GLOBAL_REGION:-"accelerate"}
COS_PART_SIZE=${COS_PART_SIZE:-"10"}
VAR_COS_REGION_DNS="cos.${COS_REGION}.myqcloud.com"
VAR_COS_GLOBAL_REGION_DNS="cos.${COS_GLOBAL_REGION}.myqcloud.com"

TAG_DATE=$(date +%Y%m%d)
ARCH=${ARCH:-`(uname -m | tr '[:upper:]' '[:lower:]')`}
arch_path=""
if [[ $ARCH == "arm64" ]] || [[ $ARCH == "aarch64" ]]; then
    arch_path="arm64/"
    COS_CMD="${PWD}/coscli"
fi

func_gpg_key_load() {
    gpg --import --pinentry-mode loopback \
        --batch --passphrase-file "${VAR_GPG_PASSPHRASE}" "${VAR_GPG_PRIV_KET}"

    gpg --list-keys --fingerprint | grep "${DEB_GPG_MAIL}" -B 1 \
    | tr -d ' ' | head -1 | awk 'BEGIN { FS = "\n" } ; { print $1":6:" }' \
    | gpg --import-ownertrust

    cat > "${HOME}/.gnupg/gpg.conf" <<_EOC_
pinentry-mode loopback
passphrase-file ${VAR_GPG_PASSPHRASE}
_EOC_
}

# =======================================
# COS extension
# =======================================
func_cos_utils_credential_init() {
    # ${1} - COS SECRET_ID
    # ${2} - COS SECRET_KEY
    # ${3} - COS bucket name
    coscmd config -a "${1}" -s "${2}" -b "${3}" -r ${COS_REGION} -p ${COS_PART_SIZE}
}


func_freight_utils_install() {
    wget https://github.com/freight-team/freight/archive/refs/tags/${VAR_FREIGHT_UTILS_VERSION}.tar.gz
    tar -zxvf ${VAR_FREIGHT_UTILS_VERSION}.tar.gz
    cd freight-* && make install
}

func_freight_utils_init() {
    # ${1} - gpg mail
    # ${2} - freight work dir
    mkdir -p ${2}
    archs="amd64"
    if [[ $ARCH == "arm64" ]] || [[ $ARCH == "aarch64" ]]; then
        archs="arm64"
    fi
    freight-init --gpg=${1} --libdir=${2}/lib \
                --cachedir=${2}/cache --conf=${2}/freight.conf \
                --archs=${archs} --origin="Apache APISIX"
}

func_dists_backup() { 
    # ${1} - bucket name
    # ${2} - COS path
    # ${3} - backup tag
    coscmd copy -r "${1}.${VAR_COS_REGION_DNS}/packages/${arch_path}${2}/dists" "/packages/${arch_path}backup/${2}_dists_${3}"
}

func_pool_clone() {
    # ${1} - bucket name
    # ${2} - COS path
    # ${3} - local pool path
    mkdir -p ${3}
    # --part-size indicates the file chunk size.
    # when the file is larger than --part-size, coscli will chunk the file by --part-size.
    # when uploading/downloading the file in chunks, it will enable breakpoint transfer by default,
    # which will generate cosresumabletask file and interfere with the file integrity.
    # ref: https://cloud.tencent.com/document/product/436/63669
    coscmd -b "${1}" -r "${COS_GLOBAL_REGION}" download -r "/packages/${arch_path}${2}/pool" "${3}"
}

func_dists_rebuild() {
    # ${1} - local pool path
    # ${2} - freight work dir
    # ${3} - deb output dir
    # ${4} - codename

    # add old deb package
    for codename in `ls ${1}`
    do
        find "${1}/${codename}" -type f -name "*.deb" \
                        -exec echo "freight-add: {}" \; \
                        -exec freight-add -c ${2}/freight.conf {} apt/${codename} \;
    done


    # add the deb package built this time
    find "${3}" -type f -name "*.deb" \
                        -exec echo "freight-add: {}" \; \
                        -exec freight-add -c ${2}/freight.conf {} apt/${4} \;

    freight-cache -c ${2}/freight.conf

    for codename in `ls ${2}/cache/pool`
    do
        rm -rf ${2}/cache/dists/${codename}
        mv ${2}/cache/dists/${codename}-* ${2}/cache/dists/${codename}
        rm -rf ${2}/cache/dists/${codename}/.refs
    done
}

func_dists_upload_ci_repo() {
    coscmd -b "${2}" delete -r -f "/packages/${arch_path}${3}" || true
    coscmd -b "${2}" -r "${COS_GLOBAL_REGION}" upload -r "${1}" "/packages/${arch_path}${3}/dists"
}

func_deb_upload() {
    # ${1} - local path
    # ${2} - bucket name
    # ${3} - COS path
    # ${4} - codename

    # We will only upload apisix and apisix-base,
    # so the directory is fixed: pool/main/a.
    # Regardless of other packages.
    export arch_path=$arch_path
    export BUCKET=$2
    export OS=$3
    export CODENAME=$4
    export COS_GLOBAL_REGION=$COS_GLOBAL_REGION
    export UPLOAD_TARGET_FILE=$UPLOAD_TARGET_FILE
    find "${1}" -type f -name "apisix_*.deb" \
        -exec echo "upload : {}" \; \
        -exec sh -c 'coscmd -b "${BUCKET}" -r "${COS_GLOBAL_REGION}" upload {} "/packages/${arch_path}${OS}/pool/${CODENAME}/main/a/apisix/${UPLOAD_TARGET_FILE}"' \;

    find "${1}" -type f -name "apisix-base*.deb" \
        -exec echo "upload : {}" \; \
        -exec sh -c 'coscmd -b "${BUCKET}" -r "${COS_GLOBAL_REGION}" upload {} "/packages/${arch_path}${OS}/pool/${CODENAME}/main/a/apisix-base/${UPLOAD_TARGET_FILE}"' \;

    find "${1}" -type f -name "apisix-runtime*.deb" \
        -exec echo "upload : {}" \; \
        -exec sh -c 'coscmd -b "${BUCKET}" -r "${COS_GLOBAL_REGION}" upload {} "/packages/${arch_path}${OS}/pool/${CODENAME}/main/a/apisix-runtime/${UPLOAD_TARGET_FILE}"' \;

}

func_repo_publish() {
    # ${1} - CI bucket
    # ${2} - repo publish bucket
    # ${3} - COS path
    coscmd delete -r -f "/packages/${arch_path}${3}/dists" || true
    coscmd -b "${2}" copy -r "${1}.${VAR_COS_REGION_DNS}/packages/${arch_path}${3}/dists" "/packages/${arch_path}${3}/dists"
}

func_repo_backup_remove() {
    # ${1} - bucket name
    # ${2} - COS path
    # ${3} - backup tag
    coscmd -b "${1}" delete -r -f "/packages/${arch_path}backup/${2}_dists_${3}" || true
}

# =======================================
# publish utils entry
# =======================================
case_opt=$1

case ${case_opt} in
init_cos_utils)
    func_cos_utils_credential_init "${TENCENT_COS_SECRETID}" "${TENCENT_COS_SECRETKEY}" "${VAR_COS_BUCKET_REPO}"
    ;;
init_freight_utils)
    func_freight_utils_install
    func_freight_utils_init ${DEB_GPG_MAIL} "/tmp/freight"
    ;;
init_gpg)
    func_gpg_key_load
    ;;
dists_backup)
    # eg: arm64/debian/dists --> arm64/backup/debian_dists_$TAG_DATE
    # VAR_OS: debian or ubuntu
    func_dists_backup "${VAR_COS_BUCKET_REPO}" "${VAR_OS}" "${TAG_DATE}"
    ;;
repo_clone)
    # eg: remote: debian/pool --> /tmp/old_pool
    func_pool_clone "${VAR_COS_BUCKET_REPO}" "${VAR_OS}" "/tmp/old_pool"
    ;;
repo_rebuild)
    func_dists_rebuild "/tmp/old_pool" "/tmp/freight" ${VAR_DEB_WORKBENCH_DIR} ${VAR_CODENAME}
    ;;
repo_ci_upload)
    func_dists_upload_ci_repo "/tmp/freight/cache/dists" "${VAR_COS_BUCKET_CI}" "${VAR_OS}"
    ;;
repo_upload)
    func_deb_upload "${VAR_DEB_WORKBENCH_DIR}" "${VAR_COS_BUCKET_REPO}" "${VAR_OS}" "${VAR_CODENAME}"
    ;;
repo_publish)
    func_repo_publish "${VAR_COS_BUCKET_CI}" "${VAR_COS_BUCKET_REPO}" "${VAR_OS}"
    ;;
repo_backup_remove)
    func_repo_backup_remove "${VAR_COS_BUCKET_REPO}" "${VAR_OS}" "${TAG_DATE}"
    ;;
*)
    echo "Unknown method!"
esac
