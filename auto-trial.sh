#!/usr/bin/env bash
# auto-trial.sh — Trình khởi chạy công cụ dùng thử Google AI Ultra
# 博客：https://blog.caowo.de/
# 发卡网：https://faka.cdkey.si/
#
# Ví dụ trong tài liệu gốc
#   ./auto-trial.sh --list                        # liệt kê ưu đãi dùng thử
#   ./auto-trial.sh --product 20x --dur 12mo      # Ultra 20x, dùng thử 12 tháng
#   ./auto-trial.sh --product 5x --dur 6mo        # Ultra 5x, dùng thử 6 tháng
#   ./auto-trial.sh --product pro --dur 3mo        # Pro 5TB, dùng thử 3 tháng
#   ./auto-trial.sh --product pro12 --dur 12mo     # Pro 5TB variant, dùng thử 12 tháng
#   ./auto-trial.sh --product 20x                  # Ultra 20x, thời hạn dài nhất hiện có
#   ./auto-trial.sh --port 16416 --list            # chỉ định cổng ADB của MuMu
#
# Gói: pro = g1.play.2tb.ai ($19.99), pro12 = g1.2tb.ai.subs_variant ($19.99, dùng thử tối đa 12 tháng),
#           5x = g1.play.20tb ($99.99), 20x = g1.play.ai.pro ($199.99), auto = tự chọn
# Thời hạn hỗ trợ gồm 1mo, 3mo, 6mo, 12mo và longest (mặc định).
#
# Người dùng phải tự xác nhận trong hộp thoại thanh toán.
#
# Yêu cầu ADB, Frida CLI, frida-server và module.apk trên thiết bị.

set -euo pipefail

# ===== Đường dẫn =====
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FRIDA_SCRIPT="${FRIDA_SCRIPT:-$SCRIPT_DIR/frida-auto-trial.js}"
FRIDA_DEVICE_PORT=27042
FRIDA_LOCAL_PORT=27043
GOOGLE_ONE_PKG="com.google.android.apps.subscriptions.red"

# Đường dẫn trên thiết bị, có thể cấu hình qua biến môi trường
MODULE_APK_DEVICE="${MODULE_APK_DEVICE:-/data/local/tmp/module.apk}"
FRIDA_SERVER_PATH="${FRIDA_SERVER_PATH:-/data/local/tmp/frida-server}"

# ===== Giá trị mặc định =====
MODE="activate"
TARGET="auto"
DURATION="longest"
DEVICE_PORT=""

# ===== Tự tìm ADB =====
find_adb() {
# 1. Đường dẫn được chỉ định qua biến môi trường
    if [[ -n "${ADB_PATH:-}" ]] && [[ -x "$ADB_PATH" ]]; then
        echo "$ADB_PATH"; return
    fi
# 2. Tìm trong PATH
    if command -v adb >/dev/null 2>&1; then
        command -v adb; return
    fi
# 3. Kiểm tra trực tiếp các vị trí ADB thường gặp
# Kiểm tra quyền thực thi trên từng đường dẫn đầy đủ.
    local candidates=(
# MuMu với gói ứng dụng lồng nhau
        "/Applications/MuMuPlayer.app/Contents/MacOS/MuMuEmulator.app/Contents/MacOS/tools/adb"
        "$HOME/Applications/MuMuPlayer.app/Contents/MacOS/MuMuEmulator.app/Contents/MacOS/tools/adb"
        "/Applications/MuMuPlayer.app/Contents/MacOS/MuMuEmulator.app/Contents/MacOS/tools/adb"
# MuMu có thư mục công cụ trực tiếp trong gói ứng dụng
        "/Applications/MuMuPlayer.app/Contents/MacOS/tools/adb"
        "$HOME/Applications/MuMuPlayer.app/Contents/MacOS/tools/adb"
        "/Applications/MuMuPlayer.app/Contents/MacOS/tools/adb"
# MuMu Pro và các tên ứng dụng khác
        "/Applications/MuMuPlayerPro.app/Contents/MacOS/MuMuEmulator.app/Contents/MacOS/tools/adb"
        "/Applications/MuMu Player.app/Contents/MacOS/MuMuEmulator.app/Contents/MacOS/tools/adb"
        "/Applications/MuMuPlayerPro.app/Contents/MacOS/tools/adb"
        "/Applications/MuMu Player.app/Contents/MacOS/tools/adb"
        # Bộ công cụ Android SDK
        "$HOME/Library/Android/sdk/platform-tools/adb"
        "/usr/local/share/android-sdk/platform-tools/adb"
        "$HOME/Android/Sdk/platform-tools/adb"
        "${LOCALAPPDATA:-_}/Android/Sdk/platform-tools/adb.exe"
        "${PROGRAMFILES:-_}/Android/android-sdk/platform-tools/adb.exe"
    )
    for c in "${candidates[@]}"; do
        [[ -x "$c" ]] && { echo "$c"; return; }
    done
    return 1
}
ADB="$(find_adb)" || { echo "[-] adb not found. Install Android SDK or set ADB_PATH"; exit 1; }

