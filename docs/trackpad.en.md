# Trackpad

[简体中文](trackpad.md) · English

Trackpad enhancements have their own page and enable switch. They currently target the MacBook's built-in trackpad. Select **Use Recommended Preset** before enabling the module.

## Recommended gestures

| Gesture | Action |
|---|---|
| Three-finger tap | Middle click |
| Three-finger swipe left/right | Previous/next tab: Control–Shift–Tab / Control–Tab |
| Three-finger swipe up/down | Maximize/restore the current window |
| Four-finger tap | Open the MacDaily panel |
| Control–Option + one-finger corner tap | Corresponding quarter-screen layout |
| Option + two-finger swipe left/right on a standard titlebar | Left/right half |
| Option + two-finger swipe up/down on a standard titlebar | Maximize/restore that window |

Directional gestures commit once, when all fingers lift. Window gestures preview their layout after reaching the configured distance. Titlebar rules use the window under the pointer; other window rules use the frontmost window captured at gesture start. Buttons, tabs, and toolbar controls do not start a titlebar gesture.

Corner regions default to 20% of the trackpad's width and height. Swipe distance defaults to 10% of the surface. Both can be adjusted. Changing apps or modifiers, or pressing Escape, cancels the current gesture.

## Configure system gestures

The **System Gestures** tab shows the current value, recommended value, configuration path, and a button that opens the appropriate system pane.

| System Settings path | Recommended value |
|---|---|
| Trackpad → More Gestures → Swipe between full-screen applications | Swipe left or right with four fingers |
| Trackpad → More Gestures → Mission Control | Swipe up with four fingers |
| Trackpad → More Gestures → App Exposé | Swipe down with four fingers |
| Trackpad → Point & Click → Look up & data detectors | Force Click with one finger |
| Accessibility → Pointer Control → Trackpad Options | Three-finger dragging off |
| Keyboard → Press Globe key to | Keep Change Input Source |

Adjust these in System Settings. MacDaily reads the effective configuration and pauses only conflicting rules. Corner taps, four-finger taps, and titlebar rules remain independent. Scrolling, zoom, rotation, and page navigation continue to follow system preferences.

## Rules and apps

Each rule has a gesture, modifiers, action, and app scope. Actions include keyboard shortcuts, middle click, window layouts, quick controls, and the MacDaily panel. App-specific rules override a matching global rule. App exceptions disable trackpad enhancements in the selected app.

**Add Missing Presets** adds missing global rules and preserves existing custom actions. Importing configuration leaves trackpad enhancement off.

## Test and practice

The **Test** tab displays touches, finger count, and recognition feedback. With no saved rules, it uses a temporary recommended preset. Testing does not execute or save those temporary mappings. Conflicts with system gestures are shown in the feedback.

Leaving the tab or clicking **End Test** stops the test and returns to the configured normal mode. **Open Window Practice** launches the existing fixed-target helper for trying layouts.

Accessibility access is used to send shortcuts and control windows. Touch callbacks run only while enhancements or testing are enabled. They stop on pause, sleep, or exit. Shortcut recording, keyboard cleaning, and mouse gesture testing temporarily suspend trackpad enhancements.

Physical-device validation was deferred by the user. See the [verification record](verification.md) for the checks actually performed.
