using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;

namespace Tatakan
{
    /// <summary>Right-click / "…" menu for shelf items. Same layout as the Mac app, minus AirDrop & Quick Look.</summary>
    internal static class ItemMenu
    {
        public static MenuItem Item(string title, string? glyph, Action action, bool enabled = true, string? gesture = null)
        {
            var m = new MenuItem { Header = title, IsEnabled = enabled, InputGestureText = gesture ?? "" };
            if (glyph != null) m.Icon = UI.Icon(glyph, 12);
            m.Click += (_, _) => action();
            return m;
        }

        public static MenuItem Header(string title)
        {
            var m = new MenuItem { Header = title.ToUpperInvariant(), IsEnabled = false, FontFamily = Theme.Mono, FontSize = 9.5 };
            return m;
        }

        public static ContextMenu Build(List<ShelfItem> items, ShelfWindow w, bool includeShelf)
        {
            var shelf = w.Shelf;
            var menu = new ContextMenu();
            bool has = items.Count > 0;
            var files = items.Where(i => i.IsFile).ToList();
            var images = items.Where(i => i.IsImage).ToList();
            var scope = items.Count == shelf.Items.Count ? "All" : $"{items.Count} Selected";

            if (has) menu.Items.Add(Header($"{scope} · {items.Count} item{(items.Count == 1 ? "" : "s")}"));
            menu.Items.Add(Item("Open", Glyph.Open, () => Actions.Open(items), has, "Enter"));
            menu.Items.Add(Item("Show in File Explorer", Glyph.Folder, () => Actions.Reveal(items), files.Count > 0));
            menu.Items.Add(new Separator());
            menu.Items.Add(Item("Copy", Glyph.Copy, () => Actions.Copy(items, shelf), has, "Ctrl+C"));
            menu.Items.Add(Item("Copy Path", Glyph.Link, () => Actions.CopyPaths(items, shelf), has));
            menu.Items.Add(Item("Save to Folder…", Glyph.Save, () => Actions.SaveTo(items, shelf, false, w), files.Count > 0));
            menu.Items.Add(Item("Move to Folder…", Glyph.Move, () => Actions.SaveTo(items, shelf, true, w), files.Count > 0));
            menu.Items.Add(new Separator());
            menu.Items.Add(Item("Share…", Glyph.Share, () => ShareUI.Show(w, items, shelf), has));
            menu.Items.Add(new Separator());
            menu.Items.Add(Item("Create ZIP", Glyph.Zip, () => Actions.Zip(items, shelf), files.Count > 0));

            var image = new MenuItem { Header = "Image", Icon = UI.Icon(Glyph.Photo, 12), IsEnabled = images.Count > 0 };
            foreach (var side in new[] { 3840, 2048, 1080, 512 })
                image.Items.Add(Item($"Resize to {side} px", null, () => Actions.ProcessImages(items, shelf, maxSide: side)));
            image.Items.Add(Item("Resize to 50%", null, () => Actions.ProcessImages(items, shelf, scale: 0.5)));
            image.Items.Add(new Separator());
            image.Items.Add(Item("Convert to PNG", null, () => Actions.ProcessImages(items, shelf, format: Actions.ImageFormat.Png)));
            image.Items.Add(Item("Convert to JPG", null, () => Actions.ProcessImages(items, shelf, format: Actions.ImageFormat.Jpg)));
            image.Items.Add(new Separator());
            image.Items.Add(Item("Extract Text (OCR)", null, () => Actions.ExtractText(items, shelf)));
            menu.Items.Add(image);

            menu.Items.Add(new Separator());
            menu.Items.Add(Item("Remove from Shelf", Glyph.Remove, () => shelf.Remove(items.Select(i => i.Id).ToList()), has, "Del"));

            if (includeShelf)
            {
                menu.Items.Add(new Separator());
                menu.Items.Add(Item("Paste", Glyph.Paste, () => Actions.Paste(shelf), true, "Ctrl+V"));
                menu.Items.Add(Item("Rename Shelf…", Glyph.Rename, () => shelf.Renaming = true, true, "F2"));
                var color = new MenuItem { Header = "Color", Icon = UI.Icon(Glyph.Color, 12) };
                for (int i = 0; i < Shelf.ColorNames.Length; i++)
                {
                    int idx = i;
                    var c = new MenuItem { Header = Shelf.ColorNames[i], IsChecked = shelf.ColorIndex == i };
                    if (i > 0) c.Icon = UI.Swatch(Shelf.Colors[i]);
                    c.Click += (_, _) => shelf.ColorIndex = idx;
                    color.Items.Add(c);
                }
                menu.Items.Add(color);
                menu.Items.Add(Item("Clear Shelf", Glyph.Delete, () => shelf.Remove(shelf.Items.Select(i => i.Id).ToList()), shelf.Items.Count > 0));
                menu.Items.Add(Item("Close Shelf", Glyph.Close, w.CloseShelf, true, "Ctrl+W"));
            }
            return menu;
        }
    }
}
