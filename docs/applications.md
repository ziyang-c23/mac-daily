# 应用管理

“应用”包含应用清单、残留和启动项三个页签。进入页面后读取应用清单；关联文件在选择应用时查询，残留由“扫描残留”启动。

## 应用与卸载

默认扫描系统应用程序目录和个人应用程序目录。可以添加目录或拖入 `.app`；系统应用通过筛选项查看。相同 Bundle ID 的副本保留各自安装路径。

列表支持搜索和按名称、大小、上次使用排序。详情显示版本、架构、开发者、路径、使用时间及关联文件大小。通过 Finder 定位、复制路径或加入概览固定应用继续操作。

勾选应用后点击“查看卸载项目”。统一预览按应用本体、缓存、日志、偏好、数据和共享项目分类，显示路径、归属依据和大小。默认选应用本体及独占缓存／日志，其他项目由你选择。多个应用关联的同一路径只处理一次，父子目录选择合并。

点击“移入废纸篓”执行。运行中的目标会先收到正常退出请求，未退出的应用及其关联项保留；其他项目分别报告结果。移入废纸篓的大小不等于已释放空间。

Homebrew Cask 应用显示 Cask 页面与可复制的卸载命令；检测到厂商卸载器时显示对应入口。它们由原有管理方式卸载。正在运行的 MacDaily 本体不参与卸载，其他安装副本可单独查看。

## 残留

点击“扫描残留”，查看用户资料库中未找到对应安装的 Bundle ID 项目。结果默认不选，勾选后进入相同的整理预览；可忽略不需要再次显示的路径。

扫描同时参考系统登记的应用位置。App Group 按应用声明关联，名称相似或厂商相同不代表独占归属；开发环境目录不作为同名应用残留。

## 启动项

启动项页读取用户启动代理、全局启动代理及系统守护进程，分别显示自动启动、已加载和当前运行状态。当前用户的启动代理可直接启停，原 plist 保留。

MacDaily 自身开机启动复用现有设置。其他应用的登录项、现代后台授权及扩展，通过“系统设置 → 通用 → 登录项与扩展”管理。

## 参考

- [Apple：卸载应用](https://support.apple.com/zh-cn/102610)、[登录项与扩展](https://support.apple.com/zh-hans/guide/mac-help/mtusr003/27/mac/27)。
- [App Cleaner & Uninstaller](https://nektony.com/help/app-cleaner/getting-started)：应用关联文件和残留分组。
- [Freemacsoft AppCleaner](https://freemacsoft.net/appcleaner/)：拖入应用的检查流程。
- [feherk/AppCleaner](https://github.com/feherk/appcleaner)、[Ignition](https://github.com/Acelogic/Ignition)：原生实现与启动代理交互参考。MacDaily 的应用模块独立实现。
- [Homebrew Cask](https://docs.brew.sh/Cask-Cookbook)：包管理器卸载入口。

[English](applications.en.md) · [返回说明](../README.md)
