#!/usr/bin/env bash
# ci/verify-plugin-apk.sh v2 — T-eng-infra-013
# 相对 v1（011）的三处修复 + 真红机制：
#   (a) 克隆：不再用 `--filter=blob:none --sparse`（011 在 runner 上失败）→ 改为 `--depth=1` 普通克隆
#   (b) 目录：补 `mkdir -p plugin-res`（v1 漏了，heredoc 写清单直接失败）
#   (c) 前置：接口源码条数 == 0 时立即 fail，不再级联
#   真红：`set -euo pipefail` + fail() 非零退出 + 任何阶段失败都会让 job 红；INJECT_FAILURE=1 用于对照实验
set -euo pipefail

ARTIFACT_DIR="${ARTIFACT_DIR:-artifacts-plugin}"
mkdir -p "$ARTIFACT_DIR"
ARTIFACT_DIR="$(cd "$ARTIFACT_DIR" && pwd)"
SDK="${SDK:-/usr/local/lib/android/sdk}"
TAG="${TAG:-android-14.0.0_r1}"
MIRROR="${MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/git/AOSP/platform/frameworks/base}"
INJECT_FAILURE="${INJECT_FAILURE:-0}"
T0="$(date +%s)"

step() { printf '\n===== [%s +%ss] %s =====\n' "$(date -u +%H:%M:%S)" "$(( $(date +%s) - T0 ))" "$*"; }
info() { printf '  %s\n' "$*"; }
mark() { printf '%s\n' "$*" >> "$ARTIFACT_DIR/stages.log"; }
fail() { printf '\n!!!!! STAGE_FAIL: %s\n' "$*" >&2; mark "FAIL_REASON: $*"; printf 'VERDICT=FAILED\n' >> "$ARTIFACT_DIR/verdict.txt"; exit 1; }
trap 'printf "\n!! 第 %s 行非预期退出（exit=%s）\n" "$LINENO" "$?" >&2' ERR

step "0. 对照注入检查（INJECT_FAILURE=$INJECT_FAILURE）"
if [ "$INJECT_FAILURE" = "1" ]; then
  mark "INJECTED_FAILURE"
  fail "对照用：这是为了证明『任何阶段失败都会让 job 真红』而故意注入的失败"
fi

step "1. 克隆 frameworks/base（--depth=1 普通克隆；修复 (a)）"
SECONDS=0
git clone --quiet --depth=1 -b "$TAG" "$MIRROR" base > "$ARTIFACT_DIR/clone.log" 2>&1 || fail "克隆 frameworks/base 失败（见 clone.log）"
info "clone 耗时 = ${SECONDS}s ; 体积 = $(du -sh base | cut -f1)"
du -sh base | tee "$ARTIFACT_DIR/base_size.txt"
mark "STAGE1_OK clone_s=${SECONDS} size=$(du -sh base | cut -f1)"

step "2. SDK 组件（build-tools / android-34）"
export PATH="$SDK/cmdline-tools/latest/bin:$SDK/platform-tools:$PATH"
yes | sdkmanager --licenses >/dev/null 2>&1 || true
[ -d "$SDK/build-tools/34.0.0" ] || sdkmanager "build-tools;34.0.0" > "$ARTIFACT_DIR/sdk.log" 2>&1 || fail "装 build-tools 失败"
[ -f "$SDK/platforms/android-34/android.jar" ] || sdkmanager "platforms;android-34" > "$ARTIFACT_DIR/sdk2.log" 2>&1 || fail "装 android-34 失败"
BT="$(ls "$SDK/build-tools" | sort -V | tail -1)"; AJ="$SDK/platforms/android-34/android.jar"
info "build-tools=$BT"; info "android.jar=$AJ"
mark "STAGE2_OK bt=$BT"

