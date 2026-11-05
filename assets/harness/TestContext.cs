using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Security.Cryptography;
using Autodesk.Revit.DB;

namespace __HARNESS_NAME__
{
    public sealed class TestContext
    {
        private readonly TextWriter log;
        private readonly List<AssemblyEvidence> assemblies;

        internal TestContext(Document document, string runDirectory, string runId, TextWriter log, List<AssemblyEvidence> assemblies)
        {
            Document = document;
            RunDirectory = runDirectory;
            RunId = runId;
            this.log = log;
            this.assemblies = assemblies;
        }

        public Document Document { get; private set; }
        public string RunDirectory { get; private set; }
        public string RunId { get; private set; }
        public int AssertionCount { get; private set; }

        public void Check(bool condition, string description)
        {
            AssertionCount++;
            log.WriteLine((condition ? "PASS " : "FAIL ") + description);
            if (!condition) throw new InvalidOperationException("Assertion failed: " + description);
        }

        public void Log(string message) { log.WriteLine(message); }

        public string InputPath(string fileName)
        {
            if (string.IsNullOrWhiteSpace(fileName) || fileName != Path.GetFileName(fileName))
                throw new ArgumentException("Pass a fixture filename, not a path.", "fileName");
            string path = Path.Combine(RunDirectory, "inputs", fileName);
            if (!File.Exists(path)) throw new FileNotFoundException("Fixture copy is missing.", path);
            return path;
        }

        public void RecordAssembly(Assembly assembly)
        {
            var item = new AssemblyEvidence
            {
                Name = assembly.GetName().Name,
                Path = assembly.Location,
                Sha256 = JsonFiles.Hash(assembly.Location)
            };
            assemblies.Add(item);
            log.WriteLine("ASSEMBLY " + item.Name + " " + item.Path + " SHA256=" + item.Sha256);
        }

        public void ExportView(View view, string fileName)
        {
            if (string.IsNullOrWhiteSpace(fileName) || fileName != Path.GetFileName(fileName))
                throw new ArgumentException("Pass an image base filename, not a path.", "fileName");
            using (var options = new ImageExportOptions
            {
                ExportRange = ExportRange.SetOfViews,
                FilePath = Path.Combine(RunDirectory, fileName),
                PixelSize = 1800,
                ZoomType = ZoomFitType.FitToPage,
                HLRandWFViewsFileType = ImageFileType.PNG,
                ShadowViewsFileType = ImageFileType.PNG
            })
            {
                options.SetViewsAndSheets(new[] { view.Id });
                Document.ExportImage(options);
            }
            log.WriteLine("EXPORTED " + fileName);
        }
    }

    [DataContract]
    internal sealed class RunConfiguration
    {
        [DataMember] public int SchemaVersion { get; set; }
        [DataMember] public string RunId { get; set; }
        [DataMember] public string ModelPath { get; set; }
        [DataMember] public string ExpectedVersion { get; set; }
    }

    [DataContract]
    public sealed class AssemblyEvidence
    {
        [DataMember] public string Name { get; set; }
        [DataMember] public string Path { get; set; }
        [DataMember] public string Sha256 { get; set; }
    }

    [DataContract]
    internal sealed class TestResult
    {
        [DataMember] public int SchemaVersion { get; set; }
        [DataMember] public string RunId { get; set; }
        [DataMember] public int ProcessId { get; set; }
        [DataMember] public string Scope { get; set; }
        [DataMember] public string RevitVersion { get; set; }
        [DataMember] public string RevitBuild { get; set; }
        [DataMember] public string ModelPath { get; set; }
        [DataMember] public string TestAssemblyPath { get; set; }
        [DataMember] public string TestAssemblySha256 { get; set; }
        [DataMember] public bool Complete { get; set; }
        [DataMember] public bool Success { get; set; }
        [DataMember] public bool RollbackVerified { get; set; }
        [DataMember] public bool ClosedWithoutSaving { get; set; }
        [DataMember] public int AssertionCount { get; set; }
        [DataMember] public List<string> Failures { get; set; }
        [DataMember] public List<AssemblyEvidence> PluginAssemblies { get; set; }
    }

    internal static class JsonFiles
    {
        internal static T Read<T>(string path)
        {
            using (var stream = File.OpenRead(path))
                return (T)new DataContractJsonSerializer(typeof(T)).ReadObject(stream);
        }

        internal static void Write<T>(string path, T value)
        {
            string temporary = path + ".tmp";
            using (var stream = File.Create(temporary))
                new DataContractJsonSerializer(typeof(T)).WriteObject(stream, value);
            // Each run owns a unique directory. Never overwrite an earlier completed result.
            File.Move(temporary, path);
        }

        internal static string Hash(string path)
        {
            using (var stream = File.OpenRead(path))
            using (var hash = SHA256.Create())
                return BitConverter.ToString(hash.ComputeHash(stream)).Replace("-", "");
        }
    }
}
