# 自动处理本轮 Revit 进程内所有 DLL 的“总是载入”

## 适用范围与授权

当用户明确要求自动信任本轮目标 Revit 进程中出现的 DLL 时，可以由外部 Windows UI Automation 操作 Revit 的“总是载入 / Always Load”。已有会话授权继续有效，无需为同一范围重复询问。该选择会记住各 DLL 的信任决定，与 PowerShell 的临时执行策略不同。

默认仍由人工处理加载确认。启用时只允许目标 Revit 进程及其开始时间匹配的窗口；脚本通过窗口树取得标准 DLL 提示的内容控件和三个按钮，对每个能确认是 DLL 加载提示的窗口逐个点击“总是载入/加载”。DLL 路径只用于记录证据，不作为过滤条件，因此路径格式差异不会漏掉其他 DLL。它不会关闭其他安全、修复、保存或配置提示，也不会修改全局安全开关、注册表白名单或证书库。

## 在测试启动器中使用

优先直接运行包内脚本。此实现依靠 Windows 自带的 .NET `System.Windows.Automation`，AI 只需能执行本地 PowerShell，无需具备截图识别、鼠标定位或某一 AI 产品的桌面插件。需要已登录且未锁定的交互式 Windows 桌面、目标 Revit 窗口和适用的操作授权；普通无桌面的 CI 服务不能按本方法保证可用。

从 skill 根目录执行，按本机实际情况填写路径：

```powershell
.\scripts\Run-RevitIntegrationTest.cmd `
    -ProjectPath 'D:\MyProject\tests\MyTests\MyTests.csproj' `
    -RevitInstallDir 'D:\Program Files\Autodesk\Revit 2019' `
    -ModelPath 'D:\TestAssets\BaseModel.rvt' `
    -AutoTrustRunner
```

`-AutoTrustRunner` 现在表示允许对本轮目标 Revit 进程内所有可识别的 DLL 加载提示选择“总是载入”。启动器生成测试入口 DLL 的路径与哈希，用于完整性校验；辅助进程不会用它限制其他 DLL。每次操作都会记录在 `ApprovedDlls` 中，并为该次调用写入独立的 `.intent.json`。搭配 `-PrepareOnly` 时仍只做准备，不启动 Revit 或操作提示。

辅助进程持续处理目标进程内后续出现的 DLL 提示，直到目标进程退出或本轮超时；不能识别标准控件的 DLL 提示会记录在 `SkippedDialogs`，不会被猜测点击。路径无法解析时仍通过控件执行，并在操作记录中保留原始提示文本。

AI 的具体执行顺序：

1. 运行上述命令，并保留启动器输出的运行目录和测试 PID。启动器已自动建立 spec 并并行启动辅助进程，不要再对同一提示启动第二个审批脚本。
2. 读取该目录的 `publisher-approval-result.json`，结合 `started.txt`、`RunnerStarted` 和 `ApprovedDlls` 判定加载与操作情况。`Monitoring` 表示辅助进程仍在监控，操作记录会逐次更新；不要把“启动器还在等待”直接视为失败。
3. 结果缺失或超时时，读取 `publisher-approval.stderr.log`、`publisher-approval.stdout.log`、操作意图文件和只读窗口诊断；保留原 Revit。辅助进程日志在其退出且启动器捕获后才会落盘。
4. 加载成功后继续核验业务结果。启动器已超时的，先读取原运行结果，不自动重启 Revit 或覆盖旧记录。

## 为什么必须从 Revit 外部操作

Revit 的未签名模块提示可能出现在该 DLL 的 `IExternalApplication.OnStartup` 之前，此时连测试 DLL 的 `DialogBoxShowing` 回调也尚未注册。因此不能依靠某一个 DLL 自己处理自身或其他 DLL 的加载提示。

`Invoke-RevitIntegrationTest.ps1` 先启动专用 Revit，记录 PID、UTC 开始时间、暂存测试 DLL 路径和哈希，再用当前宿主启动独立 PowerShell 辅助进程：`-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ...\Approve-RevitTestDll.ps1 -SpecPath ... -ApproveAlways`。辅助进程与启动器同时运行，持续扫描目标进程的 DLL 提示；收到测试入口的 `started.txt` 后继续监控，覆盖打开模型和运行测试时稍后出现的其他 DLL。辅助等待时长与本轮测试一致，启动器结束时等待辅助进程写完结果并收集日志。进程参数中的 `NonInteractive` 禁止 PowerShell 自身交互输入，不表示无 Windows 桌面运行。控制台隐藏，通过管道收集输出。

## 控件定位的实际依据

以下来自 Revit 2019 中文界面的真实 UI Automation 观察。名称可能随语言改变，不能只按标题或数字 ID 点击：

