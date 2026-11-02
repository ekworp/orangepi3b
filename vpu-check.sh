#!/bin/bash
# RK3566 VPU 硬解自检脚本
set -u
FF=/opt/ffmpeg-v4l2/bin/ffmpeg
D="${TMPDIR:-/tmp}/vpu-check"
mkdir -p "$D"

echo "== 1. 内核解码设备 =="
for d in /dev/video*; do
  [ -c "$d" ] && [ ! -L "$d" ] || continue
  drv=$(v4l2-ctl -d "$d" --info 2>/dev/null | grep -m1 'Driver name' | awk -F': ' '{print $2}')
  card=$(v4l2-ctl -d "$d" --info 2>/dev/null | grep -m1 'Card type' | awk -F': ' '{print $2}')
  [ -n "$drv" ] && printf '  %-14s %-14s %s\n' "$d" "$drv" "$card"
done

echo
echo "== 2. FFmpeg v4l2request =="
if [ ! -x "$FF" ]; then
  echo "  $FF 不存在，请重新安装 Kwiboo FFmpeg"
  exit 1
fi
"$FF" -hide_banner -hwaccels | grep -q v4l2request \
  && echo "  OK: v4l2request 可用" \
  || { echo "  FAIL: 没有 v4l2request"; exit 1; }

echo
echo "== 3. 生成 1080p 测试片源 =="
if [ ! -f "$D/h264.mp4" ]; then
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=1920x1080:rate=30 \
    -t 2 -c:v libx264 -preset ultrafast -pix_fmt yuv420p "$D/h264.mp4"
fi
if [ ! -f "$D/h265.mp4" ]; then
  echo "  生成 HEVC 约需 20-30 秒..."
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=1920x1080:rate=30 \
    -t 2 -c:v libx265 -preset ultrafast -x265-params bframes=0:ref=1 \
    -tag:v hvc1 -pix_fmt yuv420p "$D/h265.mp4"
fi

echo
echo "== 4. 硬解测试（drm_prime，无 CPU 回读） =="
for f in h264 h265; do
  printf '  %-4s: ' "$f"
  "$FF" -hide_banner -nostats -loglevel info \
    -hwaccel v4l2request -hwaccel_output_format drm_prime \
    -i "$D/$f.mp4" -f null - 2>&1 | tail -1 | sed 's/^[[:space:]]*//'
done

echo
echo "== 5. mpv =="
if command -v mpv >/dev/null 2>&1 && mpv --hwdec=help 2>/dev/null | grep -q v4l2request-copy; then
  echo "  OK: $(command -v mpv) 支持 v4l2request-copy"
  printf '  实测 h264: '
  /bin/bash -c "TIMEFORMAT='real=%3R s'; time mpv --no-audio --vo=null --hwdec=v4l2request-copy --untimed --really-quiet '$D/h264.mp4'" 2>&1 | tail -1
else
  echo "  mpv 不支持 v4l2request（需要基于 Kwiboo FFmpeg 编译）"
fi

echo
echo "== 6. Chromium 配置 =="
if [ -f /etc/chromium.d/rockchip-vpu ]; then
  echo "  OK: /etc/chromium.d/rockchip-vpu 已存在"
  echo "  在 Wayland 会话中打开 chrome://gpu，Video Decode 应显示 Hardware accelerated"
else
  echo "  未配置 Chromium 硬解"
fi
