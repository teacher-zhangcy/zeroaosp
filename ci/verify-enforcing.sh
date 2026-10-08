#!/usr/bin/env bash
# ci/verify-enforcing.sh — M2 入场券验证：让自研服务在 **enforcing** 下合法注册成 Binder 服务
#
# 分层设计（回报里逐层说明"验到了哪层、哪层仍是纸面"）：
#   L0 事实层   : getenforce / selinux 目录清单 / 运行器上 secilc·checkpolicy 可用性
#   L1 原始层   : **不改任何策略**，在 stock enforcing 下跑我们的服务，抓 avc denial 原文
#                 （这一层回答"enforcing 到底拦在哪一句"）
#   L2 策略层   : 把 patches/ 里的规则以 CIL 形式注入设备策略并加载 → **enforcing=1 下**
#                 断言 `service check <名>` 正命中、`dumpsys` 有输出
#
# 交付形态 vs 验证形态（必须分清）：
#   - 交付形态 = patches/0001-sepolicy-dsh-quickjsd-domain.patch（.te + service_contexts + file_contexts，
#     走 AOSP 构建系统，由 init 通过 init_daemon_domain 起进程、由 plat_service_contexts 做名字映射）
#   - 验证形态 = 本脚本：等价规则用 CIL 动态加载（因为免费 runner 上没有完整树可以重编镜像），
#     并用 chcon + type_transition 让进程进入同一个域 dsh_quickjsd。二者规则集一致，机制不同。
set -euo pipefail

SDK="${SDK:-/usr/local/lib/android/sdk}"
IMAGE="${IMAGE:-system-images;android-34;aosp_atd;x86_64}"
AVD_NAME="${AVD_NAME:-zeroaosp-enforcing}"
SERVICE_NAME="${SERVICE_NAME:-dsh_hello_service}"
DOMAIN_NAME="${DOMAIN_NAME:-dsh_quickjsd}"
ARTIFACT_DIR="${ARTIFACT_DIR:-artifacts-enforcing}"
BOOT_TIMEOUT_S="${BOOT_TIMEOUT_S:-600}"
NDK_API="${NDK_API:-30}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_CPP="$REPO_ROOT/m1/service/dsh_hello_service.cpp"
CIL_FILE="$REPO_ROOT/ci/enforcing/${DOMAIN_NAME}.cil"

T0="$(date +%s)"
step() { printf '\n===== [%s +%ss] %s =====\n' "$(date -u +%H:%M:%S)" "$(( $(date +%s) - T0 ))" "$*"; }
info() { printf '  %s\n' "$*"; }
elapsed() { echo "$(( $(date +%s) - T0 ))"; }
fail() { printf '\n!!!!! 断言失败: %s\n' "$*" >&2; exit 1; }

# 非预期退出（set -e 触发）也要留痕——否则只留一个静默 exit 1
trap 'printf "\n!! 脚本在第 %s 行非预期退出（exit=%s）\n" "$LINENO" "$?" >&2' ERR

write_status() { printf '%s\n' "$1" > "$ARTIFACT_DIR/status.txt"; info "status = $1"; }

write_summary() {
  {
    printf 'verify-enforcing summary (%s)\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'elapsed_s      = %s\n' "$(elapsed)"
    printf 'service_name   = %s\n' "$SERVICE_NAME"
    printf 'domain_name    = %s\n' "$DOMAIN_NAME"
    printf 'getenforce_L0  = %s\n' "$(cat "$ARTIFACT_DIR/getenforce.txt" 2>/dev/null || echo '(未采集)')"
    printf 'getenforce_L2  = %s\n' "$(cat "$ARTIFACT_DIR/getenforce_after_load.txt" 2>/dev/null || echo '(未采集)')"
    printf 'L1_service_check = %s\n' "$(cat "$ARTIFACT_DIR/L1_service_check.txt" 2>/dev/null || echo '(未采集)')"
    printf 'L2_service_check = %s\n' "$(cat "$ARTIFACT_DIR/L2_service_check.txt" 2>/dev/null || echo '(未采集)')"
  } > "$ARTIFACT_DIR/summary.txt"
  info "摘要 → $ARTIFACT_DIR/summary.txt"
}