| 对象 | UI Automation 属性或内容 | 用途 |
| --- | --- | --- |
| 目标进程 | `ProcessName=Revit`，PID 和 UTC 开始时间与 `run.json` 一致 | 避免操作用户其他 Revit 或被复用的 PID |
| 模态对话框 | `ClassName=#32770`，实测标题“安全 - 未签名的附加模块” | 在目标进程窗口子树内定位；不把标题当作唯一条件 |
| 内容 | `AutomationId=ContentText`，其中包含 `.dll` | 确认这是 DLL 加载提示，并记录原始内容 |
| 总是载入 | `AutomationId=CommandButton_1001`，实测 `Name=总是载入` | 仅当文字和其他条件都匹配时执行 |
| 载入一次 | `AutomationId=CommandButton_1002` | 与另两个按钮一起确认控件组合 |
| 不载入 | `AutomationId=CommandButton_1003` | 与另两个按钮一起确认控件组合 |

脚本也识别 `Always Load`、`总是加载`、`始终载入/加载` 及对应的“载入一次/不载入”按钮文字。其他语言、年份和版本未实机验证；缺少标准控件的提示会记录到 `SkippedDialogs` 并保持未操作，先用只读脚本观察，不猜测新 ID。

## 源码级实现步骤

可执行的完整实现为 [Approve-RevitTestDll.ps1](../scripts/Approve-RevitTestDll.ps1)，不要让模型另写一份缩减校验的点击脚本。关键 API 和顺序如下：

1. 用 `Add-Type -AssemblyName UIAutomationClient` 加载组件；从 UTF-8 spec 取得目标进程、开始时间、测试 DLL 和结果路径。
2. 用 `Get-Process -Id` 核对名称和开始时间；使用 `Get-FileHash -Algorithm SHA256` 校验测试 DLL 字节。进程退出或测试 DLL 哈希变化立即停止。
3. 用 Win32 `EnumWindows` / `EnumChildWindows` 快速筛选目标 PID 下的 `#32770` 原生对话框，再通过 `AutomationElement.FromHandle()` 获取控件树。UI Automation 不遍历桌面其他程序或 Revit 的整个 Ribbon，避免无关窗口拖慢扫描。
4. 查找 `ContentText` 和三按钮；优先使用 `CommandButton_1001/1002/1003` 或 `CommandLink_1001/1002/1003`，再按已知英文及简体中文文字查找控件。只要内容包含 `.dll` 且标准三按钮齐全，就加入待处理集合；不把当前测试入口路径作为过滤条件。
5. 调用前再次检查目标进程、按钮 `Current.IsEnabled` 和测试 DLL 哈希。为每次调用写入独立 intent 文件，优先调用 `InvokePattern.Invoke()`；若已取得的控件没有该模式，但原生类名确认为 `Button`、PID 匹配且可用，则从其 `AutomationId` 读取命令 ID，向经过 PID 和类名校验的所属对话框投递 `TDM_CLICK_BUTTON`。单个仍显示的弹窗不会反复点击，弹窗消失后可处理复用相同 HWND 的新提示。
6. 每 400 ms 观察一次，每次取得控件后只调用一个提示，再重新枚举窗口，以免继续访问已关闭的控件。即使测试入口写入 `started.txt` 仍持续监控；目标进程退出、本轮超时或父启动器变为 `TimedOut` / `LauncherFailed` 时停止操作。每次调用后更新结果和证据。

实际执行按钮的方法是以下两行。这里的 `$match.Button` 是完整脚本完成以上所有校验后获得的控件；此片段只解释调用机制，不应脱离完整脚本单独运行：

```powershell
$pattern = $match.Button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
$pattern.Invoke()
```

`InvokePattern` 相当于直接调用该按钮的操作，不依赖屏幕坐标、窗口摆放或 OCR。原生命令链接可能被 UI Automation 暴露为 `Pane` 且不支持该模式，此时通过已验证的原生 `Button` 及其控件命令 ID 投递 `TDM_CLICK_BUTTON`，支持对话框未在前台时的操作。操作记录的 `Method` 区分两种方式；均不猜坐标、不盲按回车。两种方式都不支持时保留现场并报告错误。PowerShell 匹配语句会自动改写 `$Matches`，所以源码中的候选使用 `$dialogCandidates` / `$match`，不要改名为 `$matches`。

脚本已经处理以上检查、操作意图及结果。已有结果或尚未查明的操作意图会拒绝再次运行；只能先核对旧记录和原窗口，再决定是否需要新的一次操作。

## 只读诊断：让不同 AI 获取相同的控件证据

识别失败、其他语言或版本适配时，从 skill 根目录执行：

```powershell
pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File '.\scripts\Get-RevitPublisherDialog.ps1' `
    -RunDirectory 'D:\MyTestRuns\实际运行目录'
```

仅有 Windows PowerShell 5.1 时，将 `pwsh.exe` 换成 `powershell.exe`。执行策略只作用于子进程，不能覆盖组织强制策略，也不解决窗口访问权限问题。

该脚本从运行记录核对 PID 和开始时间，然后输出 JSON：`ReadOnly`、目标进程、窗口列表，以及每个 `#32770` 弹窗内控件的 `AutomationId`、`Name`、`ControlType`、`IsEnabled` 和 `ProcessId`。它不调用按钮、不切换焦点、不发按键，也不写文件；需要留证时由调用者将输出保存到本轮运行目录。

