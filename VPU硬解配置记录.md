# RK3566 (Orange Pi 3B) VPU 硬解配置过程记录

- 日期：2026-11-02
- 系统：Armbian 26.11.0-trunk.3 noble / Ubuntu 24.04 base
- 内核：`6.18.43-current-rockchip64`（aarch64）
- 板子：`Xunlong Orange Pi 3B v1.1`（RK3566）
- 桌面：KDE Plasma **Wayland**（`wayland-0`）

> 本文记录的是实际执行过程、判断依据、踩过的坑和最终结果。
> 全程**没有修改内核、设备树或启动参数**，不需要重启；Chromium 需要退出重开。

---

## 0. 结论

| 项目 | 结果 |
|---|---|
| 网上教程的 `ppa:liujianfeng1994/rockchip-multimedia` | ❌ 不适用于本系统（缺 `/dev/mpp_service`），未安装 |
| 内核 VPU 驱动 | ✅ 已有：rkvdec（H.264/HEVC）、hantro（VP8/MPEG-2） |
| FFmpeg 硬解 | ✅ 安装 Kwiboo FFmpeg 到 `/opt/ffmpeg-v4l2` |
| mpv 硬解 | ✅ 编译 mpv 0.41 到 `/usr/local/bin/mpv` |
| Chromium 硬解 | ✅ 通过 `/etc/chromium.d/rockchip-vpu` 启用 |
| GStreamer | ⚠️ 能硬解，但 1080p HEVC 有严重拷贝缺陷，不建议 |
| VLC | ❌ VLC 3 不支持 V4L2 stateless |
| VP9/AV1 | ❌ 主line rkvdec/hantro 未暴露这两个格式 |

---

## 1. 环境确认

```bash
cat /etc/os-release
uname -a
cat /proc/device-tree/model
dpkg --print-architecture
```

结果：

```
Armbian 26.11.0-trunk.3 noble
Linux orangepi3b 6.18.43-current-rockchip64 #4 SMP PREEMPT ... aarch64
Xunlong Orange Pi 3B v1.1
arm64
```

查看 VPU 相关设备：

```bash
ls /dev | grep -Ei 'mpp|rga|vpu|dri|video'
lsmod | grep -Ei 'rkvdec|mpp|rga|hantro|vpu'
```

发现：

- `rockchip_vdec`（rkvdec）和 `hantro_vpu` 已加载；
- `/dev/video0` = RGA；
- `/dev/video1` = rkvdec；
- `/dev/video2` = hantro 解码；
- `/dev/video3` = hantro 编码；
- **没有** `/dev/mpp_service`。

```bash
v4l2-ctl --list-devices
```

```
rockchip,rk3328-vpu-dec (platform:fdea0000.video-codec): /dev/video2
rockchip,rk3568-vepu-enc (platform:fdee0000.video-codec): /dev/video3
rockchip-rga (platform:rga): /dev/video0
rkvdec (platform:rkvdec): /dev/video1
```

输出格式确认：

```bash
for d in 1 2 3; do
  v4l2-ctl -d /dev/video$d --list-formats-out
done
```

| 设备 | 输出格式 |
|---|---|
| `/dev/video1` (rkvdec) | `S265`（HEVC）、`S264`（H.264） |
| `/dev/video2` (hantro) | `MG2S`（MPEG-2）、`VP8F`（VP8） |
| `/dev/video3` (hantro enc) | `YM12`、`NM12`、`YUYV`、`UYVY` |

结论：这是 **V4L2 stateless（Request API）** 接口，不是 MPP。

---

## 2. 核查 PPA（重点）

网上教程：

```
sudo add-apt-repository ppa:liujianfeng1994/rockchip-multimedia
sudo apt dist-upgrade
sudo apt install rockchip-multimedia-config
```

### 2.1 是否有 noble 版本

```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  https://ppa.launchpadcontent.net/liujianfeng1994/rockchip-multimedia/ubuntu/dists/noble/Release
```

结果：`200`，**noble 存在**（jammy 也存在）。

### 2.2 仓库里有没有内核包

下载 noble 的 `Packages.gz` 后检查：

