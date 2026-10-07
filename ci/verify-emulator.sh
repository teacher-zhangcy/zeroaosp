#!/usr/bin/env bash
# ci/verify-emulator.sh — zeroaosp M1 常驻验证闸门（"相关改动自动验一次"）
#
# 一次约 2–4 分钟、全程 ¥0，它做这些事：
#   1. 复核 KVM：放开 /dev/kvm 权限位 + 真做 KVM_GET_API_VERSION ioctl
#   2. 用 SDK manager 现场拉官方 AOSP 系统镜像（aosp_atd，无 GMS）+ emulator + platform-tools
#   3. 建 AVD、headless 起模拟器（swiftshader 渲染 + KVM 加速）
#   4. 等 sys.boot_completed == 1（有界），采集 adb devices / getprop / ps -A
#   5. 用 NDK 编我们的 native 服务，push 进设备并启动
#   6. 【断言】ps 里必须出现我们的进程
#   7. 可选 WITH_BINDER=1：按 T-007 路径1 编 devbinder 版，【断言】`service check <名>` 正命中
#   8. 全部原始输出落进 $ARTIFACT_DIR（由 workflow 上传为 artifact）
#
# 设计原则（吸取 T-eng-infra-006 的两次假阳性教训）：
#   - 被断言检查**绝不用 `|| true` 遮盖**；断言失败即非零退出，让 job 真红
#   - 断言只认"正面命中"，绝不认名字出现在错误信息里（例如 "Service X: not found" 不算命中）
#   - 每个等待都有上限，超时即失败，并打印当时的原始输出
#
# 用法：
#   ci/verify-emulator.sh                                  # 默认闸门
#   EXPECT_PROCESS=no_such_thing ci/verify-emulator.sh      # 负向对照：断言必然失败（证明闸门真会红）
#   WITH_BINDER=1 ci/verify-emulator.sh                     # 额外验"服务被 servicemanager 登记"
#   ALLOW_NO_KVM=1 ci/verify-emulator.sh                    # 本地无 KVM 时跳过 KVM 复核（CI 上别用）
set -euo pipefail

SDK="${SDK:-/usr/local/lib/android/sdk}"
IMAGE="${IMAGE:-system-images;android-34;aosp_atd;x86_64}"
AVD_NAME="${AVD_NAME:-zeroaosp-verify}"
SERVICE_NAME="${SERVICE_NAME:-dsh_hello_service}"
EXPECT_PROCESS="${EXPECT_PROCESS:-dsh_hello_service}"
ARTIFACT_DIR="${ARTIFACT_DIR:-artifacts}"
BOOT_TIMEOUT_S="${BOOT_TIMEOUT_S:-600}"
NDK_API="${NDK_API:-30}"
WITH_BINDER="${WITH_BINDER:-0}"
ALLOW_NO_KVM="${ALLOW_NO_KVM:-0}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_CPP="$REPO_ROOT/m1/service/dsh_hello_service.cpp"

T0="$(date +%s)"
step()    { printf '\n===== [%s +%ss] %s =====\n' "$(date -u +%H:%M:%S)" "$(( $(date +%s) - T0 ))" "$*"; }
info()    { printf '  %s\n' "$*"; }
elapsed() { echo "$(( $(date +%s) - T0 ))"; }

# 断言失败：打印摘要 → 非零退出（让 job 真红）
fail() {
  printf '\n!!!!! 断言失败: %s\n' "$*" >&2
  write_summary || true
  exit 1
}

write_summary() {
  local s="$ARTIFACT_DIR/summary.txt"
  mkdir -p "$ARTIFACT_DIR"
  {
    printf 'verify-emulator summary (%s)\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'elapsed_s      = %s\n' "$(elapsed)"
    printf 'expect_process = %s\n' "$EXPECT_PROCESS"
    printf 'service_name   = %s\n' "$SERVICE_NAME"
    printf 'with_binder    = %s\n' "$WITH_BINDER"
    printf 'image          = %s\n' "$IMAGE"
    printf 'boot_completed = %s\n' "$(cat "$ARTIFACT_DIR/boot_completed.txt" 2>/dev/null || echo '(未采集)')"
    printf 'fingerprint    = %s\n' "$(cat "$ARTIFACT_DIR/fingerprint.txt" 2>/dev/null || echo '(未采集)')"
  } > "$s"
  info "摘要 → $s"
}

