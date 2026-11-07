# Orange Pi 3B USB 虚拟键盘（HID Gadget）

> 状态：已在 Orange Pi 3B v1.1 + Armbian 6.18.43 上实测通过。
> 注意：**必须先接好 USB 线再开机**，原因见文末“故障排查”第 5 条。

把板上 **USB1 叠层接口中上面的那个 USB2.0 口**（下面紧挨着蓝色 USB3.0 口）
从 Host 模式切换成 Device 模式，枚举成一个标准 USB HID 键盘。板子通过
`/dev/hidg0` 向主机发送按键。

## 硬件确认

- 开发板：Orange Pi 3B v1.1（RK3566）
- 内核：6.18.43-current-rockchip64
- 内核已支持 gadget：
  - `CONFIG_USB_DWC3=y`
  - `CONFIG_USB_DWC3_DUAL_ROLE=y`
  - `CONFIG_USB_GADGET=y`
  - `CONFIG_USB_LIBCOMPOSITE=m`
  - `CONFIG_USB_CONFIGFS=m`
  - `CONFIG_USB_F_HID=m`
- 当前 `/sys/class/udc` 为空，因为设备树把 OTG0 固定成了 Host：
  - `/usb@fcc00000`（`usb_host0_xhci`）`dr_mode = "host"`
- 原理图确认：
  - USB1 是叠层接口，上面是 USB2.0 OTG（`USB_OTG0_DP/DM`），下面是 USB3.0 Host。
  - OTG 口的 5V 由 U6 负载开关控制，使能脚是 `USB_OTG_PWREN_H`（GPIO0_A5）。
  - Type-C 只做供电（数据脚未接），所以不要动 Type-C 部分。

## 改动内容

只做两件事：

1. `/usb@fcc00000` 的 `dr_mode` 从 `host` 改成 `peripheral`。
2. 把 `usb2phy0_otg` 的 `phy-supply` 从 `vcc5v0_usb_otg` 改成常开的
   `vcc5v0_sys`。这样 `vcc5v0_usb_otg` 没有消费者，U6 保持关闭，Device
   模式下板子不会向电脑反灌 5V；电脑的 5V 仍能通过 VBUS 检测分压电阻被
   PHY 检测到。

改动以 **overlay** 形式放在 `/boot/overlay-user/usb-otg-gadget.dtbo`，
不覆盖原始 `.dtb`。如果 overlay 应用失败，Armbian 的启动脚本会自动恢复
原始设备树再启动。

## 安装

```bash
sudo bash usbkbd-config/install.sh
sudo reboot
```

安装脚本会：

- 备份 `/boot/armbianEnv.txt`；
- 安装 overlay 到 `/boot/overlay-user/`；
- 在 `/boot/armbianEnv.txt` 里加 `user_overlays=usb-otg-gadget`；
- 安装 gadget 启动脚本、systemd 服务、udev 规则和 `vkbd` 工具。

## 重启后验证

```bash
ls /sys/class/udc
# 期望看到 fcc00000.usb

systemctl status usb-gadget-kbd --no-pager
ls -l /dev/hidg0
# 期望 crw-rw---- root input ... /dev/hidg0
```

用一根**品质良好的 USB2.0 A 公对公数据线**（必须有数据线芯，不能是纯充电线）
连接板子的 OTG 口和电脑。板子仍然用 Type-C 正常供电。

> **重要：先插线，再开机。**
>
> mainline 6.18 的 RK3566 inno-usb2 PHY 有一个已知问题：如果开机时
> OTG 口没有 VBUS，PHY 状态机会把 PHY 关掉，DWC3 gadget 初始化 ep0
> 失败并报 `failed to enable ep0out`，之后端口不可恢复，热插拔也不会枚举。
> 因此请**先把 A 公对公线接到电脑，再重启板子**。详见下面的故障排查。

然后在板子上：

```bash
vkbd type "hello world"
vkbd key enter
vkbd combo ctrl alt t
```

先把电脑上的文本编辑器点焦点，再执行。

## 安全说明

