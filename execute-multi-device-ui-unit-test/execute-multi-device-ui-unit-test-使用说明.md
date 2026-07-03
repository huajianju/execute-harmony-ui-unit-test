# execute-multi-device-ui-unit-test 脚本使用说明

一键完成 HarmonyOS 工程的 **编译打包 → 安装 → 单元测试 → 导出报告 → 清理产物** 全流程。

---

## 一、前置条件

运行脚本前，需满足以下环境与设备要求。

### 1. 工具链环境

以下命令必须在终端可调用（随 DevEco Studio 或 Command Line Tools 安装）：

| 工具 | 校验命令 | 要求 |
|---|---|---|
| JDK | `java -version` | >= 17 |
| Node.js | `node -v` | 已安装 |
| ohpm | `ohpm -v` | 已安装 |
| hvigorw | `hvigorw -v` | 已安装（随 DevEco 提供） |
| hdc | `hdc -v` | 已安装（随 DevEco 提供） |

> 若任一命令找不到，请参考 [HarmonyOS 命令行工具配置指南](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-commandline-get) 配置环境变量。

### 2. SDK 环境变量

必须设置 `DEVECO_SDK_HOME`，指向 DevEco SDK 目录：

```powershell
node -e "console.log(process.env.DEVECO_SDK_HOME || 'NOT SET')"
```

示例值：`D:\Program Files\Huawei\DevEco Studio\sdk`。若输出 `NOT SET`，请在系统环境变量中配置。

### 3. 设备/模拟器

- 真机：USB 连接并开启 **开发者模式 + USB 调试**；
- 模拟器：在 DevEco 中启动模拟器。

通过以下命令确认已连接（应输出设备序列号，如 `127.0.0.1:5555`）：

```powershell
hdc list targets
```

> 多设备同时连接时，需通过 `-Device <序列号>` 指定目标设备，否则脚本会报错终止。

### 4. 签名说明

- 本脚本以安装 **HAP** 为目标（`.app` 包无法本地安装）。
- 工程 `build-profile.json5` 中 `signingConfigs` 为空时，产出 **未签名 HAP**，**模拟器可直接安装**；
- 真机调试/发布需配置签名，脚本会自动优先选择 `-signed.hap`。

---

## 二、脚本文件

**Windows：**

| 文件 | 说明 |
|---|---|
| `execute-multi-device-ui-unit-test.ps1` | 主脚本（PowerShell）。所有逻辑、参数解析、自动探测都在此。 |
| `execute-multi-device-ui-unit-test.bat` | Windows 批处理包装器。**双击即可运行**，自动透传参数，执行结束不关闭窗口。 |

**macOS / Linux：**

| 文件 | 说明 |
|---|---|
| `execute-multi-device-ui-unit-test.sh` | 主脚本（Bash 3.2+ 兼容）。与 `execute-multi-device-ui-unit-test.ps1` 功能对等：自动探测、构建、安装、UT、报告、清理、设备菜单（含自动启动模拟器）。 |
| `execute-multi-device-ui-unit-test.command` | macOS Finder **双击即可运行**的包装器，透传参数，结束按回车关闭窗口。 |

> macOS 首次使用需赋予执行权限：`chmod +x execute-multi-device-ui-unit-test.command execute-multi-device-ui-unit-test.sh`
> 参数风格为长选项（如 `--no-test`、`--build-mode release`），与 Windows 版语义一致。

> 推荐普通用户直接双击 `execute-multi-device-ui-unit-test.bat`（Windows）/ `execute-multi-device-ui-unit-test.command`（macOS）；需要传参时在命令行调用，三者（.ps1/.sh）等价。

---

## 三、快速开始

最简用法（默认编译 debug、安装到唯一设备、执行 UT、导出报告、清理产物）：

```powershell
.\execute-multi-device-ui-unit-test.bat
```

或在命令行：

```powershell
.\execute-multi-device-ui-unit-test.ps1
```

---

## 四、参数说明

所有参数均为可选，不传则使用默认值或自动探测。