step "3. 接口源码 → javac → jar（修复 (c)：0 个源文件必须红）"
# ① 源文件清单（只留实现真正需要的契约；**(c) 去掉 QS.java**——它多带依赖，我们只用 QSFactory/QSTile/QSTileView/QSIconView）
{
  echo base/packages/SystemUI/plugin_core/src/com/android/systemui/plugins/Plugin.java
  find base/packages/SystemUI/plugin_core/src/com/android/systemui/plugins/annotations -name '*.java'
  echo base/packages/SystemUI/plugin/src/com/android/systemui/plugins/qs/QSFactory.java
  echo base/packages/SystemUI/plugin/src/com/android/systemui/plugins/qs/QSTile.java
  echo base/packages/SystemUI/plugin/src/com/android/systemui/plugins/qs/QSTileView.java
  echo base/packages/SystemUI/plugin/src/com/android/systemui/plugins/qs/QSIconView.java
  echo base/packages/SystemUI/plugin/src/com/android/systemui/plugins/FragmentBase.java
} > "$ARTIFACT_DIR/iface_sources.txt"
# ② 编译期桩（**(a)(b)**：全部 public；只为过 javac —— 运行期仍解析到设备上的真类）
mkdir -p stubs/android/annotation stubs/android/metrics stubs/androidx/annotation stubs/com/android/internal/logging
cat > stubs/android/annotation/NonNull.java <<'JAVA'
package android.annotation;
import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;
@Retention(RetentionPolicy.CLASS)
@Target({ElementType.METHOD, ElementType.PARAMETER, ElementType.FIELD, ElementType.LOCAL_VARIABLE})
public @interface NonNull {}
JAVA
cat > stubs/android/annotation/Nullable.java <<'JAVA'
package android.annotation;
import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;
@Retention(RetentionPolicy.CLASS)
@Target({ElementType.METHOD, ElementType.PARAMETER, ElementType.FIELD, ElementType.LOCAL_VARIABLE})
public @interface Nullable {}
JAVA
cat > stubs/android/metrics/LogMaker.java <<'JAVA'
package android.metrics;
/** 编译期桩：QSTile 只在签名/常量里用到它。 */
public final class LogMaker {
    public LogMaker(int category) {}
    public LogMaker setSubtype(int subtype) { return this; }
    public LogMaker addTaggedData(int tag, Object value) { return this; }
}
JAVA
cat > stubs/androidx/annotation/Nullable.java <<'JAVA'
package androidx.annotation;
public @interface Nullable {}
JAVA
cat > stubs/androidx/annotation/FloatRange.java <<'JAVA'
package androidx.annotation;
public @interface FloatRange {
    double from() default -Double.MAX_VALUE;
    double to() default Double.MAX_VALUE;
}
JAVA
cat > stubs/com/android/internal/logging/InstanceId.java <<'JAVA'
package com.android.internal.logging;
public final class InstanceId {
    public static InstanceId create() { throw new UnsupportedOperationException("compile-time stub"); }
    public long getId() { throw new UnsupportedOperationException("compile-time stub"); }
}
JAVA
find stubs -name '*.java' >> "$ARTIFACT_DIR/iface_sources.txt"
sort -u "$ARTIFACT_DIR/iface_sources.txt" -o "$ARTIFACT_DIR/iface_sources.txt"
find stubs -name '*.java' | while read -r f; do printf '%s  %s 行\n' "$f" "$(wc -l < "$f")"; done | tee "$ARTIFACT_DIR/stubs.txt"
N="$(wc -l < "$ARTIFACT_DIR/iface_sources.txt")"
info "接口源文件数 = $N"
[ "$N" -gt 0 ] || fail "接口源文件数为 0（修复 (c)：此处必须红，不得级联）"
mkdir -p out-iface
javac -nowarn -d out-iface -cp "$AJ" @"$ARTIFACT_DIR/iface_sources.txt" > "$ARTIFACT_DIR/javac_iface.log" 2>&1 \
  || { grep 'error:' "$ARTIFACT_DIR/javac_iface.log" | head -8 | sed 's/^/    /'; fail "接口 javac 失败（原始错误见 javac_iface.log）"; }
info "接口 javac OK，class 数 = $(find out-iface -name '*.class' | wc -l)"
( cd out-iface && jar cf "$ARTIFACT_DIR/systemui-plugin-interfaces.jar" . )
info "接口 jar = $(stat -c%s "$ARTIFACT_DIR/systemui-plugin-interfaces.jar") B"
mark "STAGE3_OK iface_java=$N jar=$(stat -c%s "$ARTIFACT_DIR/systemui-plugin-interfaces.jar")"