# ─────────────────────────── 0. 环境事实 ───────────────────────────
step "0. 环境事实"
mkdir -p "$ARTIFACT_DIR"
info "nproc=$(nproc)  mem=$(free -h | awk '/^Mem:/{print $2}')  disk=$(df -h / | awk 'END{print $4" 可用"}')"
info "SDK=$SDK  IMAGE=$IMAGE  NDK_API=$NDK_API  REPO_ROOT=$REPO_ROOT"
{ nproc; free -h; df -h /; uname -a; } > "$ARTIFACT_DIR/resources.txt" 2>&1
[ -f "$SRC_CPP" ] || fail "找不到源文件 $SRC_CPP（脚本必须在仓内运行）"
printf '%s' "$SDK/cmdline-tools/latest/bin:$SDK/platform-tools:$SDK/emulator:$PATH" > "$ARTIFACT_DIR/.path_hint"

# ─────────────────────────── 1. KVM ───────────────────────────
step "1. KVM 复核"
if [ "$ALLOW_NO_KVM" = "1" ]; then
  info "ALLOW_NO_KVM=1，跳过（仅本地开发用）"
else
  [ -e /dev/kvm ] || fail "/dev/kvm 不存在：本机没有 KVM，跑不了模拟器"
  sudo chmod 666 /dev/kvm
  ls -l /dev/kvm | tee "$ARTIFACT_DIR/kvm_ls.txt"
  KVM_API="$(python3 -c 'import fcntl,os;fd=os.open("/dev/kvm",os.O_RDWR);print(fcntl.ioctl(fd,0xAE00,0));os.close(fd)')"
  info "KVM_GET_API_VERSION=$KVM_API"
  [ "$KVM_API" = "12" ] || fail "KVM 不可用（KVM_GET_API_VERSION=$KVM_API，期望 12）"
fi

# ─────────────────────────── 2. SDK 组件 ───────────────────────────
step "2. 安装 SDK 组件（emulator / platform-tools / 官方 AOSP 镜像）"
export PATH="$SDK/cmdline-tools/latest/bin:$SDK/platform-tools:$PATH"
command -v sdkmanager >/dev/null 2>&1 || fail "找不到 sdkmanager（SDK=$SDK）"
yes | sdkmanager --licenses > /dev/null 2>&1 || info "licenses 步骤返回非零（通常无碍）"
sdkmanager "platform-tools" "emulator" > "$ARTIFACT_DIR/sdk_emulator.log" 2>&1 \
  || { tail -20 "$ARTIFACT_DIR/sdk_emulator.log"; fail "装 emulator/platform-tools 失败"; }
sdkmanager "$IMAGE" > "$ARTIFACT_DIR/sdk_image.log" 2>&1 \
  || { tail -20 "$ARTIFACT_DIR/sdk_image.log"; fail "装系统镜像失败：$IMAGE"; }
ADB="$SDK/platform-tools/adb"
EMU_BIN="$(command -v emulator || find "$SDK" -maxdepth 3 -type f -name emulator | head -1)"
[ -x "$ADB" ] || fail "找不到 adb：$ADB"
[ -n "$EMU_BIN" ] && [ -x "$EMU_BIN" ] || fail "找不到 emulator 可执行文件"
info "adb=$ADB"; info "emulator=$EMU_BIN"
"$ADB" version | head -2 | tee "$ARTIFACT_DIR/adb_version.txt"

# ─────────────────────────── 3. 建 AVD + 起模拟器 ───────────────────────────
step "3. 建 AVD 并启动模拟器（headless / swiftshader / KVM）"
( echo no | avdmanager create avd --force -n "$AVD_NAME" -k "$IMAGE" --device pixel_5 ) >/dev/null 2>&1 \
  || ( echo no | avdmanager create avd --force -n "$AVD_NAME" -k "$IMAGE" ) >/dev/null 2>&1 \
  || fail "avdmanager 建 AVD 失败"
nohup "$EMU_BIN" -avd "$AVD_NAME" -no-window -no-audio -no-boot-anim -no-snapshot \
      -gpu swiftshader_indirect -memory 3072 -cores 2 -verbose \
      > "$ARTIFACT_DIR/emulator.log" 2>&1 &
EMU_PID=$!
sleep 20
kill -0 "$EMU_PID" 2>/dev/null || { tail -30 "$ARTIFACT_DIR/emulator.log"; fail "模拟器进程起不来（见 emulator.log）"; }
info "模拟器 pid=$EMU_PID，日志 → $ARTIFACT_DIR/emulator.log"
grep -m2 -E 'CPU Acceleration|KVM' "$ARTIFACT_DIR/emulator.log" | sed 's/^/  /' || true