- 只改 USB OTG0，USB3.0 口和另外两个 USB2.0 口仍是 Host，不受影响。
- Device 模式下 OTG 口不能再接 U 盘/鼠标键盘。
- 已关闭 OTG 口的 5V 输出，避免和电脑的 5V 冲突。
- Type-C 供电部分完全没有改动；测试时请保持 Type-C 供电接着。
- A 公对公线只用于 USB2.0 数据，不要用 USB3.0 公对公线。
- 如果启动失败：U-Boot 会因 overlay 失败自动恢复原设备树。也可以把 SD 卡
  接到别的机器，恢复 `/boot/armbianEnv.txt.bak-vkbd-*`，或删掉
  `user_overlays` 行和 `/boot/overlay-user/usb-otg-gadget.dtbo`。

## 回滚

```bash
sudo bash usbkbd-config/rollback.sh
sudo reboot
```

回滚后 OTG 口恢复 Host 模式，可以继续接 U 盘等外设。

## 常用命令

```bash
# 输入文本（US 键盘布局）
vkbd type "https://example.com"

# 单个按键
vkbd key enter
vkbd key tab
vkbd key esc
vkbd key backspace
vkbd key up

# 组合键
vkbd combo ctrl alt t
vkbd combo ctrl shift esc

# 按住/松开（例如按住 Ctrl 再点别的）
vkbd down ctrl
vkbd key esc
vkbd up
```

## SSH 键盘转发模式

在 SSH 窗口执行：

```bash
# 已执行过 install.sh：
vkbd-forward

# 或者直接从仓库运行：
./usbkbd-config/vkbd-forward.sh
```

普通字符、回车、Tab、退格、方向键、Home/End、PageUp/PageDown、
Insert/Delete、F1-F12、Shift+Tab、带修饰键的方向键/Home/End/Delete
以及 Alt+字母会直接转发。按 `Ctrl-J` 退出，程序会自动恢复 SSH 终端设置。

### 被本地终端/系统拦截的键

有些键在到达 SSH 之前就被本地 Windows 终端或系统吃掉了，例如：

- Windows Terminal 默认把 `Ctrl+V` 当粘贴、`Ctrl+C` 当复制；
- `Alt+Tab`、`Win`、`Ctrl+Alt+Del` 由 Windows 系统处理；
- `Ctrl+Shift+C/V`、`Ctrl+Tab` 等终端快捷键。

这些键**无法通过直接转发拿到**。用 `Ctrl-]` 命令前缀发送：

| 按键 | 发送到目标 Windows |
| --- | --- |
| `Ctrl-] v` | `Ctrl+V`（粘贴） |
| `Ctrl-] c` | `Ctrl+C`（复制） |
| `Ctrl-] x` | `Ctrl+X`（剪切） |
| `Ctrl-] z` | `Ctrl+Z`（撤销） |
| `Ctrl-] a` | `Ctrl+A`（全选） |
| `Ctrl-] t` | `Alt+Tab` |
| `Ctrl-] w` | `Win` |
| `Ctrl-] s` | `Shift+Insert`（多数 Windows 程序可粘贴） |
| `Ctrl-] d` | `Ctrl+Alt+Delete` |
| `Ctrl-] :` | 进入命令行 |
| `Ctrl-] ?` | 帮助 |
| `Ctrl-] q` | 退出 |

命令行示例：

```text
paste
copy
alt-tab
win
ctrl-shift-v
shift-insert
key enter
key up
key f5
combo ctrl alt t
type hello world
down ctrl
up
```

### 本地终端建议

- **PuTTY / mintty / Alacritty**：`Ctrl+V`、`Ctrl+C` 通常可以直接发到远端，
  比 Windows Terminal 更适合这种转发。
- **Windows Terminal**：可以在 `settings.json` 里取消绑定本地快捷键，
  让按键透传给终端：
  ```json
  "keybindings": [
    { "keys": "ctrl+v", "action": "unbound" },
    { "keys": "ctrl+c", "action": "unbound" },
    { "keys": "ctrl+shift+v", "action": "unbound" },
    { "keys": "ctrl+shift+c", "action": "unbound" }
  ]
  ```
  `Alt+Tab`、`Win`、`Ctrl+Alt+Del` 仍然由系统处理，只能用 `Ctrl-]` 前缀。

