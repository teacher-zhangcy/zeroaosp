#!/usr/bin/env bash
# ci/verify-plugin-apk.sh — T-eng-infra-011 ①②：不建全树，能不能编出 QSFactory 插件 APK
# 做法：sparse 取 base 的 SystemUI 插件接口源码（几 MB）→ javac 接口 → 试编实现 → d8/aapt2/签名
# 每段都把原始输出落进 artifact；失败不抛栈，按段记录（便于对号 R-a…R-d）
set -uo pipefail
ARTIFACT_DIR="${ARTIFACT_DIR:-artifacts-plugin}"
mkdir -p "$ARTIFACT_DIR"; ARTIFACT_DIR="$(cd "$ARTIFACT_DIR" && pwd)"
SDK="${SDK:-/usr/local/lib/android/sdk}"
TAG="${TAG:-android-14.0.0_r1}"
MIRROR="${MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/git/AOSP/platform/frameworks/base}"
step(){ printf '\n===== [%s] %s =====\n' "$(date -u +%H:%M:%S)" "$*"; }
info(){ printf '  %s\n' "$*"; }
mark(){ printf '%s\n' "$*" >> "$ARTIFACT_DIR/stages.log"; }
T0=$(date +%s)

step "1. sparse 取 SystemUI 插件接口源码（blob:none，只取两个子目录）"
if git clone --quiet --filter=blob:none --sparse --depth=1 -b "$TAG" "$MIRROR" base > "$ARTIFACT_DIR/clone.log" 2>&1; then
  git -C base sparse-checkout set packages/SystemUI/plugin packages/SystemUI/src/com/android/systemui/qs >> "$ARTIFACT_DIR/clone.log" 2>&1
  info "clone OK：$(du -sh base | cut -f1)（全克隆要 2.6 GB）"
  mark "STAGE1_OK $(du -sh base | cut -f1)"
else
  info "clone 失败（见 clone.log）"; mark "STAGE1_FAIL"; tail -3 "$ARTIFACT_DIR/clone.log" | sed 's/^/    /'
fi
ls base/packages/SystemUI/plugin/src/com/android/systemui/plugins/qs/ 2>/dev/null | tee "$ARTIFACT_DIR/qs_iface_files.txt"

step "2. SDK 组件（build-tools + android-34 platform）"
export PATH="$SDK/cmdline-tools/latest/bin:$SDK/platform-tools:$PATH"
yes | sdkmanager --licenses >/dev/null 2>&1 || true
[ -d "$SDK/build-tools/34.0.0" ] || sdkmanager "build-tools;34.0.0" > "$ARTIFACT_DIR/sdk.log" 2>&1 || true
[ -f "$SDK/platforms/android-34/android.jar" ] || sdkmanager "platforms;android-34" > "$ARTIFACT_DIR/sdk2.log" 2>&1 || true
BT="$(ls "$SDK/build-tools" 2>/dev/null | sort -V | tail -1)"
AJ="$SDK/platforms/android-34/android.jar"
info "build-tools=$BT"; info "android.jar=$AJ"
mark "STAGE2 aj=$([ -f "$AJ" ] && echo yes || echo no) bt=$BT"

step "3. javac 接口源码（候选甲的第一半：接口能不能单独编出来）"
mkdir -p out-iface
find base/packages/SystemUI/plugin/src -name '*.java' > "$ARTIFACT_DIR/iface_sources.txt"
info "接口源文件数 = $(wc -l < "$ARTIFACT_DIR/iface_sources.txt")"
if javac -nowarn -d out-iface -cp "$AJ" @<(cat "$ARTIFACT_DIR/iface_sources.txt") > "$ARTIFACT_DIR/javac_iface.log" 2>&1; then
  info "接口 javac OK（class 数 = $(find out-iface -name '*.class' | wc -l)）"; mark "STAGE3_OK classes=$(find out-iface -name '*.class' | wc -l)"
  ( cd out-iface && jar cf "$ARTIFACT_DIR/systemui-plugin-interfaces.jar" . ) && info "接口 jar = $(stat -c%s "$ARTIFACT_DIR/systemui-plugin-interfaces.jar") B"
else
  info "接口 javac 失败，错误行数 = $(grep -c 'error:' "$ARTIFACT_DIR/javac_iface.log" || echo 0)"
  grep 'error:' "$ARTIFACT_DIR/javac_iface.log" | head -8 | sed 's/^/    /'
  mark "STAGE3_FAIL errors=$(grep -c 'error:' "$ARTIFACT_DIR/javac_iface.log" || echo 0)"
fi

step "4. 生成插件实现 + 清单（附：AOSP 模板 ExamplePlugin 的元数据口径）"
mkdir -p plugin-src/com/zeroaosp/plugin/qs
grep -o 'com\.android\.systemui\.action\.PLUGIN_[A-Z_]*' base/packages/SystemUI/plugin/ExamplePlugin/AndroidManifest.xml 2>/dev/null | sort -u | tee "$ARTIFACT_DIR/example_manifest_actions.txt"
grep -h 'createTile\|createTileView' base/packages/SystemUI/plugin/src/com/android/systemui/plugins/qs/QSFactory.java | tee "$ARTIFACT_DIR/qsfactory_methods.txt"
cat > plugin-src/com/zeroaosp/plugin/qs/ZeroAospQsFactory.java <<'JAVA'
package com.zeroaosp.plugin.qs;

