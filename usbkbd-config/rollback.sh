#!/bin/bash
# Remove the USB HID virtual-keyboard overlay. Run with: sudo bash rollback.sh
set -euo pipefail

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
	echo "Please run with sudo: sudo bash $0" >&2
	exit 1
fi

ENV_FILE=/boot/armbianEnv.txt
DTBO_NAME=usb-otg-gadget

if grep -q '^user_overlays=' "$ENV_FILE"; then
	CURRENT=$(grep '^user_overlays=' "$ENV_FILE" | tail -n 1 | cut -d= -f2-)
	NEW=$(printf '%s' "$CURRENT" | tr ' ' '\n' | grep -vx "$DTBO_NAME" | paste -sd' ' - || true)
	if [ -z "$NEW" ]; then
		sed -i '/^user_overlays=/d' "$ENV_FILE"
	else
		sed -i "s|^user_overlays=.*|user_overlays=${NEW}|" "$ENV_FILE"
	fi
fi

rm -f "/boot/overlay-user/${DTBO_NAME}.dtbo"
systemctl disable --now usb-gadget-kbd.service 2>/dev/null || true
systemctl daemon-reload

echo "Removed the overlay and disabled the gadget service."
echo "Reboot to restore the OTG port to Host mode: sudo reboot"
