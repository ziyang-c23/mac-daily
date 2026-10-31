# 架构

## 中英本地化

MacDailyCore的L10n读取随包的中英Localizable字符串，使用格式参数保留用户路径、数量与应用名称。SwiftPM资源包分别放入主应用和练习组件的Contents/Resources；Swift接口边界统一翻译原生设备状态，权限说明使用应用主资源中的InfoPlist字符串。

界面语言以应用偏好保存，支持跟随系统、简体中文和English。进程启动时固定语言与Locale，重新打开后统一应用，避免已缓存的状态与界面使用不同语言。重开等待旧进程退出后通过系统正常打开应用，输入模块在旧进程退出前停止。

配置标识与存储的规范名称保持稳定。WindowAction区分canonicalTitle和本地化title，Shortcut区分label与displayLabel；用户定义名称和路径保留原文。练习组件由父进程传入当前语言，并沿用固定窗口标识。

## 触控板

TrackpadBridge在模块或试用开启时动态连接MultitouchSupport，筛选内建设备并同步复制有效触点帧。注册和停止使用同一个设备句柄，销毁前注销并等待正在执行的回调返回。

TrackpadGestureEngine使用归一化坐标识别轻点、方向及角落，并按应用与原生设置选择规则。TrackpadRuntime在主线程按序处理触点帧；窗口命中查询放到独立任务，标题栏查询期间保留初始帧。界面试用按30fps更新，正式模式不发布触点坐标。事件过滤仅接管已识别的内建触控板和当前会话；鼠标及合成标记事件保持各自路径。

InputActionExecutor保存会话开始时的应用、指针和窗口目标，快捷键、中键、窗口动作与快捷功能统一分派。WindowRuntime复用布局与还原历史，为触控板持有独立预览层，避免暂停触控板时关闭鼠标拖拽预览。

NativeTrackpadSettingsReader读取当前主机有效全局偏好，观察系统偏好通知与应用激活；按单条规则标记系统占用。schema7增加TrackpadSettings，旧配置只补入关闭且无规则的触控板设置；编辑触控板不会重启MouseRuntime。

## 概览与快捷面板

DashboardModel共享状态快照与面板偏好；SystemMonitorService以串行actor采集Mach、IOKit、IOPS和网络计数。界面可见时每2秒采样，仅菜单栏网速开启时每5秒只采网络，无需求时停止。容量30秒更新，温度和进程详情按显示需求读取；十分钟历史仅保存在内存。

DashboardPanelController持有400点宽AppKit面板，SwiftUI展示概览与收纳页签。主窗口复用DashboardView，窗口关闭／最小化和页面切换会释放采样需求。QuickActionService集中执行系统操作，电源断言与清洁覆盖层各自拥有生命周期。键盘清洁使用现有输入暂停状态机，结束后恢复原先启用状态。

schema6新增DashboardSettings，保留既有模块数据并备份旧格式。面板偏好变化不重启鼠标输入。MacDailyCore的MonitorCounterRate供实际网络和磁盘采样共用，接口变化、计数回退及唤醒后重新建立速率基线。

菜单栏排序从同一份展开后的辅助功能快照读取边界和项目；拒绝把仍保留折叠宽度的边界作为拖动坐标。分区判断使用边界两侧，避免宽分隔项中点造成错误归组。

SwiftPM 构建单一原生 App；SwiftUI 提供菜单栏和设置，AppKit 处理系统对话框与权限入口。源码只依赖系统框架，无第三方运行环境。

## 模块边界

- MacDailyCore：配置、验证、纯鼠标状态机和滚动数学，不调用系统输入接口。
- MacDailyApp：界面、配置生命周期、事件适配、设备监测、快捷键输出和独立输入线程。
- PointerBridge：动态加载 IOKit SPI，按物理设备读取和修改指针参数；不可用时报告，不降级为全局修改。

全局事件过滤位于独立 CFRunLoop。设置变更和前台应用变化串行送入事件线程。平滑计时器仅在有滚动尾部时工作，空闲时不轮询鼠标位置。界面只接收状态和动作结果，不接收日常键盘文本。

## 输入处理