```bash
curl -s 'https://ppa.launchpadcontent.net/liujianfeng1994/rockchip-multimedia/ubuntu/dists/noble/main/binary-arm64/Packages.gz' \
  | gunzip -c | grep -E '^Package: (linux-|librockchip|libv4l|rockchip|mpv|vlc|ffmpeg|libavcodec)' | sort -u
```

结果只有用户态包：

```
ffmpeg
libavcodec60
librockchip-mpp1       1.5.0-1+git20240612...
librockchip-vpu0
libv4l-rkmpp
rockchip-multimedia-config  1.0.2+noble
```

**没有任何 `linux-image-*` 或 `linux-dtb-*`**，所以 PPA 本身不会动内核。

### 2.3 但它依赖厂商内核

检查 `rockchip-multimedia-config` 的 udev 规则：

```
KERNEL=="mpp_service", MODE="0660", GROUP="video" ...
KERNEL=="rga", ...
```

检查 `librockchip_mpp.so.1` 的字符串：

```bash
strings librockchip_mpp.so.1 | grep -iE 'mpp_service|/dev/video|v4l2'
```

只有：

```
/dev/mpp-service
/dev/mpp_service
open mpp_service failed
/proc/mpp_service/support_cmd
```

没有 V4L2 后端。

再检查当前系统：

```bash
ls -l /dev/mpp_service /dev/mpp-service
grep -i mpp /proc/devices
grep -Ei 'ROCKCHIP_MPP|MPP_SERVICE' /boot/config-$(uname -r)
find /lib/modules/$(uname -r) -iname '*mpp*'
```

结果：

- 设备不存在；
- 内核配置没有 MPP 相关项；
- 只有 `ppp_mppe.ko`（无关）。

### 2.4 决定

- **不添加该 PPA，不执行 `apt dist-upgrade`**。
- 原因：装了也无法硬解，只会引入不必要的系统变更。
- 如果一定要用 PPA 那套（MPP），必须换带厂商内核（有 `/dev/mpp_service`）的系统镜像，例如官方 Orange Pi Ubuntu 或 Ubuntu-Rockchip；Armbian 的 apt 源里只有 `current` / `edge`，没有 vendor/legacy 内核。

---

## 3. GStreamer 路线（已试，有限可用）

### 3.1 安装

```bash
sudo apt install gstreamer1.0-plugins-bad gstreamer1.0-tools gstreamer1.0-gl
```

安装后确认插件：

```bash
gst-inspect-1.0 v4l2slh264dec   # OK
gst-inspect-1.0 v4l2slh265dec   # OK
gst-inspect-1.0 v4l2slvp8dec    # OK
gst-inspect-1.0 v4l2slvp9dec    # MISSING（内核没暴露 VP9）
```

### 3.2 实测

生成 1080p H.264/HEVC 测试片：

```bash
ffmpeg -f lavfi -i testsrc2=size=1920x1080:rate=30 -t 6 \
  -c:v libx264 -preset ultrafast -pix_fmt yuv420p test_h264.mp4
ffmpeg -f lavfi -i testsrc2=size=1920x1080:rate=30 -t 6 \
  -c:v libx265 -preset ultrafast -tag:v hvc1 -pix_fmt yuv420p test_h265.mp4
```

解码：

```bash
gst-launch-1.0 -q filesrc location=test_h264.mp4 ! qtdemux ! h264parse \
  ! v4l2slh264dec ! fakesink sync=false
```

结果（fakesink，无显示）：

| 片源 | 时间 | 等效帧率 |
|---|---|---|
| H.264 720p（120 帧） | 0.41s | ~295 fps |
| H.264 1600×900（120 帧） | 2.15s | ~56 fps |
| H.264 1080p（180 帧） | 4.33s | ~41 fps |
| HEVC 720p（120 帧） | 0.34s | ~350 fps |
| **HEVC 1920×1088（60 帧）** | **0.34s** | **~180 fps** |
| **HEVC 1920×1080（60 帧）** | **13.5s** | **~4.5 fps** |

### 3.3 根因