| 参数 | 默认值 | 说明 |
|---|---|---|
| `-BuildMode` | `debug` | 构建模式：`debug` / `release` |
| `-Product` | 自动 | 指定 product（取自 `build-profile.json5` 的第一个） |
| `-Device` | 自动 | 目标设备序列号；**多设备时必填** |
| `-BundleName` | 自动 | 应用包名（取自 `AppScope/app.json5`） |
| `-Clean` | 关闭 | 编译**前**执行 `hvigorw clean`（更干净但更慢） |
| `-Launch` | 关闭 | 安装后自动启动应用（`aa start`） |
| `-SkipOhpm` | 关闭 | 跳过 `ohpm install`（依赖已装时加速） |
| `-NoUninstall` | 关闭 | 安装前不卸载旧版本（默认会先卸载） |
| `-NoTest` | 关闭 | **跳过单元测试**（默认会执行 UT 并导报告） |
| `-KeepArtifacts` | 关闭 | **保留编译/安装产物**（默认执行后全部清理） |
| `-TestPlan` | 自动 | **多设备测试计划文件路径**（JSON5）。不传则自动检测工程根目录 `device-test-plan.json5`；都不存在时走单设备模式 |
| `-TestTimeout` | `15000` | 单个用例超时时间（毫秒） |

> 兼容提示：`-Test` 参数仍被接受（等价于默认行为），向后兼容。

---

## 四-补、多设备测试计划（device-test-plan.json5）

需要**同时启动多个模拟器、并把不同用例分配到不同设备上执行**时，使用多设备计划模式。

### 1. 启用方式（三选一）

1. 工程根目录放 `device-test-plan.json5`（可由 `device-test-plan.example.json5` 复制修改），脚本自动识别；
2. 显式传参：`-TestPlan <路径>`（Windows）/ `--test-plan <路径>`（macOS/Linux）；
3. 不配置计划文件 → 默认单设备模式（行为与旧版一致）。

### 2. 配置文件格式

```json5
{
  // 可选：模拟器可执行文件路径，不填则自动从 DEVECO_SDK_HOME 发现
  // "emulatorPath": "D:\\Program Files\\Huawei\\DevEco Studio\\tools\\emulator\\Emulator.exe",
  "devices": [
    {
      "name": "手机模拟器",                 // 可选，报告中的设备别名
      "emulator": "Pura 90 Pro",           // 模拟器实例名（Emulator -list 列出的名称），脚本会自动 -start 启动
      "tests": [                            // 该设备要执行的用例
        "ActsAbilityTest",
        "attributeTest#testAttributeIt"
      ]
    },
    {
      "name": "平板模拟器",
      "emulator": "MatePad Pro 12",
      "tests": ["ActsGraphicsTest"]
    },
    {
      "name": "USB真机",
      "device": "127.0.0.1:5555",          // 已在线设备序列号，填了就直接用（不会再次启动模拟器）
      "tests": ["ActsAbilityTest#testExample"]
    }
  ]
}
```

### 3. 字段说明

| 字段 | 必填 | 说明 |
|---|---|---|
| `devices` | 是 | 设备计划数组，至少 1 项 |
| `devices[].emulator` | 模拟器必填 | 模拟器实例名（`Emulator -list` 列出的）。脚本执行 `Emulator -start` 启动，并主动 `hdc tconn` 连接 |
| `devices[].hdcport` | 强烈建议 | hdc 端口号（10000-16555）。命令行启动的模拟器**不会自动被 hdc 发现**、`hw.hdc.port` 也常为 `notset`；指定后脚本用 `-hdcport` 启动并 `hdc tconn 127.0.0.1:<port>` 连接，稳定可靠。每个模拟器用不同端口 |
| `devices[].device` | 真机必填 | hdc 设备序列号（如 `127.0.0.1:5555`），用于复用真机或已在线设备。填了且在线则直接用，不再启动模拟器 |
| `devices[].name` | 否 | 报告中显示的设备别名，便于识别 |
| `devices[].tests` | 是 | 该设备要执行的用例数组（写法见下） |
| `emulatorPath` | 否 | 模拟器可执行文件路径，不填则自动发现 |
| `bootTimeout` | 否 | 等待模拟器系统启动完成的轮询超时（秒），默认 20。命中 `bootevent.boot.finished=true` 即止（通常几秒）；超时则额外等 15s 后再唤醒/解锁 |

