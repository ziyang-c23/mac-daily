# 空间模块 v0.6

## 目标与交互

以整盘概览进入，在一个空间页面内提供概览、大文件、重复文件、缓存整理四个页签。保持个人使用优先、按需运行，无常驻扫描和管理员组件。首版采用矩形面积图与列表联动。

本轮调研读取了本机Cleaner One Pro 6.6.8相关入口，未在其中增加授权、扫描个人文件或执行清理。当前重复目录为文稿和下载，因此作为MacDaily初始比较范围。地图交互参考GrandPerspective、DaisyDisk、CleanMyMac Space Lens和OmniDiskSweeper；算法独立实现。

## 数据与大小

打开页面只读取卷容量。扫描仅枚举元数据，不计算内容哈希；扫描器不跟随符号链接、不自动跨卷，启动盘使用Data扫描入口以避免System/Data重复映射。可访问范围、排除范围、错误和取消状态分别记录。容量条与扫描合计不强行凑齐。

地图可使用文件逻辑大小或文件系统报告的磁盘占用估算；后者不是独占物理块大小。硬链接去重，APFS克隆共享、快照和其他卷仍会造成文件合计与卷占用不同，不能承诺精确可释放字节。云端占位文件只分析元数据，不因重复比较自动下载。

扫描索引为应用拥有的临时分块文件，列表分页读取，不建立常驻数据库。应用运行目录的索引由模块负责释放；测试与基准样本只能放在源码项目的tmp目录。配置仅保存偏好、忽略路径和保留路径。

## 重复内容与缓存规则

重复比较独立启动：大小分组、分段筛选、完整SHA-256、字节核验。排除硬链接、符号链接、云端占位、应用包、受保护资料库、系统、缓存和虚拟环境。优先保留目录只影响保留建议，不声称某份文件是原件。执行前仍检查保留文件存在且内容一致。

缓存规则按已识别应用和明确路径生成，不按模糊名称分类。首批普通应用用户缓存、已识别应用30天前旧日志、Xcode DerivedData、pip下载缓存、npm `_cacache`；开发缓存提示重建和重新下载代价。uv/pnpm等共享缓存仅分析。无法确认所属应用的旧日志也仅供定位，不提供直接清理。浏览记录、Cookie、登录状态、模型、数据集、虚拟环境、Conda和任意项目产物不纳入自动建议。

## 清理边界

所有选择默认关闭，四个页签共用待整理清单。先预览路径、原因与大小，再调用系统废纸篓接口；不调用强制删除，不自动清空废纸篓、不提升权限、不结束相关程序。执行前重核身份、路径、卷、目录清单和缓存占用状态。父子重复选择去重；无法证明仍符合预览时跳过并让用户重新检查。

清理结果逐项区分已移动、跳过和失败，报告移入废纸篓的大小。重新读取容量但不把该大小称为已释放空间。实际释放取决于废纸篓、快照及文件系统共享情况。

## 参考与许可

- [Cleaner One Pro](https://apps.apple.com/us/app/cleaner-one-pro-uninstaller/id1133028347?mt=12)：磁盘图、大文件、重复文件入口。
- [GrandPerspective](https://grandperspectiv.sourceforge.net/)：GPL，参考矩形面积图行为，不复制源码。
- [DaisyDisk](https://daisydiskapp.com/guide/4/en/HiddenSpace/)：权限、共享卷、快照与未解释占用。
- [Space Lens](https://macpaw.com/support/cleanmymac/knowledgebase/space-lens-results)：列表与可视化联动。
- [OmniDiskSweeper](https://www.omnigroup.com/more)：按大小排序的逐层检查。
- [Czkawka核心](https://github.com/qarmin/czkawka/blob/master/czkawka_core/LICENSE_MIT)、[Kondo](https://github.com/tbillington/kondo)、[dua](https://github.com/Byron/dua-cli)：MIT参考，未附带Rust运行环境。
- [Mole](https://github.com/tw93/Mole#license)：GPL；[Pearcleaner](https://github.com/alienator88/Pearcleaner#license)：Commons Clause；均不直接纳入源码。
- [uv缓存](https://docs.astral.sh/uv/concepts/cache/)：官方要求不直接修改缓存目录，因此首版仅分析。
- [Apple废纸篓接口](https://developer.apple.com/documentation/foundation/filemanager/trashitem(at:resultingitemurl:))与[储存说明](https://support.apple.com/en-gb/102624)。

本说明记录设计与边界，实测结果以[验证记录](verification.md)为准，不等同于所有条件均已验收。

## 首版实际限制

整盘容量只反映系统报告的总量与可用量，不尝试删除快照或强制回收系统可清除空间。需要展开扫描详情查看遗漏范围。网络卷不支持；外置卷和真实云盘占位状态尚需单独实测。

重复比较不计入空文件；单个临时分桶最多100000条候选元数据，超过时明确要求缩小比较范围。支持的是内容完全一致，不判断哪份在语义上是原件。

普通手动整理会拒绝系统、应用内部、资料库、凭证、研究模型/数据集/环境，以及必须经过专用规则的缓存路径；被保护的项目仍可查看大小并在Finder定位。缓存所属程序检查失败时，缓存处理停止。不会因文件位于废纸篓就自动清空它。

所有持久配置都可能包含用户设置的忽略/保留路径，导出前请自行检查；扫描路径清单、内容哈希与待整理清单不进入导出配置。

## v0.7 地图布局

概览取消110pt固定地图高度，默认按可用空间的约62%分配地图区域（含路径与图例）。地图与列表间提供16pt高的拖动条，并支持辅助功能递增/递减调整。列表保留最小高度。点击“放大查看”打开960×640pt地图视图，可继续进入目录及通过路径返回；关闭保留所在目录，不触发扫描。布局比例只属于当前视图，不更改扫描设置或个人配置。
