#!/usr/bin/env bash
# Forward an interactive SSH terminal to the USB HID keyboard.
#
# Direct keys are forwarded as typed. Keys that the local terminal/OS
# intercepts (Ctrl+V, Ctrl+Shift+V, Alt+Tab, Win, ...) never reach this
# script as keystrokes, so they are sent through the Ctrl-] prefix instead:
#
#   Ctrl-] v      Ctrl+V (paste)
#   Ctrl-] c      Ctrl+C (copy)
#   Ctrl-] x      Ctrl+X (cut)
#   Ctrl-] z      Ctrl+Z (undo)
#   Ctrl-] a      Ctrl+A (select all)
#   Ctrl-] t      Alt+Tab
#   Ctrl-] w      Win key
#   Ctrl-] s      Shift+Insert (paste in many Windows apps)
#   Ctrl-] d      Ctrl+Alt+Delete
#   Ctrl-] :      command line (key/combo/type/down/up/...)
#   Ctrl-] ?      help
#   Ctrl-] q      quit
#
# Ctrl-J exits the forwarder. Ctrl-J can still be sent to the target with
#   Ctrl-] :  combo ctrl j
#
# Environment:
#   VKBD_CMD        path to the vkbd helper
#   VKBD_PREFIX     command prefix, default Ctrl-] (0x1d)
#   VKBD_EXIT       exit key, default Ctrl-J (0x0a)
#   VKBD_DEBUG=1    show vkbd errors
set -u
export LC_ALL=C

VKBD_CMD=${VKBD_CMD:-/usr/local/bin/vkbd}
if [[ ! -x "$VKBD_CMD" ]]; then
    VKBD_CMD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vkbd"
fi

CMD_PREFIX=${VKBD_PREFIX:-$'\x1d'}   # Ctrl-]
EXIT_KEY=${VKBD_EXIT:-$'\x0a'}       # Ctrl-J

# Keep the real tty on fd 3. The main loop reads bytes from a pipe fed by
# `dd`, because bash's `read` builtin resets the terminal to the shell's
# startup settings while it waits, which would undo raw mode.
exec 3<&0
old_stty=$(stty -g <&3) || exit 1
restored=0
restore() {
    # The dd coproc and any command substitution inherit the EXIT trap.
    if [[ "${BASHPID:-$$}" != "$$" ]]; then
        return 0
    fi
    (( restored )) && return 0
    restored=1
    if [[ -n "${RAW_PID:-}" ]]; then
        kill "$RAW_PID" 2>/dev/null || true
        wait "$RAW_PID" 2>/dev/null || true
    fi
    stty "$old_stty" <&3 2>/dev/null || true
    printf '\n键盘转发已退出。\n' >&2
}
trap restore EXIT
trap 'restore; exit 130' INT TERM HUP

raw_mode() {
    stty -icanon -echo -isig -icrnl -inlcr -igncr -istrip \
         -ixon -ixoff -ixany -brkint -inpck -imaxbel -iexten \
         min 1 time 0 <&3 2>/dev/null || true
}

send() {
    if [[ "${VKBD_DEBUG:-0}" == 1 ]]; then
        "$VKBD_CMD" "$@"
    else
        "$VKBD_CMD" "$@" >/dev/null 2>&1
    fi
}

cmd_help() {
    cat >&2 <<'EOF'
命令模式（先按 Ctrl-]）：
  v  Ctrl+V        c  Ctrl+C        x  Ctrl+X        z  Ctrl+Z
  a  Ctrl+A        t  Alt+Tab       w  Win           s  Shift+Insert
  d  Ctrl+Alt+Delete
  :  命令行        ?  帮助          q  退出

命令行示例：
  paste | copy | cut | undo | selectall
  alt-tab | win | ctrl-v | ctrl-shift-v | shift-insert
  key enter | key up | key f5
  combo ctrl alt t
  type hello world
  down ctrl  /  up
EOF
}

