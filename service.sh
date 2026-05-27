#!/system/bin/sh

MODDIR=${0%/*}

mkdir -p "$MODDIR/var" "$MODDIR/var/log" "$MODDIR/var/tmp"
chmod 0700 "$MODDIR/var" "$MODDIR/var/log" "$MODDIR/var/tmp"
