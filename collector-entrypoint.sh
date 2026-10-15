#!/bin/sh
# The collector image only reads COLLECTOR_SECRET from its environment. Export it
# from the Docker secret so the value never lands in the service spec.
set -eu
COLLECTOR_SECRET="$(cat /run/secrets/collector_secret)"
export COLLECTOR_SECRET
exec /run_supervisord.sh
