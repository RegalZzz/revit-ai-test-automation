# 自动处理指定测试 DLL 的“总是载入”

## 适用范围与授权

当用户明确要求自动信任本任务的指定测试 DLL 时，可以由外部 Windows UI Automation 操作 Revit 的“总是载入 / Always Load”。已有会话授权继续有效，无需为同一范围重复询问。该选择会记住此 DLL 的信任决定，与 PowerShell 的临时执行策略不同。

默认仍由人工处理加载确认。启用时只允许指定 Revit 进程、开始时间、DLL 完整路径和 SHA256 匹配的操作；未知 DLL、歧义路径、其他提示均停止自动操作。不修改全局安全开关、注册表白名单或证书库，不自动信任整台机器的插件。

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

`-AutoTrustRunner` 表示用户允许对本轮暂存的测试入口 DLL 选择“总是载入”。启动器生成期望路径与哈希，启动独立审批辅助进程，并记录 `publisher-approval-*.json` 和辅助进程日志。搭配 `-PrepareOnly` 时仍只做准备，不启动 Revit 或操作提示。

这个开关仅处理测试入口 DLL。启动时先遇到其他已安装插件的确认，结果为 `BlockedByOtherAddin`；由用户处理或在获得该 DLL 的授权后单独指定，不把其他插件自动加入信任范围。

AI 的具体执行顺序：

1. 运行上述命令，并保留启动器输出的运行目录和测试 PID。启动器已自动建立 spec 并并行启动辅助进程，不要再对同一提示启动第二个审批脚本。
2. 读取该目录的 `publisher-approval-result.json`，结合 `started.txt` 判定是否成功加载。不要把“启动器还在等待”直接视为失败，也不要要求用户重复处理已经自动处理的提示。
3. 结果缺失或超时时，读取 `publisher-approval.stderr.log`、`publisher-approval.stdout.log`、操作意图文件和只读窗口诊断；保留原 Revit。辅助进程日志在其退出且启动器捕获后才会落盘。
4. 加载成功后继续核验业务结果。启动器已超时的，先读取原运行结果，不自动重启 Revit 或覆盖旧记录。

## 为什么必须从 Revit 外部操作

Revit 的未签名模块提示可能出现在该 DLL 的 `IExternalApplication.OnStartup` 之前，此时它的 `DialogBoxShowing` 回调尚未注册。因此不能依靠该 DLL 自己处理自身加载提示。

`Invoke-RevitIntegrationTest.ps1` 先启动专用 Revit，记录 PID、UTC 开始时间、暂存 DLL 路径和哈希，再用当前宿主启动独立 PowerShell 辅助进程：`-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ...\Approve-RevitTestDll.ps1 -SpecPath ... -ApproveAlways`。辅助进程与启动器同时运行，启动器继续等测试结束。进程参数中的 `NonInteractive` 禁止 PowerShell 自身交互输入，不表示无 Windows 桌面运行。控制台隐藏，通过管道收集输出。

## 控件定位的实际依据

以下来自 Revit 2019 中文界面的真实 UI Automation 观察。名称可能随语言改变，不能只按标题或数字 ID 点击：

| 对象 | UI Automation 属性或内容 | 用途 |
| --- | --- | --- |
| 目标进程 | `ProcessName=Revit`，PID 和 UTC 开始时间与 `run.json` 一致 | 避免操作用户其他 Revit 或被复用的 PID |
| 模态对话框 | `ClassName=#32770`，实测标题“安全 - 未签名的附加模块” | 在目标进程窗口子树内定位；不把标题当作唯一条件 |
| 主说明 | `AutomationId=MainInstruction`，文字含“发布者”或 `publisher` | 确认提示类型 |
| 内容 | `AutomationId=ContentText`，其中有 DLL 完整位置 | 精确核对 DLL 路径 |
| 总是载入 | `AutomationId=CommandButton_1001`，实测 `Name=总是载入` | 仅当文字和其他条件都匹配时执行 |
| 载入一次 | `AutomationId=CommandButton_1002` | 与另两个按钮一起确认控件组合 |
| 不载入 | `AutomationId=CommandButton_1003` | 与另两个按钮一起确认控件组合 |

脚本也识别 `Always Load`、`总是加载` 和 `始终载入/加载` 等文字，但其他语言、年份和版本未实机验证。未知控件或语言保持未操作状态，先用后文只读脚本观察，不猜测新 ID。

## 源码级实现步骤

可执行的完整实现为 [Approve-RevitTestDll.ps1](../scripts/Approve-RevitTestDll.ps1)，不要让模型另写一份缩减校验的点击脚本。关键 API 和顺序如下：

