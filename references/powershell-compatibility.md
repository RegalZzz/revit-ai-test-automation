# PowerShell 权限与版本兼容

## 临时允许脚本执行

执行策略可能在加载 `.ps1` 之前拦截脚本，因此不能依靠脚本开头自己调用 Set-ExecutionPolicy 来解决。推荐由新的 PowerShell 进程使用 `-ExecutionPolicy Bypass` 运行可信的本包脚本，退出后失效，不要求改写系统或用户级策略。

Windows PowerShell 5.1：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\scripts\New-RevitTestHarness.ps1" -Destination 'D:\MyProject\tests\MyTests' -Name MyTests -RevitVersion 2019
```

PowerShell 7：

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File ".\scripts\New-RevitTestHarness.ps1" -Destination 'D:\MyProject\tests\MyTests' -Name MyTests -RevitVersion 2019
```

启动实际测试时，两者也支持相同的 `-File Invoke-RevitIntegrationTest.ps1` 用法。读取结果使用相应宿主和 `-File Read-RevitTestResult.ps1 -RunDirectory '本轮目录'`。

`scripts/Run-RevitIntegrationTest.cmd` 封装了主启动器：通过 PATH 找到 `pwsh.exe` 时使用 PowerShell 7，否则使用系统的 Windows PowerShell。只向新进程传递 Bypass，不调用 `runas`，不修改注册表或永久策略，并保留脚本退出码。已经找到宿主但执行失败时，不自动换另一个宿主重跑测试。

CMD 入口在自己的局部环境中清除继承的 PSModulePath，让所选宿主重建其默认模块搜索目录，避免从 7 启动 5.1 时误用另一版本模块而缺少 Get-FileHash 等内置命令；父会话和持久配置不受影响。

如果要在一个交互会话中连续调用多个脚本，也可对当前进程设置：

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
```

这影响当前窗口及继承其策略环境的子进程，关闭窗口后结束；需要立即恢复时，事先记录 `Get-ExecutionPolicy -Scope Process` 并恢复该值。默认优先使用单独子进程的方式。

## 限制的来源

同一个宿主中运行 `Get-ExecutionPolicy -List` 查看实际来源。`MachinePolicy`、`UserPolicy` 的优先级高于 Process；如果组织强制签名等要求，临时 Bypass 不能覆盖，应使用组织批准的签名/发布流程或请管理员处理，停止反复改策略。

执行策略不是管理员权限和文件 ACL。Bypass 不能修复目录无写入权限、AppLocker/WDAC 限制、Revit 许可或 DLL 发布者提示。普通运行使用用户 Addins 目录；目录无权限时改用授权的测试输出目录或处理具体权限，不自动提权。

## 两种宿主共用的实现约定

- 脚本声明最低版本 5.1，只使用两者共有语法；不引入 `??`、三元表达式、`&&`、`ForEach-Object -Parallel` 等仅新版本支持的写法。
- `.ps1`/`.cmd` 保持 ASCII 文本；若后续加入中文脚本字面量，使用 UTF-8 BOM，避免 5.1 将无 BOM 脚本按系统代码页误读。Markdown 与生成的 C#/JSON 可以保持 UTF-8。
- 所有 JSON 用 `Get-Content -Encoding UTF8` 读取，避免 5.1 默认 ANSI 破坏中文路径。写入使用明确的 .NET UTF8Encoding，避免宿主默认输出编码差异。
- PowerShell 7.5 的 ConvertFrom-Json 会把 ISO 时间字符串解析为 DateTime，5.1 保留字符串。进程开始时间统一转成 DateTimeOffset 后比较 UTC ticks，避免错误放行重复启动或误报进程已经结束。
- 用参数变量/数组调用外部程序，不拼接 Invoke-Expression。原生程序完整输出写入日志，并检查 `$LASTEXITCODE`；不能依赖不同宿主对 stderr 和非零退出码的默认处理。
- `-File` 的数组参数在跨进程命令行中不等同于会话内的 PowerShell 数组。需要传多个 FixturePath 时，在已经设置 Process 执行策略的会话内用 `-FixturePath @('a.dwg', 'b.rvt')` 调用 `.ps1`。CMD 入口适合普通标量参数或单个 fixture。

PowerShell 版本与 Revit 所需 .NET 版本彼此独立：PowerShell 7 可以调用 dotnet 构建 net48 测试插件，再启动 Revit 2019。Revit API 代码始终在 Revit 内执行，不在 PowerShell 7 进程里加载旧版 Revit API。
