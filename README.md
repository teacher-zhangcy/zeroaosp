# zeroaosp

> An AOSP (Android 14) downstream project — **everything is a plugin**.
> 基于 AOSP（Android 14）的下游工程 ——「一切皆插件」：框架预埋原生钩子、内置 QuickJS 本机插件运行时、PluginService 负责插件的生命周期与依赖。

## 仓库内容 / What's inside

| 路径 | 说明 |
| --- | --- |
| `manifest/zeroaosp-14.xml` | AOSP 14 **子集清单**：11 个 project，钉 `refs/tags/android-14.0.0_r1` |
| `patches/` | 下游**补丁栈目录规范**（编号规则 / 目标路径字段 / 一句话理由 / 禁止项） |
| `.github/workflows/build-modules.yml` | 云端流水线：**只编独立模块**；整机 `system.img` 不上 CI |
| `m1/` | M1 收口冒烟素材：最小自研 native 服务 + Soong/init/sepolicy 素材（不随镜像发布） |
| `ci/verify-emulator.sh` | M1 **常驻验证闸门**：起官方 AOSP 镜像的 Android、把我们的服务推上去跑、断言 `ps` 可见（详见下节「本地/CI 如何验证」） |

## 快速开始 / Quick start

```bash
repo init -u https://github.com/teacher-zhangcy/zeroaosp -b main -m manifest/zeroaosp-14.xml
repo sync -c -j4
```

> 需要 `repo` 工具；上游源码来自清华 AOSP 镜像（清单里已配好 `remote`）。本仓只放「清单 + 补丁规范 + CI 配置」，**不含任何 AOSP 源码**。

## 设计约束 / Design constraints

- **上游基线**：`android-14.0.0_r1`（是 tag，不是分支）——全项目钉死，不中途换分支。
- **CI 范围**：只编独立模块（单个 APK / 单个 APEX / QuickJS 库）；**整机镜像不在 CI 上做**。
- **插件语义**：插件变更在**下次启动**生效，不做运行时代码热替换。
- **补丁纪律**：对 AOSP 的任何改动都必须以补丁形式进 `patches/`，且带编号、目标路径与一句话理由（详见 `patches/README.md`）。
- **许可证**：Apache-2.0。**不捆绑 GMS。**

## 本地/CI 如何验证 / How to verify

M1 的常驻闸门 = **在真 Android 上把我们的 native 服务跑起来**（一次 2–4 分钟，只用 GitHub 免费额度，不需任何凭据）。

| 方式 | 入口 | 说明 |
| --- | --- | --- |
| CI 自动 | push 到 `ci/**`、`m1/**` 或本 workflow 本身 | 见 `.github/workflows/verify-emulator.yml`；改文档/清单不会白跑 |
| CI 手动 | Actions → `verify-emulator` → Run workflow | 可传 `expect_process`（负向对照用）与 `with_binder`（多验"服务被 servicemanager 登记"） |
| 本地 | `bash ci/verify-emulator.sh` | 需要 Linux + KVM + Android SDK；无 KVM 时 `ALLOW_NO_KVM=1`（只跑环境检查） |

闸门脚本（`ci/verify-emulator.sh`，229 行）做四件事：

1. **KVM 复核** —— 放开 `/dev/kvm` 权限位 + 真做 `KVM_GET_API_VERSION` ioctl（期望 12）；
2. **现场拉官方 AOSP 镜像** —— SDK manager 取 `system-images;android-34;aosp_atd;x86_64`（无 GMS）并 headless 起模拟器；
3. **编我们的服务** —— 用 runner 自带 NDK 编 `m1/service/dsh_hello_service.cpp`，`push` 进设备并启动；
4. **断言** —— `ps -A` 里必须出现我们的进程；`WITH_BINDER=1` 时额外断言 `service check <名>` 正命中且 `dumpsys` 有输出。

断言失败会让 job **真红**（脚本对被断言的检查不做任何 `|| true` 遮盖）；原始证据（启动日志、`getprop`、`ps`、服务自报日志、编译日志…）作为 artifact 保留 14 天。

**验证"闸门本身真的会红"**（负向对照）：

```bash
# CI：手动触发时把 expect_process 填成一个不存在的名字
# 本地：
EXPECT_PROCESS=no_such_process bash ci/verify-emulator.sh   # 期望：断言失败、非零退出
```

> 依赖策略：只用 GitHub 托管 runner 与 Android SDK 官方包；**不把镜像推进仓库**（每次现场拉取）。

## 状态 / Status

状态：源码研究阶段。清单别名、补丁规范、CI 草案已就位；插件框架源码与对外双语文档随后加入。
