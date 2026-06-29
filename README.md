# execute-ui-unit-test

HarmonyOS 工程**一键编译 / 安装 / 单元测试 / 报告 / 清理**的跨平台脚本工具集。自动探测工程配置，无需手填包名/模块/测试套件；模拟器未启动时可交互式启动。

---

## 文件清单

| 文件 | 平台 | 说明 |
|---|---|---|
| `execute-ui-unit-test.ps1` | Windows | PowerShell 主脚本（全部逻辑） |
| `execute-ui-unit-test.bat` | Windows | 双击运行包装器，结束显示退出码并 `pause` 不关窗 |
| `execute-ui-unit-test.sh` | macOS / Linux | Bash 主脚本（bash 3.2+ 兼容） |
| `execute-ui-unit-test.command` | macOS | Finder 双击运行包装器，结束按回车关窗 |
| `execute-ui-unit-test-使用说明.md` | 全平台 | 详细使用文档（前置条件 / 参数 / 流程 / FAQ） |

> 详细参数、执行流程、FAQ 见 [`execute-ui-unit-test-使用说明.md`](./execute-ui-unit-test-使用说明.md)。

---

## 功能

一次执行完整流水线：

1. **环境自检** —— 校验 hvigorw / hdc / ohpm / node
2. **自动探测** —— 从 `AppScope/app.json5`、`build-profile.json5`、各 `module.json5` 读取 bundleName / entry 模块 / Ability / product / 测试 target / suite
3. **安装依赖** —— `ohpm install`
4. **编译应用 HAP** —— `hvigorw assembleHap --no-daemon`
5. **定位产物** —— 优先 `-signed`，回退最新（排除测试目录）
6. **设备选择** —— `hdc list targets`；无设备时交互菜单：
   - `[1]` 我已手动启动模拟器/连接真机 —— 重新检测
   - `[2]` 自动启动本地模拟器（自动发现 `Emulator` 路径 + `-list` 列实例 + `-start <名称>` 启动 + 轮询 hdc 上线，最多 180 秒）
   - `[q]` 退出
7. **卸载旧版**（默认）→ **推送安装应用 HAP**
8. **单元测试**（默认）—— 构建 ohosTest HAP + 安装 + `aa test ... OpenHarmonyTestRunner` + 解析结果
9. **导出报告** —— `执行结果_<yyyyMMdd_HHmmss>.md`（执行信息 / 汇总 / 用例明细 / 失败详情 / 原始输出）
10. **清理产物**（默认）—— 卸载设备应用 + 删除 `build/`、`oh_modules/`、`oh-package-lock.json5`（保留 `oh-package.json5`、报告、源码）

> 模拟器 CLI：启动用 `Emulator -start <名称>`（非 Android 的 `-avd`），`-list` 列实例，`-stop` 停止。

---

## 前置条件（简）

- 工具链：JDK ≥ 17、Node.js、ohpm、hvigorw、hdc（随 DevEco Studio / Command Line Tools 安装）
- 环境变量：`DEVECO_SDK_HOME` 已设置
- 设备：真机（USB 调试）或模拟器；无设备时脚本可交互式启动模拟器
- 签名：`signingConfigs` 为空时产出未签名 HAP，**模拟器可直接安装**；真机需配置签名

> 各项校验命令见使用说明文档「前置条件」章节。

---

## 快速开始

**Windows**
```powershell
.\execute-ui-unit-test.bat                      # 双击或命令行，默认全流程
.\execute-ui-unit-test.bat -NoTest -KeepArtifacts
```

**macOS**（首次需赋权）
```bash
chmod +x execute-ui-unit-test.command execute-ui-unit-test.sh
./execute-ui-unit-test.command                  # 双击或命令行
./execute-ui-unit-test.command --no-test
```

**Linux**
```bash
chmod +x execute-ui-unit-test.sh
./execute-ui-unit-test.sh
```

---

## 参数（Windows / macOS 对等）

| Windows (.ps1) | macOS/Linux (.sh) | 默认 | 说明 |
|---|---|---|---|
| `-BuildMode` | `--build-mode` | debug | debug / release |
| `-Product` | `--product` | 自动 | 指定 product |
| `-Device` | `--device` | 自动 | 多设备时必填 |
| `-BundleName` | `--bundle-name` | 自动 | 应用包名 |
| `-Clean` | `--clean` | 关 | 编译前清理 |
| `-Launch` | `--launch` | 关 | 装完启动应用 |
| `-SkipOhpm` | `--skip-ohpm` | 关 | 跳过 ohpm install |
| `-NoUninstall` | `--no-uninstall` | 关 | 不预卸载旧版 |
| `-NoTest` | `--no-test` | 关 | 跳过 UT（默认跑 UT + 导报告） |
| `-KeepArtifacts` | `--keep-artifacts` | 关 | 保留编译/安装产物（默认清理） |
| `-TestTimeout` | `--test-timeout` | 15000 | 用例超时（毫秒） |

---

## 输出

- **UT 报告**：每次执行后生成 `执行结果_<时间>.md`，含汇总、用例明细（PASS/FAIL/ERROR + 耗时）、失败详情、原始输出。
- **清理**：默认结束后卸载设备应用并删除 `build/`、`oh_modules/`、`oh-package-lock.json5`，保持工程干净；`-KeepArtifacts` 可保留便于调试。

---

## 跨平台实现要点

- **JSON5 解析 / 报告生成**：依赖 node（运行时写入临时工具脚本），Windows 与 macOS/Linux 共用同一套解析逻辑。
- **Windows 长路径**：用 `\\?\` Win32 前缀删除 >260 字符的 hvigor 缓存。
- **非交互环境守卫**：CI / 管道重定向 stdin 时，无设备则打印提示并干净退出，避免 `Read-Host` 卡死。
- **中文支持**：Windows 脚本以 UTF-8(BOM) 保存；报告以 UTF-8 写入。
