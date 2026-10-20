using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using Microsoft.Win32;

namespace Tatakan
{
    /// <summary>User settings, saved as JSON in %APPDATA%\Tatakan\settings.json.</summary>
    public sealed class AppSettings
    {
        public bool ShakeEnabled { get; set; } = true;
        /// <summary>0 (calm) … 1 (eager).</summary>
        public double ShakeSensitivity { get; set; } = 0.5;
        public bool RemoveAfterDrag { get; set; } = true;
        public bool CloseWhenEmpty { get; set; } = true;
        /// <summary>Process names (without .exe) where shaking does nothing.</summary>
        public List<string> ExcludedApps { get; set; } = new();
        public List<ShelfSnapshot> Recent { get; set; } = new();

        public static AppSettings Shared { get; } = Load();
        public static event Action? Changed;

        public static string Folder { get; } =
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Tatakan");
        static string FilePath => Path.Combine(Folder, "settings.json");
        static readonly JsonSerializerOptions Json = new() { WriteIndented = true };

        static AppSettings Load()
        {
            try
            {
                if (File.Exists(FilePath))
                    return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(FilePath)) ?? new AppSettings();
            }
            catch { /* corrupt file → defaults */ }
            return new AppSettings();
        }

        public void Save()
        {
            try
            {
                Directory.CreateDirectory(Folder);
                if (Recent.Count > 10) Recent.RemoveRange(10, Recent.Count - 10);
                File.WriteAllText(FilePath, JsonSerializer.Serialize(this, Json));
            }
            catch { }
            Changed?.Invoke();
        }

        public void PushRecent(ShelfSnapshot s) { Recent.Insert(0, s); Save(); }

        // Launch at login (HKCU Run key, no admin needed) ----------------------
        const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

        public static bool LaunchAtLogin
        {
            get
            {
                using var k = Registry.CurrentUser.OpenSubKey(RunKey);
                return k?.GetValue("Tatakan") != null;
            }
            set
            {
                using var k = Registry.CurrentUser.CreateSubKey(RunKey);
                if (value) k.SetValue("Tatakan", $"\"{Environment.ProcessPath}\" --background");
                else k.DeleteValue("Tatakan", false);
            }
        }
    }
}
