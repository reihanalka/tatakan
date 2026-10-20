using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;

namespace Tatakan
{
    /// <summary>
    /// The Windows share sheet (Nearby Share, Mail, Phone Link, apps…) for a desktop window.
    /// Nearby Share is the closest thing Windows has to AirDrop.
    /// </summary>
    internal static class ShareUI
    {
        [ComImport, Guid("3A3DCD6C-3EAB-43DC-BCDE-45671CE800C8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IDataTransferManagerInterop
        {
            IntPtr GetForWindow([In] IntPtr appWindow, [In] ref Guid riid);
            void ShowShareUIForWindow(IntPtr appWindow);
        }

        static readonly Guid DtmIid = new(0xa5caee9b, 0x8708, 0x49d1, 0x8d, 0x36, 0x67, 0xd2, 0x5a, 0x8d, 0xa0, 0x0c);
        static readonly Dictionary<IntPtr, DataTransferManager> managers = new();
        static readonly Dictionary<IntPtr, List<ShelfItem>> pending = new();

        public static void Show(Window window, IReadOnlyCollection<ShelfItem> items, Shelf shelf)
        {
            if (items.Count == 0) { shelf.Toast("Nothing to share"); return; }
            try
            {
                var hwnd = new WindowInteropHelper(window).Handle;
                var interop = DataTransferManager.As<IDataTransferManagerInterop>();
                if (!managers.TryGetValue(hwnd, out var dtm))
                {
                    var ptr = interop.GetForWindow(hwnd, DtmIid);
                    dtm = WinRT.MarshalInterface<DataTransferManager>.FromAbi(ptr);
                    dtm.DataRequested += (s, e) => OnRequested(hwnd, e);
                    managers[hwnd] = dtm;
                }
                pending[hwnd] = items.ToList();
                interop.ShowShareUIForWindow(hwnd);
            }
            catch (Exception e)
            {
                System.Diagnostics.Debug.WriteLine("Tatakan share: " + e);
                shelf.Toast("Share unavailable");
            }
        }

        static async void OnRequested(IntPtr hwnd, DataRequestedEventArgs e)
        {
            if (!pending.TryGetValue(hwnd, out var items)) return;
            var req = e.Request;
            var deferral = req.GetDeferral();
            try
            {
                req.Data.Properties.Title = items.Count == 1 ? items[0].Title : $"{items.Count} items from Tatakan";
                req.Data.Properties.ApplicationName = "Tatakan";

                var storage = new List<IStorageItem>();
                foreach (var i in items)
                {
                    try
                    {
                        if (i.IsFile && i.Path != null)
                        {
                            if (i.IsDirectory) storage.Add(await StorageFolder.GetFolderFromPathAsync(i.Path));
                            else storage.Add(await StorageFile.GetFileFromPathAsync(i.Path));
                        }
                        else if (i.Kind == ItemKind.Text && items.Count > 1)
                        {
                            var f = Actions.TextToFile(i);
                            if (f != null) storage.Add(await StorageFile.GetFileFromPathAsync(f));
                        }
                    }
                    catch { }
                }
                if (storage.Count > 0) req.Data.SetStorageItems(storage);

                var links = items.Where(i => i.Kind == ItemKind.Link).ToList();
                if (links.Count == 1 && Uri.TryCreate(links[0].Path, UriKind.Absolute, out var u)) req.Data.SetWebLink(u);
                var texts = items.Where(i => i.Kind == ItemKind.Text).Select(i => i.Text)
                    .Concat(links.Count > 1 ? links.Select(l => l.Path) : Enumerable.Empty<string?>()).ToList();
                if (texts.Count > 0 && (items.Count == 1 || storage.Count == 0))
                    req.Data.SetText(string.Join(Environment.NewLine, texts));
            }
            finally { deferral.Complete(); }
        }
    }
}