1080 不是 16 的倍数，rkvdec 实际解码高度是 1088；GStreamer 在 1088→1080 时走了极慢的软件拷贝路径。1088 高度则完全正常。

另外尝试过：

- `v4l2convert`（RGA）→ 仍然慢，因为慢在解码器输出阶段；
- `waylandsink` → `wayland dmabuf video format not found`，无法创建 `wl_buffer`；
- `glimagesink` → 虽然协商到 DMABuf，但画面卡住（等待/导入问题）；
- caps 强制 1088 / `videocrop` → preroll 失败。

结论：GStreamer 保留安装，但**本地 1080p HEVC 不建议使用**；H.264 和 720p/1088 高度可用。

安装命令汇总：

```bash
sudo apt install gstreamer1.0-plugins-bad gstreamer1.0-tools gstreamer1.0-gl
```

---

## 4. FFmpeg 路线（最终采用）

### 4.1 为什么不直接用发行版/官方 FFmpeg

- Ubuntu 24.04 自带 FFmpeg 6.1：`ffmpeg -hwaccels` 没有 `v4l2request`。
- 主线 FFmpeg 8.0.1 / 7.1.1 源码里也**没有** `v4l2request`（`grep -r v4l2request` 为空）。
- BtbN 的静态 arm64 构建同样没有。
- 正确来源：**Kwiboo 的 FFmpeg 分支** `v4l2-request-n8.0.1`。

### 4.2 第一次：最小化构建（用于验证）

```bash
git clone --depth 1 --branch v4l2-request-n8.0.1 \
  https://github.com/Kwiboo/FFmpeg.git
cd FFmpeg

./configure --prefix=/opt/ffmpeg-v4l2 \
  --disable-doc --disable-network --disable-debug --disable-everything \
  --enable-protocol=file --enable-demuxer=mov,matroska \
  --enable-decoder=h264,hevc,vp8,vp9,av1 \
  --enable-parser=h264,hevc,vp8,vp9,av1 \
  --enable-hwaccel=h264_v4l2request,hevc_v4l2request,vp8_v4l2request,vp9_v4l2request,av1_v4l2request \
  --enable-v4l2-request --enable-libdrm \
  --enable-filter=null,scale,format,hwdownload,hwupload \
  --enable-muxer=null,rawvideo,framecrc \
  --enable-encoder=wrapped_avframe,rawvideo \
  --enable-ffmpeg --disable-ffplay --disable-ffprobe
```

踩坑：

1. 第一次 configure 报：
   `v4l2_request requested, but not all dependencies are satisfied: ... libudev`
   → `sudo apt install libudev-dev`。
2. `-f null -` 需要 `wrapped_avframe` 编码器，否则报
   `Automatic encoder selection failed` → 加上 `--enable-encoder=wrapped_avframe`。

验证：

```bash
ffmpeg -hwaccels | grep v4l2request
ffmpeg -hwaccel v4l2request -hwaccel_output_format drm_prime \
  -i test_h265.mp4 -f null -
```

结果：1080p HEVC 180 帧 / 0.75s ≈ **240 fps**。

### 4.3 第二次：完整构建（最终安装）

最小化构建没有音频/网络/常用容器，不能作为日常 ffmpeg，所以重新做完整构建。

第一次尝试 out-of-tree 构建失败：

```
Out of tree builds are impossible with config.h in source dir.
```

原因是源码目录里已经有上一次 in-tree 构建的 `config.h`。解决：

```bash
cd FFmpeg
make distclean

./configure --prefix=/opt/ffmpeg-v4l2 \
  --enable-shared --enable-pic \
  --disable-doc --disable-debug \
  --enable-gpl \
  --enable-v4l2-request --enable-libdrm \
  --disable-ffplay

make -j4
sudo make install
```

安装后注册共享库：

```bash
echo '/opt/ffmpeg-v4l2/lib' | sudo tee /etc/ld.so.conf.d/ffmpeg-v4l2.conf
sudo ldconfig
```

确认：

```bash
/opt/ffmpeg-v4l2/bin/ffmpeg -version
/opt/ffmpeg-v4l2/bin/ffmpeg -hwaccels | grep v4l2request
```

