#!/usr/bin/env bash
# healthcheck-wrf.sh — Health check script for WPS and WRF containers
#
# Usage:
#   healthcheck-wrf.sh --wps    # Check WPS executables
#   healthcheck-wrf.sh --wrf    # Check WRF executables
#   healthcheck-wrf.sh          # Check both (auto-detect based on available binaries)

set -euo pipefail

check_executable() {
    local exe="$1"
    local label="$2"

    if [ ! -f "$exe" ]; then
        echo "FAIL: $label not found at $exe"
        return 1
    fi

    if [ ! -x "$exe" ]; then
        echo "FAIL: $label exists but is not executable at $exe"
        return 1
    fi

    echo "OK: $label found and executable"
    return 0
}

check_wps() {
    local failed=0
    local wps_dir="${WPS_DIR:-/wps}"

    echo "Checking WPS executables in $wps_dir ..."

    check_executable "$wps_dir/geogrid.exe" "geogrid.exe" || failed=1
    check_executable "$wps_dir/ungrib.exe"  "ungrib.exe"  || failed=1
    check_executable "$wps_dir/metgrid.exe" "metgrid.exe" || failed=1

    return $failed
}

check_wrf() {
    local failed=0
    local wrf_dir="${WRF_DIR:-/wrf}"

    # Check multiple possible locations for WRF executables
    local wrf_exe=""
    local real_exe=""

    for candidate in "$wrf_dir/wrf.exe" "$wrf_dir/main/wrf.exe" "$wrf_dir/run/wrf.exe"; do
        if [ -f "$candidate" ]; then
            wrf_exe="$candidate"
            break
        fi
    done

    for candidate in "$wrf_dir/real.exe" "$wrf_dir/main/real.exe" "$wrf_dir/run/real.exe"; do
        if [ -f "$candidate" ]; then
            real_exe="$candidate"
            break
        fi
    done

    echo "Checking WRF executables in $wrf_dir ..."

    if [ -z "$wrf_exe" ]; then
        echo "FAIL: wrf.exe not found in any expected location"
        failed=1
    else
        check_executable "$wrf_exe" "wrf.exe" || failed=1
    fi

    if [ -z "$real_exe" ]; then
        echo "FAIL: real.exe not found in any expected location"
        failed=1
    else
        check_executable "$real_exe" "real.exe" || failed=1
    fi

    return $failed
}

# Parse arguments
mode=""
case "${1:-}" in
    --wps)
        mode="wps"
        ;;
    --wrf)
        mode="wrf"
        ;;
    --help|-h)
        echo "Usage: $0 [--wps|--wrf]"
        echo "  --wps  Check WPS executables (geogrid, ungrib, metgrid)"
        echo "  --wrf  Check WRF executables (wrf.exe, real.exe)"
        echo "  (none) Auto-detect and check available executables"
        exit 0
        ;;
    "")
        mode="auto"
        ;;
    *)
        echo "Unknown option: $1"
        echo "Usage: $0 [--wps|--wrf]"
        exit 1
        ;;
esac

exit_code=0

if [ "$mode" = "wps" ] || [ "$mode" = "auto" ]; then
    check_wps || exit_code=1
fi

if [ "$mode" = "wrf" ] || [ "$mode" = "auto" ]; then
    check_wrf || exit_code=1
fi

if [ $exit_code -eq 0 ]; then
    echo "Health check PASSED"
else
    echo "Health check FAILED"
fi

exit $exit_code