import android.content.Context;
import com.android.systemui.plugins.annotations.ProvidesInterface;
import com.android.systemui.plugins.qs.QSFactory;
import com.android.systemui.plugins.qs.QSTile;
import com.android.systemui.plugins.qs.QSTileView;

/** zeroaosp M2 插件：QS 磁贴工厂（实现宿主既有的 QSFactory 契约，不改宿主一行）。 */
@ProvidesInterface(action = QSFactory.ACTION, version = QSFactory.VERSION)
public class ZeroAospQsFactory implements QSFactory {
    @Override
    public QSTile createTile(String tileSpec) {
        return null;   // 骨架：M2 后续接真实 tile
    }

    @Override
    public QSTileView createTileView(Context context, QSTile tile, boolean collapsedView) {
        return null;   // 骨架：M2 后续接真实 view
    }

    public int getVersion() {
        return QSFactory.VERSION;
    }
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

step "5. javac 实现 → d8 dex"
mkdir -p out-classes out-dex
if javac -nowarn -d out-classes -cp "$AJ:$ARTIFACT_DIR/systemui-plugin-interfaces.jar" $(find plugin-src -name '*.java') > "$ARTIFACT_DIR/javac_impl.log" 2>&1; then
  info "实现 javac OK"; mark "STAGE5_JAVAC_OK"
else
  info "实现 javac 失败（错误行数 $(grep -c 'error:' "$ARTIFACT_DIR/javac_impl.log" || echo 0)）"
  grep 'error:' "$ARTIFACT_DIR/javac_impl.log" | head -10 | sed 's/^/    /'; mark "STAGE5_JAVAC_FAIL"
fi
if [ -d out-classes ] && [ -n "$(find out-classes -name '*.class' | head -1)" ]; then
  "$SDK/build-tools/$BT/d8" --min-api 26 --output out-dex $(find out-classes -name '*.class') > "$ARTIFACT_DIR/d8.log" 2>&1 \
    && { info "d8 OK：$(ls -l out-dex/classes.dex | awk '{print $5}') B"; mark "STAGE5_D8_OK"; } \
    || { info "d8 失败"; tail -6 "$ARTIFACT_DIR/d8.log" | sed 's/^/    /'; mark "STAGE5_D8_FAIL"; }
fi

step "6. aapt2 + 签名 → APK"
mkdir -p out-apk
"$SDK/build-tools/$BT/aapt2" link -o out-apk/zeroaosp-qs-plugin-unsigned.apk \
  --manifest plugin-res/AndroidManifest.xml --min-sdk-version 26 --target-sdk-version 34 \
  -I "$AJ" out-dex > "$ARTIFACT_DIR/aapt2.log" 2>&1 \
  && { info "aapt2 link OK"; mark "STAGE6_AAPT2_OK"; } \
  || { info "aapt2 失败"; tail -6 "$ARTIFACT_DIR/aapt2.log" | sed 's/^/    /'; mark "STAGE6_AAPT2_FAIL"; }
if [ -f out-apk/zeroaosp-qs-plugin-unsigned.apk ]; then
  KS="$ARTIFACT_DIR/debug.keystore"
  keytool -genkeypair -keystore "$KS" -storepass android -keypass android -alias androiddebugkey \
    -dname "CN=Android Debug,O=Android,C=US" -keyalg RSA -keysize 2048 -validity 10000 > "$ARTIFACT_DIR/keytool.log" 2>&1 || true
  "$SDK/build-tools/$BT/zipalign" -f 4 out-apk/zeroaosp-qs-plugin-unsigned.apk out-apk/zeroaosp-qs-plugin-aligned.apk \
    > "$ARTIFACT_DIR/zipalign.log" 2>&1 || true
  "$SDK/build-tools/$BT/apksigner" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android \
    --out "$ARTIFACT_DIR/zeroaosp-qs-plugin.apk" out-apk/zeroaosp-qs-plugin-aligned.apk > "$ARTIFACT_DIR/apksigner.log" 2>&1 \
    && { info "签名 OK：$(stat -c%s "$ARTIFACT_DIR/zeroaosp-qs-plugin.apk") B"; mark "STAGE6_SIGN_OK"; } \
    || { info "签名失败"; tail -6 "$ARTIFACT_DIR/apksigner.log" | sed 's/^/    /'; mark "STAGE6_SIGN_FAIL"; }
  "$SDK/build-tools/$BT/aapt2" dump badging "$ARTIFACT_DIR/zeroaosp-qs-plugin.apk" 2>/dev/null | head -5 | tee "$ARTIFACT_DIR/apk_badging.txt" || true
fi
cp -f "$ARTIFACT_DIR"/stages.log . 2>/dev/null || true
printf '\n=== 阶段小结（stages.log） ===\n'; cat "$ARTIFACT_DIR/stages.log" | sed 's/^/  /'
printf '\n总耗时 %ss\n' "$(( $(date +%s) - T0 ))"