结果：

- 521 个解码器、417 种格式（mp4/mkv/webm/ts/avi/flv 等）；
- 有 AAC/MP3/Opus/FLAC/Vorbis 音频解码；
- 没有 x264/x265 外部编码器；
- 没有 HTTPS/TLS（没装 openssl/gnutls），`http://` 和本地文件正常。

最终实测（1080p，`drm_prime`）：

| 片源 | 时间 | 速度 |
|---|---|---|
| HEVC 1080p（180 帧） | 0.74s | ≈ 243 fps / 8.0x |
| H.264 1080p（180 帧） | 0.96s | ≈ 187 fps / 6.2x |
| HEVC 720p（120 帧） | 0.24s | ≈ 500 fps / 16.5x |

使用：

```bash
/opt/ffmpeg-v4l2/bin/ffmpeg -hwaccel v4l2request \
  -hwaccel_output_format drm_prime -i input.mp4 -f null -
```

注意：系统 `/usr/bin/ffmpeg` 保留不动；需要 x264 编码时继续用它。

---

## 5. Chromium 路线（可用）

### 5.1 先确认二进制里有 V4L2 解码器

```bash
chromium --version       # 151.0.7922.71
strings /usr/lib/chromium/chromium | grep -c V4L2VideoDecoder
strings /usr/lib/chromium/chromium | grep -c AcceleratedVideoDecoder
strings /usr/lib/chromium/chromium | grep -c V4L2StatelessVideoDecoder
```

结果都非 0，说明编译进了 V4L2 stateless 解码器。

### 5.2 写系统级 flags

Ubuntu 的 `/usr/bin/chromium` 会 source `/etc/chromium.d/*`，所以新建：

`/etc/chromium.d/rockchip-vpu`

```sh
export CHROMIUM_FLAGS="$CHROMIUM_FLAGS --ozone-platform=wayland"
export CHROMIUM_FLAGS="$CHROMIUM_FLAGS --enable-features=AcceleratedVideoDecoder,AcceleratedVideoDecodeLinuxGL,AcceleratedVideoDecodeLinuxZeroCopyGL"
export CHROMIUM_FLAGS="$CHROMIUM_FLAGS --ignore-gpu-blocklist --enable-gpu-rasterization --enable-zero-copy"
```

说明：

- 真正控制硬解的 feature 是 `AcceleratedVideoDecoder`；
- 必须 Wayland；X11 下不会走 V4L2；
- 一开始用 `--ozone-platform-hint=auto`，但在 SSH 环境里 Chromium 选了 X11 并报
  `Missing X server or $DISPLAY`，所以改成显式 `--ozone-platform=wayland`。

### 5.3 验证

用一个本地 H.264 页面测试：

```bash
timeout 35 chromium --user-data-dir=/tmp/chromeprofile --no-first-run \
  --enable-logging=stderr --v=1 file:///tmp/vputest/test.html
```

日志关键行：

```
InitializeBackend(): Using a stateless API for profile: h264 baseline and fourcc: S264
SetupInputFormat(): Input (OUTPUT queue) Fourcc: S264
SetupOutputFormat(): Output (CAPTURE queue) candidate: NV12
```

确认走了 `/dev/video1` 的 rkvdec。桌面里打开 `chrome://gpu` 应显示
`Video Decode: Hardware accelerated`；`chrome://media-internals` 里是 `V4L2VideoDecoder`。

回滚：

```bash
sudo rm /etc/chromium.d/rockchip-vpu
```

---

## 6. mpv 路线（可用）

### 6.1 为什么必须自己编

系统 mpv 0.37 链接的是 Ubuntu FFmpeg 6.1，`mpv --hwdec=help` 里没有 `v4l2request`。
必须用 4.3 的 Kwiboo FFmpeg 重新编译 mpv。

### 6.2 依赖

先试：

```bash
sudo apt-get build-dep mpv
```

失败：

```
libpipewire-0.3-dev : Depends: libpipewire-0.3-0t64 (= 1.0.5-1ubuntu3.3)
but 1.2.6-2+24.04+noble+stable+build4 is to be installed
```