# ===== Đọc tham số =====
while [[ $# -gt 0 ]]; do
    case "$1" in
        --list)        MODE="list"; shift ;;
        --product)     TARGET="$2"; shift 2 ;;
        --dur|--duration) DURATION="$2"; shift 2 ;;
        --port)        DEVICE_PORT="$2"; shift 2 ;;
        --adb)         ADB="$2"; shift 2 ;;
        --script)      FRIDA_SCRIPT="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ===== Xác định gói từ tên viết tắt =====
case "$TARGET" in
    20x|20X|ultra20x) TARGET="g1.play.ai.pro" ;;
    5x|5X|ultra5x)    TARGET="g1.play.20tb" ;;
    pro|Pro|PRO)      TARGET="g1.play.2tb.ai" ;;
    pro12|Pro12|PRO12) TARGET="g1.2tb.ai.subs_variant" ;;
    auto|g1.*)        ;; # giữ nguyên giá trị
    *) echo "Unknown product: $TARGET (use pro, 5x, 20x, pro12, or a g1.* product ID)"; exit 1 ;;
esac

# ===== Hàm hỗ trợ =====
log()  { echo "[*] $*"; }
ok()   { echo "[+] $*"; }
err()  { echo "[-] $*" >&2; }
die()  { err "$*"; exit 1; }

# ===== 1. Tìm thiết bị MuMu =====
detect_device() {
    if [[ -n "$DEVICE_PORT" ]]; then
        DEVICE="127.0.0.1:$DEVICE_PORT"
        log "Đang dùng thiết bị chỉ định $DEVICE"
        "$ADB" connect "$DEVICE" >/dev/null 2>&1 || true
        return
    fi

    log "Đang tìm thiết bị MuMu..."
# Các cổng ADB thường dùng của MuMu
    for port in 16384 16416 16448 16480 16512; do
        if "$ADB" connect "127.0.0.1:$port" 2>/dev/null | grep -q "connected"; then
            DEVICE="127.0.0.1:$port"
            ok "Đã tìm thấy thiết bị tại $DEVICE"
            return
        fi
    done

# Dự phòng bằng thiết bị ADB đã kết nối
    local dev
    dev=$("$ADB" devices 2>/dev/null | grep -v "^List" | grep "device$" | head -1 | awk '{print $1}')
    if [[ -n "$dev" ]]; then
        DEVICE="$dev"
        ok "Đang dùng thiết bị đã kết nối $DEVICE"
        return
    fi

    die "No MuMu device found. Start the emulator or use --port <PORT>"
}