> **模拟器识别（重要）**：命令行 `Emulator -start` 启动的模拟器，`hdc` 不会自动发现，且 `-list -details` 的 `hw.hdc.port` 常为 `notset`。因此**强烈建议给每个模拟器配置 `hdcport`**：脚本会用 `-hdcport <端口>` 启动，再 `hdc tconn 127.0.0.1:<端口>` 主动连接。端口范围 10000-16555，各模拟器互不冲突即可。
> ⚠️ 若模拟器已用别的端口启动过，请先 `Emulator -stop "<名称>"` 关闭，再让脚本用配置的 `hdcport` 重新启动。

### 4. 用例过滤语法（对应 `aa test` 的 `-s class`）

| 写法 | 含义 |
|---|---|
| `ActsAbilityTest` | 运行整个测试套（对应代码里的 `describe('ActsAbilityTest')`） |
| `ActsAbilityTest#testExample` | 仅运行该套中名为 `testExample` 的用例（对应 `it('testExample')`） |

> 每个设备的 `tests` 会用逗号拼接成一次 `aa test` 调用（如 `-s class A,B#c`），无需拆分多次执行。

### 5. 多设备执行流程

```
读取计划 → 探测工程参数 → 编译应用 HAP + 测试 HAP（只编译一次）
→ 依次处理每台设备（一次只跑一个模拟器，跑完即关）：
    启动模拟器（-hdcport + hdc tconn 主动连接）→ 卸载旧版 → 安装应用 → 安装测试 HAP → 跑 aa test → 收集结果 → 关闭模拟器（Emulator -stop）
→ 导出合并报告（执行结果_<时间>.md，含全局汇总 + 各设备分节）
→ 清理：卸载真机应用 + 删除 build/oh_modules/锁文件（模拟器已关闭）
```

> 多设备模式为**串行**执行（一台跑完再跑下一台），稳定可靠、日志不交错、对机器资源友好。

---

## 五、执行流程

脚本按以下顺序自动执行（带 `[默认]` 标记的步骤默认开启）：

```
1.  环境自检          —— 校验 hvigorw / hdc / ohpm / node 是否可用
2.  探测工程参数      —— 自动读取 bundleName / Ability / 模块 / product / 测试套件
3.  安装依赖          —— ohpm install              [-SkipOhpm 可跳过]
4.  [可选] 编译前清理 —— hvigorw clean             [-Clean 触发]
5.  编译应用 HAP      —— hvigorw assembleHap --no-daemon
6.  定位应用 HAP      —— 优先 -signed，回退最新（排除测试目录）
7.  选择设备          —— hdc list targets（多设备需 -Device；无设备时交互菜单：[1]重新检测/[2]自动启动模拟器/[q]退出）
8.  [默认] 卸载旧版   —— bm uninstall              [-NoUninstall 可跳过]
9.  推送并安装应用    —— hdc file send + bm install
10. [可选] 启动应用   —— aa start                  [-Launch 触发]
11. [默认] 单元测试   —— 构建 ohosTest HAP + 安装 + aa test + 解析报告
12. [默认] 导出报告   —— 生成 执行结果_<时间>.md
13. [默认] 清理产物   —— 卸载设备应用 + 删除 build/ oh_modules/ 锁文件
```

### 自动探测的字段

脚本无需手动填写以下内容，全部从工程配置读取：

