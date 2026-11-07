#!/bin/sh
# Create/remove a USB HID keyboard gadget through configfs.
set -eu

GADGET_DIR=/sys/kernel/config/usb_gadget/vkbd
REPORT_DESC=/usr/local/lib/vkbd/keyboard.bin
UDC_WAIT_TENTHS=100   # 10 seconds

log() { echo "usb-gadget-kbd: $*"; }

wait_for_udc() {
	i=0
	while [ "$i" -lt "$UDC_WAIT_TENTHS" ]; do
		udc=$(ls /sys/class/udc 2>/dev/null | head -n 1 || true)
		if [ -n "$udc" ]; then
			echo "$udc"
			return 0
		fi
		i=$((i + 1))
		sleep 0.1
	done
	return 1
}

teardown() {
	[ -d "$GADGET_DIR" ] || return 0

	# Unbind first so the host sees a clean disconnect.
	if [ -e "$GADGET_DIR/UDC" ]; then
		echo "" > "$GADGET_DIR/UDC" 2>/dev/null || true
	fi

	rm -f "$GADGET_DIR"/configs/*/* 2>/dev/null || true
	rmdir "$GADGET_DIR"/functions/hid.* 2>/dev/null || true
	rmdir "$GADGET_DIR"/configs/*/strings/* 2>/dev/null || true
	rmdir "$GADGET_DIR"/configs/* 2>/dev/null || true
	rmdir "$GADGET_DIR"/strings/* 2>/dev/null || true
	rmdir "$GADGET_DIR" 2>/dev/null || true
}

setup() {
	modprobe libcomposite
	modprobe usb_f_hid

	if ! grep -qs ' /sys/kernel/config configfs ' /proc/mounts; then
		mount -t configfs none /sys/kernel/config
	fi

	udc=$(wait_for_udc) || {
		log "no UDC found - is the device-tree overlay applied (dr_mode=peripheral)?"
		exit 1
	}

	teardown

	mkdir -p "$GADGET_DIR"
	cd "$GADGET_DIR"

	echo 0x1d6b > idVendor
	echo 0x0104 > idProduct
	echo 0x0100 > bcdDevice
	echo 0x0200 > bcdUSB

	mkdir -p strings/0x409
	echo "OPI3B-VKBD-0001" > strings/0x409/serialnumber
	echo "Orange Pi" > strings/0x409/manufacturer
	echo "Virtual Keyboard" > strings/0x409/product

	mkdir -p configs/c.1/strings/0x409
	echo "HID Keyboard" > configs/c.1/strings/0x409/configuration
	echo 100 > configs/c.1/MaxPower

	mkdir -p functions/hid.usb0
	echo 1 > functions/hid.usb0/protocol
	echo 1 > functions/hid.usb0/subclass
	echo 8 > functions/hid.usb0/report_length
	cat "$REPORT_DESC" > functions/hid.usb0/report_desc

	ln -s functions/hid.usb0 configs/c.1/

	echo "$udc" > UDC
	log "bound to $udc"
}

case "${1:-start}" in
	start)   setup ;;
	stop)    teardown; log "stopped" ;;
	restart) teardown; setup ;;
	*)       echo "usage: $0 {start|stop|restart}" >&2; exit 2 ;;
esac