原因是系统里的 PipeWire 来自第三方源，版本冲突。改为手动装依赖，并禁用 pipewire：

```bash
sudo apt install meson ninja-build pkgconf \
  libass-dev libplacebo-dev libdrm-dev libegl-dev libgl-dev libgbm-dev \
  libwayland-dev wayland-protocols libx11-dev libxkbcommon-dev \
  libasound2-dev libpulse-dev libarchive-dev libuchardet-dev \
  libjpeg-dev liblcms2-dev libvulkan-dev libsdl2-dev liblua5.2-dev \
  libdisplay-info-dev
```

`libdisplay-info-dev` 是 meson 配置阶段报错后补装的：

```
meson.build:958:18: ERROR: Dependency "libdisplay-info" not found
```

### 6.3 编译

```bash
git clone --depth 1 --branch v0.41.0 https://github.com/mpv-player/mpv.git
cd mpv

export PKG_CONFIG_PATH=/opt/ffmpeg-v4l2/lib/pkgconfig
export LDFLAGS='-Wl,-rpath,/opt/ffmpeg-v4l2/lib'

meson setup build --prefix=/usr/local --buildtype=release \
  -Dlibmpv=false \
  -Dpipewire=disabled -Djavascript=disabled \
  -Dvaapi=disabled -Dvdpau=disabled -Dcaca=disabled \
  -Dwayland=enabled -Degl=enabled -Dgl=enabled -Ddrm=enabled \
  -Dalsa=enabled -Dpulse=enabled \
  -Dlibarchive=enabled -Duchardet=enabled \
  -Djpeg=enabled -Dlcms2=enabled -Dvulkan=enabled \
  -Dbuild-date=false

meson compile -C build -j4
sudo meson install -C build
```

关键点：

- `PKG_CONFIG_PATH` 必须指向 `/opt/ffmpeg-v4l2/lib/pkgconfig`，否则会链到系统 FFmpeg 6.1；
- `LDFLAGS` 加 rpath，运行时才能找到 `/opt/ffmpeg-v4l2/lib`。

确认：

```bash
which mpv                      # /usr/local/bin/mpv
mpv --version                  # mpv v0.41.0, FFmpeg 8066a27
mpv --hwdec=help | grep v4l2request
```

### 6.4 配置

`~/.config/mpv/mpv.conf`：

```
hwdec=v4l2request-copy
vo=gpu
gpu-context=wayland
```

为什么用 `v4l2request-copy` 而不是零拷贝：

- 两者都能用；
- 这块 Mali G52 上零拷贝 GL 导入反而 CPU 占用更高（实测 15s CPU vs 7s CPU / 6s 视频）；
- `v4l2request-copy` 稳定、画面正确。

### 6.5 验证

```bash
mpv --no-audio --msg-level=all=info test_h265.mp4 2>&1 | grep 'hardware decoding'
```

输出：

```
Using hardware decoding (v4l2request-copy).
```

实测 1080p HEVC 6 秒片源，Wayland 下约 7.7 秒播放完（含启动），实时无压力。

---

## 7. 最终安装/修改清单

| 路径 | 内容 |
|---|---|
| `/opt/ffmpeg-v4l2/bin/ffmpeg` | Kwiboo FFmpeg 8（完整构建） |
| `/opt/ffmpeg-v4l2/lib/` | FFmpeg 共享库 |
| `/etc/ld.so.conf.d/ffmpeg-v4l2.conf` | `/opt/ffmpeg-v4l2/lib` |
| `/usr/local/bin/mpv` | mpv 0.41.0 |
| `/usr/local/share/applications/mpv.desktop` | mpv 桌面项 |
| `/etc/chromium.d/rockchip-vpu` | Chromium 硬解 flags |
| `~/.config/mpv/mpv.conf` | mpv 硬解默认配置 |
| `~/vpu-check.sh` | 自检脚本 |
| 本目录 `vpu-check.sh` | 自检脚本副本 |
| 本目录 `VPU-硬解配置说明.md` | 使用/回滚简明说明 |