send_byte() {
    local c=$1 code letter oct
    case "$c" in
        $'\r')           send key enter ;;
        $'\t')           send key tab ;;
        $'\x08'|$'\x7f') send key backspace ;;
        $'\x00')         send combo ctrl space ;;
        $'\x1c')         send combo ctrl backslash ;;
        $'\x1e')         send combo ctrl shift 6 ;;
        $'\x1f')         send combo ctrl shift minus ;;
        *)
            printf -v code '%d' "'${c}"
            if (( code >= 1 && code <= 26 )); then
                printf -v oct '%03o' $((code + 96))
                printf -v letter '%b' "\\$oct"
                send combo ctrl "$letter"
            elif [[ "$c" == [[:print:]] ]]; then
                send type "$c"
            fi
            ;;
    esac
}

send_key_with_mods() {
    local name=$1 mod=${2:-1}
    local -a mods=()
    case "$mod" in
        2) mods=(shift) ;;
        3) mods=(alt) ;;
        4) mods=(shift alt) ;;
        5) mods=(ctrl) ;;
        6) mods=(shift ctrl) ;;
        7) mods=(alt ctrl) ;;
        8) mods=(shift alt ctrl) ;;
    esac
    if ((${#mods[@]})); then
        send combo "${mods[@]}" "$name"
    else
        send key "$name"
    fi
}

send_ascii_with_mods() {
    local code=$1 mod=${2:-1}
    local -a mods=()
    local c oct
    case "$mod" in
        2) mods=(shift) ;;
        3) mods=(alt) ;;
        4) mods=(shift alt) ;;
        5) mods=(ctrl) ;;
        6) mods=(shift ctrl) ;;
        7) mods=(alt ctrl) ;;
        8) mods=(shift alt ctrl) ;;
    esac

    case "$code" in
        0)  send combo ctrl space; return ;;
        8|127)
            if ((${#mods[@]})); then send combo "${mods[@]}" backspace
            else send key backspace; fi
            return
            ;;
        9)
            if ((${#mods[@]})); then send combo "${mods[@]}" tab
            else send key tab; fi
            return
            ;;
        13)
            if ((${#mods[@]})); then send combo "${mods[@]}" enter
            else send key enter; fi
            return
            ;;
        27)
            if ((${#mods[@]})); then send combo "${mods[@]}" esc
            else send key esc; fi
            return
            ;;
        32)
            if ((${#mods[@]})); then send combo "${mods[@]}" space
            else send key space; fi
            return
            ;;
    esac

    if (( code >= 1 && code <= 26 )); then
        printf -v oct '%03o' $((code + 96))
        printf -v c '%b' "\\$oct"
        if ((${#mods[@]})); then
            send combo "${mods[@]}" ctrl "$c"
        else
            send combo ctrl "$c"
        fi
        return
    fi

    if (( code >= 33 && code <= 126 )); then
        printf -v oct '%03o' "$code"
        printf -v c '%b' "\\$oct"
        if ((${#mods[@]})); then
            send combo "${mods[@]}" "$c"
        else
            send type "$c"
        fi
    fi
}

read_escape() {
    local next i
    ESCAPE_SEQ=''
    # Never wait indefinitely; SSH latency usually delivers a sequence intact.
    IFS= read -r -s -N 1 -t 0.08 next || return 0

    # Alt+key: ESC followed by a single non-CSI/SS3 byte. Return immediately
    # so the next typed key is not swallowed.
    if [[ "$next" != '[' && "$next" != 'O' ]]; then
        ESCAPE_SEQ=$next
        return 0
    fi

    ESCAPE_SEQ=$next

    # SS3: ESC O <one byte>, e.g. F1-F4 and application cursor keys.
    if [[ "$ESCAPE_SEQ" == 'O' ]]; then
        IFS= read -r -s -N 1 -t 0.08 next && ESCAPE_SEQ+="$next"
        return 0
    fi

    # CSI: read until a final byte.
    for ((i = 0; i < 16; i++)); do
        IFS= read -r -s -N 1 -t 0.08 next || break
        ESCAPE_SEQ+="$next"
        case "$ESCAPE_SEQ" in
            *'~'|*[ABCDHFZ]|*'u') break ;;
        esac
    done
}

command_line() {
    printf 'vkbd> ' >&2
    local line='' ch
    while IFS= read -r -s -N 1 ch; do
        case "$ch" in
            $'\r'|$'\n')
                printf '\n' >&2
                break
                ;;
            $'\x7f'|$'\x08')
                if [[ -n "$line" ]]; then
                    line=${line%?}
                    printf '\b \b' >&2
                fi
                ;;
            $'\x03')
                printf '^C\n' >&2
                return
                ;;
            $'\x04')
                printf '\n' >&2
                return
                ;;
            $'\x1b')
                read_escape
                ;;
            *)
                if [[ "$ch" == [[:print:]] ]]; then
                    line+="$ch"
                    printf '%s' "$ch" >&2
                fi
                ;;
        esac
    done

    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && return

    case "$line" in
        help|\?) cmd_help ;;
        exit|quit|q) exit 0 ;;
        paste|ctrl-v|ctrl+v) send combo ctrl v ;;
        copy|ctrl-c|ctrl+c) send combo ctrl c ;;
        cut|ctrl-x|ctrl+x) send combo ctrl x ;;
        undo|ctrl-z|ctrl+z) send combo ctrl z ;;
        redo|ctrl-y|ctrl+y) send combo ctrl y ;;
        selectall|select-all|ctrl-a|ctrl+a) send combo ctrl a ;;
        alt-tab|alt+tab) send combo alt tab ;;
        win|start) send key win ;;
        shift-insert|shift+insert) send combo shift insert ;;
        ctrl-shift-v|ctrl+shift+v) send combo ctrl shift v ;;
        ctrl-alt-del|ctrl+alt+del) send combo ctrl alt delete ;;
        type\ *) send type "${line#type }" ;;
        key\ *) send key "${line#key }" ;;
        combo\ *) send combo ${line#combo } ;;
        down\ *) send down "${line#down }" ;;
        up) send up ;;
        *) printf 'vkbd: 未知命令: %s（输入 ? 查看帮助）\n' "$line" >&2 ;;
    esac
}

