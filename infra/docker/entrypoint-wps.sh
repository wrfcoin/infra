#!/bin/bash
# entrypoint-wps.sh — WPS entrypoint with automatic geography data download
#
# If /data/geog is empty, downloads WPS_GEOG_LOW_RES (geog_minimum set, ~200MB)
# from the WRF GitHub releases, then exec's the passed command.

set -e

GEOG_DIR="/data/geog"
GEOG_URL="https://www2.mmm.ucar.edu/wrf/src/wps_files/geog_minimum.tar.bz2"

if [ -d "${GEOG_DIR}" ] && [ -z "$(ls -A "${GEOG_DIR}" 2>/dev/null)" ]; then
    echo "[entrypoint-wps] /data/geog is empty — downloading WPS_GEOG minimum dataset..."
    cd /tmp
    wget -q "${GEOG_URL}" -O geog_minimum.tar.bz2
    tar xjf geog_minimum.tar.bz2 -C "${GEOG_DIR}" --strip-components=1
    rm -f geog_minimum.tar.bz2
    echo "[entrypoint-wps] Geography data download complete."
else
    echo "[entrypoint-wps] /data/geog already populated, skipping download."
fi

exec "$@"
