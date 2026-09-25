# PSE-PowerTuner

基于 **PowerSettingsExplorer** 逆向出的隐藏电源设置 GUID 表，把处理器性能相关的 26 项
设置自动调成三档场景。核心不是"调用 powercfg"，而是**直接调用 `powrprof.dll`**——
这是 PowerSettingsExplorer 的做法，也是本机能生效的唯一路径。

| 档位 | Key | 基底方案 | 适用 |
|---|---|---|---|
| 稳定本 | `balanced-stable` | 平衡 | 日常办公、开发机、虚拟机 |
| 极致版 | `max-perf` | 高性能 | 游戏、渲染、低延迟 |
| 节能版 | `eco` | 节能 | 续航、移动办公 |

## 为什么必须用 powrprof 而不是 powercfg

本机（多数 OEM 精简电源策略机器同理）的 `powercfg /query` 只认**方案已承载**的设置，
对注册表中存在但方案未实例化的隐藏项一律报「指定的电源方案、子组或设置不存在」。
同一个 GUID 的实测对比：

```
powercfg /query SUB_PROCESSOR be337238-0d82-4146-a960-4f3749d470c7
  → 指定的电源方案、子组或设置不存在

PowerReadACValueIndex(scheme, SUB_PROCESSOR, be337238-...)
  → rc=0, value=2          ← 成功
```

也就是说，**任何纯 powercfg 的调优脚本在这台机器上会把 Turbo / EPP / 核心停放全部静默跳过**。
注册表 `HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\54533251-…`（处理器电源管理）
下实际有 **95 项**设置，但 `powercfg` 只肯显示 2 项。

## 快速开始

```powershell
# 以管理员身份启动 PowerShell
cd <本仓库目录>

.\Apply-PowerProfile.ps1 -Detect                 # 1. 只看硬件检测与推荐
.\Apply-PowerProfile.ps1 -List                   # 2. 看三档配置表
.\Apply-PowerProfile.ps1 -Diff max-perf          # 3. 对比当前值 vs 目标值（只读）
.\Apply-PowerProfile.ps1 -Profile max-perf -DryRun -IncludeDC   # 4. 演练，无痕
.\Apply-PowerProfile.ps1 -Profile max-perf -IncludeDC           # 5. 正式应用
```