未修改：

- 内核、设备树、`/boot/armbianEnv.txt`；
- 没有添加 PPA；
- 没有执行 `apt dist-upgrade`。

---

## 8. 使用与回滚

### 使用

```bash
# mpv 自动硬解
mpv 视频.mp4

# FFmpeg 硬解
/opt/ffmpeg-v4l2/bin/ffmpeg -hwaccel v4l2request \
  -hwaccel_output_format drm_prime -i 视频.mp4 -f null -

# 自检
~/vpu-check.sh
```

Chromium：退出重开，打开 `chrome://gpu` 看 `Video Decode`。

### 回滚

```bash
sudo rm /etc/chromium.d/rockchip-vpu          # Chromium
rm ~/.config/mpv/mpv.conf                     # mpv 默认配置
sudo rm /usr/local/bin/mpv                    # mpv 本体
sudo rm -rf /opt/ffmpeg-v4l2                  # FFmpeg
sudo rm /etc/ld.so.conf.d/ffmpeg-v4l2.conf
sudo ldconfig
```

---

## 9. 仍然存在的限制

1. **VLC 3 不支持 V4L2 stateless**，主line上无法硬解；用 mpv 代替。
2. **VP9/AV1 未暴露**：`/dev/video1` 只有 `S264`/`S265`，`/dev/video2` 只有 `MPEG2`/`VP8`；YouTube 默认 VP9/AV1 仍会软解。可装 h264ify 强制 H.264。
3. 如果一定要 PPA 的 MPP 全功能（VLC/Chromium/mpv 全硬解），需要换厂商内核镜像（`/dev/mpp_service`）。
4. `/opt/ffmpeg-v4l2` 没有 TLS，不能直接拉 `https://`；在线视频建议用 yt-dlp 先下载。
5. GStreamer 的 1080p HEVC 拷贝缺陷仍然存在（1088 高度正常）。

---

## 10. 关键命令速查

```bash
# 设备/驱动
v4l2-ctl --list-devices
v4l2-ctl -d /dev/video1 --list-formats-out

# 检查 mpp_service 是否存在
ls -l /dev/mpp_service
grep -i mpp /proc/devices

# FFmpeg
/opt/ffmpeg-v4l2/bin/ffmpeg -hwaccels
/opt/ffmpeg-v4l2/bin/ffmpeg -hwaccel v4l2request \
  -hwaccel_output_format drm_prime -i in.mp4 -f null -

# mpv
mpv --hwdec=help | grep v4l2request
mpv --no-audio --msg-level=all=info in.mp4 2>&1 | grep 'hardware decoding'

# Chromium
cat /etc/chromium.d/rockchip-vpu
```

---

## 11. 升级 / 重装新系统后，能否照本文重配？

**可以，但要先分清是哪种“升级”。** 本文的命令和版本是针对
`Armbian 26.11 noble + kernel 6.18 + Chromium 151 + KDE Wayland` 验证的，
换环境后需要按下面的检查项调整，不能无脑整段复制。

### 11.1 三种情况

#### A. 只是 `apt upgrade` / 内核小版本更新（仍是 Armbian noble）

大概率直接继续用：

- `/opt/ffmpeg-v4l2`、`/usr/local/bin/mpv` 不会被 apt 删除；
- 重跑 `~/vpu-check.sh`，确认设备节点和硬解仍正常；
- 检查 `/dev/video*` 编号是否变化（rkvdec 目前是 `video1`，升级后不保证）；
- Chromium 若升级了大版本，`AcceleratedVideoDecoder` 之类的 feature 名可能变化，重新看 `chrome://gpu`；
- 如果新内核开始提供 `/dev/mpp_service`，那 PPA 路线才重新变得可行（用 `ls /dev/mpp_service` 判断）。

#### B. 全新安装同版本或更高版本 Armbian（`/` 被清空，`/home` 保留）

文档还在，但 `/opt` 和 `/usr/local` 里的二进制没了，需要重编：

