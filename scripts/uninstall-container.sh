#!/bin/bash 
# Copyright © 2025-2026 Apple Inc. and the container project authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -uo pipefail

INSTALL_DIR="/usr/local"
DELETE_DATA=
OPTS=0

# An independent `container` system is identified by its launchd label prefix
# (CONTAINER_LAUNCH_PREFIX) and its data directory (CONTAINER_APP_ROOT). Set
# these to uninstall a system started with a custom prefix; they default to the
# standard values. Note that the `container` binary itself is shared by every
# system and is always removed regardless of these variables.
PREFIX="${CONTAINER_LAUNCH_PREFIX:-com.apple.container}"
APP_ROOT="${CONTAINER_APP_ROOT:-$HOME/Library/Application Support/com.apple.container}"

# Escape regex metacharacters (notably the dots) so the prefix can be used
# safely inside the grep pattern below.
PREFIX_RE=$(printf '%s' "$PREFIX" | sed 's/[][\.*^$/]/\\&/g')

usage() {
    echo "Usage: $0 {-d | -k}"
    echo "Uninstall container (system prefix: '$PREFIX')"
    echo
    echo "Options:"
    echo "d     Delete user data directory."
    echo "k     Don't delete user data directory."
    echo
    echo "Set CONTAINER_LAUNCH_PREFIX / CONTAINER_APP_ROOT to target an"
    echo "independent container system. The shared binary is always removed."
    exit 1
}

while getopts ":dk" arg; do
    case "$arg" in
        d)
            DELETE_DATA=true
            ((OPTS+=1))
            ;;
        k)
            DELETE_DATA=false
            ((OPTS+=1))
            ;;
        *)
            echo "Invalid option: -${OPTARG}"
            usage
            ;;
    esac
done

if [ $OPTS != 1 ]; then 
    echo "Invalid number of options. Must provide either -d OR -k"
    usage
    exit 1
fi

# check if container is still running
CONTAINER_RUNNING=$(launchctl list | grep -e "${PREFIX_RE}"'\W')
if [ -n "$CONTAINER_RUNNING" ]; then
    echo '`container` is still running. Please ensure the service is stopped by running `container system stop`'
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
    echo "This script requires an administrator password to remove the application files from system directories."
fi

FILES=$(pkgutil --only-files --files com.apple.container-installer)
for i in ${FILES[@]}; do
    # this command can fail for some of the reported files from pkgutil such as 
    # `/usr/local/bin/._uninstall-container.sh``
    sudo rm $INSTALL_DIR/$i &> /dev/null
done


DIRS=($(pkgutil --only-dirs --files com.apple.container-installer))
for ((i=${#DIRS[@]}-1; i>=0; i--)); do 
    # this command will fail when trying to remove `bin` and `libexec` since those directories
    # may not be empty
    sudo rmdir $INSTALL_DIR/${DIRS[$i]} &> /dev/null
done

sudo pkgutil --forget com.apple.container-installer > /dev/null
echo 'Removed `container` tool and helpers'

if [ "$DELETE_DATA" = true ]; then
    echo "Removing \`container\` user data at $APP_ROOT"
    sudo rm -rf "$APP_ROOT"
    echo 'Removing `container` user defaults'
    defaults delete com.apple.container.defaults > /dev/null 2>&1 || true
fi
