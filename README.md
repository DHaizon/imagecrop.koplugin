# imagecrop.koplugin

A [KOReader](https://github.com/koreader/koreader) plugin that adds interactive crop functionality to the built-in Image Viewer. Select any rectangular region of an image with two taps, fine-tune it with arrow controls, and save the result as a PNG — or pin it directly to [pinnedelements.koplugin](#integration-with-pinnedelementskoplugin).

> Built with vibecoding using [Claude](https://claude.ai) (Anthropic).

---

## Features

- **Two-tap crop selection** — tap once to set the top-left corner (crosshair appears), tap again to set the bottom-right corner (selection rectangle appears).
- **Visual overlay** — a high-contrast black/white border with L-shaped corner markers makes the selection clearly visible on E-ink screens.
- **Pixel-nudge navigation bar** — once a selection is active, a `◄ ▲ ▼ ►` bar appears above the action buttons to shift the entire selection one pixel at a time for precise adjustments.
- **Crop & Save** — saves the selected region as a PNG file next to the source image (`<original_name>_crop_YYYYMMDD_HHMMSS.png`). Falls back to `koreader/screenshots/` if no source path is available.
- **Pin to PinnedElements** — crops the selection in memory and saves it directly as a pinned image entry in [pinnedelements.koplugin](https://github.com/your-username/pinnedelements.koplugin), without saving a separate file first (see [below](#integration-with-pinnedelementskoplugin)).
- **Reset / Cancel** — reset clears the current selection so you can start over; cancel exits crop mode and restores the Image Viewer to its original state.
- **Non-destructive** — original images are never modified.
- **Kindle Paperwhite compatible** — grayscale-safe PNG output via `BlitBuffer → TYPE_BBRGB32 → writePNG`.

---

## How it works

The plugin patches KOReader's `ImageViewer` widget at startup to inject a **Crop** button into its button bar. When tapped, it launches a fullscreen `CropOverlay` on top of the current image.

### Crop overlay states

| State | What you see | What tapping the image does |
|---|---|---|
| `idle` | Button bar only (`Cancel` / `Pin` / `Crop`) | Sets the top-left corner → crosshair appears |
| `one` | Full-screen crosshair at first point | Sets the bottom-right corner → selection rectangle appears |
| `two` | Selection rectangle + arrow bar | Starts a new selection from that point |

The `Pin` and `Crop` buttons in the action bar are greyed out until a full selection (state `two`) is active.

### Save path

- If the image was opened from a file, the crop is saved **next to the source file**: `<dir>/<basename>_crop_YYYYMMDD_HHMMSS.png`
- If no file path is available (e.g. an in-memory image), it falls back to: `koreader/screenshots/crop_YYYYMMDD_HHMMSS.png`

After saving, a dialog shows the full output path with a **View** button to open the cropped image immediately.

---

## Workflow

1. Open any image in KOReader (tap a cover, an image in a book, or open a file from the file browser).
2. In the Image Viewer, tap **Crop** in the bottom button bar.
3. The viewer goes fullscreen (title bar and buttons hidden) and the crop overlay activates.
4. **Tap** anywhere on the image to set the **top-left corner** — a crosshair appears.
5. **Tap** again to set the **bottom-right corner** — the selection rectangle appears along with the arrow navigation bar.
6. Use **◄ ▲ ▼ ►** to nudge the selection by one pixel at a time if needed.
7. Choose an action:
   - **Crop** — saves the cropped region as a PNG and shows the output path.
   - **Pin** — sends the crop directly to PinnedElements (requires the plugin to be active).
   - **Reset** — clears the selection so you can start over.
   - **Cancel** — exits crop mode and returns the Image Viewer to its normal state.

---

## Integration with pinnedelements.koplugin

[pinnedelements.koplugin](https://github.com/your-username/pinnedelements.koplugin) is a companion plugin that lets you pin pages, text selections, and images to a persistent popup while reading. When it is installed alongside `imagecrop.koplugin`, the **Pin** button in the crop overlay becomes fully functional, turning any cropped region into a pinned image entry without any extra steps.

### What happens when you tap Pin

1. The selected region is captured from the framebuffer in memory (before the crop overlay closes and the layout shifts).
2. The PNG is saved directly into PinnedElements' own image directory: `koreader/pinnedelements/images/crop_<timestamp>_<rand>.png`.
3. A new entry is appended to the current book's pin list with `type = "image"`, the current page number, and the label *"Cropped image"*.
4. The pin list is flushed to disk immediately (`<book_filename>.lua` inside `koreader/pinnedelements/`).
5. A `Crop pinned` notification appears on screen.

No separate file is left in your document folder — the image lives entirely inside PinnedElements' storage.

### Accessing pinned crops

Open the PinnedElements popup at any time (via the reader menu → **Pinned Elements** → **View pinned elements**, or via the Dispatcher shortcut). The popup shows a paginated list of all pins for the current book — pages, text fragments, and images together. Tapping a pinned crop opens it in PinnedElements' own image viewer, which supports pan, zoom, and rotation, and includes a navigation bar to browse forward and backward through all pinned images without returning to the list.

Pins can be sorted by page number or by creation order using the menu icon in the popup title bar. Individual pins can be renamed or deleted from the same popup; deleting an image pin also removes the PNG file from disk.

### Both plugins patch ImageViewer

Both `imagecrop.koplugin` and `pinnedelements.koplugin` inject buttons into KOReader's `ImageViewer` at init time — **Crop** and **Pin** respectively. Each plugin re-applies its own wrapper on every document open (`onReaderReady`) so that neither silently overwrites the other regardless of plugin load order. The result is that both buttons appear side by side in the Image Viewer's button bar whenever both plugins are active.

### How detection works

`imagecrop.koplugin` looks for `_G.PinnedElements_active` at the moment **Pin** is tapped. `pinnedelements.koplugin` sets this global to itself in `onReaderReady` — i.e. every time a document is opened. No configuration is needed: as long as both plugins are installed and a document is open, the Pin button works automatically. If `pinnedelements.koplugin` is absent or no document has been opened yet, tapping Pin shows a `PinnedElements not active` notification and does nothing else.

---

## Installation

### Option 1 — App Store (appstore.koplugin)

If you have [appstore.koplugin](https://github.com/omer-faruq/appstore.koplugin) installed:

1. Open KOReader → **Tools** → **App Store**.
2. Go to the **Plugins** tab.
3. Use the filter dialog to search for `imagecrop`.
4. Tap the entry to open the quick action menu and choose **Install** — this downloads and extracts the repo ZIP automatically.
5. Restart KOReader.

### Option 2 — FileBrowserPlus (Wi-Fi, no USB)

If you have [filebrowserplus.koplugin](https://github.com/patelneeraj/filebrowserplus.koplugin) installed, you can transfer the plugin over Wi-Fi from any phone or computer:

1. Open KOReader's top menu.
2. Make sure your device is connected to Wi-Fi.
3. Go to **Gearbox Menu → Network → FileBrowserPlus**.
4. When the server starts, note the IP address and port shown on screen. Visit that address (e.g. `http://192.168.x.x:8080`) from your phone or computer connected to the same Wi-Fi network.
5. You can change the password or create new users via the FileBrowser web interface.
6. Navigate to the folder where you downloaded `imagecrop.koplugin/` on the other device.
7. Copy the `imagecrop.koplugin/` folder to `/mnt/us/koreader/plugins/` on your Kindle.
8. Restart KOReader.

### Option 3 — Manual (USB)

1. Connect your Kindle to a computer via USB.
2. Copy the `imagecrop.koplugin/` folder to:
   ```
   /mnt/us/koreader/plugins/imagecrop.koplugin/
   ```
3. Safely eject and restart KOReader.

### File structure

```
koreader/plugins/
└── imagecrop.koplugin/
    ├── main.lua
    └── _meta.lua        (optional, for plugin metadata)
```

---

## Compatibility

- Tested on **Kindle Paperwhite 4** running KOReader v2026.03.
- Should work on any KOReader-supported device; E-ink grayscale output is fully supported.
- Requires KOReader with `ui/widget/imageviewer`, `ffi/blitbuffer`, and `ui/renderimage` available (all standard in current KOReader builds).

---

## Optional dependency

| Plugin | Required? | Purpose |
|---|---|---|
| [pinnedelements.koplugin](https://github.com/your-username/pinnedelements.koplugin) | No | Enables the **Pin** button to save crops as pinned image entries |