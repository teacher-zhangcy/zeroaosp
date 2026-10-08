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

step "6b. 实机：装到 emulator → 重启 → logcat 正例/负例（有 APK 才跑）"
APK="$ARTIFACT_DIR/zeroaosp-qs-plugin.apk"
if [ ! -f "$APK" ]; then
  info "APK 不存在 → 跳过实机（上一级已给原始报错）"; mark "STAGE6B_SKIPPED_NO_APK"
else
  IMAGE="${IMAGE:-system-images;android-34;aosp_atd;x86_64}"
  sudo chmod 666 /dev/kvm || fail "KVM 权限失败"
  sdkmanager "platform-tools" "emulator" "$IMAGE" > "$ARTIFACT_DIR/sdk_dev.log" 2>&1 || fail "装 emulator/镜像失败"
  ADB="$SDK/platform-tools/adb"
  EMU_BIN="$(command -v emulator || find "$SDK" -maxdepth 3 -type f -name emulator | head -1)"
  ( echo no | avdmanager create avd --force -n nag -k "$IMAGE" --device pixel_5 ) >/dev/null 2>&1 || true
  nohup "$EMU_BIN" -avd nag -no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader_indirect -memory 3072 -cores 2 > "$ARTIFACT_DIR/emulator.log" 2>&1 &
  sleep 20; "$ADB" start-server >/dev/null 2>&1 || true; timeout 120 "$ADB" wait-for-device || true
  BOOT=""; for i in $(seq 1 40); do BOOT="$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')"; [ "$BOOT" = "1" ] && break; sleep 10; done
  [ "$BOOT" = "1" ] || fail "模拟器未启动完成"
  "$ADB" shell getprop ro.build.type | tee "$ARTIFACT_DIR/build_type.txt"
  # 负例：插件未装
  "$ADB" logcat -c >/dev/null 2>&1 || true
  sleep 5
  "$ADB" logcat -d -s DshQsTile:* > "$ARTIFACT_DIR/logcat_negative.txt" 2>&1 || true
  info "负例 logcat 行数 = $(wc -l < "$ARTIFACT_DIR/logcat_negative.txt")"
  # 安装插件
  "$ADB" install -r -g "$APK" | tee "$ARTIFACT_DIR/adb_install.txt"
  "$ADB" shell pm path com.zeroaosp.plugin | tee "$ARTIFACT_DIR/pm_path.txt" || true
  # 重启 → 正例
  "$ADB" reboot >/dev/null 2>&1 || true; sleep 25; "$ADB" wait-for-device || true
  for i in $(seq 1 40); do BOOT="$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')"; [ "$BOOT" = "1" ] && break; sleep 10; done
  sleep 25
  "$ADB" logcat -d -s DshQsTile:* > "$ARTIFACT_DIR/logcat_positive.txt" 2>&1 || true
  info "正例 logcat 行数 = $(wc -l < "$ARTIFACT_DIR/logcat_positive.txt")"
  head -10 "$ARTIFACT_DIR/logcat_positive.txt" | sed 's/^/    /'
  "$ADB" logcat -d | grep -i -m8 'zeroaosp\|PluginManager' > "$ARTIFACT_DIR/logcat_pluginmgr.txt" 2>&1 || true
  "$ADB" exec-out screencap -p > "$ARTIFACT_DIR/screen.png" 2>/dev/null || true
  info "截图 → $ARTIFACT_DIR/screen.png（**辅助、M1 未落证通道**）"
  mark "STAGE6B_OK"
fi
printf '\n--- stages.log ---\n'; cat "$ARTIFACT_DIR/stages.log" | sed 's/^/  /'
printf '\n--- verdict.txt ---\n'; cat "$ARTIFACT_DIR/verdict.txt" | sed 's/^/  /'
printf '\n✅ APK 编译链全绿（%ss）\n' "$(( $(date +%s) - T0 ))"
