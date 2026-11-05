using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using Autodesk.Revit.DB;
using Autodesk.Revit.UI;
using Autodesk.Revit.UI.Events;

namespace __HARNESS_NAME__
{
    public sealed class RevitTestApplication : IExternalApplication
    {
        private string root;
        private RunConfiguration config;

        public Result OnStartup(UIControlledApplication application)
        {
            string directory = Environment.GetEnvironmentVariable("REVIT_TEST_RUN_DIRECTORY");
            string runId = Environment.GetEnvironmentVariable("REVIT_TEST_RUN_ID");
            if (string.IsNullOrEmpty(directory) || string.IsNullOrEmpty(runId)) return Result.Succeeded;
            root = Path.GetFullPath(directory);
            try
            {
                config = JsonFiles.Read<RunConfiguration>(Path.Combine(root, "run.json"));
                if (config.SchemaVersion != 1 || config.RunId != runId) return Result.Succeeded;
                if (!string.Equals(Path.GetFullPath(config.ModelPath), Path.Combine(root, "Model.rvt"), StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("ModelPath must point to this run's Model.rvt copy.");
                if (File.Exists(Path.Combine(root, "started.txt")))
                    throw new InvalidOperationException("This run has already started; refusing to execute it again.");
                File.WriteAllText(Path.Combine(root, "started.txt"), "Loaded " + GetType().Assembly.Location);
                application.DialogBoxShowing += LogDialog;
                application.Idling += Run;
            }
            catch (Exception exception)
            {
                File.WriteAllText(Path.Combine(root, "startup-error.txt"), exception.ToString());
            }
            return Result.Succeeded;
        }

        public Result OnShutdown(UIControlledApplication application)
        {
            application.Idling -= Run;
            application.DialogBoxShowing -= LogDialog;
            return Result.Succeeded;
        }

        private void LogDialog(object sender, DialogBoxShowingEventArgs args)
        {
            var taskDialog = args as TaskDialogShowingEventArgs;
            string id = taskDialog == null ? args.GetType().Name : taskDialog.DialogId;
            File.AppendAllText(Path.Combine(root, "dialogs.log"), DateTime.UtcNow.ToString("o") + " " + id + Environment.NewLine);
            // Deliberately no OverrideResult: diagnose actual prompts before adding a narrow handler.
        }

        private void Run(object sender, IdlingEventArgs args)
        {
            var ui = (UIApplication)sender;
            ui.Idling -= Run;
            Document document = null;
            TestContext context = null;
            var result = new TestResult
            {
                SchemaVersion = 1,
                RunId = config.RunId,
                ProcessId = Process.GetCurrentProcess().Id,
                Scope = TestScenario.Scope,
                RevitVersion = ui.Application.VersionNumber,
                RevitBuild = ui.Application.VersionBuild,
                ModelPath = config.ModelPath,
                TestAssemblyPath = GetType().Assembly.Location,
                Failures = new List<string>(),
                PluginAssemblies = new List<AssemblyEvidence>()
            };
            using (var log = new StreamWriter(Path.Combine(root, "assertions.log"), false, new UTF8Encoding(false)) { AutoFlush = true })
            {
                try
                {
                    result.TestAssemblySha256 = JsonFiles.Hash(result.TestAssemblyPath);
                    log.WriteLine("Revit " + result.RevitVersion + " " + result.RevitBuild);
                    log.WriteLine("SCOPE " + result.Scope);
                    log.WriteLine("RUNNER " + result.TestAssemblyPath + " SHA256=" + result.TestAssemblySha256);
                    if (result.RevitVersion != config.ExpectedVersion)
                        throw new InvalidOperationException("Actual Revit version differs from the requested version.");
                    using (var info = BasicFileInfo.Extract(config.ModelPath))
                    using (var options = new OpenOptions())
                    {
                        if (info.IsWorkshared)
                        {
                            options.DetachFromCentralOption = DetachFromCentralOption.DetachAndPreserveWorksets;
                            using (var worksets = new WorksetConfiguration(WorksetConfigurationOption.OpenAllWorksets))
                                options.SetOpenWorksetsConfiguration(worksets);
                        }
                        document = ui.Application.OpenDocumentFile(ModelPathUtils.ConvertUserVisiblePathToModelPath(config.ModelPath), options);
                    }
                    context = new TestContext(document, root, config.RunId, log, result.PluginAssemblies);
                    string[] baseline = ElementIds(document);
                    using (var group = new TransactionGroup(document, "Isolated integration tests - rolled back"))
                    {
                        group.Start();
                        try { TestScenario.Run(context); }
                        finally
                        {
                            TransactionStatus status = group.RollBack();
                            bool sameIds = baseline.SequenceEqual(ElementIds(document));
                            result.RollbackVerified = status == TransactionStatus.RolledBack && sameIds;
                            context.Check(status == TransactionStatus.RolledBack, "Outer transaction group rolled back");
                            context.Check(sameIds, "Original element ID set restored after rollback");
                        }
                    }
                }
                catch (Exception exception)
                {
                    result.Failures.Add(exception.ToString());
                    log.WriteLine("FAIL " + exception);
                }
                finally
                {
                    try
                    {
                        if (document != null && document.IsValidObject)
                        {
                            result.ClosedWithoutSaving = document.Close(false);
                            if (!result.ClosedWithoutSaving) result.Failures.Add("Test document refused to close without saving.");
                        }
                    }
                    catch (Exception exception) { result.Failures.Add("Document close failed: " + exception); }
                    result.AssertionCount = context == null ? 0 : context.AssertionCount;
                    result.Complete = true;
                    result.Success = result.Failures.Count == 0 && result.RollbackVerified && result.ClosedWithoutSaving && result.AssertionCount > 0;
                    log.WriteLine(result.Success ? "PASS integration suite; all model changes rolled back" : "FAIL integration suite");
                    JsonFiles.Write(Path.Combine(root, "result.json"), result);
                    ui.DialogBoxShowing -= LogDialog;
                    if (ui.Application.Documents.IsEmpty)
                    {
                        try { ui.PostCommand(RevitCommandId.LookupPostableCommandId(PostableCommand.ExitRevit)); }
                        catch (Exception exception) { log.WriteLine("EXIT REQUEST FAILED " + exception); }
                    }
                    else { log.WriteLine("Process preserved because other documents remain open."); }
                }
            }
        }

        private static string[] ElementIds(Document document)
        {
            // Revit requires a filter before extracting a collector. Include both types and instances.
            var allElements = new LogicalOrFilter(new ElementIsElementTypeFilter(false), new ElementIsElementTypeFilter(true));
            return new FilteredElementCollector(document).WherePasses(allElements).ToElementIds()
                .Select(id => id.ToString()).OrderBy(id => id, StringComparer.Ordinal).ToArray();
        }
    }
}
