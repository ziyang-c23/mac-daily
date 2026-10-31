# References and third-party notices

## Trackpad references (v0.10)

TrackpadBridge and the gesture engine are independently implemented. The MultitouchSupport contact ABI was checked against OpenMultitouchSupport (MIT, Copyright (c) 2019 TakutoNakamura): https://github.com/Kyome22/OpenMultitouchSupport . Its binary framework and Swift dependencies are not bundled.

Behavior references: native macOS Trackpad settings, BetterAndBetter2.8.0, Swish, BetterTouchTool, Multitouch, and MiddleClick. MiddleClick is GPL3 and was used only as a product reference; no code from it is included. Letter/drawing gestures from BetterAndBetter's saved presets are not part of this gesture recognizer.

## Dashboard references (v0.9)

State 2.2.0 and the user's screenshot informed the layered dashboard and controls. iStat Menus and One Switch informed detail views and quick actions. No product artwork is included.

Native metric collection and action adapters were independently implemented after reviewing Stats (https://github.com/exelban/stats , MIT, Copyright (c) 2019 Serhiy Mytrovtsiy) and OnlySwitch (https://github.com/jacklandrin/OnlySwitch , MIT, Copyright (c) 2021 jack). These apps are not bundled. AppleSMC request layouts describe the read-only system protocol; CPU/GPU temperature groups are enumerated at runtime.

Dock display anchoring independently implements mouse-movement boundary geometry. Behavior references: DockAnchor (https://github.com/bwya77/DockAnchor) and dock-lock (https://github.com/upipibi/dock-lock), both MIT. Their source is not included.

MacDaily is MIT licensed. It uses Apple system frameworks and has no downloaded runtime package dependencies.

## LinearMouse

Device-scoped pointer handling was researched using LinearMouse's PointerKit, Device and scheme implementation. The MacDaily bridge is independently written; it uses the same macOS HID service property semantics (16.16 fixed point resolution/acceleration) and dynamically resolves SPI. It does not copy the LinearMouse application.

Reference: https://github.com/linearmouse/linearmouse — MIT License, Copyright (c) 2021–2024 LinearMouse. See https://github.com/linearmouse/linearmouse/blob/main/LICENSE .

Any later copied or adapted component must retain its actual upstream license and copyright notices. Source-available, GPL and AGPL reference applications are not included in this repository.

## Product research

Rectangle, BetterAndBetter, Mac Mouse Fix, StrokeMouse and other utilities informed feature comparisons. No product assets or GPL/AGPL code are included. The default shortcuts are conventional macOS shortcuts, and the directional gesture recognizer is original code.

## Window interaction references (v0.2)

Magnet's documented interaction informed edge/corner behavior: https://magnet.crowdcafe.com/ and https://magnet.crowdcafe.com/faq.html . No Magnet code or artwork is included. Geometry, state transitions, AX integration and layout glyphs are original implementation using system frameworks. Rectangle and SwiftShift were studied earlier as MIT references; neither application is bundled.

## Custom drag activation areas (v0.5)

The installed Magnet 3.0.7 settings were inspected read-only to understand separate activation and destination areas and landscape/portrait editing. MacDaily independently implements normalized rectangles, a draft editor and a resolver; recommended areas use familiar halves, thirds and corners, with no imported user command IDs, shortcuts, binary assets or proprietary source. Magnet reference: https://magnet.crowdcafe.com/ .

## Storage references (v0.6)

Storage scanning, treemap layout, content comparison and cleanup are independently written in Swift using Apple frameworks. Product behavior references: Cleaner One Pro, DaisyDisk, GrandPerspective, CleanMyMac Space Lens and OmniDiskSweeper. No proprietary assets or GPL implementation is included.

MIT references reviewed: https://github.com/qarmin/czkawka (czkawka_core only), https://github.com/tbillington/kondo , https://github.com/Byron/dua-cli . No code or binaries from these projects are bundled. GrandPerspective and Mole are GPL; Pearcleaner is Apache-2.0 with Commons Clause. Their implementations are not incorporated. See docs/storage.md for feature and safety boundaries.

## Menu bar references (v0.8)

Menu bar catalog, panel, layout controller and runtime are independently implemented using AppKit and Accessibility. The macOS 27 pusher-width mechanism was researched from CleanMenuBar at e9652547fa5ff70e7e93ab76ac2966bedcafe02d (MIT): https://github.com/atilac/CleanMenuBar . No source was copied verbatim. Hidden Bar (MIT) informed section interaction, while iBar, Bartender and Ice informed product behavior. No proprietary assets or GPL implementation is included.
