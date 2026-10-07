# m1/ — M1 收口冒烟素材（zeroaosp）

> 本目录**不是 AOSP 源码**，也不随任何镜像发布；它是 M1 阶段"我们自己的模块能不能被编出来、能不能起来"的**最小素材集**。

## 里面有什么

| 路径 | 说明 |
|---|---|
| `service/dsh_hello_service.cpp` | 最小 native 服务：启动即打印身份信息；`-DDSH_WITH_BINDER=1` 时向 servicemanager 注册 Binder 服务并实现 `dump()`（可被 `dumpsys` 观测） |
| `service/Android.bp` | 该服务的 **Soong 模块定义**（`cc_binary`），写法参照 `frameworks/native/cmds/servicemanager/Android.bp` |
| `service/dsh_hello_service.rc` | **init 片段**（`service` 段 + 启动条件），范式见 `system/core/rootdir/init.rc` 与 `servicemanager.rc` |
| `service/dsh_hello_service.te` | **SELinux 域占位**（形状给出，未验证） |
| `service/file_contexts.snippet` | 文件标签占位行 |

## 这份素材验证到哪一步（诚实边界）

- ✅ **能编**：CI 里用 **host g++** 与 **Android NDK** 两种方式编出可执行文件；host 版还会当场 `--selftest` 跑起来。
- ✅ **素材可用**：`.bp` 用 `bpfix`（Soong 自带解析器）做语法校验，`.rc`/`.te` 作为接入构建时的输入。
- ❌ **未验证**：把模块**塞进 system.img**（需要完整 AOSP 树：官方要求 ≥400 GB 磁盘，本仓的 CI 只有 87 GB 可用）。
- ❌ **未验证**：服务在 Android 上真正注册成功并被 `dumpsys` 观测（需要先把 Android 跑起来，见仓库 CI 的 KVM 探测结论）。

## 怎么用

```bash
# CI：.github/workflows/m1-probes.yml（P1 KVM 探测 + P2 本目录的冒烟构建）
# 本地：见上面"能编"一行的两条命令；产物在 CI 的 artifact 里（含 SHA256SUMS）
```