step "0. 环境事实"
mkdir -p "$ARTIFACT_DIR" devlibs
{ nproc; free -h; df -h /; } > "$ARTIFACT_DIR/resources.txt" 2>&1
[ -f "$SRC_CPP" ] || fail "找不到 $SRC_CPP（脚本须在仓内运行）"
[ -f "$CIL_FILE" ] || fail "找不到 $CIL_FILE（本脚本需要的 CIL 形式规则）"

step "1. KVM + 起模拟器（与 147s 闸门同法）"
sudo chmod 666 /dev/kvm
python3 -c 'import fcntl,os;fd=os.open("/dev/kvm",os.O_RDWR);print("KVM_GET_API_VERSION =",fcntl.ioctl(fd,0xAE00,0));os.close(fd)' | tee "$ARTIFACT_DIR/kvm.txt"
export PATH="$SDK/cmdline-tools/latest/bin:$SDK/platform-tools:$PATH"
yes | sdkmanager --licenses > /dev/null 2>&1 || true
sdkmanager "platform-tools" "emulator" > "$ARTIFACT_DIR/sdk_emulator.log" 2>&1 || { tail -10 "$ARTIFACT_DIR/sdk_emulator.log"; fail "装 emulator 失败"; }
sdkmanager "$IMAGE" > "$ARTIFACT_DIR/sdk_image.log" 2>&1 || { tail -10 "$ARTIFACT_DIR/sdk_image.log"; fail "装镜像失败"; }
ADB="$SDK/platform-tools/adb"
EMU_BIN="$(command -v emulator || find "$SDK" -maxdepth 3 -type f -name emulator | head -1)"
[ -x "$ADB" ] && [ -n "$EMU_BIN" ] || fail "缺 adb 或 emulator"
( echo no | avdmanager create avd --force -n "$AVD_NAME" -k "$IMAGE" --device pixel_5 ) >/dev/null 2>&1 || true
nohup "$EMU_BIN" -avd "$AVD_NAME" -no-window -no-audio -no-boot-anim -no-snapshot \
      -gpu swiftshader_indirect -memory 3072 -cores 2 -verbose > "$ARTIFACT_DIR/emulator.log" 2>&1 &
sleep 20
"$ADB" start-server >/dev/null 2>&1 || true
timeout 120 "$ADB" wait-for-device || true
BOOT=""; WAITED=0
while [ "$WAITED" -lt "$BOOT_TIMEOUT_S" ]; do
  BOOT="$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
  [ "$BOOT" = "1" ] && break
  sleep 10; WAITED=$((WAITED + 10))
done
[ "$BOOT" = "1" ] || { tail -30 "$ARTIFACT_DIR/emulator.log"; fail "启动未完成（等了 ${WAITED}s）"; }
info "启动完成，用时 ${WAITED}s"
"$ADB" root >/dev/null 2>&1 || info "adb root 非零"
sleep 4; "$ADB" wait-for-device || true

