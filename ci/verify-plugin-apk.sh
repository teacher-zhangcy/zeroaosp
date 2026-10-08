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
# ① 收窄：只编「插件契约 + 注解 + qs 三个文件 + 隐藏 API 来源」
# ② 补隐藏 API：android.annotation.*（@Nullable 等）来自 base/core/java，其源码一起编进 classpath
{
  echo base/packages/SystemUI/plugin/src/com/android/systemui/plugins/Plugin.java
  find base/packages/SystemUI/plugin/src/com/android/systemui/plugins/annotations -name '*.java'
  find base/packages/SystemUI/plugin/src/com/android/systemui/plugins/qs -name '*.java'
  find base/core/java/android/annotation -name '*.java'
} | sort -u > "$ARTIFACT_DIR/iface_sources.txt"
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

import android.content.Context;
import android.util.Log;
import com.android.systemui.plugins.annotations.ProvidesInterface;
import com.android.systemui.plugins.qs.QSFactory;
import com.android.systemui.plugins.qs.QSTile;
import com.android.systemui.plugins.qs.QSTileView;

/** zeroaosp M2 插件：QS 磁贴工厂（实现宿主既有契约，不改宿主一行）。自报 tag=DshQsTile。 */
@ProvidesInterface(action = QSFactory.ACTION, version = QSFactory.VERSION)
public class ZeroAospQsFactory implements QSFactory {
    public static final String TAG = "DshQsTile";

    public ZeroAospQsFactory() {
        Log.i(TAG, "slot state=PLUGIN_LOADED cls=" + getClass().getName());
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
    <application android:label="zeroaosp QS plugin">
        <meta-data android:name="com.android.systemui.action.PLUGIN_QS_FACTORY"
            android:value="com.zeroaosp.plugin.qs.ZeroAospQsFactory" />
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
  --min-sdk-version 26 --target-sdk-version 34 -I "$AJ" out-dex > "$ARTIFACT_DIR/aapt2.log" 2>&1 \
  || { tail -8 "$ARTIFACT_DIR/aapt2.log" | sed 's/^/    /'; fail "aapt2 link 失败"; }
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

step "7. 小结"
printf '\n--- stages.log ---\n'; cat "$ARTIFACT_DIR/stages.log" | sed 's/^/  /'
printf '\n--- verdict.txt ---\n'; cat "$ARTIFACT_DIR/verdict.txt" | sed 's/^/  /'
printf '\n✅ APK 编译链全绿（%ss）\n' "$(( $(date +%s) - T0 ))"
