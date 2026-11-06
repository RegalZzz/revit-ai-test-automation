# revit-ai-test-automation

AI 辅助 Revit 自动化测试项目与 Skill，版本 v1.1。

当前最新版为 **v1.1**，包括对本轮 Revit 进程内所有可识别 DLL 加载提示的自动处理、只读窗口诊断和回归测试。完整更新内容见 [版本记录](CHANGELOG.md)。

这是一个独立的 Skill 包，用于指导 AI 编码助手在 Revit 二次开发中尽可能自动完成测试：理解业务规则、设计场景、生成测试代码、构建、启动 Revit、在模型副本中执行、检查结果并回归验证。包内含技术方案、业务接入说明、PowerShell 工具及 C# 测试插件模板。

核心流程通过 Revit 官方 API 执行。需要验证按钮或正式命令入口时，可根据所用 AI 工具具备的桌面自动化能力追加操作测试。运行环境为 Windows、目标版本 Revit、可用许可及相应 .NET 开发工具。

## 版本与分享包

根目录的 [VERSION](VERSION) 是包版本的统一来源，当前内容为 `1.1`，对外展示为 `v1.1`。`SKILL.md` 的 `metadata.version`、正文版本及 `agents/openai.yaml` 的展示版本与之保持一致。

分享包命名为 `revit-ai-test-automation-v1.1.zip`，压缩包内保留 `revit-ai-test-automation/` 根目录。Skill 注册名、调用名和安装目录不含版本号；接收者查看 `VERSION` 即可确认安装版本。

后续发布时按以下规则递增版本，并同步更新上述标识与 [版本记录](CHANGELOG.md)，重新生成对应版本的分享包：

- 修复问题或补充说明：增加修订号，例如 `v1.1.1`。
- 增加兼容功能：增加次版本号，例如 `v1.2`。
- 引入不兼容变更：增加主版本号，例如 `v2.0`，并在版本记录中说明迁移方法。

## 安装与使用

克隆本仓库即可取得完整项目：

```powershell
git clone https://github.com/RegalZzz/revit-ai-test-automation.git
```

也可在 GitHub 使用 Code → Download ZIP，解压后将目录改名为 `revit-ai-test-automation`。项目根目录就是完整 Skill 根目录，保留整个目录结构，并按所用 AI 编码助手的技能加载方式安装。以下为支持这些目录的工具的安装示例：

- 个人使用：放到 `%USERPROFILE%\.codex\skills\`（配置了 `CODEX_HOME` 时使用其 `skills/`）。
- 团队项目使用：放到项目的 `.agents/skills/`。

在支持 `$skill-name` 调用的助手中输入：

> 使用 $revit-ai-test-automation 为当前 Revit 插件设计并尽可能自动完成回归测试。复用业务服务，生成测试场景，在模型副本中执行，诊断失败并输出可核验的结果。

其他 AI 工具可直接读取 `SKILL.md`，再按其中的相对路径使用参考文档、脚本和模板。`agents/openai.yaml` 是可选的宿主展示元数据；测试脚本和 C# 模板可以独立使用。

## 项目结构

```text
revit-ai-test-automation/
├── SKILL.md             AI 执行指引
├── README.md            安装与使用
├── VERSION              当前包版本
├── CHANGELOG.md         版本更新记录
├── agents/              Skill 展示与调用元数据
├── scripts/             PowerShell 启动、诊断与结果读取工具
├── assets/harness/      Revit 测试插件的 C# 项目模板
├── references/          技术方案、业务接入、加载确认和验证记录
├── tests/               DLL 加载弹窗的原生控件回归测试
└── LICENSE              MIT 许可证
```

## 直接使用脚本

需要已安装目标版本的 Revit、可用许可、.NET SDK 和相应 targeting pack。支持 Windows PowerShell 5.1 和 PowerShell 7；启动时使用进程级临时执行策略，无需永久修改用户/系统策略。

主测试提供 `scripts/Run-RevitIntegrationTest.cmd`：优先使用可发现的 PowerShell 7，否则用 Windows PowerShell 5.1。创建项目和读取结果也提供两种宿主的启动示例，见 [权限与版本兼容](references/powershell-compatibility.md)。如果仅有 5.1，将下例中的 `pwsh.exe` 换成 `powershell.exe`。

以下从 skill 目录执行，路径按本机实际位置填写：

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File ".\scripts\New-RevitTestHarness.ps1" `
    -Destination 'D:\MyRevitProject\tests\MyPluginIntegrationTests' `
    -Name MyPluginIntegrationTests -RevitVersion 2019

# 编辑生成的 TestScenario.cs，并添加真实业务项目引用后，先检查准备阶段。
.\scripts\Run-RevitIntegrationTest.cmd `
    -ProjectPath 'D:\MyRevitProject\tests\MyPluginIntegrationTests\MyPluginIntegrationTests.csproj' `
    -RevitInstallDir 'D:\Program Files\Autodesk\Revit 2019' `
    -ModelPath 'D:\TestAssets\BaseModel.rvt' -PrepareOnly

# 去掉 -PrepareOnly 才会启动新的 Revit 进程并运行测试。
# 单个 CAD / 链接输入可用 -FixturePath 'D:\TestAssets\Input.dwg' 复制。
# 多个 fixture 在 PowerShell 会话中传数组，详见兼容说明。
# 超时或人工处理启动提示后，读取同一运行目录：
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Read-RevitTestResult.ps1" -RunDirectory 'D:\MyTestRuns\实际运行目录'
```

默认结果目录为测试项目下的 `.local/revit-tests/<运行 ID>/`，可通过 `-TestRoot` 指定。将测试产物目录排除出版本管理。`scripts/` 下文件须保持同目录；模板只在创建新测试项目时使用。

临时 Bypass 不能覆盖组织强制策略，也不会获得管理员或文件访问权限。遇到这类限制按具体来源处理，不自动提权。

如果已授权自动信任本轮 Revit 进程中出现的 DLL，实际启动时可加 `-AutoTrustRunner`。外部辅助脚本准确匹配目标进程和启动时间，通过 UI Automation 获取 DLL 加载弹窗的按钮控件，逐个调用“始终加载/总是载入”，持续到目标进程退出或测试超时。DLL 路径仅记录证据；测试入口 DLL 仍保留 SHA256 完整性校验，其他 DLL 同样处理。详情见 [加载确认自动处理](references/publisher-approval.md)。

这项能力由包内 PowerShell + Windows UI Automation 实现，AI 可直接调用，无需额外安装鼠标自动化库。控件识别失败时，可对实际运行目录执行 `Get-RevitPublisherDialog.ps1`，获取该测试进程的弹窗和控件信息；完整命令与实现原理均见上述文档。

`api-smoke` 是可编译运行的基础 API 示例。未接入业务时，通过只表示基础流程成功。脚本不代替模型断言；未识别控件的 DLL 提示会保留并记录，其他类型的安全弹窗仍由用户处理。

技术细节见 [工作流程](references/workflow.md) 和 [业务接入](references/adapters.md)。本包不附 Autodesk 程序集和测试模型；接收者需要自行准备。

制作时的检查范围和未验证部分见 [资源验证记录](references/package-validation.md)。

项目采用 [MIT 许可证](LICENSE)。