step "L0 事实层：enforcing 状态与 selinux 资产"
"$ADB" shell getenforce | tee "$ARTIFACT_DIR/getenforce.txt"
"$ADB" shell 'cat /sys/fs/selinux/enforce' | tee "$ARTIFACT_DIR/enforce_value.txt"
# 以下全部是**诊断性**采集：任何一条失败都不应该让脚本退出（断言在 L2 才做）
"$ADB" shell 'ls -l /system/etc/selinux/' > "$ARTIFACT_DIR/selinux_etc.txt" 2>&1 || true
"$ADB" shell 'ls -l /system/etc/selinux/mapping/' >> "$ARTIFACT_DIR/selinux_etc.txt" 2>&1 || true
"$ADB" shell 'ls -l /vendor/etc/selinux/ /system_ext/etc/selinux/ /product/etc/selinux/' >> "$ARTIFACT_DIR/selinux_etc.txt" 2>&1 || true
"$ADB" shell 'cat /proc/self/attr/current' > "$ARTIFACT_DIR/shell_context.txt" 2>&1 || true
"$ADB" shell 'ls /system/bin' > "$ARTIFACT_DIR/system_bin.txt" 2>&1 || true
grep -iE '^(chcon|restorecon|getenforce|setenforce|secilc|checkpolicy)$' "$ARTIFACT_DIR/system_bin.txt" > "$ARTIFACT_DIR/selinux_bins.txt" 2>&1 || true
sed 's/^/  /' "$ARTIFACT_DIR/selinux_etc.txt" | head -30
info "--- shell 域 / 设备侧工具 ---"
cat "$ARTIFACT_DIR/shell_context.txt" | sed 's/^/  /' || true
cat "$ARTIFACT_DIR/selinux_bins.txt" | sed 's/^/  /' || true
info "--- 运行器上的 selinux 工具 ---"
( command -v secilc || echo "secilc: 缺失" ) > "$ARTIFACT_DIR/tools_host.txt" 2>&1 || true
( command -v checkpolicy || echo "checkpolicy: 缺失" ) >> "$ARTIFACT_DIR/tools_host.txt" 2>&1 || true
apt-cache policy secilc checkpolicy >> "$ARTIFACT_DIR/tools_host.txt" 2>&1 || true
sed 's/^/  /' "$ARTIFACT_DIR/tools_host.txt"

step "L0b 编译服务（T-007 路径1：链接设备 .so）"
NDK="$(ls -d "$SDK"/ndk/* 2>/dev/null | sort -V | tail -1 || true)"
[ -n "$NDK" ] || fail "没有 NDK"
TC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
for so in libbinder.so libutils.so libcutils.so libbase.so liblog.so libc++.so; do
  "$ADB" pull "/system/lib64/$so" "devlibs/$so" > /dev/null 2>&1 || fail "拉 $so 失败"
done
for spec in "frameworks/native /tmp/fwnative" "system/libbase /tmp/fwbase" "system/core /tmp/fwcore" "system/logging /tmp/fwlog"; do
  set -- $spec
  [ -d "$2" ] || git clone --depth=1 -b android-14.0.0_r1 "https://android.googlesource.com/platform/$1" "$2" > /dev/null 2>&1 \
    || git clone --depth=1 -b android-14.0.0_r1 "https://mirrors.tuna.tsinghua.edu.cn/git/AOSP/platform/$1" "$2" > /dev/null 2>&1 \
    || fail "取 AOSP14 头失败：$1"
done
INC="-I/tmp/fwnative/libs/binder/include -I/tmp/fwnative/libs/nativebase/include -I/tmp/fwbase/include"
INC="$INC -I/tmp/fwcore/libutils/include -I/tmp/fwcore/libsystem/include -I/tmp/fwcore/libcutils/include -I/tmp/fwlog/liblog/include"
"$TC/x86_64-linux-android${NDK_API}-clang++" -O2 -std=c++20 -Wall -fno-rtti -fno-exceptions \
  -DDSH_WITH_BINDER=1 -DDSH_DEVICE_LINKED=1 $INC "$SRC_CPP" \
  -Ldevlibs -lbinder -lutils -lcutils -lbase -llog -lc++ \
  -Wl,-rpath-link,devlibs -Wl,--allow-shlib-undefined -o dsh_hello_service.devbinder \
  2> "$ARTIFACT_DIR/compile.log" || { cat "$ARTIFACT_DIR/compile.log"; fail "编 devbinder 失败"; }
info "编译 OK：$(file -b dsh_hello_service.devbinder)"

