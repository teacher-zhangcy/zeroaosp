#!/usr/bin/env bash
# ci/verify-m2-skeleton.sh —— 把 patches/0002、0003 应用到真的 frameworks/base（钉死 tag 的浅克隆），
# 并**实测**回答 T-eng-infra-010 第②条的一半：「不建全树，能不能测到 Java 改动」。
#
# 三段实测：
#   A. 单文件 javac：脱离平台 classpath 会怎样（给出真实错误行数与首行）
#   B. Soong 前置路径存在性 + 有界尝试（envsetup.sh / lunch 会缺什么）
#   C. 磁盘与时长：clone / am / 探测各阶段的 df 与耗时
set -euo pipefail

ARTIFACT_DIR="${ARTIFACT_DIR:-artifacts-m2}"
TAG="${TAG:-android-14.0.0_r1}"
MIRROR="${MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/git/AOSP/platform}"
T0="$(date +%s)"
step() { printf '\n===== [%s +%ss] %s =====\n' "$(date -u +%H:%M:%S)" "$(( $(date +%s) - T0 ))" "$*"; }
info() { printf '  %s\n' "$*"; }
elapsed() { echo "$(( $(date +%s) - T0 ))"; }
fail() { printf '\n!!!!! 失败: %s\n' "$*" >&2; exit 1; }
trap 'printf "\n!! 脚本在第 %s 行非预期退出（exit=%s）\n" "$LINENO" "$?" >&2' ERR

mkdir -p "$ARTIFACT_DIR"
ARTIFACT_DIR="$(cd "$ARTIFACT_DIR" && pwd)"   # 绝对化：脚本中途会 cd 进 base/，相对路径会失效
df -h / | tee "$ARTIFACT_DIR/df_before.txt"

step "1. 浅克隆 frameworks/base（$TAG）"
SECONDS=0
git clone --quiet --depth=1 -b "$TAG" "$MIRROR/frameworks/base" base > "$ARTIFACT_DIR/clone_base.log" 2>&1 \
  || git clone --quiet --depth=1 "$MIRROR/frameworks/base" base >> "$ARTIFACT_DIR/clone_base.log" 2>&1 \
  || fail "克隆 frameworks/base 失败（见 clone_base.log）"
info "clone 耗时 = ${SECONDS}s"
du -sh base | tee "$ARTIFACT_DIR/base_size.txt"
df -h / | tee "$ARTIFACT_DIR/df_after_clone.txt"
git -C base log --oneline -1 | tee "$ARTIFACT_DIR/base_head.txt"

step "2. 应用 patches/0002 与 0003（git am）"
cd base
git config core.autocrlf false
: > "$ARTIFACT_DIR/am.log"
for p in ../patches/000[234]-*.patch; do
  [ -f "$p" ] || fail "找不到补丁 $p"
  echo "== git am $p" | tee -a "$ARTIFACT_DIR/am.log"
  if git -c user.name=ci -c user.email=ci@zeroaosp.invalid am "$p" >> "$ARTIFACT_DIR/am.log" 2>&1; then
    echo "   AM_OK" | tee -a "$ARTIFACT_DIR/am.log"
  else
    echo "   AM_FAILED" | tee -a "$ARTIFACT_DIR/am.log"
    fail "git am 失败：$p（原始输出在 am.log）"
  fi
done
{ git log --oneline -3; echo "---"; git show --stat --oneline HEAD~1 | head -4; echo "---"; git show --stat --oneline HEAD | head -5; } | tee "$ARTIFACT_DIR/am_result.txt"
cd ..
df -h / | tee "$ARTIFACT_DIR/df_after_am.txt"

step "3. 实测 A：不用平台 classpath，直接 javac 改动过的 Settings.java"
javac -version 2>&1 | tee "$ARTIFACT_DIR/javac_version.txt" || info "javac 不存在"
mkdir -p out
set +e
javac -d out -nowarn base/core/java/android/provider/Settings.java > "$ARTIFACT_DIR/javac_settings.log" 2>&1
JRC=$?
set -e
info "javac 退出码 = $JRC"
info "error: 行数 = $(grep -c 'error:' "$ARTIFACT_DIR/javac_settings.log" 2>/dev/null || echo 0)"
info "首 5 条原始错误："
grep 'error:' "$ARTIFACT_DIR/javac_settings.log" | head -5 | sed 's/^/    /' || true

step "4. 实测 B：Soong 前置路径存在性 + 有界尝试"
for r in build/soong build/make build/blueprint; do
  dest="$(echo "$r" | tr '/' '_')"
  SECONDS=0
  git clone --quiet --depth=1 -b "$TAG" "$MIRROR/$r" "$dest" >> "$ARTIFACT_DIR/clone_base.log" 2>&1 \
    || git clone --quiet --depth=1 "$MIRROR/$r" "$dest" >> "$ARTIFACT_DIR/clone_base.log" 2>&1 \
    || info "（$r 克隆失败）"
  info "clone $r 耗时 = ${SECONDS}s"
done
{
  for path in build/soong build/make build_blueprint prebuilts/build-tools prebuilts/clang/host/linux-x86 prebuilts/sdk device/google/cuttlefish frameworks/base frameworks/av frameworks/native system/core; do
    if [ -e "$path" ]; then echo "存在:   $path"; else echo "缺失:   $path"; fi
  done
} | tee "$ARTIFACT_DIR/soong_prereqs.txt"
info "有界尝试 build/make 的 envsetup.sh（上限 60s）："
set +e
timeout 60 bash build_make/envsetup.sh > "$ARTIFACT_DIR/envsetup.log" 2>&1
ERC=$?
set -e
info "envsetup.sh 退出码 = $ERC"
tail -8 "$ARTIFACT_DIR/envsetup.log" | sed 's/^/    /' || true
du -sh . | tee "$ARTIFACT_DIR/tree_size_after_probe.txt"
df -h / | tee "$ARTIFACT_DIR/df_after_probe.txt"

step "5. 汇总"
{
  printf 'verify-m2-skeleton summary (%s)\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'elapsed_s            = %s\n' "$(elapsed)"
  printf 'base_size            = %s\n' "$(cat "$ARTIFACT_DIR/base_size.txt")"
  printf 'javac_rc             = %s\n' "$JRC"
  printf 'javac_error_lines    = %s\n' "$(grep -c 'error:' "$ARTIFACT_DIR/javac_settings.log" 2>/dev/null || echo 0)"
  printf 'envsetup_rc          = %s\n' "$ERC"
  printf 'tree_after_probe     = %s\n' "$(cat "$ARTIFACT_DIR/tree_size_after_probe.txt")"
  printf 'disk_after_probe     = %s\n' "$(tail -1 "$ARTIFACT_DIR/df_after_probe.txt")"
  printf 'am_result            = %s\n' "$(grep -c AM_OK "$ARTIFACT_DIR/am.log" || echo 0) 个补丁应用成功"
} > "$ARTIFACT_DIR/summary.txt"
cat "$ARTIFACT_DIR/summary.txt" | sed 's/^/  /'
printf '\n✅ 脚本走完（%ss）\n' "$(elapsed)"
