#!/usr/bin/env bash
# Runs the generated artifact inside a user/mount namespace. The real /etc,
# /var/log and /usr/local are shadowed by temporary test directories.
set -e
mount --bind "$TEST_ETC" /etc
mount --bind "$TEST_VARLOG" /var/log
mount --bind "$TEST_LOCAL" /usr/local
exec bash "$OLA_ARTIFACT" "$@"