# ===== 2. Chuẩn bị Frida =====
setup_frida() {
    log "Setting up Frida port forwarding ($FRIDA_LOCAL_PORT → $FRIDA_DEVICE_PORT)..."
    "$ADB" -s "$DEVICE" forward "tcp:$FRIDA_LOCAL_PORT" "tcp:$FRIDA_DEVICE_PORT" 2>/dev/null || true

# Kiểm tra tiến trình frida-server. Trên MuMu có quyền root sẵn thì không cần su.
    local fs_pid
    fs_pid=$("$ADB" -s "$DEVICE" shell "pidof frida-server" 2>/dev/null | tr -d '\r\n' || echo "")
    if [[ -z "$fs_pid" ]]; then
        log "Đang khởi động frida-server..."
        "$ADB" -s "$DEVICE" shell "$FRIDA_SERVER_PATH -D &"
        sleep 2
        fs_pid=$("$ADB" -s "$DEVICE" shell "pidof frida-server" 2>/dev/null | tr -d '\r\n' || echo "")
        [[ -n "$fs_pid" ]] || die "Không thể khởi động frida-server tại $FRIDA_SERVER_PATH"
    fi
    ok "frida-server đang chạy (PID $fs_pid)"

# Kiểm tra sự hiện diện của module.apk
    if ! "$ADB" -s "$DEVICE" shell "ls $MODULE_APK_DEVICE" >/dev/null 2>&1; then
        die "module.apk not found at $MODULE_APK_DEVICE on device. Push it first:\n  \"\$ADB\" -s $DEVICE push module.apk $MODULE_APK_DEVICE"
    fi
    ok "Đã tìm thấy module.apk"
}

# ===== 3. Lấy PID của Google One =====
get_pid() {
# Khởi động lại Google One để đặt lại trạng thái Activity.
# Ghi thông báo trạng thái ra stderr và chỉ trả PID qua stdout.
    log "Đang khởi động lại Google One..." >&2
    "$ADB" -s "$DEVICE" shell "am force-stop $GOOGLE_ONE_PKG" 2>/dev/null || true
    sleep 1
    "$ADB" -s "$DEVICE" shell "monkey -p $GOOGLE_ONE_PKG 1" >/dev/null 2>&1
    sleep 3
    local pid
    pid=$("$ADB" -s "$DEVICE" shell "pidof $GOOGLE_ONE_PKG" 2>/dev/null || echo "")
    [[ -n "$pid" ]] || die "Không thể khởi động Google One"
# Nếu có nhiều PID, lấy PID đầu tiên.
    pid=$(echo "$pid" | tr -s ' ' '\n' | head -1 | tr -d '\r\n')
    ok "Google One PID: $pid" >&2
    echo "$pid"
}

