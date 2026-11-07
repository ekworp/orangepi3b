#!/bin/bash
# Install the USB HID virtual-keyboard gadget on the Orange Pi 3B.
# Run with: sudo bash install.sh
set -euo pipefail

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
	echo "Please run with sudo: sudo bash $0" >&2
	exit 1
fi

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ENV_FILE=/boot/armbianEnv.txt
DTBO_NAME=usb-otg-gadget
DTBO_DST=/boot/overlay-user/${DTBO_NAME}.dtbo

MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || true)
case "$MODEL" in
*v2.1*) BASE_DTB=/boot/dtb/rockchip/rk3566-orangepi-3b-v2.1.dtb ;;
*) BASE_DTB=/boot/dtb/rockchip/rk3566-orangepi-3b-v1.1.dtb ;;
esac

echo "==> checking prerequisites"
[ -f "$BASE_DTB" ] || { echo "base DTB not found: $BASE_DTB" >&2; exit 1; }
[ -f "$ENV_FILE" ] || { echo "armbianEnv.txt not found: $ENV_FILE" >&2; exit 1; }
[ -f "$HERE/${DTBO_NAME}.dtbo" ] || { echo "missing $HERE/${DTBO_NAME}.dtbo" >&2; exit 1; }
command -v fdtoverlay >/dev/null || { echo "fdtoverlay missing" >&2; exit 1; }
command -v fdtget >/dev/null || { echo "fdtget missing" >&2; exit 1; }

echo "==> validating overlay against $BASE_DTB"
TMP_DTB=$(mktemp)
trap 'rm -f "$TMP_DTB"' EXIT
fdtoverlay -i "$BASE_DTB" -o "$TMP_DTB" "$HERE/${DTBO_NAME}.dtbo"
MODE=$(fdtget "$TMP_DTB" /usb@fcc00000 dr_mode)
[ "$MODE" = "peripheral" ] || {
	echo "overlay validation failed: dr_mode=$MODE" >&2
	exit 1
}
echo "    ok: OTG0 dr_mode=peripheral"

echo "==> backing up $ENV_FILE"
STAMP=$(date +%Y%m%d-%H%M%S)
cp -a "$ENV_FILE" "${ENV_FILE}.bak-vkbd-${STAMP}"
echo "    ${ENV_FILE}.bak-vkbd-${STAMP}"

echo "==> installing device-tree overlay"
install -d -m 0755 /boot/overlay-user
install -m 0644 "$HERE/${DTBO_NAME}.dtbo" "$DTBO_DST"

echo "==> enabling user overlay in armbianEnv.txt"
if grep -q '^user_overlays=' "$ENV_FILE"; then
	CURRENT=$(grep '^user_overlays=' "$ENV_FILE" | tail -n 1 | cut -d= -f2-)
	case " $CURRENT " in
	*" ${DTBO_NAME} "*) echo "    already enabled" ;;
	*)
		NEW=$(printf '%s %s' "$CURRENT" "$DTBO_NAME" | sed 's/^ *//; s/  */ /g')
		sed -i "s|^user_overlays=.*|user_overlays=${NEW}|" "$ENV_FILE"
		echo "    user_overlays=${NEW}"
		;;
	esac
else
	echo "user_overlays=${DTBO_NAME}" >> "$ENV_FILE"
	echo "    user_overlays=${DTBO_NAME}"
fi

echo "==> installing gadget scripts"
install -m 0755 "$HERE/usb-gadget-kbd.sh" /usr/local/sbin/usb-gadget-kbd.sh
install -m 0755 "$HERE/vkbd" /usr/local/bin/vkbd
install -d -m 0755 /usr/local/lib/vkbd
install -m 0644 "$HERE/keyboard.bin" /usr/local/lib/vkbd/keyboard.bin
install -m 0644 "$HERE/usb-gadget-kbd.service" \
	/etc/systemd/system/usb-gadget-kbd.service
install -m 0644 "$HERE/99-hidg.rules" /etc/udev/rules.d/99-hidg.rules

echo "==> enabling service"
systemctl daemon-reload
systemctl enable usb-gadget-kbd.service
udevadm control --reload-rules || true
udevadm trigger --subsystem-match=hidg || true

cat <<EOF

Done.

Next steps:
  1. Power the board through the USB-C port as usual.
  2. Reboot:  sudo reboot
  3. Connect the OTG port (the upper USB2.0 port in the USB1 stack,
     directly above the blue USB3.0 port) to the host PC with a
     good-quality USB2.0 A-to-A cable.
  4. Type:    vkbd type "hello world"
              vkbd key enter
              vkbd combo ctrl alt t

Rollback:
  sudo bash $HERE/rollback.sh
  sudo reboot

If it does not boot: mount the SD card on another machine and restore
  /boot/armbianEnv.txt.bak-vkbd-${STAMP}
or remove the user_overlays line and /boot/overlay-user/${DTBO_NAME}.dtbo.
EOF
