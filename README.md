# Claude IP 桌面检测

基于 [Net.Coffee Claude 检测页](https://ip.net.coffee/claude/)公开接口与检测方式实现的非官方 macOS 桌面工具。

项目包含两个独立应用：

- **Claude IP 桌宠**：悬浮桌宠、J.A.R.V.I.S. 风格面板、三路出口、风险评分、DNS / UDP 检测、设备信息与历史记录。
- **Claude IP 组件**：小、中、大三种 WidgetKit 组件，以及无窗口的独立刷新宿主。组件不依赖桌宠运行。

## 构建与运行

需要 macOS、Apple Silicon 和 Swift Command Line Tools。当前脚本构建 arm64，桌宠最低部署目标为 macOS 13，组件为 macOS 14。

```bash
./build.sh
open "dist/Claude IP 桌宠.app"
open "dist/Claude IP 组件.app"
```

构建脚本会生成两个应用，执行本地 ad-hoc 签名，并注册组件。运行组件宿主后，可在桌面的「编辑小组件」中搜索「Claude IP 组件」并添加所需尺寸。

开发时也可运行 `./script/build_and_run.sh`，构建并启动桌宠。

## 主要功能

- 中国出口 IPv4、Cloudflare 出口和 Claude 出口。
- 原站信任评分、地区、ASN、运营商、住宅 / 机房属性及风险提示。
- Claude 可用性、Claude 服务状态、DNS 泄露与出口、WebRTC UDP 泄露检测。
- 默认隐藏 IP；组件评分旁的问号可切换 IP 显隐。
- 手动重新检测及五分钟自动刷新；加载期间显示「检测中」。
- 桌面组件采用浅色渐变、同心圆弧卡片和点阵地球；定位落点以折线连接国家信息标签。
- 桌宠支持展开 / 收起、拖动、右键菜单和本地历史记录。

WebRTC UDP 检测使用 Google 与 Cloudflare 的 STUN 节点，在应用自身的 WebKit 上下文中收集候选地址，并沿用原站的出口比较规则。检测受限或失败时显示对应状态，UDP 结果不参与信任评分。

## 目录

```text
src/main.swift               桌宠窗口与原生桥接
src/web/                     桌宠页面、样式、检测逻辑及地图数据
src/host/main.swift          独立组件宿主
widget/                      SwiftUI 组件、数据层与刷新呈现
widget/Resources/            必需的 HUD 图片和静态地图资源
script/                      构建与运行入口
tools/                       开发检查和示例渲染工具源码
build.sh                     构建、签名与组件注册
```

## 示例数据与隐私

组件预览使用虚构网络名称和文档示例 IP，与真实检测结果分开。渲染工具默认使用示例数据；只有显式传入 `--live` 才会读取本机检测缓存，生成的真实截图不应提交到仓库。

应用的运行日志、缓存、窗口位置和历史保存在本机应用数据目录。源码仓库不包含这些运行记录，也不包含固定的 AppKey、登录令牌或签名私钥。

`.gitignore` 排除了构建产物、验证目录、日志、备份、Finder 元数据和常见凭据文件。运行时仍会请求所列服务，查询 IP、地区、风险及相关检测结果。

## 资源来源

HUD 图片为项目内的界面资源，地图数据来源见 [资源说明](widget/Resources/SOURCES.md)。国家锚点仅用于示意，不表示精确 IP 或城市位置。
