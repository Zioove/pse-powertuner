# vendor / 第三方组件

本目录存放本项目所依赖的第三方工具归档，仅作参考与溯源用途。

## PowerSettingsExplorer.zip

| 项 | 值 |
|---|---|
| 文件 | `PowerSettingsExplorer.zip` |
| 大小 | 36,482 B |
| SHA256 | `AA61144604263969E0210349ACE60B688B8AFBF26CF6FF7FD21A5FF3985BED3E` |
| 来源 | 用户自 github.com 下载（zip 内 ADS 记录 `HostUrl=https://github.com/`，原始仓库 URL 未完整记录） |
| 归档内文件 | `PowerSettingsExplorer.exe`（99,328 B，SHA256 `B2094D475BED243A6315965728AF3D01890EEA18BEF3440F9202070400A0B902`）、`PowerSettingsExplorer.exe.config`（349 B） |

### 工具信息

- **名称**：PowerSettingsExplorer
- **作者**：Sameer（原始发布页署名）
- **版本**：1.0.0.0 / 文件描述 "PowerSettings"
- **构建年份**：2017（LegalCopyright 标注）
- **运行时**：.NET Framework 4.5.1，MSIL / x86（32 位）
- **签名**：未做 Authenticode 数字签名
- **许可**：**归档内未附任何许可文件**（无 LICENSE / COPYING / EULA / README）

### 用途说明

本项目**不调用**该可执行文件。它仅用于比对与溯源：本项目通过阅读其程序集
（`PowerSettings.Program`、`PwrSetting`、`POWER_DATA_ACCESSOR`）确认了底层
`powrprof.dll` 原生 API 的调用方式与设置数据的语义，然后在 PowerShell 中自行实现。
详见仓库根目录 README 的「关于 PowerSettingsExplorer」章节。

### 使用与合规提示

- 该归档以**原样**提供，未做任何修改。本项目不对其功能、安全性或兼容性作任何担保。
- 归档内未包含许可声明，因此本仓库对其**不授予任何再分发许可**。若您是版权所有者
  并希望移除，请提 issue，我们会立即删除。
- 可执行文件无数字签名，运行前请自行校验上方 SHA256，并自行评估风险。
- 本项目自身的代码以 MIT 许发布（见根目录 `LICENSE`），该许可**不覆盖**本目录内容。
