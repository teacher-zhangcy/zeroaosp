# patches/ — AOSP 下游补丁栈目录规范（草案 v0.1）

> 状态：**草案 v0.1**（2026-10-07）。本文件**不含任何真实补丁**——补丁由后续工作按本规范加入。
> 三条硬约束：① 改树必须留痕（编号 + 目标路径 + 一句话理由）；② 改动规模有预算上限（按 hunk 计）；③ 云端按同一分支拉子集后再叠加 `patches/`。


## 1. 目录结构

```
patches/
├── README.md              # 本规范
├── INDEX.tsv              # 机器可读台账（唯一事实源）
└── NNNN-<area>-<slug>.patch
```

`patches/` 下**只允许**这三类文件；临时 diff、草稿、`*.orig`、`*.rej`、备份文件一律不许入库。

## 2. 编号规则

| 项 | 规则 |
|---|---|
| 形式 | 4 位十进制，从 `0001` 起 |
| 唯一性 | 全局唯一；**只增不减、不复用** |
| 删除 | 补丁作废时**保留编号空位**，`INDEX.tsv` 里 `status=retired`，编号不得让给新补丁 |
| 排序 | 应用顺序严格 = 编号升序 |
| 与分类的关系 | 编号与 area、模块、文件均无关（避免插入导致整体重排）；分类由 `INDEX.tsv` 的 `area` 列承担 |

## 3. 文件名格式

```
NNNN-<area>-<slug>.patch
```

- `NNNN`：§2 的编号，补零到 4 位。
- `<area>` ∈ `bus` \| `pkg` \| `js` \| `ui` \| `common` \| `build` \| `sepolicy`
  —— 前四个对应四条工作方向（插件总线 / 插件包机制 / JS 引擎 / UI 槽位）；`common` = 跨线公共改动（必须在台账里标 common）；`build` = 构建系统；`sepolicy` = 权限策略。
- `<slug>`：小写字母 / 数字 / 连字符；≤ 5 个词、≤ 40 字符；描述「改了什么」，不写「为什么」。
- 全 ASCII：不用中文、不用大写、不用下划线、不用空格。
- 文件本体必须是 `git format-patch` 产物（含 `From` / `Subject` / `---` / `diff --git` 段），能 `git am` 干净应用；**裸 diff 不算**。
- 示例：`0007-bus-aidl-event-bus.patch`、`0011-common-quickjs-soong-module.patch`

## 4. 目标路径字段（`target_paths`）

- **权威位置**：`INDEX.tsv` 的 `target_paths` 列；多路径用 `,` 分隔，分隔符旁不留空格。
- **取值口径**：**AOSP 树根相对路径**（= `repo init` 后工作树根的相对路径）；不带 `a/`、`b/` 前缀，不带盘符或本机目录。
  例：`frameworks/base/core/java/android/app/ActivityThread.java`
- **一致性硬约束**：补丁内每条 `diff --git a/X b/X` 的 `X` 必须与 `target_paths` **集合相等**（不多不少）。
  校验命令（对单个补丁，真实输出应是路径清单）：
  ```powershell
  Select-String -Path patches\0007-bus-aidl-event-bus.patch -Pattern '^diff --git' | ForEach-Object { $_.Line }
  ```
- **应用定位**：按路径前缀在 manifest 别名（`manifest/zeroaosp-14.xml`）的 `project path=` 表里找到所属仓，进入该仓执行 `git am`。
- **越界处理**：目标文件所属 project 不在清单里 → **拒绝该补丁**；要纳入必须先改清单（并在 `INDEX.tsv` 的 `added_project` 列记录），不许「先改树后补清单」。

## 5. 一句话理由字段（`rationale`）

- **权威位置**：`INDEX.tsv` 的 `rationale` 列；≤ 120 字符、单行、无制表符。
- **格式**：`<做什么>：<不改会怎样>`。
- 同一字符串必须出现在补丁 commit message 首行（便于 `git log --grep` 反查台账）。
- **反例（应被校验拒绝）**：`优化`、`调整`、`适配`、`修复`、`完善`、`重构`、`update`、`fix`。
- **正例**：`预埋按键事件钩子：否则插件收不到 KEYCODE，只能轮询`
- **正例**：`QuickJS 进 Soong：否则 JS 引擎无法随系统镜像构建`

## 6. `INDEX.tsv` 台账 schema

制表符分隔，首行表头，字段顺序固定（共 9 列）：

```
id	area	status	target_paths	rationale	upstream_rev	added_project	author	added
0001	bus	accepted	frameworks/base/services/core/java/com/android/server/PluginBus.java	预埋事件总线注册点：否则插件无法在启动期挂载	refs/tags/android-14.0.0_r1	-	eng-infra	2026-10-07
```

- `status` ∈ `proposed` \| `accepted` \| `retired`；只有 `accepted` 才允许进构建。
- `upstream_rev`：该补丁所基于的上游 tag；本项目固定 `refs/tags/android-14.0.0_r1`。
- `added_project`：若该补丁引入了清单里原本没有的 project，填其 `name`，否则 `-`。
- 校验：9 列齐全；`id` 升序且唯一；`target_paths` 非空。

## 7. 禁止项（硬规则 10 条）

1. **禁止改树不留痕**：对 AOSP 源码的任何改动必须对应 `patches/` 里一个补丁。
2. **禁止一个补丁混多个主题**：一个补丁 = 一个可独立解释、可独立回退的改动。
3. **禁止依赖上游未稳定内部 API**：引用的类 / 方法必须能在钉死 tag 里找到。
4. **禁止绝对路径 / 本机路径**（Windows 盘符路径、类 Unix 的家目录与工作树绝对路径等）出现在补丁或台账里。
5. **禁止入库内容**：构建产物、二进制 blob、`out/`、`.repo/`、`*.img`、`*.apk`、`*.apex`。
6. **禁止任何凭据**：token、密钥、密码、设备指纹 —— 永不入库。
7. **禁止修改参考树** `reference/aosp-14/`（只读）。
8. **禁止 CRLF 与整文件重排**：补丁必须 LF；不许夹带无用的 re-indent / 格式化工噪。
9. **禁止静默扩范围**：新增改动须有对应 Q 裁决或补丁清单条目；B 档 30–80 hunk 是硬约束。
10. **禁止跳过校验直接进仓**：先过 §4 / §5 的一致性检查，再提交。

## 8. 应用顺序（可复现流程）

```bash
# 1) 干净上游树：本地 = reference/aosp-14/（只读参考）；云端 = manifest 别名 sync 出的工作树
# 2) 按编号升序列补丁并看清各自的目标仓
for p in $(ls patches/[0-9][0-9][0-9][0-9]-*.patch | sort); do
  echo "== $p"; grep '^diff --git' "$p"
done
# 3) 逐个应用：cd <manifest 里对应的 project path> && git am ../../patches/<file>
# 4) 全部应用后核对：git -C <project path> log --oneline -n <该仓补丁数> 应与台账反序一致
```

> 首版只交付规范；上述流程**尚未用真实补丁验证**，首次应用时必须把实际输出记录下来。

## 9. 版本与变更

- v0.1（2026-10-07）：首版草案。
- 变更走 PR + 一句话理由；**编号规则与 §7 禁止项是契约**，改动需要人类签字。
