# Mouse gestures

Open Mouse → Buttons & Gestures to configure the right, middle, and side buttons. The right and middle buttons each have click, eight-direction, and held-button wheel settings, with independent enable controls.

## Actions

Choose a direction in the diagram and assign a shortcut, window layout, system action, or MacDaily quick action. Hold the configured button, move in the direction, and release to execute. The default distance is 36 pt and can be adjusted. The pending action appears once the distance is reached.

Ordinary clicks and drags retain their native behavior when no gesture is completed. A wheel combination does not add a click when released. Shortcut feedback says Sent; window and system actions report their execution result separately.

## BetterAndBetter settings

Read BetterAndBetter Settings loads locally saved normal-mouse rules. The editable migration list shows source gestures and corresponding actions. Applying selected entries updates only matching button, trigger, and modifier rules. Right and middle button groups can be enabled separately.

If direct access is unavailable, use Choose BetterAndBetter Settings File to select the file in the native file picker.

Supported entries include cardinal and diagonal directions, wheel combinations, shortcuts, minimize, restore minimized window, full screen, and brightness. Letters, custom drawings, and button chords are listed with reasons they were not imported. Left and right mappings retain the source settings; executable key codes and modifiers determine shortcut behavior.

Restore Minimized targets the application's last window minimized by MacDaily. System navigation uses the current macOS shortcut configuration, available under System Settings → Keyboard → Keyboard Shortcuts → Mission Control.

## Recognition and execution

- Recognition Practice is a local drawing simulation for checking direction and distance.
- Real Mouse Inspection uses the same device attribution and input adapter as normal operation. It displays the current event, device, and rule match without executing actions.

Runtime state, enabled rule count, recognition, and execution are shown separately. If all rules are disabled, the page says so explicitly.

Schema 9 retains existing settings and backs up older configuration before the first replacement. Inspection events are kept only as transient interface state.

[中文](mouse.md) · [README](../README.en.md)