# ─────────────────────────── 4. 等启动完成 ───────────────────────────
step "4. 等 Android 启动完成（上限 ${BOOT_TIMEOUT_S}s）"
"$ADB" start-server >/dev/null 2>&1 || true
timeout 120 "$ADB" wait-for-device || info "wait-for-device 超时（继续轮询）"
BOOT=""; WAITED=0
while [ "$WAITED" -lt "$BOOT_TIMEOUT_S" ]; do
  BOOT="$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
  [ "$BOOT" = "1" ] && break
  sleep 10; WAITED=$((WAITED + 10))
  [ $((WAITED % 60)) -eq 0 ] && info "已等 ${WAITED}s（boot_completed='$BOOT'）"
done
printf '%s' "$BOOT" > "$ARTIFACT_DIR/boot_completed.txt"
[ "$BOOT" = "1" ] || { tail -40 "$ARTIFACT_DIR/emulator.log"; fail "启动未完成：sys.boot_completed='$BOOT'（等了 ${WAITED}s）"; }
info "启动完成，用时 ${WAITED}s"

# ─────────────────────────── 5. 观测 ───────────────────────────
step "5. 采集设备事实（adb devices / fingerprint / ps / service list）"
"$ADB" devices -l                             > "$ARTIFACT_DIR/adb_devices.txt" 2>&1
"$ADB" shell getprop ro.build.fingerprint     > "$ARTIFACT_DIR/fingerprint.txt" 2>&1
"$ADB" shell getprop                          > "$ARTIFACT_DIR/getprop.txt" 2>&1
"$ADB" shell 'ps -A'                          > "$ARTIFACT_DIR/ps-A.txt" 2>&1
"$ADB" shell 'service list'                   > "$ARTIFACT_DIR/service_list.txt" 2>&1
FP="$(tr -d '\r' < "$ARTIFACT_DIR/fingerprint.txt")"
info "fingerprint = $FP"
info "ps 行数 = $(wc -l < "$ARTIFACT_DIR/ps-A.txt")，service 条目 = $(wc -l < "$ARTIFACT_DIR/service_list.txt")"
grep -q 'emulator-' "$ARTIFACT_DIR/adb_devices.txt" || fail "adb devices 里没有 emulator-*（设备没起来）"

# ─────────────────────────── 6. 编并推我们的服务 ───────────────────────────
step "6. 用 NDK 编我们的服务并推进设备"
NDK="$(ls -d "$SDK"/ndk/* 2>/dev/null | sort -V | tail -1 || true)"
[ -n "$NDK" ] || fail "SDK 里没有 NDK"
TC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
info "NDK=$NDK"
"$TC/x86_64-linux-android${NDK_API}-clang++" -O2 -std=c++17 -static-libstdc++ \
  "$SRC_CPP" -o dsh_hello_service.stub 2> "$ARTIFACT_DIR/compile_stub.log" \
  || { cat "$ARTIFACT_DIR/compile_stub.log"; fail "编 stub 版失败"; }
file dsh_hello_service.stub | tee "$ARTIFACT_DIR/file_stub.txt"
sha256sum dsh_hello_service.stub | tee "$ARTIFACT_DIR/sha_stub.txt"

"$ADB" root >/dev/null 2>&1 || info "adb root 返回非零（下面仍按现有权限继续）"
sleep 5; "$ADB" wait-for-device || true
"$ADB" shell setenforce 0 >/dev/null 2>&1 || info "setenforce 0 未成功（可能已是 permissive）"
"$ADB" push dsh_hello_service.stub "/data/local/tmp/$SERVICE_NAME" > "$ARTIFACT_DIR/push.txt" 2>&1 \
  || { cat "$ARTIFACT_DIR/push.txt"; fail "push 失败"; }
"$ADB" shell chmod 755 "/data/local/tmp/$SERVICE_NAME"
"$ADB" shell "setsid /data/local/tmp/$SERVICE_NAME > /data/local/tmp/$SERVICE_NAME.log 2>&1 < /dev/null &"
sleep 6
"$ADB" shell "cat /data/local/tmp/$SERVICE_NAME.log" > "$ARTIFACT_DIR/service_self_log.txt" 2>&1
info "服务自报日志："; sed 's/^/  /' "$ARTIFACT_DIR/service_self_log.txt"

# ─────────────────────────── 7. 断言 ───────────────────────────
step "7. 断言：进程在跑（判据只看 ps 的进程名列）"
"$ADB" shell 'ps -A' > "$ARTIFACT_DIR/ps-after-run.txt" 2>&1
grep -E "[[:space:]]${EXPECT_PROCESS}$" "$ARTIFACT_DIR/ps-after-run.txt" | tee "$ARTIFACT_DIR/ps_match.txt" \
  || { printf '\n--- ps-after-run.txt 前 30 行 ---\n'; head -30 "$ARTIFACT_DIR/ps-after-run.txt"; \
       fail "ps -A 里没有进程 $EXPECT_PROCESS（进程没起来，或没推成功）"; }