command_mode() {
    local key
    # Single key, no echo. Esc/Enter cancels.
    IFS= read -r -s -N 1 key || return
    case "$key" in
        v|V) printf '[Ctrl+V]\n' >&2; send combo ctrl v ;;
        c|C) printf '[Ctrl+C]\n' >&2; send combo ctrl c ;;
        x|X) printf '[Ctrl+X]\n' >&2; send combo ctrl x ;;
        z|Z) printf '[Ctrl+Z]\n' >&2; send combo ctrl z ;;
        a|A) printf '[Ctrl+A]\n' >&2; send combo ctrl a ;;
        t|T) printf '[Alt+Tab]\n' >&2; send combo alt tab ;;
        w|W) printf '[Win]\n' >&2; send key win ;;
        s|S) printf '[Shift+Insert]\n' >&2; send combo shift insert ;;
        d|D) printf '[Ctrl+Alt+Delete]\n' >&2; send combo ctrl alt delete ;;
        ':') command_line ;;
        '?'|h|H) cmd_help ;;
        q|Q) exit 0 ;;
        $'\x1b'|$'\r'|$'\x1d'|'') : ;;
        *) printf '[vkbd: 未绑定 Ctrl-] %s]\n' "$key" >&2 ;;
    esac
}

raw_mode

# Pump raw bytes from the tty (fd 3) into a pipe. `read` on a pipe does not
# touch the terminal settings, unlike `read` on a tty.
coproc RAW_INPUT { exec dd bs=1 <&3 2>/dev/null; }
RAW_PID=$RAW_INPUT_PID
exec <&"${RAW_INPUT[0]}"

printf '键盘转发已启动。\n' >&2
printf '  Ctrl-J 退出；Ctrl-] 命令前缀（Ctrl-] ? 查看帮助）。\n' >&2