step "L1 原始层：stock enforcing（不改任何策略、不做 setenforce/chcon）下跑我们的服务"
"$ADB" shell 'dmesg -c > /dev/null 2>&1' || true     # 清空 dmesg 便于只看本次的 denial
"$ADB" push dsh_hello_service.devbinder "/data/local/tmp/${SERVICE_NAME}_l1" > /dev/null 2>&1
"$ADB" shell chmod 755 "/data/local/tmp/${SERVICE_NAME}_l1"
"$ADB" shell "setsid /data/local/tmp/${SERVICE_NAME}_l1 > /data/local/tmp/l1.log 2>&1 < /dev/null &" || true
sleep 8
"$ADB" shell "cat /data/local/tmp/l1.log" > "$ARTIFACT_DIR/L1_self_log.txt" 2>&1 || true
"$ADB" shell "service check $SERVICE_NAME" > "$ARTIFACT_DIR/L1_service_check.txt" 2>&1 || true
"$ADB" shell 'ps -A' > "$ARTIFACT_DIR/L1_ps.txt" 2>&1 || true
"$ADB" shell 'dmesg' > "$ARTIFACT_DIR/L1_dmesg.txt" 2>&1 || true
"$ADB" shell 'logcat -d -b all -t 300' > "$ARTIFACT_DIR/L1_logcat.txt" 2>&1 || true
info "--- L1 自身日志（原文） ---"; sed 's/^/  /' "$ARTIFACT_DIR/L1_self_log.txt"
info "--- L1 service check（原文） ---"; sed 's/^/  /' "$ARTIFACT_DIR/L1_service_check.txt"
info "--- L1 avc denial（原文，取前 25 行） ---"
grep -iE 'avc: *denied' "$ARTIFACT_DIR/L1_dmesg.txt" "$ARTIFACT_DIR/L1_logcat.txt" 2>/dev/null | head -25 | sed 's/^/  /' || info "（没有抓到 avc denial）"

step "L2 策略层：注入 patches 规则（CIL 形式）→ 加载 → enforcing 下重测"
# (a) 取设备策略输入
mkdir -p policy
"$ADB" shell 'ls /system/etc/selinux/*.cil /system/etc/selinux/mapping/*.cil 2>/dev/null' > "$ARTIFACT_DIR/cil_list.txt" 2>&1 || true
sed 's/^/  /' "$ARTIFACT_DIR/cil_list.txt"
for f in plat_sepolicy.cil; do
  "$ADB" pull "/system/etc/selinux/$f" "policy/$f" > /dev/null 2>&1 || info "（设备上没有 /system/etc/selinux/$f）"
done
# vendor 策略依赖"平台公共策略的版本化副本"，它在 vendor 分区（AOSP 的 secilc 输入顺序：pub_versioned → plat → vendor）
"$ADB" pull /vendor/etc/selinux/plat_pub_versioned.cil policy/plat_pub_versioned.cil > /dev/null 2>&1 \
  || "$ADB" pull /system/etc/selinux/plat_pub_versioned.cil policy/plat_pub_versioned.cil > /dev/null 2>&1 \
  || info "（两处都没有 plat_pub_versioned.cil）"
"$ADB" pull /vendor/etc/selinux/vendor_sepolicy.cil policy/vendor_sepolicy.cil > /dev/null 2>&1 || info "（设备上没有 vendor_sepolicy.cil）"
ls -l policy | sed 's/^/  /'
# (b) 注入我们的规则
cp "$CIL_FILE" "policy/zz-${DOMAIN_NAME}.cil"
grep -c '' "policy/zz-${DOMAIN_NAME}.cil" > "$ARTIFACT_DIR/cil_lines.txt" 2>&1 || true
info "注入的 CIL 行数 = $(cat "$ARTIFACT_DIR/cil_lines.txt")"
python3 -c "
b=0
for l in open('policy/zz-${DOMAIN_NAME}.cil',encoding='utf-8'):
    s=l.split(';')[0]
    b+=s.count('(')-s.count(')')
