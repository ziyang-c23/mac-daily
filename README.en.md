# MacDaily

[GitHub](https://github.com/ziyang-c23/mac-daily) · [v1.0 Download](https://github.com/ziyang-c23/mac-daily/releases/tag/v1.0)

[简体中文](README.md) · English

MacDaily brings everyday Mac utilities into one native app: mouse and trackpad enhancements, window snapping, a system dashboard, quick controls, menu bar collection, and on-demand storage inspection. It is built for personal use, with a simple interface and independent tools.

Current version: **v1.0**. The interface supports **Simplified Chinese and English**. Raycast continues to handle app search and file search; MacDaily also offers a small set of pinned apps.

## Build and run

Requires an Apple Silicon Mac, macOS 14 or later, and Swift 6 command-line tools.

```sh
./scripts/test.sh
./scripts/build.sh
ditto dist/MacDaily.app /Applications/MacDaily.app
open /Applications/MacDaily.app
```

The app is built at `dist/MacDaily.app`. Build caches and test fixtures stay under the ignored `tmp/` directory. Set `MACDAILY_SIGN_IDENTITY` to use an existing signing identity; the default build uses local ad-hoc signing.

## Language

Open **Settings → Language** and choose **Follow System**, **简体中文**, or **English**. Click **Reopen App** to apply the choice to the entire interface, including menus, runtime messages, and the window practice helper. Language is an app preference; tool rules and configuration identifiers remain unchanged.

## Overview and quick controls

Left-click the menu bar icon to open the dashboard. **Overview** contains metric cards, pinned apps, and quick controls; **Collected** contains hidden menu bar items. Right-click the icon for the tools menu.

CPU, GPU, memory, disk, network, and battery cards appear by default. CPU and GPU use stacked activity charts. Click a card for details, including CPU and memory process lists. Temperature is an optional card. **Mac Information** shows the OS version, model, CPU core groups, GPU, memory, startup disk, SSD model, and SIP status.

**All Features** opens the control editor. It includes keeping the Mac awake, keeping the display on, appearance, screen locking, screen and keyboard cleaning, desktop visibility, Dock controls, mute, and links to system settings. Cards, controls, and pinned apps can be added, removed, and reordered.

Monitoring runs every two seconds while the dashboard is visible. With only the menu bar network indicator enabled, it reads network counters every five seconds. Otherwise, monitoring sampling stops.

## Mouse

Configure right, middle, and side buttons independently. Eight-direction gestures, held-button wheel combinations, and direct window/system actions use a shared execution path. Hold a button, move, and release; the default distance is 36 pt.

Read locally saved BetterAndBetter rules into an editable migration list, selecting which entries and button groups to enable. Recognition Practice is a local simulation; Real Mouse Inspection uses actual device attribution and rule matching without executing actions. [Mouse guide](docs/mouse.en.md).

## Trackpad

The Trackpad page provides gesture mappings, current system settings with exact configuration paths, and a live touch test. Start with **Use Recommended Preset**, then enable the module.

The preset includes three-finger middle click, tab switching, maximize/restore, four-finger dashboard access, Control–Option corner taps, and Option–two-finger titlebar gestures. System three-finger conflicts pause the corresponding rules individually. [Trackpad guide](docs/trackpad.en.md).

## Windows

Drag windows to the sides for halves, corners for quarters, the top to maximize, or the bottom for thirds. Moving along the bottom edge can extend a layout to two thirds. A preview appears before release.

The Window page also offers explicit layouts, centering, restore, display changes, spacing, app exceptions, and custom activation areas. Landscape and portrait areas are edited separately. Maximize uses the current display's usable bounds. A separate practice window provides a fixed target for trying layouts.

## Menu bar

The Menu Bar page separates **Visible** and **Collected** items. Its controls move items between groups or change order. Opening a collected item reveals its native icon and invokes its menu. Auto-collapse is configurable, and native menus keep the bar expanded while in use.

The collection backend targets macOS 27. Native item sorting remains a known issue in the current verification record; it is not counted as a passed feature test.

## Storage

Storage provides a disk overview, a linked treemap and folder list, large-file filters, exact duplicate comparison, and documented cache rules. Scans start on request and can be canceled. Duplicate comparison runs separately from metadata scanning.

Select items to build a review list, then inspect paths, reasons, and sizes before moving them to Trash. Results report bytes moved to Trash; disk capacity is read again afterward.

## Configuration and validation

Configuration schema 9 preserves existing mouse, window, storage, menu bar, dashboard, and trackpad settings and adds application scan locations, ignored paths, and list preferences. Before replacing an older format, the app saves a `configuration.schemaN-backup.json` file. Import leaves input enhancements, drag snapping, and menu bar collection off for review.

The verification record distinguishes automated tests, native interface probes, UI checks, and physical-device tests: [verification](docs/verification.md). Trackpad physical testing was deferred at the user's request.

## License

MIT. MacDaily uses system frameworks. See [third-party references](THIRD_PARTY_NOTICES.md).

## Applications

Browse installed apps, inspect related files, review multiple apps together before moving selected items to Trash, scan leftovers on demand, and manage user launch agents. [Applications guide](docs/applications.en.md).