| 字段 | 来源文件 | 示例值 |
|---|---|---|
| bundleName | `AppScope/app.json5` | `com.example.immersive` |
| entry 模块名 | `build-profile.json5` | `default` |
| Ability 名 | entry 模块 `module.json5` 的 `mainElement` | `EntryAbility` |
| product | `build-profile.json5` 的 `products[0]` | `default` |
| 测试 target | entry 模块 `build-profile.json5` 中含 `test` 的 target | `ohosTest` |
| 测试套件名 | `src/ohosTest/module.json5` 的 `module.name` | `phone_test` |

---

## 六、用法示例

```powershell
# 1. 默认全流程（推荐，双击 bat 等价）
.\execute-multi-device-ui-unit-test.bat

# 2. 只编译安装应用，不跑 UT、不清理产物
.\execute-multi-device-ui-unit-test.bat -NoTest -KeepArtifacts

# 3. release 模式 + 编译前清理
.\execute-multi-device-ui-unit-test.bat -BuildMode release -Clean

# 4. 装完自动启动应用（保留产物便于调试）
.\execute-multi-device-ui-unit-test.bat -Launch -KeepArtifacts

# 5. 自定义用例超时（30 秒）
.\execute-multi-device-ui-unit-test.bat -TestTimeout 30000

# 6. 指定设备（多设备场景）
.\execute-multi-device-ui-unit-test.bat -Device 127.0.0.1:5555

# 7. 直接调用 ps1（与 bat 等价）
.\execute-multi-device-ui-unit-test.ps1 -SkipOhpm -NoUninstall

# 8. 多设备计划模式（根目录放好 device-test-plan.json5，直接双击/运行即可自动启用）
.\execute-multi-device-ui-unit-test.bat

# 9. 显式指定计划文件 + 保留产物便于调试
.\execute-multi-device-ui-unit-test.bat -TestPlan D:\plans\regression.json5 -KeepArtifacts

# 10. macOS / Linux 多设备
./execute-multi-device-ui-unit-test.sh --test-plan ./my-plan.json5
```

---

## 七、输出说明

### 1. 单元测试报告

每次执行 UT 后，在工程根目录生成：

```
执行结果_<yyyyMMdd_HHmmss>.md
```

报告内容包含：
- **执行信息**：bundleName / 测试套件 / 测试目标 / 构建模式 / 超时 / 执行时间 / 执行模式（单设备 or 多设备计划）
- **全局汇总**：总数 / 通过 / 失败 / 错误 / 忽略 / 总体结论（多设备模式下为各设备合计）
- **各设备分节**（每台设备一节）：序列号、用例筛选、本机汇总、用例明细（测试类、用例名、PASS/FAIL/ERROR、耗时）、失败详情、该设备完整 `aa test` 原始输出（折叠块）

> 单设备模式报告结构相同（仅一节，无「各设备」标题嵌套）。多设备模式下，所有设备结果合并在同一份 `执行结果_<时间>.md` 中。

### 2. 产物清理

执行结束（默认）会清理以下内容，保持工程干净：

| 类型 | 清理对象 |
|---|---|
| 设备安装产物 | 已安装的应用（`bm uninstall`） |
| 编译产物 | 所有模块的 `build/` 目录 |
| ohpm 安装产物 | 所有 `oh_modules/` 目录 |
| 依赖锁文件 | 所有 `oh-package-lock.json5` |

**保留**：`oh-package.json5`（依赖声明）、测试报告、源码。

> 用 `-KeepArtifacts` 可跳过清理，便于连续调试。

---

## 八、常见问题（FAQ）

**Q1：双击 `execute-multi-device-ui-unit-test.bat` 闪退？**
A：通常因前置条件未满足（工具不在 PATH、SDK 变量未设、无设备）。改在命令行运行可看到完整错误信息。

