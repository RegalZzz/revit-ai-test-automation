# DLL 加载确认回归

在已登录、未锁定的 Windows 桌面执行：

```powershell
pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\Test-PublisherApproval.ps1
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\Test-PublisherApproval.ps1
```

测试使用 .NET Framework 自带的 C# 编译器，在独立临时目录生成名为 `Revit.exe` 的测试替身，以覆盖审批脚本真实的进程名、PID 和开始时间检查。替身只显示标题带 `TEST DOUBLE` 的原生 Windows TaskDialog，不加载真实 Revit 或 DLL、不改变信任配置、不读取或写入模型。弹窗在测试中实际可见，辅助控制台保持隐藏。

覆盖连续多个 DLL、测试入口启动前后出现的其他 DLL、中文按钮、标准按钮和命令链接、控件 ID 不同时按名称查找、特殊路径格式、排除其他进程、观察模式、无关提示、超时保留进程、父启动器停止、进程身份与测试 DLL 哈希不匹配，以及已有 intent 的拒绝重试。辅助脚本按控件能力选择 `InvokePattern` 或 `TDM_CLICK_BUTTON`，实际方法写入操作记录；本机原生 TaskDialog 使用后者，不把它声称为前者的运行证据。

脚本结束后只清理自身创建的测试进程，保留临时目录中的结果、每次操作意图、点击日志和错误输出。控制台输出证据目录。测试替身通过不等同于目标 Revit 版本的实机回归。