检查诊断输出中的实际 DLL 位置、发布者说明和按钮文字，再依据证据调整审批脚本识别条件并复测。`NoModalDialogObserved` 只表示当前未看到该类窗口，可能是尚在启动、已加载或另一个界面阻塞；不等于 DLL 已加载成功。进程已退出则看保存的结果，不改用任意其他 Revit 进程。

| 观察结果 | 下一步 |
| --- | --- |
| 找到 DLL 提示但未识别控件 | 保存诊断信息；依据实际控件适配后再复测 |
| DLL 路径格式无法解析 | 标准控件匹配时仍执行；查看操作记录的 `ContentText` |
| UI Automation 无权读取或调用 | 核对交互桌面、是否锁屏及权限差异；不自动提权 |
| `.intent.json` 已有，结果缺失或未知 | 检查原窗口及启动信号，禁止直接再次调用 |
| 加载已成功，业务仍等待 | 看 `dialogs.log` 和业务日志；加载确认不处理其他模态提示 |

## 单独调用与观察模式

已有启动器没有接入 `-AutoTrustRunner` 时，可单独调用同一个辅助脚本。先确认本轮没有另一个审批进程，也没有未决操作意图；以下不是同时运行第二个审批进程的步骤。

`Approve-RevitTestDll.ps1` 接收一个 UTF-8 JSON 文件：

```json
{
  "ProcessId": 12345,
  "ProcessStartedUtc": "2026-11-04T00:00:00.0000000Z",
  "AssemblyPath": "D:\\TestRuns\\bin\\MyTests.dll",
  "AssemblySha256": "实际文件的64位SHA256十六进制值",
  "TimeoutSeconds": 120,
  "StartedSignalPath": "D:\\TestRuns\\started.txt",
  "ResultPath": "D:\\TestRuns\\publisher-approval-result.json",
  "ParentRunPath": "D:\\TestRuns\\run.json"
}
```

PID、开始时间、测试入口路径和哈希必须来自实际本轮启动记录，不沿用示例值。`AssemblyPath`/`AssemblySha256` 用于校验测试入口完整性，不限制其他 DLL 提示。可以先不传 `-ApproveAlways` 运行，返回 `ObservedOnly` 时不操作按钮；取得适用授权后，用新的结果文件路径重新运行并传 `-ApproveAlways`。

本包启动器使用的 spec 字段来源：

| spec 字段 | 实际数据来源 |
| --- | --- |
| ProcessId / ProcessStartedUtc | `run.json` 同名字段，由启动 Revit 的进程对象记录 |
| AssemblyPath | `run.json.TestAssemblyPath`，指向暂存目录中的本轮 DLL |
| AssemblySha256 | `run.json.TestAssemblySha256`，不得用错误文件哈希替换以绕过不匹配 |
| TimeoutSeconds | 本轮辅助等待时长，1–86400 秒；启动器传入与测试相同的时长 |
| StartedSignalPath | 本轮目录的 `started.txt`，由测试 DLL 自己写入，不能人工创建冒充成功 |
| ResultPath | 本轮目录内新的结果文件路径；旧 `.intent.json` 和新的 `.action-XXXX.intent.json` 均必须不存在 |
| ParentRunPath | 本轮 `run.json`，可选；本包启动器始终填写，以便超时后停止审批 |

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Approve-RevitTestDll.ps1" -SpecPath 'D:\TestRuns\approval-spec.json' -ApproveAlways
```

也可使用 Windows PowerShell 5.1。需要交互式 Windows 桌面及可用的 UI Automation；脚本无权操作目标窗口时记录错误并保留原进程，不自动提权。

## 如何判断成功

- `Monitoring`：持续监控中；查看 `ApprovedDlls`、`ActionCount` 及 `RunnerStarted`，结果会逐次更新。
- `ObservedOnly`：识别到 DLL 提示，未发起操作。
- `RunnerStartedAfterInvoke`：处理了一个或多个 DLL 提示，并收到本轮测试入口的启动信号。
- `RunnerAlreadyStarted`：入口已经启动，本次没有点击；不能据此声称本次自动点击成功。
- `InvocationOutcomeUnknown`：调用结果不明，检查原窗口和日志，不自动再点击。
- `InvokedAndProcessExited` / `ProcessExitedWithoutAction`：进程已退出，需读取真实测试结果；单凭退出不能证明加载或测试成功。
- `TimedOut` / `LauncherStopped`：保留进程，先检查本轮状态。

加载确认成功不等于业务测试通过；仍需核验业务断言、回滚和输入文件哈希。`ApprovedDlls` 展示实际处理的 DLL，`SkippedDialogs` 展示无法安全识别的提示。某个 DLL 的信任决定可能只对对应路径和文件生效，DLL 重建或路径变化时可能再次提示，不假定一次选择永久覆盖所有后续文件。

实测证据和版本范围见 [资源验证记录](package-validation.md)。本方法不会关闭 Revit 全局加载检查、修改证书库或向所有插件授信。
