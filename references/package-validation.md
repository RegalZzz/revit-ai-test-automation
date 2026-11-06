# 包内资源验证记录

日期：2026-11-06。

## 2026-11-06：统一包版本

当前最新版明确为 v1.1。增加 `VERSION` 和 `CHANGELOG.md`，统一 README、Skill 元数据及界面展示版本；分享包命名为 `revit-ai-test-automation-v1.1.zip`，包内根目录仍为 `revit-ai-test-automation/`。本次只调整版本说明与展示，不变更测试脚本、DLL 提示处理或 Revit 模板。

## 2026-11-05：扩展为处理本轮全部 DLL 提示

`Approve-RevitTestDll.ps1` 现在按目标 Revit PID、进程开始时间、`#32770` 对话框、`ContentText` 中的 `.dll` 文本和标准三按钮控件识别提示，不再把测试入口 DLL 路径作为过滤条件。Win32 先筛选目标窗口，再由 UI Automation 取得按钮控件；优先调用 `InvokePattern`，原生命令链接缺少该模式时按已验证的控件命令 ID 调用 `TDM_CLICK_BUTTON`。一次运行可连续处理多个 DLL，收到测试入口启动信号后仍持续到进程退出或本轮超时。`ApprovedDlls` 记录每次操作，`SkippedDialogs` 记录无法识别的 DLL 提示；测试入口 DLL 仍保留 SHA256 完整性校验。

新增可复现测试 `tests/Test-PublisherApproval.ps1` 及原生 TaskDialog 测试替身。在 Windows PowerShell 5.1.22621.7376 与 PowerShell 7.5.4 下各通过 23 项断言：连续四个 DLL 提示、测试入口启动前后的其他 DLL（含延迟三秒的提示）、中文“始终加载”、控件 ID 不同、特殊路径、标准按钮与命令链接、排除其他进程、观察模式、无关按钮及非 DLL 提示、超时保留进程、父启动器停止、开始时间/哈希不符，以及已有操作意图的拒绝重试。本机 TaskDialog 控件实际通过 `TDM_CLICK_BUTTON` 选中预期按钮，并由替身记录返回的按钮 ID；不将它作为 `InvokePattern` 分支的新实机证据。全部六份 PowerShell 脚本在两种宿主解析通过，包内 15 个 Markdown 本地链接检查通过。

以上测试未启动真实 Revit、加载 DLL、改变 DLL 信任或读写模型。本次未新增真实 Revit 多 DLL 弹窗实测；此前单 DLL 的 Revit 2019 证据见下文，实际插件集合及其他版本仍需分别验证。

## 2026-11-05：独立项目与更名

项目、Skill 目录、注册名称、展示名称和调用示例统一为 `revit-ai-test-automation`，版本保持 v1.1。独立项目根目录即完整 Skill 根目录，包含所有说明、参考文档、脚本和 C# 模板，可直接复制安装。临时测试清单与活动记录的文件前缀同步使用新名称。

本次检查更名后的 Skill 结构、相对链接、项目与安装副本内容一致性、PowerShell 5.1/7 脚本解析及分享包字节完整性。未重新执行真实 Revit 测试；原有实机与脚本验证范围见下文。

## v1.1 本次更新

补充“总是载入”的源码级技术说明：外部辅助进程的启动时机、UI Automation 遍历 API、实测控件 ID、路径与 SHA256 检查、InvokePattern 调用、启动信号判定及不同模型的执行顺序。

新增 `Get-RevitPublisherDialog.ps1` 只读诊断脚本。在 Windows PowerShell 5.1.22621.7376 与 PowerShell 7.5.4 下分别通过 13 项检查，覆盖五份脚本解析、指定进程观测、无模态框状态、排除其他进程窗口、运行记录未变、开始时间不匹配、错误进程名、未启动运行及进程已退出。使用短期进程 test double，没有启动真实 Revit、操作加载按钮或读写模型。本次新增诊断脚本未重新在真实 Revit 弹窗上运行；自动点击的实机依据仍为下方已记录的 Revit 2019 测试。

v1.1 的 Skill 结构、相对链接、版本标识及归档内容在交付时检查。分享 ZIP 保持 `revit-ai-test-automation/` 根目录，只含文档、脚本和源码模板。

## 已验证

