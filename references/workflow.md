# 技术方案与运行说明

## 执行链

```text
PowerShell 构建测试 DLL、复制输入、生成运行 ID
  → 临时注册 Application .addin
  → 新 Revit 进程（仅该进程继承测试环境变量）
  → IExternalApplication.OnStartup 注册 Idling
  → 一次 Idling：打开副本 → 构造场景 → 真实业务服务 → 模型断言/导图
  → 回滚事务组 → 关闭测试文档且不保存 → 原子写 result.json
  → 没有其他文档时 PostCommand(ExitRevit)
  → PowerShell 核对结果、哈希和进程状态，删除自己的临时清单
```

这是在桌面版 Revit 内运行的集成测试，不是独立于 Revit 的几何模拟，也不是无界面的服务器服务。机器需要能正常启动目标 Revit 和许可。

脚本入口支持 Windows PowerShell 5.1 与 PowerShell 7；`Run-RevitIntegrationTest.cmd` 自动选择宿主并只给新进程临时执行策略。创建项目、读取结果及组织限制处理见 [PowerShell 权限与版本兼容](powershell-compatibility.md)。

## 创建器与版本

`New-RevitTestHarness.ps1` 复制 `assets/harness/`，替换程序集/命名空间并生成独有 AddInId 和 `harness.json`。它拒绝覆盖现有目录。生成项目使用 SDK csproj、x64 和显式 Compile；API 引用 `Private=False`。

| 目标 Revit | 模板框架 | 验证含义 |
| --- | --- | --- |
| 2019–2024 | .NET Framework 4.8 | 必须使用该年的 API 编译并实机回归；早期版本部署需安装 .NET 4.8 |
| 2025–2026 | .NET 8 Windows | 使用对应 API、SDK；编译和每年实机兼容性各自验证 |

Revit 的 API 年份不能只靠 TargetFramework 推断。运行结果记录实际 `VersionNumber` 和 `VersionBuild`，年份不匹配则失败。未列出的新版本先核对官方运行时要求，再扩展创建器，不能默认兼容。

## 启动器

`Invoke-RevitIntegrationTest.ps1` 参数：

| 参数 | 用途 |
| --- | --- |
| ProjectPath | 创建器生成的测试 csproj，旁边必须有 harness.json |
| RevitInstallDir | 含 Revit.exe、RevitAPI.dll、RevitAPIUI.dll 的目标安装目录 |
| ModelPath | 测试底模的本地 RVT 路径；只复制和读取源文件 |
| FixturePath | 可选额外本地文件，复制到运行目录 inputs/；按文件名取用 |
| TestRoot | 可选结果根目录；默认测试项目下 .local/revit-tests/ |
| TimeoutSeconds | 默认 600；按真实测试耗时调整，不以无限等待代替诊断 |
| PrepareOnly | 构建并生成副本与清单，但不注册、不启动 Revit |
| AutoTrustRunner | 明确授权后，仅对本轮测试入口 DLL 自动操作“总是载入” |

每轮输出包括构建日志、测试 DLL 及依赖、Model.rvt、输入副本、待注册清单、run.json。API DLL 不应出现在测试输出中。临时 `.addin` 写入当前用户对应年份的 Addins 目录，测试结束只删除本轮文件。

底模应为已关闭的专用测试文件；文件被 Revit 或其他进程独占时，启动器停止并保留错误记录。选择一个已关闭的 fixture 或副本再运行，不干预占用该文件的用户进程。

同一 Windows 会话中使用按年份的互斥锁及活动进程记录，阻止本工具重复启动尚未完成的测试。互斥锁不能约束其他自动化工具；调用者仍应串行安排 Revit 测试。测试插件若没有配对环境变量/运行 ID 就不执行，因此其他正常启动的 Revit 即便扫描到清单也不会建模。

## 文档与事务

`OpenDocumentFile` 打开 API 文档，不保证它成为用户界面的活动文档。业务服务测试可以显式传入 `Document` 和 `View`。依赖 `ActiveUIDocument`、选择集或交互的命令，要单独设计激活文档和正式入口的测试。

模板检测工作共享文件并以 `DetachAndPreserveWorksets` 打开副本；不保存、不同步中心。主文档的复制不会复制外部链接、共享参数文件等资源。需要变更链接时，先创建专用链接副本并明确重载到该副本。

场景放在一个外层 TransactionGroup 中；场景和业务代码各自使用子 Transaction。模板检查回滚返回值以及前后元素 ID 集合。事务组不保护外部文件、项目外配置、新建的其他文档或 HTTP 请求，这些由具体场景独立管理。

业务服务若自带同类 TransactionGroup，确认其嵌套行为；若本来要求外层已有 Transaction，按其契约调用，不因测试模板强行改变生产事务语义。

## 启动提示与超时

模板订阅 DialogBoxShowing 只记录 DialogId。发布者信任提示可能在 OnStartup 之前发生，此时连 started.txt 都可能不存在。默认由用户处理；用户明确授权指定测试 DLL 时，可按 [发布者提示自动处理](publisher-approval.md) 启用外部辅助脚本。不用坐标盲点“确定”。确需处理无关配置警告时，根据已观察的 DialogId 添加精确分支并记录结果。

超时后启动器返回失败，清理临时注册但保留进程和运行目录。处理提示后运行：

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Read-RevitTestResult.ps1" -RunDirectory '本轮实际目录'
```

仅有 Windows PowerShell 5.1 时，将 `pwsh.exe` 换成 `powershell.exe`。

读取器不启动、不关闭 Revit。结果未产生是“未完成”；有效结果但进程仍活跃时明确报告。成功结论必须包含正确运行 ID/进程 ID、对应年份、完整结果、至少一条断言、无失败、回滚成功、文档关闭、程序集哈希匹配，以及源文件和输入副本哈希未变。

不能把旧运行的 PASS、PrepareOnly 的成功、启动器早先的超时退出码，写成新一轮通过。测试生成 result.json 后才会请求退出；退出请求可能被其他文档或弹窗阻挡，不应强制终止。

## 结果与证据

- `run.json`：启动器的运行 ID、输入路径和哈希、期望年份、PowerShell 版本/Edition、测试程序集哈希及进程 ID。
- `started.txt` / `dialogs.log`：确认插件是否真正加载，以及到达回调后的弹窗 ID。
- `assertions.log`：逐条断言和异常，执行时刷新。
- `result.json`：完成后原子写入的强类型结果，包括 Scope、版本、回滚、断言数、错误及业务程序集路径/哈希。
- 导出 PNG：通过 ExportImage 指定测试视图取得。图片是补充证据，几何和参数断言仍是判断依据。

错误定位顺序：无 Revit 进程→启动参数/许可；有进程无 started.txt→加载/信任提示；已启动但无结果→查看日志和 Revit 提示；结果失败→查看具体断言；业务通过但正式入口失败→另查命令上下文、界面或调用参数。

## 来源与验证边界

方案来自 Revit 2019 的消火栓及雨污水标注回归实践：在模型副本中生成测试对象、验证实际连接器/标注几何、导图并回滚。通用包移除了这些项目专用的族名、系统名、路径和依赖。原业务通过不代表新接入业务或其他 Revit 年份已经通过。