1. 用 `Add-Type -AssemblyName UIAutomationClient` 加载组件；从 UTF-8 spec 取得目标进程、开始时间和 DLL。
2. 用 `Get-Process -Id` 核对名称；将开始时间统一为 `[DateTimeOffset]`，比较 `.UtcDateTime.Ticks` 与进程 `.StartTime.ToUniversalTime().Ticks`。使用 `Get-FileHash -Algorithm SHA256` 校验实际 DLL 字节；进程退出或哈希变化立即停止。
3. 对 `AutomationElement.RootElement.FindAll(TreeScope.Children, PropertyCondition(ProcessIdProperty, targetId))` 返回的顶层窗口逐个观察。在每个窗口内用 `FindAll(TreeScope.Subtree, PropertyCondition(ClassNameProperty, '#32770'))` 找原生模态框，不枚举全桌面每个按钮。
4. 用 `FindFirst(TreeScope.Descendants, PropertyCondition(AutomationIdProperty, id))` 找上述五个控件。三个按钮、内容和主说明必须同时存在；主说明和“总是载入”文字均须匹配。
5. 从 `ContentText.Current.Name` 的 DLL 位置字段提取唯一完整路径，与 `Resolve-Path -LiteralPath` 得到的期望路径作忽略大小写的完整比较。只处理本地盘符绝对路径；不支持或含歧义的路径不操作。先提取路径，再归一化 UI 提供者转义的双反斜杠；不要对整段内容解码 `\n`，否则真实的 `\new` 目录会被破坏。
6. 只允许一个匹配对话框。调用前再检查进程身份、DLL 哈希、目标 PID 和按钮 `Current.IsEnabled`。取得 `InvokePattern`，先写 `.intent.json` 并标记本次已尝试，再调用一次 `Invoke()`。
7. 每 400 ms 观察一次，等待本次 DLL 在真实 `OnStartup` 中写入的 `started.txt`；父启动器变为 `TimedOut` / `LauncherFailed` 时停止后续操作。一次脚本运行最多发起一次点击，调用异常也不自动重试。

实际执行按钮的方法是以下两行。这里的 `$match.Button` 是完整脚本完成以上所有校验后获得的控件；此片段只解释调用机制，不应脱离完整脚本单独运行：

```powershell
$pattern = $match.Button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
$pattern.Invoke()
```

`InvokePattern` 相当于直接调用该按钮的操作，不依赖屏幕坐标、窗口摆放或 OCR。若提供者不支持该模式，脚本报错并保留现场，不退回盲按回车。PowerShell 匹配语句会自动改写 `$Matches`，所以源码中的候选集合使用 `$dialogCandidates`，不要改名为 `$matches`。

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
| 找到其他 DLL 的提示 | 保留原进程，按已有授权范围处理，不能把其他 DLL 自动加入信任范围 |
| 无匹配控件或路径不明 | 保存诊断信息；无法依据实际控件适配时交给用户 |
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

PID、开始时间、路径和哈希必须来自实际本轮启动记录，不沿用示例值。可以先不传 `-ApproveAlways` 运行，返回 `ObservedOnly` 时不操作按钮；取得适用授权后，用新的结果文件路径重新运行并传 `-ApproveAlways`。

本包启动器使用的 spec 字段来源：

| spec 字段 | 实际数据来源 |
| --- | --- |
| ProcessId / ProcessStartedUtc | `run.json` 同名字段，由启动 Revit 的进程对象记录 |
| AssemblyPath | `run.json.TestAssemblyPath`，指向暂存目录中的本轮 DLL |
| AssemblySha256 | `run.json.TestAssemblySha256`，不得用错误文件哈希替换以绕过不匹配 |
| TimeoutSeconds | 本轮辅助等待时长，1–600 秒 |
| StartedSignalPath | 本轮目录的 `started.txt`，由测试 DLL 自己写入，不能人工创建冒充成功 |
| ResultPath | 本轮目录内新的结果文件路径；对应 `.intent.json` 也必须不存在 |
| ParentRunPath | 本轮 `run.json`，可选；本包启动器始终填写，以便超时后停止审批 |

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Approve-RevitTestDll.ps1" -SpecPath 'D:\TestRuns\approval-spec.json' -ApproveAlways
```

也可使用 Windows PowerShell 5.1。需要交互式 Windows 桌面及可用的 UI Automation；脚本无权操作目标窗口时记录错误并保留原进程，不自动提权。

## 如何判断成功

- `ObservedOnly`：识别到预期提示，未发起操作。
- `RunnerStartedAfterInvoke`：发起“总是载入”后收到预期测试入口的启动信号。
- `RunnerAlreadyStarted`：入口已经启动，本次没有点击；不能据此声称本次自动点击成功。
- `BlockedByOtherAddin`：提示对应其他 DLL 或完整路径无法确认，未对该提示操作。
- `InvocationOutcomeUnknown`：调用结果不明，检查原窗口和日志，不自动再点击。
- `InvokedAndProcessExited` / `ProcessExitedWithoutAction`：进程已退出，需读取真实测试结果；单凭退出不能证明加载或测试成功。
- `TimedOut` / `LauncherStopped`：保留进程，先检查本轮状态。

加载确认成功不等于业务测试通过；仍需核验业务断言、回滚和输入文件哈希。验证长期记忆时，使用相同 DLL 路径及文件内容启动新 Revit，再确认无需审批操作就能收到启动信号。DLL 重建或路径变化时可能再次提示，不假定一次选择永久覆盖所有后续文件。

实测证据和版本范围见 [资源验证记录](package-validation.md)。本方法不会关闭 Revit 全局加载检查、修改证书库或向所有插件授信。