step "4. 生成实现与清单（修复 (b)：mkdir -p plugin-res）"
mkdir -p plugin-src/com/zeroaosp/plugin/qs plugin-res
grep -o 'com\.android\.systemui\.action\.PLUGIN_[A-Z_]*' base/packages/SystemUI/plugin/ExamplePlugin/AndroidManifest.xml 2>/dev/null | sort -u | tee "$ARTIFACT_DIR/example_manifest_actions.txt" || true
grep -h 'createTile\|createTileView' base/packages/SystemUI/plugin/src/com/android/systemui/plugins/qs/QSFactory.java | tee "$ARTIFACT_DIR/qsfactory_methods.txt"
cat > plugin-src/com/zeroaosp/plugin/qs/ZeroAospQsFactory.java <<'JAVA'
package com.zeroaosp.plugin.qs;

import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.os.IBinder;
import android.util.Log;
import com.android.systemui.plugins.annotations.ProvidesInterface;
import com.android.systemui.plugins.qs.QSFactory;
import com.android.systemui.plugins.qs.QSTile;
import com.android.systemui.plugins.qs.QSTileView;

/**
 * zeroaosp M2 插件：QS 磁贴工厂（实现宿主既有契约，不改宿主一行）。
 * 必须 extends Service：宿主用 queryIntentServices(action) 发现插件（PluginActionManager:250-257），
 * 清单里对应 <service> + <intent-filter>，不是 meta-data。
 */
@ProvidesInterface(action = QSFactory.ACTION, version = QSFactory.VERSION)
public class ZeroAospQsFactory extends Service implements QSFactory {
    public static final String TAG = "DshQsTile";

    public ZeroAospQsFactory() {
        Log.i(TAG, "slot state=PLUGIN_LOADED cls=" + getClass().getName());
    }

    @Override
    public IBinder onBind(Intent intent) {
        Log.i(TAG, "slot state=PLUGIN_LOADED onBind action=" + (intent == null ? "null" : intent.getAction()));
        return null;
    }

    @Override
    public void onCreate() {
        super.onCreate();
        Log.i(TAG, "slot state=PLUGIN_LOADED onCreate");
    }

    @Override
    public QSTile createTile(String tileSpec) {
        Log.i(TAG, "slot state=PLUGIN_FILLED tileSpec=" + tileSpec);
        return null;
    }

    @Override
    public QSTileView createTileView(Context context, QSTile tile, boolean collapsedView) {
        return null;
    }

    public int getVersion() { return QSFactory.VERSION; }
}
JAVA
cat > plugin-res/AndroidManifest.xml <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.zeroaosp.plugin">
    <uses-permission android:name="com.android.systemui.permission.PLUGIN" />
    <application android:label="zeroaosp QS plugin">
        <service android:name="com.zeroaosp.plugin.qs.ZeroAospQsFactory"
                 android:exported="false">
            <intent-filter>
                <action android:name="com.android.systemui.action.PLUGIN_QS_FACTORY" />
            </intent-filter>
        </service>
    </application>
</manifest>
XML
mark "STAGE4_OK"

step "5. javac 实现 → d8"
mkdir -p out-classes out-dex
javac -nowarn -d out-classes -cp "$AJ:$ARTIFACT_DIR/systemui-plugin-interfaces.jar" $(find plugin-src -name '*.java') > "$ARTIFACT_DIR/javac_impl.log" 2>&1 \
  || { grep 'error:' "$ARTIFACT_DIR/javac_impl.log" | head -10 | sed 's/^/    /'; fail "实现 javac 失败（原始错误见 javac_impl.log）"; }
info "实现 javac OK"
find out-classes -name '*.class' > "$ARTIFACT_DIR/impl_classes.txt"
"$SDK/build-tools/$BT/d8" --min-api 26 --output out-dex @"$ARTIFACT_DIR/impl_classes.txt" > "$ARTIFACT_DIR/d8.log" 2>&1 \
  || { tail -8 "$ARTIFACT_DIR/d8.log" | sed 's/^/    /'; fail "d8 失败（原始输出见 d8.log）"; }
info "d8 OK：classes.dex $(stat -c%s out-dex/classes.dex) B"
mark "STAGE5_OK dex=$(stat -c%s out-dex/classes.dex)"

