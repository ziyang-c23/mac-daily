# Applications

The Applications page has three tabs: Apps, Leftovers, and Startup Items. The app inventory loads when you open the page. Related files load when an app is selected; leftover scanning starts only when requested.

## Apps and removal

The default locations are `/Applications` and your home Applications folder. Add a folder or drop an `.app` to inspect another location. System apps are available through a filter. Multiple copies retain their individual installation paths.

Search or sort by name, size, or last use. Details show version, architecture, developer, path, last use, and related-file size. Reveal the app in Finder, copy its path, or add it to the dashboard's pinned apps.

Select one or more apps and choose Review Removal. The shared preview groups app bundles, caches, logs, preferences, data, and shared items, showing each path, association reason, and size. App bundles and exclusive caches/logs are selected by default; choose data separately. Shared paths are processed once, and nested selections are merged.

Move to Trash performs the selected operations. Running targets receive a normal quit request. Apps that do not quit and their related files remain pending; other results are reported individually. Bytes moved to Trash do not represent space already freed.

Homebrew-managed apps offer a Cask page and a copyable uninstall command. Detected vendor uninstallers have their own entry. The currently running MacDaily bundle cannot remove itself; other installed copies can be inspected separately.

## Leftovers

Scan Leftovers checks Bundle ID entries in selected user Library locations against the app inventory and registered installation paths. Nothing is selected by default. Choose entries for the same removal preview, or ignore paths you want to retain.

App Groups use declared group identifiers. Similar names and shared developer prefixes do not establish exclusive ownership; development environments are not treated as leftovers of similarly named apps.

## Startup items

The page lists user launch agents, global launch agents, and system daemons. Automatic startup, loaded state, and current process state are shown separately. User launch agents can be enabled or disabled while retaining their plist files.

MacDaily's own launch-at-login preference uses the existing setting. Manage other apps' login items, modern background authorization, and extensions in System Settings → General → Login Items & Extensions.

[中文](applications.md) · [README](../README.en.md)