print('CIL_PAREN=' + ('balanced' if b==0 else 'unbalanced:%d'%b))" 2>&1 | tee "$ARTIFACT_DIR/cil_balance.txt" || true
# (c) 运行器上找 secilc
SECILC="$(command -v secilc || true)"
if [ -z "$SECILC" ]; then
  info "secilc 不在 PATH，尝试 apt 安装（CI 运行器内；这是验证工具，不入仓）"
  if sudo apt-get update -qq > "$ARTIFACT_DIR/apt.log" 2>&1 && sudo apt-get install -y -qq secilc >> "$ARTIFACT_DIR/apt.log" 2>&1; then
    SECILC="$(command -v secilc || true)"
  fi
fi
[ -n "$SECILC" ] || { info "secilc 不可用 → L2 无法在本轮完成（见 apt.log）"; tail -5 "$ARTIFACT_DIR/apt.log" 2>/dev/null || true; write_status "L2_SKIPPED_NO_SECILC"; write_summary; info "总耗时 $(elapsed)s"; exit 1; }
info "secilc = $SECILC"
# (d) 编译新策略
# (d) 编译新策略（policyvers 必须与设备内核一致，否则 load 会 EINVAL）
POLICYVERS="$("$ADB" shell cat /sys/fs/selinux/policyvers 2>/dev/null | tr -d '\r' || true)"
[ -n "$POLICYVERS" ] || POLICYVERS=30
info "设备 /sys/fs/selinux/policyvers = $POLICYVERS"
set -- $(ls policy/*.cil | grep -v 'mapping/')
info "secilc 输入顺序：$*"
"$SECILC" "$@" -o "$ARTIFACT_DIR/policy.new" -c "$POLICYVERS" -m -M true -G -N \
  > "$ARTIFACT_DIR/secilc.log" 2>&1 || { info "secilc 失败原文："; tail -25 "$ARTIFACT_DIR/secilc.log" | sed 's/^/  /'; fail "secilc 编译新策略失败"; }
info "secilc OK → $(stat -c%s "$ARTIFACT_DIR/policy.new") B"
# (e) 放宽窗口：**只**用来装策略与给文件打标签（脚手架动作），
#     窗口内不做任何"注册成功与否"的判断；随后立刻回到 enforcing，断言全部发生在 enforcing=1 之后
info "== 放宽窗口（仅装策略 + 打标签；这一段的动作不是交付形态）=="
"$ADB" shell 'setenforce 0' >/dev/null 2>&1 || true
"$ADB" shell getenforce | tee "$ARTIFACT_DIR/getenforce_window.txt"
"$ADB" push "$ARTIFACT_DIR/policy.new" /data/local/tmp/policy.new > /dev/null 2>&1 || fail "推策略失败"
"$ADB" shell 'cat /data/local/tmp/policy.new > /sys/fs/selinux/load' > "$ARTIFACT_DIR/load.log" 2>&1 \
  || info "（load 返回非零，见 load.log；enforcing 下写 selinuxfs 需要 load_policy 权限，故在窗口内做）"
sed 's/^/  /' "$ARTIFACT_DIR/load.log" || true
# 加载是否真的生效：把"当前已加载的策略"读回来，找我们的类型名
"$ADB" shell 'cat /sys/fs/selinux/policy' > "$ARTIFACT_DIR/policy_loaded.bin" 2> "$ARTIFACT_DIR/policy_loaded.err" || true
if grep -qa "dsh_quickjsd" "$ARTIFACT_DIR/policy_loaded.bin" 2>/dev/null; then
  info "✅ 已加载策略里含 dsh_quickjsd（load 生效）"
else
  info "⚠ 已加载策略里没有 dsh_quickjsd（load 未生效；后续断言即使通过也只能证明 su 域路径）"
  write_status "L2_LOAD_NOT_EFFECTIVE"
fi
"$ADB" shell "cp /data/local/tmp/${SERVICE_NAME}_l1 /data/local/tmp/${DOMAIN_NAME}" > "$ARTIFACT_DIR/cp.log" 2>&1 || fail "复制二进制失败（见 cp.log）"
"$ADB" shell "chcon u:object_r:${DOMAIN_NAME}_exec:s0 /data/local/tmp/${DOMAIN_NAME}" 2> "$ARTIFACT_DIR/chcon.log" || info "（chcon 非零，见 chcon.log）"
"$ADB" shell "ls -Z /data/local/tmp/${DOMAIN_NAME}" > "$ARTIFACT_DIR/chcon_result.txt" 2>&1 || true
sed 's/^/  /' "$ARTIFACT_DIR/chcon_result.txt" || true
info "== 关窗：回到 enforcing =="
"$ADB" shell 'setenforce 1' >/dev/null 2>&1 || true
"$ADB" shell getenforce | tee "$ARTIFACT_DIR/getenforce_after_load.txt"
# (g) 断言：**enforcing 下**注册（先复核 enforcing，再跑进程）
grep -qx "Enforcing" "$ARTIFACT_DIR/getenforce_after_load.txt" || fail "getenforce ≠ Enforcing（断言前必须回到 enforcing）"
"$ADB" shell "setsid /data/local/tmp/${DOMAIN_NAME} > /data/local/tmp/l2.log 2>&1 < /dev/null &" || true
sleep 8
"$ADB" shell "cat /data/local/tmp/l2.log" > "$ARTIFACT_DIR/L2_self_log.txt" 2>&1 || true
"$ADB" shell "ps -A -Z" > "$ARTIFACT_DIR/L2_ps.txt" 2>&1 || true
"$ADB" shell "service check $SERVICE_NAME" > "$ARTIFACT_DIR/L2_service_check.txt" 2>&1 || true
"$ADB" shell "dumpsys $SERVICE_NAME" > "$ARTIFACT_DIR/L2_dumpsys.txt" 2>&1 || true
"$ADB" shell 'dmesg' > "$ARTIFACT_DIR/L2_dmesg.txt" 2>&1 || true
"$ADB" shell getenforce | tee "$ARTIFACT_DIR/getenforce_at_assert.txt"
info "--- L2 进程上下文（ps -Z 里含 dsh_quickjsd 的行） ---"; grep -i "${DOMAIN_NAME}" "$ARTIFACT_DIR/L2_ps.txt" | sed 's/^/  /' || info "（没有该域的行）"
info "--- L2 自身日志 ---"; sed 's/^/  /' "$ARTIFACT_DIR/L2_self_log.txt"
info "--- L2 service check ---"; sed 's/^/  /' "$ARTIFACT_DIR/L2_service_check.txt"
info "--- L2 avc denial（若有） ---"; grep -iE 'avc: *denied' "$ARTIFACT_DIR/L2_dmesg.txt" | head -20 | sed 's/^/  /' || info "（无）"
grep -q "Service $SERVICE_NAME: found" "$ARTIFACT_DIR/L2_service_check.txt" \
  || fail "enforcing 下未正命中：$(cat "$ARTIFACT_DIR/L2_service_check.txt")"
# 关键：看的是 ps -Z 的**上下文列**（第一列），不是进程名列。
# T-006 的 v3 与本次 L2 第一版都栽在"名字出现在输出里就算命中"这种假阳性上，这里显式收紧成三条独立检查。
grep -qE "^u:r:${DOMAIN_NAME}:s0[[:space:]]" "$ARTIFACT_DIR/L2_ps.txt" \
  || fail "进程上下文不是 u:r:${DOMAIN_NAME}:s0（L2_ps.txt 首行：$(head -1 "$ARTIFACT_DIR/L2_ps.txt")）"
grep -qa "${DOMAIN_NAME}" "$ARTIFACT_DIR/policy_loaded.bin" 2>/dev/null \
  || fail "已加载策略里没有 ${DOMAIN_NAME}（load 未生效，不能算 enforcing 下合法注册）"
info "✅ enforcing 下注册成功，且进程上下文 = u:r:${DOMAIN_NAME}:s0（策略确已加载）"
write_status "L2_ENFORCING_REGISTERED"
write_summary
printf '\n✅ 全部通过（%ss）\n' "$(elapsed)"