step "6. aapt2 → zipalign → 签名"
mkdir -p out-apk
"$SDK/build-tools/$BT/aapt2" link -o out-apk/unsigned.apk --manifest plugin-res/AndroidManifest.xml \
  --min-sdk-version 26 --target-sdk-version 34 -I "$AJ" > "$ARTIFACT_DIR/aapt2.log" 2>&1 \
  || { tail -8 "$ARTIFACT_DIR/aapt2.log" | sed 's/^/    /'; fail "aapt2 link 失败"; }
# aapt2 不打包 dex：classes.dex 要用 zip 塞进 APK（标准做法；上一轮传目录导致 "Is a directory"）
( cd out-dex && zip -q -j ../out-apk/unsigned.apk classes.dex ) || fail "把 classes.dex 塞进 APK 失败"
info "aapt2 link + dex 打包 OK：$(stat -c%s out-apk/unsigned.apk) B"
KS="$ARTIFACT_DIR/debug.keystore"
keytool -genkeypair -keystore "$KS" -storepass android -keypass android -alias androiddebugkey \
  -dname "CN=Android Debug,O=Android,C=US" -keyalg RSA -keysize 2048 -validity 10000 > "$ARTIFACT_DIR/keytool.log" 2>&1 \
  || fail "生成 debug keystore 失败"
"$SDK/build-tools/$BT/zipalign" -f 4 out-apk/unsigned.apk out-apk/aligned.apk > "$ARTIFACT_DIR/zipalign.log" 2>&1 \
  || fail "zipalign 失败"
"$SDK/build-tools/$BT/apksigner" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android \
  --out "$ARTIFACT_DIR/zeroaosp-qs-plugin.apk" out-apk/aligned.apk > "$ARTIFACT_DIR/apksigner.log" 2>&1 \
  || { tail -8 "$ARTIFACT_DIR/apksigner.log" | sed 's/^/    /'; fail "apksigner 签名失败"; }
info "APK = $(stat -c%s "$ARTIFACT_DIR/zeroaosp-qs-plugin.apk") B"
sha256sum "$ARTIFACT_DIR/zeroaosp-qs-plugin.apk" | tee "$ARTIFACT_DIR/apk.sha256"
"$SDK/build-tools/$BT/aapt2" dump badging "$ARTIFACT_DIR/zeroaosp-qs-plugin.apk" 2>/dev/null | head -4 | tee "$ARTIFACT_DIR/apk_badging.txt" || true
"$SDK/build-tools/$BT/apksigner" verify --print-certs "$ARTIFACT_DIR/zeroaosp-qs-plugin.apk" 2>/dev/null | head -3 | tee "$ARTIFACT_DIR/apk_certs.txt" || true
mark "STAGE6_OK"
printf 'VERDICT=BUILD_OK\n' >> "$ARTIFACT_DIR/verdict.txt"

step "6b. 实机仪器化：两时机 × 5 产物 + exported 变体（T-021）"
APK="$ARTIFACT_DIR/zeroaosp-qs-plugin.apk"
if [ ! -f "$APK" ]; then
  info "APK 不存在 → 跳过实机"; mark "STAGE6B_SKIPPED_NO_APK"
