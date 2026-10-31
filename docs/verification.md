# v1.0 验证记录

日期：2026-10-31。构建环境：Apple Silicon、Swift 6 工具链；应用部署要求 macOS 14 或更新版本。

## 版本与构建

用户明确将现有 v0.13 功能快照定为 v1.0 并发布到 GitHub。主应用、练习组件、界面与只读诊断的版本号为1.0，构建号100，配置格式继续使用schema9。

Release构建及本地签名验证通过。安装包为Apple Silicon arm64版本，构建来源和测试结果随Release提供。

## 自动测试

- 全量201项测试、25个测试组通过。
- 7种指针策略模拟通过。
- 验证涵盖鼠标八方向及动作输出、设备会话归属、规则迁移、配置兼容、窗口布局、触控板识别、应用关联及空间检查。

## 实际操作记录

应用页面、BetterAndBetter迁移、识别练习及既有模块的实际检查范围沿用[v0.13记录](history/v0.13-verification.md)。最终鼠标动作和触控板物理测试由用户后续进行，菜单栏原生排序尚有未通过项，具体记录见对应历史版本。

## 发布产物

- `dist/MacDaily.app`
- `dist/MacDaily-v1.0.zip`
- `dist/build-info.json`
- [GitHub v1.0](https://github.com/ziyang-c23/mac-daily/releases/tag/v1.0)

[中文说明](../README.md) · [English](../README.en.md)
