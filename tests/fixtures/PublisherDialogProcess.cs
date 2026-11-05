// Test double only. This executable never loads Revit or a DLL, changes trust,
// opens a model, or writes to a real Revit run. It displays native TaskDialogs.
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

internal static class PublisherDialogProcess
{
    private delegate int Callback(IntPtr window, uint notification, IntPtr wParam, IntPtr lParam, IntPtr data);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode, Pack = 1)]
    private struct Button
    {
        public int Id;
        [MarshalAs(UnmanagedType.LPWStr)] public string Text;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode, Pack = 1)]
    private struct Configuration
    {
        public uint Size;
        public IntPtr Parent, Instance;
        public uint Flags, CommonButtons;
        [MarshalAs(UnmanagedType.LPWStr)] public string Title;
        public IntPtr MainIcon;
        [MarshalAs(UnmanagedType.LPWStr)] public string Instruction, Content;
        public uint ButtonCount;
        public IntPtr Buttons;
        public int DefaultButton;
        public uint RadioCount;
        public IntPtr Radios;
        public int DefaultRadio;
        [MarshalAs(UnmanagedType.LPWStr)] public string Verification, Expanded, ExpandText, CollapseText;
        public IntPtr FooterIcon;
        [MarshalAs(UnmanagedType.LPWStr)] public string Footer;
        public Callback Callback;
        public IntPtr CallbackData;
        public uint Width;
    }

    [DllImport("comctl32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    private static extern void TaskDialogIndirect(ref Configuration configuration, out int button, out int radio,
        [MarshalAs(UnmanagedType.Bool)] out bool verified);

    [DllImport("user32.dll")]
    private static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

    private static int Show(string directory, string dll, string mode, bool chinese)
    {
        string always = chinese ? "\u59CB\u7EC8\u52A0\u8F7D" : "Always Load";
        string once = chinese ? "\u52A0\u8F7D\u4E00\u6B21" : "Load Once";
        string deny = chinese ? "\u4E0D\u52A0\u8F7D" : "Do Not Load";
        if (mode == "wrong-button") always = "Delete file";
        var buttons = new[] {
            new Button { Id = mode == "fallback" ? 2001 : 1001, Text = always },
            new Button { Id = mode == "fallback" ? 2002 : 1002, Text = once },
            new Button { Id = mode == "fallback" ? 2003 : 1003, Text = deny }
        };
        int size = Marshal.SizeOf(typeof(Button));
        IntPtr memory = Marshal.AllocHGlobal(size * buttons.Length);
        for (int i = 0; i < buttons.Length; i++)
            Marshal.StructureToPtr(buttons[i], IntPtr.Add(memory, i * size), false);
        int denyId = buttons[2].Id;
        Callback callback = delegate(IntPtr window, uint notification, IntPtr wParam, IntPtr lParam, IntPtr data) {
            // Automatically dismiss only this synthetic dialog after 15 seconds.
            if (notification == 4 && wParam.ToInt64() > 15000)
                SendMessage(window, 0x400 + 102, new IntPtr(denyId), IntPtr.Zero);
            return 0;
        };
        var configuration = new Configuration {
            Size = (uint)Marshal.SizeOf(typeof(Configuration)),
            Flags = 0x8u | 0x800u | (mode == "standard-buttons" ? 0u : 0x10u),
            Title = "TEST DOUBLE - Revit publisher approval",
            Instruction = "The publisher could not be verified (test double).",
            Content = "Location: " + dll,
            ButtonCount = (uint)buttons.Length, Buttons = memory,
            Callback = callback, Width = 350
        };
        int selected, radio;
        bool verified;
        try { TaskDialogIndirect(ref configuration, out selected, out radio, out verified); }
        finally
        {
            for (int i = 0; i < buttons.Length; i++)
                Marshal.DestroyStructure(IntPtr.Add(memory, i * size), typeof(Button));
            Marshal.FreeHGlobal(memory);
            GC.KeepAlive(callback);
        }
        File.AppendAllText(Path.Combine(directory, "clicks.log"), dll + "|" + selected + Environment.NewLine);
        return selected;
    }

    [STAThread]
    private static void Main(string[] arguments)
    {
        string directory = arguments[0], mode = arguments[1];
        try
        {
            File.WriteAllText(Path.Combine(directory, "test-double.txt"), "Synthetic UI only. No Revit API or trust changes.");
            if (mode == "sequence")
            {
                if (Show(directory, Path.Combine(directory, "OtherBefore.dll"), mode, false) != 1001) return;
                if (Show(directory, Path.Combine(directory, "Runner.dll"), mode, true) != 1001) return;
                File.WriteAllText(Path.Combine(directory, "started.txt"), "Synthetic runner signal");
                Thread.Sleep(3000);
                if (Show(directory, Path.Combine(directory, "OtherAfter.dll"), mode, true) != 1001) return;
                Show(directory, "unusual-provider://Vendor.dll", mode, false);
            }
            else if (mode == "idle")
            {
                Thread.Sleep(15000);
            }
            else
            {
                Show(directory, Path.Combine(directory, mode == "non-dll" ? "Model.rvt" : "Other.dll"), mode, true);
            }
        }
        catch (Exception exception)
        {
            File.WriteAllText(Path.Combine(directory, "fixture-error.log"), exception.ToString());
            Environment.ExitCode = 1;
        }
    }
}