任何正式应用前都会全量备份到 `%ProgramData%\PSE-PowerTuner\backup\<时间戳>-<标签>\`，
包含每个方案的 `.pow`、`manifest.json`，以及 `values.json`（**原生 API 逐项快照，还原的唯一可靠依据**）。

## 三档差异（AC 交流档）

| 设置 | 稳定本 | 极致版 | 节能版 |
|---|---|---|---|
| `PERFBOOSTMODE` 性能提升模式 | 2 激进 | 2 激进 | 1 启用 |
| `PERFEPP` 能效偏好 | 50 | **0 纯性能** | 80 |
| `CPMINCORES` 最小停放核心% | 25 | **100 禁止停放** | 50 |
| `PROCTHROTTLEMIN` 最小处理器状态% | 5 | **100 锁高频** | 5 |
| `PROCTHROTTLEMAX` 最大处理器状态% | 100 | 100 | 85 |
| `PERFINCPOL` 升频策略 | 0 保守 | **2 常时** | 0 保守 |
| `PERFINCTHRESHOLD` / `PERFDECTHRESHOLD` | 60 / 20 | **20 / 60** | 60 / 20 |
| `PERFLATENCYSENSITIVITY` 延迟敏感度 | 50 | **100** | 0 |
| `PERFHETERO` 异构调度 | 4 优先P核 | 4 优先P核 | 0 自动 |
| `IDLEDISABLE` 空闲禁用（DC） | 0 | — | 1 |

电池档（DC）是独立的一套更保守参数，需加 `-IncludeDC` 才写入。

## 本机实测验证结果

34 项候选设置经「读 → 写 → 回读 → 还原」往返验证：

- **26 项可读可写** → 全部编入三档配置
- **3 项只读**（`PERFINCTIME` / `PERFDECTIME` / `PERFTIME`，写入被拒）
- **1 项不可读**（`93b8b6dc-…` 异构线程调度，rc=2）
- 极致版演练：**47 项写入全部通过，0 失败**；节能版：**41 项，0 失败**

原始数据：`_ref\writable-test.csv`、`_ref\processor-settings.csv`（95 项完整清单）。

## 文件

| 文件 | 作用 |
|---|---|
| `modules\PowerTune.psm1` | 公共库：powrprof P/Invoke、GUID 表、三档配置、备份/回滚 |
| `Apply-PowerProfile.ps1` | 一键入口：探测 → 选档 → 应用 → 核验；支持 `-DryRun` 演练 |
| `Rollback-PowerScheme.ps1` | 回滚到指定备份或 Windows 默认 |
| `Invoke-PowerBench.ps1` | 基准对照（吞吐 / 频率 / 抖动），纯 .NET，无第三方依赖 |
| `Show-PowerReport.ps1` | HTML 报告：三档差异 + 基准趋势 |
| `Install-PowerTuneTask.ps1` | 计划任务：登录应用 / 插拔电源自适应 |
| `_ref\Test-PwrApi.ps1` | 可写性探测工具，换机器时重跑它刷新白名单 |
| `_ref\writable-test.csv` | 26 项可写 / 3 项只读 / 1 项不可读 的实测记录 |

## 换到别的机器

不同硬件暴露的设置集不同（大小核 CPU 才有 `PERFHETERO`；部分 OEM 会裁掉更多项）。
脚本已内建存在性校验：读不到就记为 `Fail` 并跳过，不会写坏方案。要在新机器上刷新白名单：

```powershell
.\_ref\Test-PwrApi.ps1        # 产出 _ref\writable-test.csv，据此更新模块内的 $Script:Writable
```

## 安全设计

1. **存在性校验**：每项写入后立即回读比对，不一致即判失败，绝不盲写。
2. **全量备份**：`.pow` + `values.json` 双份，值还原走原生 API。
3. **可逆**：改动落在克隆方案上，不动原方案；`-Restore` 一键回出厂。
4. **无痕演练**：`-DryRun` 写临时方案 → 校验 → 立即删除。
5. **日志**：`%ProgramData%\PSE-PowerTuner\log\powertune.log` 记录每项写入结果。

## 已知限制与风险

**极致版把最小处理器状态设为 100% 并禁止核心停放。** 在散热受限的轻薄本上，这会持续高频、
触发温度墙降频，实际表现可能**低于**稳定本。笔记本建议先跑：

```powershell
.\Apply-PowerProfile.ps1 -Profile max-perf -IncludeDC
.\Invoke-PowerBench.ps1 -Label "极致版"
.\Apply-PowerProfile.ps1 -Profile balanced-stable -IncludeDC
.\Invoke-PowerBench.ps1 -Label "稳定本"
.\Show-PowerReport.ps1 -Open     # 看两档的多核吞吐与抖动对比
```

**3 项只读设置**无法调整：`PERFINCTIME`、`PERFDECTIME`、`PERFTIME`（升/降频时间与检查间隔）。

**回滚：**
```powershell
.\Rollback-PowerScheme.ps1 -List      # 看备份
.\Rollback-PowerScheme.ps1            # 回滚最近一次
.\Apply-PowerProfile.ps1 -Restore     # 恢复出厂电源方案
```

⚠️ 注意 `-Restore` 会调用 `powercfg -restoredefaultschemes`，**该命令会删除所有非默认电源方案**。
如果你有自建方案，先 `.\Rollback-PowerScheme.ps1 -List` 确认备份存在再执行。

## 关于 PowerSettingsExplorer

本项目的向导来源于 **PowerSettingsExplorer**（Sameer，2017，.NET 4.5.1 / x86 / 未签名）。
它本身是 powercfg 的 GUI 封装，但关键是它**不走 powercfg.exe**，而是直接 P/Invoke `powrprof.dll`：

```
PowerEnumerate            PowerGetActiveScheme     PowerSetActiveScheme
PowerReadACValueIndex     PowerWriteACValueIndex   PowerRead/WriteDCValueIndex
PowerReadFriendlyName     PowerReadDescription     PowerWriteSettingAttributes
PowerReadValueMin/Max/Increment      PowerReadPossibleValue
PowerReadDefaultACIndex   PowerReadDefaultDCIndex  PowerDeterminePlatformRole
```

内部数据模型：

- `PwrSetting{ SubgroupGuid, SettingGuid, acIndexes, dcIndexes, hidden, PossibleValues, Units, _valueMin, _valueMax, _valueIncrement }`
- `POWER_DATA_ACCESSOR`（29 个成员，含 `ACCESS_AC_POWER_SETTING_INDEX`、`ACCESS_ATTRIBUTES`、`ACCESS_ACTIVE_OVERLAY_SCHEME` 等）
- `SchemeTypes{ scheme, overlay, profile }`、`RegType`（含 `REG_QWORD`）
- 支持 `ExportSettings` / `ImportSettings` / `SaveSettingsAsSctipt` / `WriteToBatchFile`

本项目只借鉴其 API 调用方式与 GUID 语义，**未包含也未分发该工具的二进制文件**。
需要图形界面请自行获取原工具。

## 许可

MIT

