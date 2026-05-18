#! /bin/bash -f
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

ALL_DOMAINS=false

# Services are stopped for a single `container` system, identified by its
# launchd label prefix. This matches the CONTAINER_LAUNCH_PREFIX environment
# variable used by the `container` binary, so an independent system started
# with a custom prefix is torn down by running this script with the same
# variable set. Defaults to the standard `com.apple.container` prefix.
PREFIX="${CONTAINER_LAUNCH_PREFIX:-com.apple.container}"

# Escape regex metacharacters (notably the dots) so the prefix can be used
# safely inside the grep patterns below.
PREFIX_RE=$(printf '%s' "$PREFIX" | sed 's/[][\.*^$/]/\\&/g')

usage() {
    echo "Usage: $0 [-a] [-h]"
    echo "Stop container services for the prefix '$PREFIX'"
    echo
    echo "Options:"
    echo "a     Stop container services in all launchd domains."
    echo "h     Show this help message."
    echo
    echo "Set CONTAINER_LAUNCH_PREFIX to target an independent container system."
    exit 1
}

while getopts ":ah" arg; do
    case "$arg" in
        a)
            ALL_DOMAINS=true
            ;;
        h)
            usage
            ;;
        *)
            echo "Invalid option: -${OPTARG}"
            usage
            ;;
    esac
done

if $ALL_DOMAINS; then
    uid=$(id -u)
    for domain in "gui/$uid" "user/$uid" "system"; do
        if [ "$domain" = "system" ] && [ "$uid" -ne 0 ]; then
            continue
        fi
        launchctl print "$domain" 2>/dev/null \
            | grep -oE "${PREFIX_RE}\.[^ ]+" \
            | sort -u \
            | while read -r service; do
                launchctl bootout "$domain/$service" 2>/dev/null || true
            done
    done
else
    domain_string=""

    launchd_domain=$(launchctl managername)

    if [[ "$launchd_domain" == "System" ]]; then
      domain_string="system"
    elif [[ "$launchd_domain" == "Aqua" ]]; then
      domain_string="gui/$(id -u)"
    elif [[ "$launchd_domain" == "Background" ]]; then
      domain_string="user/$(id -u)"
    else
        echo "Unsupported launchd domain. Exiting"
        exit 1
    fi

    launchctl list | grep -e "${PREFIX_RE}"'\W' | awk '{print $3}' \
        | xargs -I % sh -c 'launchctl bootout '"$domain_string"'/% 2>/dev/null || true'
fi
