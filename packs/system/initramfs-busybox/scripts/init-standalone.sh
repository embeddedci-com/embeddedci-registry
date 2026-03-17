#!/bin/sh
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev || mount -t tmpfs none /dev
echo
echo "Booted into BusyBox initramfs!"
echo "Kernel: $(uname -a)"
echo
exec /bin/sh