info "OK：ps 中看到 $EXPECT_PROCESS"

if [ "$WITH_BINDER" = "1" ]; then
  step "7b. 断言（WITH_BINDER=1）：服务被 servicemanager 登记"
  mkdir -p devlibs
  for so in libbinder.so libutils.so libcutils.so libbase.so liblog.so libc++.so; do
    "$ADB" pull "/system/lib64/$so" "devlibs/$so" > /dev/null 2>&1 \
      || fail "拉取设备库失败：$so（WITH_BINDER=1 需要它当链接桩）"
  done
  for repo in "frameworks/native /tmp/fwnative" "system/libbase /tmp/fwbase" \
              "system/core /tmp/fwcore" "system/logging /tmp/fwlog"; do
    set -- $repo
    [ -d "$2" ] || git clone --depth=1 -b android-14.0.0_r1 \
        "https://android.googlesource.com/platform/$1" "$2" > /dev/null 2>&1 \
      || git clone --depth=1 -b android-14.0.0_r1 \
        "https://mirrors.tuna.tsinghua.edu.cn/git/AOSP/platform/$1" "$2" > /dev/null 2>&1 \
      || fail "取 AOSP 14 头失败：$1"
  done
  INC="-I/tmp/fwnative/libs/binder/include -I/tmp/fwnative/libs/nativebase/include -I/tmp/fwbase/include"
  INC="$INC -I/tmp/fwcore/libutils/include -I/tmp/fwcore/libsystem/include -I/tmp/fwcore/libcutils/include"
  INC="$INC -I/tmp/fwlog/liblog/include"
  "$TC/x86_64-linux-android${NDK_API}-clang++" -O2 -std=c++20 -Wall -fno-rtti -fno-exceptions \
    -DDSH_WITH_BINDER=1 -DDSH_DEVICE_LINKED=1 $INC "$SRC_CPP" \
    -Ldevlibs -lbinder -lutils -lcutils -lbase -llog -lc++ \
    -Wl,-rpath-link,devlibs -Wl,--allow-shlib-undefined \
    -o dsh_hello_service.devbinder 2> "$ARTIFACT_DIR/compile_devbinder.log" \
    || { cat "$ARTIFACT_DIR/compile_devbinder.log"; fail "编 devbinder 版失败"; }
  sha256sum dsh_hello_service.devbinder | tee "$ARTIFACT_DIR/sha_devbinder.txt"
  "$ADB" push dsh_hello_service.devbinder "/data/local/tmp/${SERVICE_NAME}_dev" > /dev/null 2>&1 \
    || fail "push devbinder 版失败"
  "$ADB" shell chmod 755 "/data/local/tmp/${SERVICE_NAME}_dev"
  "$ADB" shell "setsid /data/local/tmp/${SERVICE_NAME}_dev > /data/local/tmp/${SERVICE_NAME}_dev.log 2>&1 < /dev/null &"
  sleep 6
  "$ADB" shell "cat /data/local/tmp/${SERVICE_NAME}_dev.log" > "$ARTIFACT_DIR/devbinder_self_log.txt" 2>&1
  sed 's/^/  /' "$ARTIFACT_DIR/devbinder_self_log.txt"
  "$ADB" shell "service check $SERVICE_NAME" > "$ARTIFACT_DIR/service_check.txt" 2>&1
  "$ADB" shell "service list" | grep -i "$SERVICE_NAME" > "$ARTIFACT_DIR/service_list_match.txt" 2>&1 || true
  "$ADB" shell "dumpsys $SERVICE_NAME" > "$ARTIFACT_DIR/dumpsys.txt" 2>&1
  sed 's/^/  /' "$ARTIFACT_DIR/service_check.txt"
  # 只认 "Service <名>: found" 这一句正面命中；不认名字出现在 "not found" 里
  grep -q "Service $SERVICE_NAME: found" "$ARTIFACT_DIR/service_check.txt" \
    || fail "service check 未正命中：$SERVICE_NAME 没被 servicemanager 登记"
  grep -qi "$SERVICE_NAME" "$ARTIFACT_DIR/dumpsys.txt" \
    || fail "dumpsys 没有出现 $SERVICE_NAME"
  grep -qi "Can't find service" "$ARTIFACT_DIR/dumpsys.txt" \
    && fail "dumpsys 报 Can't find service（服务没登记）"
  info "OK：service check 正命中 + dumpsys 有输出"
fi

# ─────────────────────────── 8. 收尾 ───────────────────────────
step "8. 收尾"
write_summary
info "总耗时 $(elapsed)s；artifact 目录内容："
ls -l "$ARTIFACT_DIR" | sed 's/^/  /'
printf '\n✅ 闸门通过（%ss）\n' "$(elapsed)"