设备归属先经 HID sender ID 和缓存设备表识别。触控板或未知来源不启用普通鼠标规则。自身合成事件携带标记，入口直接透传。仅关注必要的按键、拖动、滚轮及 Escape 取消，不订阅无按键的连续鼠标移动。

启用的按钮规则在按下时捕获会话。短按输出配置的点击动作或回放原始点击；方向手势到松开才触发；不支持的拖动回放缓存的按下与移动，再恢复原生拖动。滚轮组合在持有期间执行，抑制最后的普通点击。应用切换、修饰键变化、暂停、配置变更和 Escape 取消会话。

触发快捷键前再次确认目标应用仍处于前台。平滑滚动使用独立累加器，方向反转会清除旧方向尾部；触控板滚动、点击、应用切换和暂停终止尾部。

## 设备和恢复

设备识别与高级指针控制独立于输入规则。高级控制只作用于已识别的鼠标服务，在写入前读取原值，采用单一所有者管理恢复。原生系统 API 的私有 SPI 部分单独封装并探测可用性。正常退出和暂停明确恢复；强制终止／进程崩溃的恢复能力必须以实现和验证记录为准，不能承诺所有异常均即时恢复。

## 配置与占位

配置使用带 schemaVersion 的 JSON。读取或导入必须校验长度、有限数值、范围和规则冲突，失败保留当前有效配置。应用页面只描述计划用途，没有后台服务或可执行占位操作。空间模块按需运行，权限与辅助功能独立。

## v0.2 窗口模块

WindowGeometry 提供不依赖桌面的布局计算，统一使用 Quartz/AX 左上原点、Y 向下坐标。SnapZoneResolver 识别边缘，SnapZoneTracker 管理底边滑动；WindowTransitionPolicy 校验延迟提交与还原基线。

WindowRuntime 与 MouseRuntime 独立。开启拖拽时才创建被动监听，监听回调只采样并限频，AX 查询在回调外执行。鼠标增强因其他工具冲突暂停时，窗口拖拽仍可独立启用。没有空闲窗口位置轮询。

拖拽从按下时命中的标准可调整窗口开始，确认实际位置改变、尺寸未改变，才生成预览。松手后短暂延迟让原生拖拽结束，再核对应用、会话和配置代际；切换应用取消待提交操作。透明 NSPanel 不成为焦点、不接收鼠标。AX 写入后读取实际位置与尺寸，失败尝试恢复；历史限制为64个窗口，不持久记录用户桌面。

显式窗口动作通过相同执行器完成。页面按钮记住上一个外部 AX 窗口；鼠标动作核对前台应用；练习窗口只能通过明确入口选中，不允许误选本应用设置窗。

配置新增 windows 与可选 windowAction，schema 升为2，避免旧程序把窗口动作静默解释成备用快捷键。鼠标旧配置迁移不添加新规则；新安装提供四个关闭的右键方向窗口预设。配置导入会强制关闭拖拽，供用户检查。


## v0.4 手势反馈与试用

MouseDecision.feedback 是瞬时识别状态，不表示下游已经成功执行。运行时限频发送状态给界面；窗口动作结果由窗口执行器回报，前台应用变化会显式取消。未知滚轮来源不因按钮处于按下状态就被当作鼠标。

GestureDirectionRecognizer 被真实状态机与局部试用共用。部分方向配置对起步偏向增加宽限，避免刚达到阈值就提前回放；点击与仅滚轮规则仍保持原生拖动阈值。长按超时不会在松手时误触发。

SafeGestureTestView 在本应用内接收 NSEvent，使用独立生成的测试配置，丢弃全部动作和回放结果。左键模拟便于安全练习，不证明外接设备的全局 sender 归属。InputSuspensionState 为试用和快捷键录制保存共同恢复意图，支持嵌套、交错、手动暂停和终止。

窗口练习采用按需启动的普通临时子进程，无管理员权限，关闭窗口或父应用后退出。固定目标检查 PID、Bundle ID、随机 AXIdentifier 及标题；缺失时拒绝操作，不跟随前台应用回退。练习吸附开关不修改日常配置。

## v0.5 自定义拖拽激活区域