while IFS= read -r -s -N 1 key; do
    if [[ "$key" == "$EXIT_KEY" ]]; then
        break
    fi

    if [[ "$key" == "$CMD_PREFIX" ]]; then
        command_mode
        continue
    fi

    if [[ "$key" == $'\x1b' ]]; then
        read_escape
        sequence=$ESCAPE_SEQ
        case "$sequence" in
            '')                     send key esc ;;
            '[A'|'OA')              send key up ;;
            '[B'|'OB')              send key down ;;
            '[C'|'OC')              send key right ;;
            '[D'|'OD')              send key left ;;
            '[H'|'OH'|'[1~'|'[7~') send key home ;;
            '[F'|'OF'|'[4~'|'[8~') send key end ;;
            '[Z')                   send combo shift tab ;;
            '[2~')                  send key insert ;;
            '[3~')                  send key delete ;;
            '[5~')                  send key pageup ;;
            '[6~')                  send key pagedown ;;
            '[11~'|'OP')            send key f1 ;;
            '[12~'|'OQ')            send key f2 ;;
            '[13~'|'OR')            send key f3 ;;
            '[14~'|'OS')            send key f4 ;;
            '[15~')                 send key f5 ;;
            '[17~')                 send key f6 ;;
            '[18~')                 send key f7 ;;
            '[19~')                 send key f8 ;;
            '[20~')                 send key f9 ;;
            '[21~')                 send key f10 ;;
            '[23~')                 send key f11 ;;
            '[24~')                 send key f12 ;;

            # xterm modifyOtherKeys: ESC [ 27 ; mod ; code ~
            '[27;'*';'*'~')
                body=${sequence#\[27;}
                mod=${body%%;*}
                code=${body#*;}
                code=${code%%~*}
                send_ascii_with_mods "$code" "$mod"
                ;;

            # CSI-u / kitty keyboard protocol: ESC [ code ; mod u
            '['*';'*'u')
                body=${sequence#\[}
                code=${body%%;*}
                mod=${body#*;}
                mod=${mod%u}
                send_ascii_with_mods "$code" "$mod"
                ;;

            # Modified arrows / Home / End: ESC [ 1 ; mod <final>
            '[1;'*[ABCDHF])
                mod=${sequence:3}
                mod=${mod%?}
                case "${sequence: -1}" in
                    A) send_key_with_mods up "$mod" ;;
                    B) send_key_with_mods down "$mod" ;;
                    C) send_key_with_mods right "$mod" ;;
                    D) send_key_with_mods left "$mod" ;;
                    H) send_key_with_mods home "$mod" ;;
                    F) send_key_with_mods end "$mod" ;;
                esac
                ;;

            # Modified special keys: ESC [ number ; mod ~
            '['*';'*'~')
                body=${sequence#\[}
                num=${body%%;*}
                rest=${body#*;}
                mod=${rest%%~*}
                case "$num" in
                    2)  send_key_with_mods insert "$mod" ;;
                    3)  send_key_with_mods delete "$mod" ;;
                    5)  send_key_with_mods pageup "$mod" ;;
                    6)  send_key_with_mods pagedown "$mod" ;;
                    1|7) send_key_with_mods home "$mod" ;;
                    4|8) send_key_with_mods end "$mod" ;;
                    11) send_key_with_mods f1 "$mod" ;;
                    12) send_key_with_mods f2 "$mod" ;;
                    13) send_key_with_mods f3 "$mod" ;;
                    14) send_key_with_mods f4 "$mod" ;;
                    15) send_key_with_mods f5 "$mod" ;;
                    17) send_key_with_mods f6 "$mod" ;;
                    18) send_key_with_mods f7 "$mod" ;;
                    19) send_key_with_mods f8 "$mod" ;;
                    20) send_key_with_mods f9 "$mod" ;;
                    21) send_key_with_mods f10 "$mod" ;;
                    23) send_key_with_mods f11 "$mod" ;;
                    24) send_key_with_mods f12 "$mod" ;;
                esac
                ;;

            # Alt+special keys that do not start with CSI.
            $'\t')  send combo alt tab ;;
            $'\r')  send combo alt enter ;;
            $'\x7f'|$'\x08') send combo alt backspace ;;

            *)
                # Alt+printable key.
                if [[ "$sequence" != \[* && "$sequence" != O* &&
                      "$sequence" == [[:print:]] ]]; then
                    send combo alt "$sequence"
                fi
                ;;
        esac
    else
        send_byte "$key"
    fi
done