1. 先跑 11.2 的前置检查；
2. 按第 4 节重编 FFmpeg；
3. 按第 5 节写 Chromium flags（先确认 Chromium 仍是 deb 包，见 11.3）；
4. 按第 6 节重编 mpv；
5. 跑 `~/vpu-check.sh`。

#### C. 换成厂商内核镜像（官方 Orange Pi Ubuntu / Ubuntu-Rockchip）

这时主line 的 `v4l2request` 路线不再是唯一选择：

```bash
ls -l /dev/mpp_service
```

- 如果存在，就可以按 PPA 教程走 MPP（VLC/Chromium/mpv 都可能硬解）；
- 如果不存在，仍然按本文的主线方案。

### 11.2 重配前的前置检查

```bash
uname -a
cat /etc/os-release

# 内核到底是 mainline 还是 vendor
ls -l /dev/mpp_service 2>&1
v4l2-ctl --list-devices
v4l2-ctl -d /dev/video1 --list-formats-out   # 应看到 S264/S265

# 桌面会话必须是 Wayland
echo "$XDG_SESSION_TYPE"                     # 期望 wayland

# Chromium 是否仍是 deb 包、是否编进了 V4L2 解码器
chromium --version
strings /usr/lib/chromium/chromium | grep -c V4L2VideoDecoder
```

### 11.3 需要按新系统调整的地方

| 项目 | 本文假设 | 新系统可能要改 |
|---|---|---|
| 解码设备 | rkvdec = `/dev/video1` | 编号可能变，先 `v4l2-ctl --list-devices` |
| 内核路线 | mainline，无 mpp_service | 若变 vendor 内核，可改用 PPA/MPP |
| Chromium 安装方式 | Ubuntu deb，读 `/etc/chromium.d/` | snap/flatpak 不读该目录，flags 要换写法 |
| Chromium feature 名 | `AcceleratedVideoDecoder` | 新版本可能改名，以 `chrome://gpu` 为准 |
| 桌面会话 | KDE Wayland | 若是 X11，Chromium 的 `--ozone-platform=wayland` 会导致启动失败 |
| 包名/版本 | `libplacebo-dev >= 6.338`、`meson >= 1.3`、`libdisplay-info-dev` | 新发行版包名/最低版本可能变 |
| FFmpeg 源码 | Kwiboo `v4l2-request-n8.0.1` | 新内核可能需要更新的分支；编译报 UAPI 缺失时先升级 `linux-libc-dev` |
| mpv 源码 | `v0.41.0` | 需与系统 libplacebo 版本匹配；不匹配就换 mpv 版本 |
| apt 源/代理 | 清华源，代理 `127.0.0.1:7890` | 新系统不一定有同样的源/代理，按实际改 |

### 11.4 版本锁定（便于复现）

| 组件 | 本文使用 |
|---|---|
| FFmpeg | Kwiboo 分支 `v4l2-request-n8.0.1`（commit `8066a27`） |
| mpv | `v0.41.0` |
| Chromium | `151.0.7922.71` |
| 内核 | `6.18.43-current-rockchip64` |
| 发行版 | Armbian 26.11.0-trunk.3 noble |

源码 tag 是锁定的，所以只要新系统还能装齐依赖，重编结果基本可复现。

### 11.5 不建议直接拷贝的东西

- **不要**把旧系统的 `/opt/ffmpeg-v4l2` 和 `/usr/local/bin/mpv` 直接拷到新系统：
  它们依赖新系统的 glibc / libplacebo / Mesa ABI，版本不匹配会直接报错。重新编译更稳。
- **要**备份本文所在目录（`~/nodejs/orangepi`），尤其是 `VPU硬解配置记录.md`、
  `VPU-硬解配置说明.md`、`vpu-check.sh`。如果重装只保留 `/home`，这三个文件会跟着保留。

### 11.6 最省事的复用顺序

```bash
# 1. 先看缺什么
~/nodejs/orangepi/vpu-check.sh

# 2. 如果只是设备编号变了，改脚本/命令里的 /dev/videoN
# 3. 如果 FFmpeg/mpv 不在了，按第 4、6 节重编
# 4. 如果 Chromium 不硬解，先看 chrome://gpu，再按第 5 节调整 flags
```