# ===== 4. Điền cấu hình và chạy script Frida =====
run_frida() {
    local pid="$1"
    local tmp_script
    tmp_script="/tmp/.frida-run-$$.js"

# Điền giá trị cấu hình vào bản sao tạm của script.
    sed \
        -e "s|^var MODE = .*|var MODE = \"$MODE\";|" \
        -e "s|^var TARGET_PRODUCT = .*|var TARGET_PRODUCT = \"$TARGET\";|" \
        -e "s|^var PREFER_DURATION = .*|var PREFER_DURATION = \"$DURATION\";|" \
        -e "s|^var MODULE_APK = .*|var MODULE_APK = \"$MODULE_APK_DEVICE\";|" \
        "$FRIDA_SCRIPT" > "$tmp_script"

    log "Injecting (mode=$MODE target=$TARGET duration=$DURATION)..."

# Xóa bộ đệm logcat trước khi chèn mã để chỉ đọc kết quả của lần chạy này.
    "$ADB" -s "$DEVICE" logcat -c 2>/dev/null || true

# Chạy Frida ở nền với stdin từ /dev/null để phiên tương tác không chặn script.
    frida -H "127.0.0.1:$FRIDA_LOCAL_PORT" -p "$pid" -l "$tmp_script" \
        </dev/null >/dev/null 2>&1 &
    FRIDA_PID=$!

# Đọc logcat định kỳ để giới hạn thời gian chờ.
    log "Đang chờ kết quả..."
    local elapsed=0
    local max_wait=60
    local got_terminal=false
    local seen_lines=0

    while [[ $elapsed -lt $max_wait ]]; do
        sleep 2
        elapsed=$((elapsed + 2))

# Đọc các thông báo AutoTrial đã ghi.
        local output
        output=$("$ADB" -s "$DEVICE" logcat -d -s "AutoTrial:*" 2>/dev/null \
            | sed 's/^.*AutoTrial *: *//')

        [[ -z "$output" ]] && continue

# Bỏ qua các dòng đã hiển thị.
        local total_lines
        total_lines=$(echo "$output" | wc -l)
        if [[ $total_lines -le $seen_lines ]]; then continue; fi
        local new_output
        new_output=$(echo "$output" | tail -n +"$((seen_lines + 1))")
        seen_lines=$total_lines

# Xử lý các dòng mới.
        while IFS= read -r msg; do
            case "$msg" in
                "=== AUTO_TRIAL_START"*)  log "Đã bắt đầu chạy script" ;;
                "BillingClient connected") ok "BillingClient connected" ;;
                "Products found:"*)       log "$msg" ;;
                PRODUCT*)                 echo ""; echo "  $msg" ;;
                "  ["*)                   echo "    $msg" ;;
                "  TRIAL "*)              ok "$msg" ;;
                TRIALS_FOUND*)            echo ""; log "$msg" ;;
                SELECTED*)                ok "$msg" ;;
                "Waiting for Activity"*)  log "Đang chờ màn hình sẵn sàng..." ;;
                BILLING_FLOW_LAUNCHED*)
                    ok "Đã yêu cầu mở cửa sổ thanh toán. Hãy kiểm tra trên thiết bị (Ctrl-C khi xong)"
                    got_terminal=true ;;
                "=== TRIAL_ACTIVATED ===")
                    echo ""; ok "ĐÃ KÍCH HOẠT DÙNG THỬ"
                    echo ""; echo "  Gói tự gia hạn sau thời gian dùng thử. Hãy hủy trước khi hết hạn."
                    echo ""; got_terminal=true ;;
                "=== USER_CANCELLED ===")
                    err "Người dùng đã hủy"; got_terminal=true ;;
                "=== ITEM_ALREADY_OWNED ===")
                    err "Tài khoản đã đăng ký"; got_terminal=true ;;
                "=== PURCHASE_FAILED"*)
                    err "$msg"; got_terminal=true ;;
                "=== LIST_COMPLETE ===")
                    echo ""; ok "Đã liệt kê xong"; got_terminal=true ;;
                "=== NO_TRIALS ===")
                    err "Không tìm thấy ưu đãi dùng thử"; got_terminal=true ;;
                "=== SELECT_FAILED ==="|\
                "=== NO_ACTIVITY ==="|\
                "=== CONNECT_FAILED"*|\
                "=== LAUNCH_ERROR"*)
                    err "$msg"; got_terminal=true ;;
            esac
        done <<< "$new_output"

        $got_terminal && break
    done

    if ! $got_terminal; then
        err "Timed out after ${max_wait}s — check logcat manually: adb logcat -d -s AutoTrial:*"
    fi

    rm -f "$tmp_script"
}

# ===== Dọn tiến trình =====
cleanup() {
    [[ -n "${FRIDA_PID:-}" ]] && kill "$FRIDA_PID" 2>/dev/null || true
}
trap cleanup EXIT

# ===== Điểm bắt đầu =====
main() {
    echo "=== Google AI Ultra Trial Tool ==="
    echo "博客：https://blog.caowo.de/"
    echo "发卡网：https://faka.cdkey.si/"
    echo ""

    detect_device
    setup_frida
    local pid
    pid=$(get_pid)

    [[ ! -f "$FRIDA_SCRIPT" ]] && die "Không tìm thấy script Frida: $FRIDA_SCRIPT"

    echo ""
    run_frida "$pid"
}

main