### 实现说明

旧版脚本直接用 bash 的 `read` 从 tty 读字节。bash 的 `read` 在等待输入时
会按 shell 启动时的终端设置重设 termios，把 `stty` 设置的 raw 模式覆盖掉，
导致 `Ctrl+C`、`Ctrl+V`、`Ctrl+\` 等被 pty 自己吞掉。

现在改为：

```text
tty (fd 3) -> dd bs=1 -> pipe -> read
```

所有 `read` 都从管道读取，不再修改 tty；`stty` 只通过 fd 3 操作真实终端。
另外修复了：

- `trap restore EXIT` 被子 shell 继承，导致运行中恢复 cooked 模式；
- Shift+Tab、带修饰键的方向键/Home/End/Delete、F1-F4 的 SS3 序列；
- Alt+字母会误吞后续按键；
- `vkbd key win` 把修饰键放进 keycode 数组的问题。

### 环境变量

- `VKBD_CMD`：`vkbd` 路径
- `VKBD_PREFIX`：命令前缀，默认 `Ctrl-]`（0x1d）
- `VKBD_EXIT`：退出键，默认 `Ctrl-J`（0x0a）
- `VKBD_DEBUG=1`：显示 `vkbd` 错误

### 更高保真的方案

如果不想用前缀，想要接近物理键盘的体验，需要绕过本地终端：

1. **本地低层键盘钩子 + 网络到板子**（保真度最高）
   - Windows 端用 `WH_KEYBOARD_LL` 捕获并屏蔽按键，通过 TCP/WebSocket
     发给板子；
   - 可以捕获 `Alt+Tab`、`Win`、`Ctrl+V` 等；`Ctrl+Alt+Del` 是 SAS，
     用户态钩子通常拿不到，仍可用命令前缀发送。
2. **浏览器 Keyboard Lock + WebSocket**（无需安装软件）
   - 板子跑一个 WebSocket 服务，浏览器全屏后调用
     `navigator.keyboard.lock()` 捕获按键；
   - 可捕获大部分终端会拦截的键，但 `Alt+Tab`、`Win` 等系统键
     是否可捕获取决于浏览器/Windows 版本。

需要的话可以在当前 `vkbd-forward.sh` 基础上继续做这两种方案。

## 故障排查

1. `ls /sys/class/udc` 为空：
   - overlay 没生效。检查 `cat /boot/armbianEnv.txt` 是否有
     `user_overlays=usb-otg-gadget`；
   - 检查 `/boot/overlay-user/usb-otg-gadget.dtbo` 是否存在；
   - 看启动日志：`dmesg | grep -iE 'dwc3|gadget|overlay'`。
2. `systemctl status usb-gadget-kbd` 失败：
   - 先确认 UDC 存在，再 `sudo systemctl restart usb-gadget-kbd`。
3. 电脑没识别：
   - 换一根确认带数据线的 A 公对公线；
   - 确认插的是 USB1 叠层中**上面**的 USB2.0 口，不是下面蓝色 USB3.0 口；
   - 电脑上 `dmesg` / 设备管理器看是否有新的 HID 键盘。
4. 权限不足：
   - `ls -l /dev/hidg0`，应为 `root input`、`0660`；
   - `groups` 确认当前用户在 `input` 组。
5. 内核日志出现 `dwc3 fcc00000.usb: failed to enable ep0out`：
   - 这是 mainline RK3566 inno-usb2 PHY 的已知问题：开机时 OTG 口没有
     VBUS，PHY 被状态机关掉，gadget 初始化 ep0 失败，之后端口不可恢复；
   - 规避：**先把 A 公对公线接到电脑，再重启板子**；
   - 重启后确认 `cat /sys/class/udc/fcc00000.usb/state` 不是
     `not attached`，且日志里不再出现该错误；
   - 永久修复需要给内核打
     `phy: rockchip: inno-usb2: keep peripheral-only OTG port active`
     补丁并重新编译内核，或等 Armbian 后续内核包含该修复。
