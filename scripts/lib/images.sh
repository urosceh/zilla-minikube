#!/usr/bin/env bash
# Source image lock variables. Requires ZILLA_MINIKUBE_ROOT to be set.

set -euo pipefail

: "${ZILLA_MINIKUBE_ROOT:?ZILLA_MINIKUBE_ROOT must be set}"

# shellcheck source=/dev/null
source "${ZILLA_MINIKUBE_ROOT}/config/images.lock.env"
