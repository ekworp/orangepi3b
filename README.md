# Orange Pi 3B (RK3566) VPU 硬解配置

本仓库记录在 **Armbian / 主line内核** 上为 Orange Pi 3B（RK3566）启用硬件视频解码的完整过程、验证数据和自检脚本。

> 这是一份配置记录，不是一键安装器。换系统/换内核后请先看
> [升级与重配](VPU硬解配置记录.md#11-升级--重装新系统后能否照本文重配)。

## 环境

| 项目 | 版本 |
|---|---|
| 板子 | Xunlong Orange Pi 3B v1.1（RK3566） |
| 系统 | Armbian 26.11.0-trunk.3 noble |
| 内核 | `6.18.43-current-rockchip64`（mainline） |
| 桌面 | KDE Plasma Wayland |
| Chromium | 151.0.7922.71 |
| mpv | 0.41.0 |
| FFmpeg | Kwiboo `v4l2-request-n8.0.1` |

## 结论速览

| 项目 | 状态 |
|---|---|
| 内核 VPU 驱动 | ✅ rkvdec（H.264/HEVC）、hantro（VP8/MPEG-2） |
| FFmpeg 硬解 | ✅ 1080p HEVC 约 243 fps |
| mpv 硬解 | ✅ `hwdec=v4l2request-copy`，1080p 实时 |
| Chromium 硬解 | ✅ `V4L2VideoDecoder`，需 Wayland |
| GStreamer | ⚠️ 可用，但 1080p HEVC 有 1088→1080 拷贝缺陷 |
| VLC | ❌ VLC 3 不支持 V4L2 stateless |
| VP9 / AV1 | ❌ 主line rkvdec/hantro 未暴露 |

## 为什么不用 PPA

网上常见的方案是：

```bash
sudo add-apt-repository ppa:liujianfeng1994/rockchip-multimedia
sudo apt dist-upgrade
sudo apt install rockchip-multimedia-config
```

这个 PPA **有 noble 版本，也不包含内核包**，但它依赖厂商内核的 `/dev/mpp_service`。
Armbian 主line内核没有这个设备/驱动，所以装上也硬解不了。本仓库采用 **V4L2 stateless（Request API）** 路线：

| 设备 | 驱动 | 能力 |
|---|---|---|
| `/dev/video1` | rkvdec | H.264 (`S264`)、HEVC (`S265`) |
| `/dev/video2` | hantro | VP8、MPEG-2 |
| `/dev/video3` | hantro | H.264/H.265 编码 |

详细证据见 [配置记录第 2 节](VPU硬解配置记录.md#2-核查-ppa重点)。

## 快速使用

```bash
# 自检：设备、FFmpeg、mpv、Chromium
~/nodejs/orangepi/vpu-check.sh

# mpv（自动硬解）
mpv 视频.mp4

# FFmpeg 硬件解码
/opt/ffmpeg-v4l2/bin/ffmpeg -hwaccel v4l2request \
  -hwaccel_output_format drm_prime -i 视频.mp4 -f null -
```

Chromium 打开 `chrome://gpu`，Video Decode 应显示 `Hardware accelerated`；
`chrome://media-internals` 里应看到 `V4L2VideoDecoder`。

## 文件说明

| 文件 | 内容 |
|---|---|
| `VPU硬解配置记录.md` | 完整配置过程：环境确认、PPA 核查、GStreamer 实测、FFmpeg/mpv 编译、Chromium flags、升级指引 |
| `VPU-硬解配置说明.md` | 简明使用与回滚说明 |
| `vpu-check.sh` | 一键自检脚本 |
| `OrangePi_3B_RK3566_用户手册_v1.9.pdf` | 官方用户手册（版权归深圳市迅龙软件有限公司，仅作资料存档） |

## 已知限制

- **VLC 3** 不支持 V4L2 stateless，主line 上无法硬解；用 mpv 代替。
- **VP9/AV1** 当前内核未暴露，YouTube 默认 VP9/AV1 仍会软解；可装 h264ify 强制 H.264。
- **GStreamer** 的 1080p HEVC 只有约 4.5 fps（1088→1080 软件拷贝问题），本地播放建议用 mpv/FFmpeg。
- `/opt/ffmpeg-v4l2` 没有 TLS，不能直接拉 `https://`；在线视频建议用 yt-dlp。
- 想要 PPA/MPP 的完整硬解生态，需要换带厂商内核（有 `/dev/mpp_service`）的系统镜像。

## 参考

- [Kwiboo FFmpeg（v4l2-request）](https://github.com/Kwiboo/FFmpeg)
- [mpv](https://github.com/mpv-player/mpv)
- [Linux V4L2 stateless codec API](https://www.kernel.org/doc/html/latest/userspace-api/media/v4l/dev-stateless-decoder.html)

## License

本仓库的文档与脚本可自由参考、修改。`OrangePi_3B_RK3566_用户手册_v1.9.pdf` 版权归深圳市迅龙软件有限公司所有，不在本仓库许可范围内。