WindowActivationProfile 分横屏和竖屏保存有序区域。NormalizedWindowRect 使用屏幕左上角起算的比例坐标；激活区域相对完整显示器，目标布局相对可用区域。WindowActivationResolver 为纯函数，优先匹配首个启用区域，不匹配时不回退到边缘布局；窗口间距在目标上计算。

默认模式保留原 SnapZoneTracker；自定义模式使用同一目标验证、预览和延迟提交路径。激活提示面板忽略鼠标且不激活，取消、提交、设置变化和停止均隐藏。编辑器持有独立草稿，只提交激活相关字段，保留日常吸附状态、间距、例外和鼠标配置。

配置格式升为 schema 3，旧 schema 1/2 按缺省值补齐新字段，首次写入前分别保存旧文件。现有配置继续使用标准边缘模式，不因升级改变日常触发行为。旧程序拒绝 schema 3，防止静默忽略自定义区域。

## v0.6 空间模块

StorageFileSystem读取原始元数据，StorageScanner聚合目录与覆盖范围，临时分块索引承载文件记录。StorageIndex查询分页结果；TreemapLayout为纯面积布局，界面不重新估算文件大小。StorageModel将工作放在后台任务，串行管理取消、代际及临时目录生命周期。

DuplicateFinder将元数据筛选与内容比较分离：仅明确开始时读取普通本地文件，以大小、样本、SHA-256、字节比较确认。StorageSafetyPolicy集中处理路径边界、云端位置、包及研究数据保护。CacheRules内置可解释规则，运行时提供应用元数据和进程名称。

CleanupService唯一负责预览与移入废纸篓，预览目录成员元数据摘要，执行时再次核验。界面不能直接删除文件。System/Data用户路径别名只有在身份与元数据匹配时规范化，避免默认整盘结果被误判为可清理系统文件或全部拒绝。

配置schema4新增StorageSettings，旧schema1/2/3分别迁移默认值并保留原始备份。空间设置变更不重置MouseRuntime；扫描索引、内容哈希和待整理选择不写入配置。应用退出、任务取消及关闭结果释放会话资源，无后台定时扫描。

## v0.8 菜单栏

MenuBarCatalog在后台读取菜单栏项目，MenuBarLayoutController持有自己的分隔项，MenuBarPanelController显示应用图标与名称。MenuBarRuntime管理单一AppKit入口、原工具菜单、原生菜单观察与一次性收起计时器。MenuBarOrderController将设置面板内的分组/排序操作同步到系统；合成事件使用现有MacDaily标记，且成对释放鼠标输入。

配置schema5新增MenuBarSettings。旧配置补入关闭状态并保存schema4原件；菜单栏设置变化不重启鼠标处理。图标顺序由系统保存，关闭模块移除自己的分隔项。日常应用位置为/Applications/MacDaily.app，源码与构建入口保持不变。

## 应用管理

ApplicationInventory 按需读取应用、包内辅助程序标识、签名信息、架构与大小；ApplicationAssociationResolver 生成关联项和残留候选。ApplicationsModel 在后台任务中查询，SwiftUI 只持有当前结果。ApplicationCleanupService 合并预览并通过系统废纸篓处理，使用独立应用包策略，不改变空间模块的规则。

StartupItemsService 区分 launchd 的启用、加载与运行状态，仅当前用户的启动代理提供直接启停；第三方现代登录项与后台授权由原生设置管理。配置 schema 8 的 ApplicationsSettings 只保存扫描目录、忽略项及列表偏好。应用设置变更不重启鼠标输入运行时。

## 鼠标动作与输入适配

MouseEventAdapter保持按住会话的设备归属，MouseEngine仅输出一次typed动作，MouseRuntime通过InputActionExecutor派发；按下时异步捕获目标PID和窗口，事件回调不进行AX查询。MouseBinding.effectiveAction兼容旧shortcut/windowAction字段，schema9新增InputAction与四个斜向。

BetterAndBetterMouseImporter独立转换全局普通鼠标规则并合并选定触发项。真实鼠标检查复用正式适配和状态机，但原样放行事件且不执行动作，不改变指针设置；匹配次数仅保留当前检查会话。
