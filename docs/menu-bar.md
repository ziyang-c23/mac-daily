# 菜单栏管理

左键点击MacDaily打开概览与收纳页签，右键打开工具菜单。收纳开关位于独立的「菜单栏」页面；首次关闭。日常应用位置为`/Applications/MacDaily.app`。概览的状态、固定应用和快捷功能见[概览说明](dashboard.md)。

## 分区与展开

控制面板提供“收纳”和“常显”两组。每项可直接切换分组、上移和下移，也可拖动到另一分组或目标行之前。操作完成后，面板显示系统实际排列；原位顺序由系统保存。

应用在操作期间展开原菜单栏，读取当前位置，执行系统的移动交互，再收起。移动事件带有MacDaily合成标记，鼠标增强和窗口拖动处理器会略过；结束、取消及正常退出均释放已按下的鼠标键，并恢复指针位置。

「原位展开」显示收纳的图标。收起时间可选5、10、15、30秒或保持展开。原应用菜单正在操作时保留展开，菜单关闭后再计时。关闭管理或退出MacDaily会移除自己的分隔项。

## 聚合面板

收纳页签显示应用图标和项目名称。点击项目先原位展开，再通过辅助功能点击动作打开其原生菜单。点击面板外部或按Escape关闭。设置页另提供独立聚合栏的查看入口。项目读取应用图标与名称。

右键工具菜单保留鼠标启停、18种窗口布局、拖拽吸附、设置和退出，并提供原位展开和分区调整。

## 实现

MenuBarCatalog在后台读取AXExtrasMenuBar和项目元数据；MenuBarLayoutController管理MacDaily自己的分隔项；MenuBarPanelController显示聚合面板；MenuBarOrderController同步控制面板的移动与排序；MenuBarRuntime协调入口、布局、菜单操作及一次性收起计时器。

菜单栏模块以macOS27为目标。折叠长度按最窄显示器宽度的一半减20pt计算，分隔项保持在状态栏中，展开入口与分隔项分开。该机制参考CleanMenuBar对macOS27的测量；源代码为独立实现。

## 参考

- [本机iBar对应产品](https://www.better365.cn/ibar.html)：分区、普通展开与聚合访问。
- [Bartender 7](https://www.macbartender.com/Bartender7/)：单入口聚合与应用图标模式。
- [Ice](https://github.com/jordanbaird/Ice)：聚合栏交互参考，GPL源码未纳入本项目。
- [Hidden Bar](https://github.com/dwarvesf/hidden)：MIT；常显/收纳分区交互。
- [CleanMenuBar](https://github.com/atilac/CleanMenuBar/tree/e9652547fa5ff70e7e93ab76ac2966bedcafe02d)：MIT；macOS27独立分隔项机制。

实际验证结果见[验证记录](verification.md)。
