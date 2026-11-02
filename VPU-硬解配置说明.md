# Orange Pi 3B (RK3566) VPU 硬解配置记录

- 系统：Armbian 26.11.0-trunk.3 noble，内核 `6.18.43-current-rockchip64`
- 桌面：KDE Plasma **Wayland**
- 日期：2026-11-02

## 一、关于网上那个 PPA

`ppa:liujianfeng1994/rockchip-multimedia`

- **有 noble 版本**（arm64 包齐全，jammy 也有）。
- 仓库里**没有内核包**（无 `linux-image-*`、`linux-dtb-*`），所以它本身不会改内核。
- 但它整套方案依赖厂商内核的 `/dev/mpp_service`。当前 Armbian 主line内核没有这个设备，也没有 `rockchip_mpp` 模块；`librockchip_mpp` 里只认 `/dev/mpp_service`，没有 V4L2 后端。
- 结论：**在这套系统上装 PPA 的 ffmpeg/mpv/chromium 也硬解不了**。因此没有添加该 PPA，也没有执行 `apt dist-upgrade`。

主line内核实际提供的是 V4L2 stateless 接口：

| 设备 | 驱动 | 能力 |
|---|---|---|
| `/dev/video1` | rkvdec | H.264 (`S264`)、HEVC (`S265`) |
| `/dev/video2` | hantro-vpu | VP8、MPEG-2 |
| `/dev/video3` | hantro-vpu | H.264/H.265 编码 |

## 二、已完成的配置

### 1. FFmpeg（完整版，可用）

位置：`/opt/ffmpeg-v4l2/bin/ffmpeg`
来源：**Kwiboo 的 FFmpeg 分支** `v4l2-request-n8.0.1`（主线 FFmpeg 至今没有 `v4l2request` hwaccel）。

构建参数：`--enable-shared --enable-pic --enable-gpl --enable-v4l2-request --enable-libdrm`

- 521 个解码器、417 种格式（mp4/mkv/webm/ts/avi/flv 等）。
- 共享库在 `/opt/ffmpeg-v4l2/lib`，已写入 `/etc/ld.so.conf.d/ffmpeg-v4l2.conf`。
- 没有外部的 x264/x265 编码器，也**没有 HTTPS/TLS**（未装 openssl/gnutls）；本地解码和 `http://` 没问题。

实测（1080p，`drm_prime` 零拷贝）：

| 片源 | 速度 |
|---|---|
| H.264 1080p | 180 帧 / 0.96s ≈ 187 fps |
| HEVC 1080p | 180 帧 / 0.74s ≈ 243 fps |
| HEVC 720p | 120 帧 / 0.24s ≈ 500 fps |

用法：

```bash
/opt/ffmpeg-v4l2/bin/ffmpeg -hwaccel v4l2request \
  -hwaccel_output_format drm_prime -i input.mp4 -f null -
```

系统自带的 `/usr/bin/ffmpeg` 仍在，做编码/需要 x264 时继续用它。

### 2. mpv（可用）

位置：`/usr/local/bin/mpv`（v0.41.0，优先于系统的 `/usr/bin/mpv` 0.37）

- 链接的是上面的 Kwiboo FFmpeg（`v4l2request` / `v4l2request-copy` 都在）。
- 默认配置 `~/.config/mpv/mpv.conf`：

```
hwdec=v4l2request-copy
vo=gpu
gpu-context=wayland
```

验证：

```bash
mpv --no-audio --msg-level=all=info video.mp4 2>&1 | grep 'hardware decoding'
# 输出：Using hardware decoding (v4l2request-copy).
```

实测 1080p HEVC 6 秒片源，Wayland 下约 7.7 秒播放完（含启动），实时无压力。

说明：`v4l2request`（零拷贝）在这块 Mali G52 上也能用，但 CPU 占用更高；推荐 `v4l2request-copy`。

### 3. Chromium（可用）

已写入 `/etc/chromium.d/rockchip-vpu`：

```
--ozone-platform=wayland
--enable-features=AcceleratedVideoDecoder,AcceleratedVideoDecodeLinuxGL,AcceleratedVideoDecodeLinuxZeroCopyGL
--ignore-gpu-blocklist --enable-gpu-rasterization --enable-zero-copy
```

验证方法：

- 打开 `chrome://gpu`，**Video Decode** 应显示 `Hardware accelerated`
- 打开 `chrome://media-internals`，应看到 `kVideoDecoderName: V4L2VideoDecoder`
- 日志中会出现 `Using a stateless API ... fourcc: S264`

必须使用 **Wayland** 会话。回滚：`sudo rm /etc/chromium.d/rockchip-vpu`。

### 4. GStreamer（已安装，有限可用）

已安装 `gstreamer1.0-plugins-bad`、`gstreamer1.0-tools`、`gstreamer1.0-gl`：

```bash
gst-launch-1.0 -q filesrc location=test.mp4 ! qtdemux ! h264parse \
  ! v4l2slh264dec ! fakesink sync=false
```

注意：**1080p HEVC 只有约 4.5 fps**，因为 1080 不是 16 的倍数，GStreamer 在 1088→1080 时走了极慢的软件拷贝；1920×1088 的 HEVC 可以到 180 fps。H.264 1080p 约 40 fps，够实时。**本地播放/转码请优先用 mpv 或上面的 FFmpeg。**

## 三、目前还不能硬解的

- **VLC**：VLC 3 不支持 V4L2 stateless。需要在主line上硬解就只能换播放器（mpv 已可用）。
- **VP9 / AV1**：当前主line的 rkvdec/hantro 只暴露 H.264/HEVC 和 VP8/MPEG2，没有 `VP9F`/`AV1F`。YouTube 默认发 VP9/AV1，浏览器里这部分仍会软解；可装 h264ify 强制 YouTube 走 H.264。
- 如果想要“网上教程里那种全都硬解”的效果（MPP + PPA），需要换带厂商内核（有 `/dev/mpp_service`）的系统镜像，例如官方 Orange Pi Ubuntu 或 Ubuntu-Rockchip；Armbian 没有对应的 vendor 内核包。
- `/opt/ffmpeg-v4l2` 没有 TLS，直接用它拉 `https://` 流会失败；在线视频可用 yt-dlp 下载后播放。

## 四、自检

```bash
~/vpu-check.sh
```

## 五、回滚

- Chromium：`sudo rm /etc/chromium.d/rockchip-vpu`
- mpv 默认配置：删除 `~/.config/mpv/mpv.conf`
- FFmpeg：`sudo rm -rf /opt/ffmpeg-v4l2 /etc/ld.so.conf.d/ffmpeg-v4l2.conf && sudo ldconfig`
- mpv：`sudo rm /usr/local/bin/mpv`（桌面文件在 `/usr/local/share/applications/mpv.desktop`）
