# MacDaily

MacDaily unifies core daily macOS utilities for personal use. Keep it native, simple and lightweight. Mouse, Trackpad and Window have separate pages; storage adds on-demand inspection and Trash-only cleanup; the dashboard combines monitoring and quick actions. Applications adds on-demand inventory, related-file preview, Trash-only removal and user launch-agent management. Raycast keeps application search and file search.

Use SwiftPM and the build/test scripts. Preserve the MIT license and third-party notices. Do not copy GPL/AGPL code. Never register input hooks, change pointer settings, or request permissions from placeholder modules. Do not log raw input.

All scratch files, build artifacts, caches and test fixtures must be explicitly placed under this repository's `tmp/<task>/`; set TMPDIR, TMP, TEMP and compiler/package caches accordingly. Final app bundles belong in `dist/`. No temporary writes to /tmp, /private/tmp, /var/folders or elsewhere. Tests must explicitly use repository scratch paths. Do not mutate the user's real app configuration in tests.

Normal shutdown, pause, sleep and permission loss must release captured input and restore pointer values owned by MacDaily. Distinguish synthetic/runtime tests from physical-device validation. No auto-launch or disabling other input tools during builds.
