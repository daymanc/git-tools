#!/bin/bash

set -x
set -e
set -o pipefail

JENKINS_CLUSTER="20"
CLUSTER=${CLUSTER:-${JENKINS_CLUSTER}}
EXECUTOR_NUMBER=${EXECUTOR_NUMBER:=user-$LOGNAME}

if [ -z "$RELEASE_VERSION" -o -z "$BUILD_NUMBER" -o -z "$GITHUB_OWNER" -o -z "$GITHUB_BRANCH"  \
     -o -z "$WORKSPACE" -o -z "$FILE_SERVER" -o -z "$FILE_SERVER_USER" -o -z "$SYSLOG_SERVER"  \
     -o -z "$SYSLOG_SERVER_USER" -o -z "$CLUSTER" ]
then
    echo "Required variable not set" >&2
    exit 1
fi

# If we have a source version and a release version then we should be part of an upgrade
[ "${SOURCE_VERSION}" ] && UPGRADE=1

# If not defined, then we are bound to the ever-locked Jenkins cluster 20
BUILD_STRING="automated-build${CLUSTER}"
CLUSTER_LOGFILE="${CLUSTER}-messages"
AUTOMATED_BUILD_GZIP="automated-build.log.gz"

SOURCE_VERSION_ESCAPED=$(echo "${SOURCE_VERSION}" | sed -e 's|\.|\\\.|g')
RELEASE_VERSION_ESCAPED=$(echo "${RELEASE_VERSION}" | sed -e 's|\.|\\\.|g')

env | sort

nc -w0 -u ${SYSLOG_SERVER} 514 <<< "${BUILD_STRING}: Build ${RELEASE_VERSION} (${BUILD_NUMBER}) finish"

if [ "${UPGRADE}" ]
then
    echo "NOTE: This was an Upgrade test."
    RESULTS_LOG="upgrade-test-${SOURCE_VERSION}-to-${RELEASE_VERSION}-testid-${BUILD_NUMBER}"
    TEACUP_ARTIFACTS_DIR="teacup-artifacts-${SOURCE_VERSION}-to-${RELEASE_VERSION}-testid-${BUILD_NUMBER}"
    AWK_VERSION_MATCH=${SOURCE_VERSION_ESCAPED}
else
    RESULTS_LOG="functional-test-${RELEASE_VERSION}-testid-${BUILD_NUMBER}"
    TEACUP_ARTIFACTS_DIR="teacup-artifacts-${RELEASE_VERSION}-testid-${BUILD_NUMBER}"
    AWK_VERSION_MATCH=${RELEASE_VERSION_ESCAPED}
fi

ssh "${SYSLOG_SERVER_USER}@${SYSLOG_SERVER}" \
   "zcat /var/log/${CLUSTER_LOGFILE}.1.gz | \
    cat - /var/log/${CLUSTER_LOGFILE} | \
    awk '/ ${BUILD_STRING}: Build ${AWK_VERSION_MATCH} \(${BUILD_NUMBER}\) start/,/ ${BUILD_STRING}: Build ${RELEASE_VERSION_ESCAPED} \(${BUILD_NUMBER}\) finish$/' | \
    gzip -c > ${AUTOMATED_BUILD_GZIP}"

scp -q ${SYSLOG_SERVER_USER}@${SYSLOG_SERVER}:${AUTOMATED_BUILD_GZIP} .

scp -q ${AUTOMATED_BUILD_GZIP} "${FILE_SERVER_USER}@${FILE_SERVER}:/home/shared/builds/${GITHUB_OWNER}/${GITHUB_BRANCH}/debug/${RESULTS_LOG}.log.gz"

if [ -n "${EXECUTOR_NUMBER}" -a -d "/tmp/teacup-artifacts-${EXECUTOR_NUMBER}" ]
then
    rsync -rltgoD --chmod=Du=rwx,Dg=rx,Do=rx,Fu=rw,Fg=r,Fo=r "/tmp/teacup-artifacts-${EXECUTOR_NUMBER}/" "${FILE_SERVER_USER}@${FILE_SERVER}:/home/shared/builds/${GITHUB_OWNER}/${GITHUB_BRANCH}/debug/${TEACUP_ARTIFACTS_DIR}/"
    rm -rf "/tmp/teacup-artifacts-${EXECUTOR_NUMBER}"
fi

set +x

echo
echo
echo "Errors in the log:"

if [ -x "${WORKSPACE}"/teacup/tools/extract-errors.py ]
then
    zcat ${AUTOMATED_BUILD_GZIP} | "${WORKSPACE}"/teacup/tools/extract-errors.py
else
    zcat ${AUTOMATED_BUILD_GZIP} | awk '/^Traceback \(most recent/,/^(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)/'
fi
echo

cat <<EOF
Options to view the log:
http://${FILE_SERVER}/builds/${GITHUB_OWNER}/${GITHUB_BRANCH}/debug/${RESULTS_LOG}.log
http://${FILE_SERVER}/builds/${GITHUB_OWNER}/${GITHUB_BRANCH}/debug/${RESULTS_LOG}.log.gz
http://${FILE_SERVER}/builds/${GITHUB_OWNER}/${GITHUB_BRANCH}/debug/${TEACUP_ARTIFACTS_DIR}/
scp ${FILE_SERVER}:/home/shared/builds/${GITHUB_OWNER}/${GITHUB_BRANCH}/debug/${RESULTS_LOG}.log.gz .
EOF