- Skill 结构检查通过；包内相对链接和模板替换完整。
- 原有三份 PowerShell 脚本在 Windows PowerShell 5.1.22621.7376 和 PowerShell 7.5.4 中解析并执行相关流程；新增加载确认辅助脚本的两宿主检查见下文。
- 生成 net48 测试项目，使用本机 Revit 2019 API 构建：0 警告、0 错误。
- PrepareOnly 实际完成构建、模型副本、Application 清单和运行记录，支持中文及空格路径；未启动 Revit。
- 25 项脚本/结果检查通过，涵盖拒绝覆盖已有项目、2025 框架选择、准备结果不能冒充通过、错误运行 ID/进程 ID/版本、失败标志、缺少断言、回滚/关闭缺失、程序集哈希错误、输入变化、缺少结果，以及保留原超时状态。
- 以明确标注为 test double 的本地小进程验证启动器：子进程环境传参、额外 fixture 复制、正常结束与结果读取、超时保留进程并清理本轮清单、活动子进程阻止重复启动，以及超时后读取原结果。模拟进程未调用任何 Revit API。
- 两种宿主均验证中文及空格路径、UTF-8 JSON、ISO 日期与活动进程识别、原生程序 stderr 和非零构建退出码。PowerShell 7 另外验证启用原生命令错误偏好时仍正确保存失败日志。
- CMD 入口实际验证自动选择 7 和回落 5.1 两个分支：临时 Bypass、完整 PrepareOnly、中文参数、错误退出码；父会话执行策略保持不变。回落分支也覆盖从 7 启动 5.1 时的模块路径隔离。
- 在 Process 策略为 Restricted 的父进程中，通过 CMD 入口成功启动临时 Bypass 子进程执行 PrepareOnly；父进程仍保持 Restricted。没有修改 CurrentUser/LocalMachine，也未测试或宣称能够覆盖组织强制策略。

## 发布者确认与真实 Revit 运行

- 在 Revit 2019 中文界面实测按 PID、进程开始时间、DLL 路径和 SHA256 匹配后，以 UI Automation InvokePattern 操作“总是载入”；结果为 `RunnerStartedAfterInvoke`，同时收到该测试 DLL 的启动信号。
- 使用相同路径、相同字节的探针 DLL 启动另一独立 Revit，直接收到启动信号；观察结果为 `RunnerAlreadyStarted`、`ActionInvoked=false`。这验证了该 DLL 的信任记忆，不代表新 DLL 或新路径也一定免提示。
- 完整启动器携带 `-AutoTrustRunner`，在 PowerShell 7.5.4 中完成真实 Revit 2019（Build `20180216_1515(x64)`）的泛化 `api-smoke` 测试：4 项场景断言、2 项回滚断言全部通过，图像导出成功，文档不保存关闭，源文件与输入副本哈希均未改变，Revit 正常退出，启动器退出码为 0。
- 该实机运行中按目标 PID 关闭了已观察确认的“默认族样板文件无效”配置提示。模板保留默认的记录行为，未将这一环境提示扩展为无差别自动关闭弹窗。
- 首次真实模板运行发现元素收集器未设置过滤器；修复为显式包含实例和类型后，重新运行通过。首次运行记录仍保留失败及此前的启动器超时状态，不改写为通过。
- 新辅助脚本在 Windows PowerShell 5.1.22621.7376 与 PowerShell 7.5.4 下分别通过 18 项检查：四份脚本解析，错误 SHA256、错误进程开始时间、已有结果、未决操作意图均拒绝操作，父启动器超时停止审批，已有启动信号正确报告未点击。拒绝流程使用短期进程 test double，不作为真实 Revit 点击证据。

## 尚未验证

尚未验证 Revit 2020–2026 实机兼容性，以及其他版本或语言的发布者提示控件；实际自动点击来自 Revit 2019 中文界面与 PowerShell 7。两宿主检查不等同于两宿主均完成真实 Revit 自动点击。基础 `api-smoke` 通过也不代表接收者的业务插件已通过。

技术方案本身来源于此前已实际完成的 Revit 2019 副本业务测试；接收者接入自己的业务后，仍须在自己的目标版本、模型与依赖环境中完成一次基础运行和业务回归。界面按钮及正式命令入口需要另外验证。
