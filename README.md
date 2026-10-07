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

## 状态 / Status

状态：源码研究阶段。清单别名、补丁规范、CI 草案已就位；插件框架源码与对外双语文档随后加入。