**Q2：提示"未检测到设备/模拟器"怎么办？**
A：脚本会弹出交互菜单：
   - `[1]` 我已手动启动模拟器/连接真机 —— 重新检测；
   - `[2]` 自动启动本地模拟器 —— 回车即可使用自动发现的 `Emulator.exe` 路径（默认 `$DEVECO_SDK_HOME\..\tools\emulator\Emulator.exe`），脚本先 `-list` 列出可用设备实例名，输入设备名后执行 `Emulator.exe -start "<设备名>"` 异步启动，并轮询 `hdc list targets` 直到设备上线（最多 180 秒，每 5 秒检测一次），然后自动继续后续编译安装测试流程；
   - `[q]` 退出。

   > 注：模拟器路径需为 HarmonyOS `Emulator.exe`，设备名需为 `-list` 输出中的实例名（如 `Pura 90 Pro`、`MatePad Pro 12`）。

**Q3：报错 `Multiple devices ... specify with -Device`？**
A：存在多个设备，用 `-Device <序列号>` 指定。

**Q4：安装失败 `install failed`？**
A：常见原因为签名不匹配或版本冲突。模拟器用未签名包即可；真机需在 `build-profile.json5` 配置 `signingConfigs`。也可加 `-Clean` 重新干净构建。

**Q5：清理时残留 `build/` 目录？**
A：hvigor 缓存文件路径可能超过 Windows 260 字符限制。脚本已使用 `\\?\` 长路径前缀删除；若仍残留，关闭 DevEco/编辑器后重试。

**Q6：不想每次都跑测试/清理怎么办？**
A：加 `-NoTest`（跳过测试）或 `-KeepArtifacts`（保留产物）。

**Q7：PowerShell 报"无法加载脚本，未签名"？**
A：`execute-multi-device-ui-unit-test.bat` 已内置 `ExecutionPolicy Bypass`；若直接调 ps1，可执行 `Set-ExecutionPolicy -Scope Process Bypass`。

**Q8：怎么让不同模拟器跑不同用例？**
A：使用多设备计划模式——在工程根目录创建 `device-test-plan.json5`（参考 `device-test-plan.example.json5`），为每个设备的 `emulator`（模拟器实例名）配置专属的 `tests` 用例列表。脚本会依次启动各模拟器，并把各自用例分配到对应设备执行，最后合并报告。

**Q9：计划里 `emulator` 和 `device` 有什么区别？模拟器没启动会自动启动吗？**
A：会自动启动。模拟器填 `emulator`（实例名，`Emulator -list` 列出的，如 `Pura 90 Pro`）；真机填 `device`（hdc 序列号，如 `127.0.0.1:5555`）。两者二选一。
对于 `emulator`：脚本调用官方 `Emulator -list -details` 读取该实例的 `isRunning` 与 `hw.hdc.port`——已在运行就直接用其 hdc 端口（序列号 `127.0.0.1:<端口>`）；未运行就执行 `Emulator -start` 启动，再轮询直到就绪。**所以模拟器只需填实例名，无需手填端口或序列号，开或没开都能自动处理。** 若始终无法定位，请用 `Emulator -list -details` 确认实例名拼写、以及首次启动是否需要同意软件许可协议。

**Q10：多设备模式为什么是串行？会同时启动多个模拟器吗？**
A：不会同时启动多个。脚本一次只启动一个模拟器：启动 → 安装 → 跑该设备用例 → **关闭（Emulator -stop）** → 再启动下一个。这样同时只有一个模拟器在跑，内存/CPU 占用最低、端口不冲突、日志清晰。如需缩短总耗时，可把用例划分到更多设备上分摊。

**Q11：用例筛选写法不对导致"未解析到汇总行"？**
A：`tests` 里填的是**测试套名**（`describe('xxx')` 的第一个参数）或**`套名#用例名`**，不是类的全限定包名。可用 `-KeepArtifacts` 保留产物，查看报告里的原始 `aa test` 输出确认筛选是否命中。

---

## 九、相关命令速查

```powershell
# 查看连接设备
hdc list targets

# 查看已安装应用
hdc shell bm dump -a

# 手动卸载应用
hdc shell bm uninstall -n <bundleName>

# 查看应用日志
hdc shell hilog | findstr <tag>

# 单独编译应用 HAP
hvigorw assembleHap --no-daemon

# 单独编译测试 HAP
hvigorw assembleHap --no-daemon -p module=<entry>@ohosTest
```
