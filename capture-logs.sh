#!/bin/bash

set -x
set -e
set -o pipefail

JENKINS_CLUSTER="20"
FILESERVER="smurf"

if [ -z "${FILESERVER}" -o -z "${FS_SSH_USER}" -o -z "${RELEASE_VERSION}" -o -z "${GITHUB_OWNER}" -o -z "${GITHUB_BRANCH}" -o -z "${BUILD_NUMBER}" -o -z "${WORKSPACE}" ]
then
    echo "Required variable not set" >&2
    exit 1
fi

# If we have a source version and a release version then we should be part of an upgrade
[ "${SOURCE_VERSION}" ] && UPGRADE=1

# If not defined, then we are bound to the ever-locked Jenkins cluster 20
CLUSTER=${CLUSTER:-${JENKINS_CLUSTER}}
BUILD_STRING="automated-build${CLUSTER}"
CLUSTER_LOGFILE="${CLUSTER}-messages"
AUTOMATED_BUILD_GZIP="automated-build.log.gz"

EXECUTOR_NUMBER=${EXECUTOR_NUMBER:=user-$LOGNAME}

SOURCE_VERSION_ESCAPED=$(echo "${SOURCE_VERSION}" | sed -e 's|\.|\\\.|g')
RELEASE_VERSION_ESCAPED=$(echo "${RELEASE_VERSION}" | sed -e 's|\.|\\\.|g')

env | sort

# Push in a finish delimiter to the finished job
nc -w0 -u ${FILESERVER} 514 <<< "${BUILD_STRING}: Build ${RELEASE_VERSION} (${BUILD_NUMBER}) finish"

if [ "${UPGRADE}" ]
then
    echo "NOTE: This was an Upgrade test."
    RESULTS_LOG="upgrade-test-${SOURCE_VERSION}-to-${RELEASE_VERSION}-testid-${BUILD_NUMBER}"
    TEACUP_ARTIFACTS_DIR="teacup-artifacts-${SOURCE_VERSION}-to-${RELEASE_VERSION}-testid-${BUILD_NUMBER}"
    ssh ${FS_SSH_USER}@${FILESERVER} << EOF
        zcat /var/log/${CLUSTER_LOGFILE}.1.gz |
        cat - /var/log/${CLUSTER_LOGFILE} |
        awk '/ ${BUILD_STRING}: Build ${SOURCE_VERSION_ESCAPED} \(${BUILD_NUMBER}\) start FLAVOR=pentos/,/ ${BUILD_STRING}: Build ${RELEASE_VERSION_ESCAPED} \(${BUILD_NUMBER}\) finish$/' |
        gzip -c > ${AUTOMATED_BUILD_GZIP}
EOF

    #ssh ${FS_SSH_USER}@${FILESERVER} "zcat /var/log/${CLUSTER_LOGFILE}.1.gz | cat - /var/log/${CLUSTER_LOGFILE} | awk '/ ${BUILD_STRING}: Build ${SOURCE_VERSION_ESCAPED} \(${BUILD_NUMBER}\) start FLAVOR=pentos/,/ ${BUILD_STRING}: Build ${RELEASE_VERSION_ESCAPED} \(${BUILD_NUMBER}\) finish$/' | gzip -c > ${AUTOMATED_BUILD_GZIP}"
else
    RESULTS_LOG="functional-test-${RELEASE_VERSION}-testid-${BUILD_NUMBER}"
    TEACUP_ARTIFACTS_DIR="teacup-artifacts-${RELEASE_VERSION}-testid-${BUILD_NUMBER}"

    ssh ${FS_SSH_USER}@${FILESERVER} << EOF
        zcat /var/log/${CLUSTER_LOGFILE}.1.gz |
        cat - /var/log/${CLUSTER_LOGFILE} |
        awk '/ ${BUILD_STRING}: Build ${RELEASE_VERSION_ESCAPED} \(${BUILD_NUMBER}\) start/,/ ${BUILD_STRING}: Build ${RELEASE_VERSION_ESCAPED} \(${BUILD_NUMBER}\) finish$/' |
        gzip -c > ${AUTOMATED_BUILD_GZIP}"
EOF
fi

# TODO(NB) Try and do this in one step, the above command should be able to copy it directly, but ssh -A isn't working for some reason.
scp -q ${FS_SSH_USER}@${FILESERVER}:${AUTOMATED_BUILD_GZIP} .

scp -q automated-build.log.gz ${FS_SSH_USER}@${FILESERVER}:/home/shared/builds/${GITHUB_OWNER}/${GITHUB_BRANCH}/debug/${RESULTS_LOG}.log.gz

if [ -d /tmp/teacup-artifacts-${EXECUTOR_NUMBER} ]
then
    rsync -rltgoD --chmod=Du=rwx,Dg=rx,Do=rx,Fu=rw,Fg=r,Fo=r /tmp/teacup-artifacts-${EXECUTOR_NUMBER}/ ${FS_SSH_USER}@${FILESERVER}:/home/shared/builds/${GITHUB_OWNER}/${GITHUB_BRANCH}/debug/${TEACUP_ARTIFACTS_DIR}/
    # this is already run above, so this file won't appear. will appear if only run once
    rm -rf /tmp/teacup-artifacts-${EXECUTOR_NUMBER}
fi

set +x

echo
echo
echo "Errors in the log:"

if [ -x "${WORKSPACE}"/teacup/tools/extract-errors.py ]
then
    zcat automated-build.log.gz | "${WORKSPACE}"/teacup/tools/extract-errors.py
else
    zcat automated-build.log.gz | awk '/^Traceback \(most recent/,/^(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)/'
fi
echo

cat <<EOF
Options to view the log:
http://${FILESERVER}/builds/${GITHUB_OWNER}/${GITHUB_BRANCH}/debug/${RESULTS_LOG}.log
http://${FILESERVER}/builds/${GITHUB_OWNER}/${GITHUB_BRANCH}/debug/${RESULTS_LOG}.log.gz
http://${FILESERVER}/builds/${GITHUB_OWNER}/${GITHUB_BRANCH}/debug/${TEACUP_ARTIFACTS_DIR}/
scp ${FILESERVER}:/home/shared/builds/${GITHUB_OWNER}/${GITHUB_BRANCH}/debug/${RESULTS_LOG}.log.gz .
EOF