else
  sudo chmod 666 /dev/kvm || fail "KVM 权限失败"
  # T-022：换**完整系统镜像**（ATD 无 SystemUI）；候选按序尝试，谁先装上用谁
  IMAGE=""
  for cand in "system-images;android-34;google_apis;x86_64" "system-images;android-34;default;x86_64" "system-images;android-33;google_apis;x86_64" "system-images;android-34;aosp_atd;x86_64"; do
    info "尝试镜像：$cand"
    if sdkmanager "platform-tools" "emulator" "$cand" > "$ARTIFACT_DIR/sdk_dev_$(echo "$cand" | tr ';' '_').log" 2>&1; then
      IMAGE="$cand"; printf 'IMAGE_USED=%s\n' "$cand" > "$ARTIFACT_DIR/image_used.txt"; info "== 采用镜像：$cand"; break
    fi
  done
  [ -n "$IMAGE" ] || fail "所有候选镜像都装不上"
  cat "$ARTIFACT_DIR/image_used.txt"
  ADB="$SDK/platform-tools/adb"
  EMU_BIN="$(command -v emulator || find "$SDK" -maxdepth 3 -type f -name emulator | head -1)"
  ( echo no | avdmanager create avd --force -n nag -k "$IMAGE" --device pixel_5 ) >/dev/null 2>&1 || true
  nohup "$EMU_BIN" -avd nag -no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader_indirect -memory 3072 -cores 2 > "$ARTIFACT_DIR/emulator.log" 2>&1 &
  sleep 20; "$ADB" start-server >/dev/null 2>&1 || true; timeout 120 "$ADB" wait-for-device || true
  wait_boot() { local b=""; for i in $(seq 1 45); do b="$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')"; [ "$b" = "1" ] && return 0; sleep 10; done; return 1; }
  wait_boot || fail "模拟器未启动完成"
  # T-022 硬门槛：SystemUI 必须在场，否则不许进入插件观测（三条命令任一有输出即可）
  SUB=""
  "$ADB" shell ps -A | grep -i systemui > "$ARTIFACT_DIR/systemui_presence_ps.txt" 2>&1
  [ -s "$ARTIFACT_DIR/systemui_presence_ps.txt" ] && SUB="ps -A"
  "$ADB" shell dumpsys activity services | grep -i systemui > "$ARTIFACT_DIR/systemui_presence_dumpsys.txt" 2>&1
  [ -n "$SUB" ] || { [ -s "$ARTIFACT_DIR/systemui_presence_dumpsys.txt" ] && SUB="dumpsys activity services"; }
  "$ADB" shell service list | grep -i statusbar > "$ARTIFACT_DIR/systemui_presence_servicelist.txt" 2>&1
  [ -n "$SUB" ] || { [ -s "$ARTIFACT_DIR/systemui_presence_servicelist.txt" ] && SUB="service list|statusbar"; }
  info "SystemUI 在场证明：来源 = $SUB"
  head -3 "$ARTIFACT_DIR/systemui_presence_ps.txt" | sed 's/^/    /'
  head -3 "$ARTIFACT_DIR/systemui_presence_servicelist.txt" | sed 's/^/    /'
  printf 'SYSTEMUI_PRESENT_VIA=%s\n' "$SUB" >> "$ARTIFACT_DIR/verdict.txt"
  [ -n "$SUB" ] || fail "SystemUI 不在场（三条命令全空）→ 按 T-022 硬门槛不许进入插件观测；镜像=$(cat "$ARTIFACT_DIR/image_used.txt")"
  "$ADB" shell getprop ro.build.type | tee "$ARTIFACT_DIR/build_type.txt"
  # 每时机固定 5 个产物
  collect() {
    t="$1"
    "$ADB" logcat -d -v time > "$ARTIFACT_DIR/logcat_full_$t.txt" 2>&1 || true
    grep -iE "PluginManager|PluginActionManager|Found .*plugins|zeroaosp|DshQsTile" "$ARTIFACT_DIR/logcat_full_$t.txt" > "$ARTIFACT_DIR/logcat_filtered_$t.txt" 2>&1 || true
    "$ADB" shell dumpsys package com.zeroaosp.plugin > "$ARTIFACT_DIR/dumpsys_package_$t.txt" 2>&1 || true
    "$ADB" shell cmd package query-services -a com.android.systemui.action.PLUGIN_QS_FACTORY > "$ARTIFACT_DIR/query_services_$t.txt" 2>&1 \
      || "$ADB" shell pm query-services -a com.android.systemui.action.PLUGIN_QS_FACTORY > "$ARTIFACT_DIR/query_services_$t.txt" 2>&1 || true
    "$ADB" shell ps -A | grep -i systemui > "$ARTIFACT_DIR/ps_systemui_$t.txt" 2>&1 || true
    info "[$t] 产物行数：full=$(wc -l < "$ARTIFACT_DIR/logcat_full_$t.txt") filtered=$(wc -l < "$ARTIFACT_DIR/logcat_filtered_$t.txt") query=$(wc -l < "$ARTIFACT_DIR/query_services_$t.txt") ps=$(wc -l < "$ARTIFACT_DIR/ps_systemui_$t.txt")"
    info "[$t] query_services 原文："; head -5 "$ARTIFACT_DIR/query_services_$t.txt" | sed 's/^/    /'
    info "[$t] DshQsTile 命中行："; grep -i 'DshQsTile' "$ARTIFACT_DIR/logcat_filtered_$t.txt" | head -5 | sed 's/^/    /' || true
    info "[$t] PluginActionManager 命中行："; grep -i 'PluginActionManager\|Found .*plugins' "$ARTIFACT_DIR/logcat_filtered_$t.txt" | head -8 | sed 's/^/    /' || true
  }
  "$ADB" logcat -c >/dev/null 2>&1 || true; sleep 5
  collect negative
  # (a) 装 → 重启 → 采集
  "$ADB" install -r -g "$APK" > "$ARTIFACT_DIR/adb_install_a.txt" 2>&1
  cat "$ARTIFACT_DIR/adb_install_a.txt" | sed 's/^/    /'
  "$ADB" reboot >/dev/null 2>&1 || true; sleep 30; "$ADB" wait-for-device || true; wait_boot || true; sleep 25
  collect a
  # (b) 覆盖安装（触发 PACKAGE_REPLACED，不重启）→ 采集
  "$ADB" logcat -c >/dev/null 2>&1 || true
  "$ADB" install -r -g "$APK" > "$ARTIFACT_DIR/adb_install_b.txt" 2>&1
  cat "$ARTIFACT_DIR/adb_install_b.txt" | sed 's/^/    /'
  "$ADB" shell am broadcast -a android.intent.action.PACKAGE_ADDED -d package:com.zeroaosp.plugin > "$ARTIFACT_DIR/trigger_b.txt" 2>&1 || true
  "$ADB" shell cmd package compile -f -m speed com.zeroaosp.plugin >> "$ARTIFACT_DIR/trigger_b.txt" 2>&1 || true
  sleep 30
  collect b
  # exported=true 变体：同 run 内现场重打一个 APK 并覆盖安装对照
  sed 's/android:exported="false"/android:exported="true"/' plugin-res/AndroidManifest.xml > plugin-res/AndroidManifest.exp.xml
  "$SDK/build-tools/$BT/aapt2" link -o out-apk/unsigned-exp.apk --manifest plugin-res/AndroidManifest.exp.xml \
    --min-sdk-version 26 --target-sdk-version 34 -I "$AJ" > "$ARTIFACT_DIR/aapt2_exp.log" 2>&1 \
    && ( cd out-dex && zip -q -j ../out-apk/unsigned-exp.apk classes.dex ) \
    && "$SDK/build-tools/$BT/zipalign" -f 4 out-apk/unsigned-exp.apk out-apk/aligned-exp.apk > /dev/null 2>&1 \
    && "$SDK/build-tools/$BT/apksigner" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android \
         --out "$ARTIFACT_DIR/zeroaosp-qs-plugin-exp.apk" out-apk/aligned-exp.apk > "$ARTIFACT_DIR/apksigner_exp.log" 2>&1 \
    || info "（exported 变体打包失败，见 aapt2_exp.log）"
  if [ -f "$ARTIFACT_DIR/zeroaosp-qs-plugin-exp.apk" ]; then
    "$ADB" logcat -c >/dev/null 2>&1 || true
    "$ADB" install -r -g "$ARTIFACT_DIR/zeroaosp-qs-plugin-exp.apk" > "$ARTIFACT_DIR/adb_install_exp.txt" 2>&1
    cat "$ARTIFACT_DIR/adb_install_exp.txt" | sed 's/^/    /'
    "$ADB" shell am broadcast -a android.intent.action.PACKAGE_REPLACED -d package:com.zeroaosp.plugin >> "$ARTIFACT_DIR/trigger_b.txt" 2>&1 || true
    sleep 30
    collect exp
    sha256sum "$ARTIFACT_DIR/zeroaosp-qs-plugin-exp.apk" | tee "$ARTIFACT_DIR/apk_exp.sha256"
  fi
  "$ADB" exec-out screencap -p > "$ARTIFACT_DIR/screen.png" 2>/dev/null || true
  info "截图 → $ARTIFACT_DIR/screen.png（**辅助、M1 未落证通道**）"
  # T-022 探针（这一段用 set +e 包住：探针是取证，不让单条命令的失败中断取证；构建段的红灯纪律不变）
  set +e
  "$ADB" shell settings list secure > "$ARTIFACT_DIR/probe_secure_all.txt" 2>&1
  grep -i 'plugin' "$ARTIFACT_DIR/probe_secure_all.txt" > "$ARTIFACT_DIR/probe_plugin_enabler.txt" 2>&1
  SPID="$("$ADB" shell pidof com.android.systemui 2>/dev/null | tr -d '\r' | awk '{print $1}')"
  info "SystemUI pid = '$SPID'"
  "$ADB" shell logcat -d -v time > "$ARTIFACT_DIR/probe_logcat_all.txt" 2>&1
  if [ -n "$SPID" ]; then
    grep -E "\( *$SPID\)" "$ARTIFACT_DIR/probe_logcat_all.txt" > "$ARTIFACT_DIR/probe_systemui_log.txt" 2>&1
  else
    grep -iE 'SystemUI' "$ARTIFACT_DIR/probe_logcat_all.txt" > "$ARTIFACT_DIR/probe_systemui_log.txt" 2>&1
  fi
  grep -i 'plugin' "$ARTIFACT_DIR/probe_logcat_all.txt" > "$ARTIFACT_DIR/probe_plugin_all.txt" 2>&1
  "$ADB" shell dumpsys package com.zeroaosp.plugin > "$ARTIFACT_DIR/probe_pkg_state.txt" 2>&1
  "$ADB" shell cmd package resolve-service -a com.android.systemui.action.PLUGIN_QS_FACTORY --brief > "$ARTIFACT_DIR/probe_resolve.txt" 2>&1
  set -e
  info "探针行数：enabler=$(wc -l < "$ARTIFACT_DIR/probe_plugin_enabler.txt") systemui_log=$(wc -l < "$ARTIFACT_DIR/probe_systemui_log.txt") plugin_all=$(wc -l < "$ARTIFACT_DIR/probe_plugin_all.txt") resolve=$(wc -l < "$ARTIFACT_DIR/probe_resolve.txt")"
  info "探针 secure-settings 里的 plugin 条目："; head -8 "$ARTIFACT_DIR/probe_plugin_enabler.txt" | sed 's/^/    /'
  info "探针 resolve-service："; head -5 "$ARTIFACT_DIR/probe_resolve.txt" | sed 's/^/    /'
  info "探针 SystemUI 日志里的插件相关行："; grep -im10 -E 'QSTileHost|PluginActionManager|PluginManager|PluginEnabler|addPluginListener|Found .*plugins|PluginInstance' "$ARTIFACT_DIR/probe_systemui_log.txt" | sed 's/^/    /'
  # T-023：平台签名豁免实验（AOSP **公开测试密钥**，CI 现场从公开源取，不入仓、不进回报正文）
  set +e
  mkdir -p pk
  GITSRC="https://android.googlesource.com/platform/build/+/refs/tags/android-14.0.0_r1/target/product/security"
  RAW="https://raw.githubusercontent.com/aosp-mirror/platform_build/android-14.0.0_r1/target/product/security"
  for f in platform.pk8 platform.x509.pem; do
    if curl -sSL -m 60 "$GITSRC/$f?format=TEXT" | base64 -d > "pk/$f" 2>>"$ARTIFACT_DIR/pk_fetch.log" && [ -s "pk/$f" ]; then
      info "取到 $f（googlesource）"
    else
      curl -sSL -m 60 "$RAW/$f" -o "pk/$f" 2>>"$ARTIFACT_DIR/pk_fetch.log" && info "取到 $f（aosp-mirror raw）" || info "取 $f 失败"
    fi
  done
  ls -l pk | sed 's/^/    /'
  openssl pkcs8 -inform DER -nocrypt -in pk/platform.pk8 -out pk/platform.pem 2>>"$ARTIFACT_DIR/pk_fetch.log"
  openssl pkcs12 -export -in pk/platform.x509.pem -inkey pk/platform.pem -out pk/platform.p12 -name platform -passout pass:android 2>>"$ARTIFACT_DIR/pk_fetch.log"
  set -e
  if [ -s pk/platform.p12 ]; then
    sha256sum pk/platform.p12 | tee "$ARTIFACT_DIR/p12.sha256"
    "$SDK/build-tools/$BT/apksigner" sign --ks pk/platform.p12 --ks-pass pass:android --ks-key-alias platform \
      --out "$ARTIFACT_DIR/zeroaosp-qs-plugin-platform.apk" out-apk/aligned.apk > "$ARTIFACT_DIR/apksigner_platform.log" 2>&1 \
      || info "（平台签名失败，见 apksigner_platform.log）"
    if [ -f "$ARTIFACT_DIR/zeroaosp-qs-plugin-platform.apk" ]; then
      sha256sum "$ARTIFACT_DIR/zeroaosp-qs-plugin-platform.apk" | tee "$ARTIFACT_DIR/apk_platform.sha256"
      "$SDK/build-tools/$BT/apksigner" verify --print-certs "$ARTIFACT_DIR/zeroaosp-qs-plugin-platform.apk" 2>&1 | tee "$ARTIFACT_DIR/apk_platform_certs.txt"
    fi
  else
    info "（p12 未生成，见 pk_fetch.log）"
  fi
  # 分水岭判据：设备侧 SystemUI 的签名指纹
  "$ADB" shell dumpsys package com.android.systemui > "$ARTIFACT_DIR/systemui_dumpsys.txt" 2>&1
  grep -iE 'signatures=|signingCertificate|Signing Certificate|SHA-256|digest|apkSigningVersion' "$ARTIFACT_DIR/systemui_dumpsys.txt" | head -12 | tee "$ARTIFACT_DIR/systemui_certs_dumpsys.txt"
  # T-024 稳妥取法：pull SystemUI.apk 后 apksigner verify --print-certs（不再用过宽 grep 当证书证据）
  SUIPATH="$("$ADB" shell pm path com.android.systemui 2>/dev/null | tr -d '\r' | sed 's/^package://' | head -1)"
  info "SystemUI apk 路径 = '$SUIPATH'"
  if [ -n "$SUIPATH" ]; then
    "$ADB" pull "$SUIPATH" "$ARTIFACT_DIR/SystemUI.apk" > "$ARTIFACT_DIR/pull_systemui.log" 2>&1 || info "（pull 失败，见 pull_systemui.log）"
  fi
  if [ -f "$ARTIFACT_DIR/SystemUI.apk" ]; then
    sha256sum "$ARTIFACT_DIR/SystemUI.apk" | tee "$ARTIFACT_DIR/systemui_apk.sha256"
    "$SDK/build-tools/$BT/apksigner" verify --print-certs "$ARTIFACT_DIR/SystemUI.apk" 2>&1 | tee "$ARTIFACT_DIR/systemui_certs.txt"
  else
    info "（SystemUI.apk 未拉到 → 证书指纹只能靠 dumpsys 段，见 systemui_certs_dumpsys.txt）"
  fi
  # 装平台签名插件 → 重启 → 采集
  if [ -f "$ARTIFACT_DIR/zeroaosp-qs-plugin-platform.apk" ]; then
    "$ADB" logcat -c >/dev/null 2>&1 || true
    # T-024：先卸载 debug 签名版，否则 INSTALL_FAILED_UPDATE_INCOMPATIBLE
    "$ADB" uninstall com.zeroaosp.plugin 2>&1 | tee "$ARTIFACT_DIR/adb_uninstall_before_platform.txt"
    "$ADB" install -r -g "$ARTIFACT_DIR/zeroaosp-qs-plugin-platform.apk" 2>&1 | tee "$ARTIFACT_DIR/adb_install_platform.txt"
    "$ADB" reboot >/dev/null 2>&1 || true; sleep 30; "$ADB" wait-for-device || true; wait_boot || true; sleep 25
    collect platform
    info "platform 采集：PluginActionManager 行 →"; grep -i 'PluginActionManager' "$ARTIFACT_DIR/logcat_filtered_platform.txt" | head -8 | sed 's/^/    /'
    info "platform 采集：DshQsTile 行 →"; grep -i 'DshQsTile' "$ARTIFACT_DIR/logcat_filtered_platform.txt" | head -8 | sed 's/^/    /'
    "$ADB" shell dumpsys package com.zeroaosp.plugin | grep -iE 'signature|permission|granted|PLUGIN|signatures' | head -12 | tee "$ARTIFACT_DIR/pkg_platform_perm.txt"
  fi
  mark "STAGE6C_OK"
  mark "STAGE6B_OK"
fi
printf '\n--- stages.log ---\n'; cat "$ARTIFACT_DIR/stages.log" | sed 's/^/  /'
printf '\n--- verdict.txt ---\n'; cat "$ARTIFACT_DIR/verdict.txt" | sed 's/^/  /'
printf '\n✅ APK 编译链全绿（%ss）\n' "$(( $(date +%s) - T0 ))"
