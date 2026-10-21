#!/bin/sh
set -eu

: "${MQTT_USERNAME:?MQTT_USERNAME is required}"
: "${MQTT_PASSWORD:?MQTT_PASSWORD is required}"

# The username travels in MQTT_BROKER_URL userinfo exactly like the password
# (user:pass@host), so it diverges between mqtt.js (URL-decodes) and Mosquitto
# (literal) the same way. The unreserved set also subsumes the old colon rule:
# a ':' in the username would truncate the passwd-file entry.
case "${MQTT_USERNAME}" in
  *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~-]*)
    printf '%s\n' \
      'ERROR: MQTT_USERNAME must use only URL-unreserved characters: A-Z a-z 0-9 - . _ ~' >&2
    exit 1
    ;;
esac

# The same value is inserted into MQTT_BROKER_URL. mqtt.js decodes URL
# userinfo before authenticating, while Mosquitto receives this environment
# value literally. Restricting the shared password to RFC 3986 unreserved
# characters prevents encoded and decoded credentials from diverging.
case "${MQTT_PASSWORD}" in
  *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~-]*)
    printf '%s\n' \
      'ERROR: MQTT_PASSWORD must use only URL-unreserved characters: A-Z a-z 0-9 - . _ ~' >&2
    exit 1
    ;;
esac

# The eclipse-mosquitto image has no USER directive, so this runs as root;
# writing the root-owned /mosquitto/auth volume and the chown below depend on
# that. Fail with a clear message if a user: directive or upstream image
# change ever breaks the assumption.
if [ "$(id -u)" -ne 0 ]; then
  printf '%s\n' 'ERROR: provision-auth must run as root to provision /mosquitto/auth' >&2
  exit 1
fi

auth_dir="/mosquitto/auth"
password_file="${auth_dir}/passwd.txt"
temporary_file="${password_file}.tmp.$$"

cleanup() {
  rm -f "${temporary_file}"
}
trap cleanup EXIT HUP INT TERM

# umask before mkdir so the auth dir itself is 0700, not 0755.
umask 077
mkdir -p "${auth_dir}"

# mosquitto_passwd -b exposes the password in the process list. Instead, write
# a root-only temporary plaintext file, convert it in place to Mosquitto's
# supported salted password format, and atomically install only the hash.
printf '%s:%s\n' "${MQTT_USERNAME}" "${MQTT_PASSWORD}" >"${temporary_file}"
mosquitto_passwd -U "${temporary_file}"
chown "${PUID:-1883}:${PGID:-1883}" "${temporary_file}"
chmod 0600 "${temporary_file}"
mv -f "${temporary_file}" "${password_file}"
trap - EXIT HUP INT TERM

exec /usr/sbin/mosquitto -c /mosquitto/config/mosquitto.conf
