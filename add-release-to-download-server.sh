#!/bin/bash

set -e
set -u
set -x
set -o pipefail

RELEASE_VERSION=${RELEASE_VERSION:=}
INCLUDE_CHROOT=${INCLUDE_CHROOT:="no"}
CUSTOMER_OVERRIDE=${CUSTOMER_OVERRIDE:=}
GA_OVERRIDE=${GA_OVERRIDE:="no"}
SSH_USER=${SSH_USER:="builder"}                                                      
SSH_OPTS=${SSH_OPTS:="-q -o StrictHostKeyChecking=no -o ConnectTimeout=10"}

RELEASE_FILE=""
RELEASE_SHA1=""
RELEASE_CHROOT=""

IS_GA="no"
IS_CUSTOMER="no"

UPDATE_SERVER="updates"
DOWNLOAD_SERVER="download"
SSH_UPDATES="ssh $SSH_OPTS $SSH_USER@$UPDATE_SERVER"
SSH_DOWNLOAD="ssh $SSH_OPTS $SSH_USER@$DOWNLOAD_SERVER"

# As nginx dir's are restrictive to the builder acct, use download dir as the cross-check
CUSTOMER_CHECK_DIR="/var/www/download"
DOWNLOAD_DIR_BASE="/var/www/download"
DOWNLOAD_REL_DIR="/var/release-files"

if [ -z "$RELEASE_VERSION" ]; then
    echo "Error: RELEASE_VERSION is not set!" >&2
    exit 1
fi

copy_over_file () {
    # Run a sha1sum on the file and compare with source. If it checks out don't copy over

    local file_local=$1
    local file_remote=$2

    local sha1_local=$(sha1sum $file_local | awk " {print \$1} ")
    local sha1_remote=$($SSH_DOWNLOAD "sha1sum $file_remote" | cut -d' ' -f1 )

    echo local:  $sha1_local
    echo remote: $sha1_remote

    if [ "$sha1_local" != "$sha1_remote" ]; then
        echo "There was a checksum mismatch with local file: $file_local and remote file: $file_remote"
        echo "Copying file: $file_local over..."
        scp "$file_local" "$SSH_USER@$DOWNLOAD_SERVER:$DOWNLOAD_REL_DIR"
    else
        echo "File: $file_local and file: $file_remote look good!"
    fi
}

GA_BUILDS=$($SSH_UPDATES " ls /opt/piston/updates | egrep -o "[0-9]+\.[0-9]+\.[0-9]+" ")

if [ -z "$GA_BUILDS" ]; then
    echo "Error: Found no GA builds on update server!" >&2
    exit 1
fi

for GA_BUILD in $GA_BUILDS; do
    if [ "$RELEASE_VERSION" = "$GA_BUILD" ]
    then
        echo "Found the build: $RELEASE_VERSION, it's a GA build."
        IS_GA="yes"
        break
    fi
done

if [[ "$IS_GA" = "no" ]] && [[ "$GA_OVERRIDE" = "no" ]]; then
    echo "Error: Build: $RELEASE_VERSION is not seen as a GA version!" >&2
    exit 1
fi

if [ ! -z "$CUSTOMER_OVERRIDE" ]; then
    echo "Overriding customer $CUSTOMER to new specified value: $CUSTOMER_OVERRIDE"
    CUSTOMER="$CUSTOMER_OVERRIDE"
fi

CUSTOMERS=$($SSH_DOWNLOAD "find $CUSTOMER_CHECK_DIR -type d -print")

for C in $CUSTOMERS; do
    if [ "$CUSTOMER" = "${C##*/}" ]; then
        echo "Found the customer: $CUSTOMER."
        IS_CUSTOMER="yes"
        break
    fi
done

if [ "$IS_CUSTOMER" = "no" ]; then
    echo "Error: Found no customer for: $CUSTOMER on download server!" >&2
    echo -e "Login to the download server and issue the following command:\n\tsudo /usr/local/sbin/add-download-directory" >&2
    exit 1
fi

echo "Ensuring release files exist on smurf.."
RELEASE_FILE="$(find /home/shared/builds/piston -name pentos-installer-$RELEASE_VERSION.img -print | egrep '.*')"
RELEASE_SHA1="$(find /home/shared/builds/piston -name pentos-installer-$RELEASE_VERSION.img.sha1 -print | egrep '.*')"

BASE_FILES=("$RELEASE_FILE" "$RELEASE_SHA1")
if [ "$INCLUDE_CHROOT" = "yes" ]; then
    RELEASE_CHROOT="$(find /home/shared/builds/piston -name "iocane-chroot-*-$RELEASE_VERSION.tar.gz" -print | egrep '.*')"
    BASE_FILES+=("$RELEASE_CHROOT")
fi

for FILE in "${BASE_FILES[@]}"; do
    FILENAME="${FILE##*/}"
    DEST_REL="$DOWNLOAD_REL_DIR/$FILENAME"
    DEST_CUST="$DOWNLOAD_DIR_BASE/$CUSTOMER/$FILENAME"

    echo "Processing file: $FILENAME..."
    copy_over_file "$FILE" "$DEST_REL"

    # If this file exists and fails to remove, the subsequent symlink will attempt will fail
    echo "Removing old soft-link reference..."
    $SSH_DOWNLOAD " rm $DEST_CUST " || true

    echo "Adding new soft-link..."
    $SSH_DOWNLOAD " ln -s $DEST_REL $DEST_CUST "

    echo "Updating file ownership..."
    $SSH_DOWNLOAD " chown $SSH_USER:pistoncloud $DEST_REL "

    echo "Done!"
done
