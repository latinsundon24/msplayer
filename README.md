# msplayer

横屏 iOS 直播播放器（SwiftUI），同时集成 **系统原生解码（AVPlayer）** 与 **VLC（MobileVLCKit）**，可在「解码更换」中切换或自动兜底。

当前版本：**1.2 (3)**（左栏底部与「关于应用」均可查看，便于确认安装的是哪一版）。

> 独立项目：包名 `com.msplayer.app`，与任何其他工程无关联。

## 功能

- 启动即横屏播放界面，左栏「播放列表 / 频道列表 / 节目单」，右栏八项菜单：
  线路选择、列表订阅、EPG订阅、显示设置、解码更换、应用设置、关于应用、退出应用
- 播放列表支持 **在线与本地** `.m3u` / `.m3u8` / `.txt`
- 左栏「播放列表」按订阅时自定义的名称显示
- M3U 标签支持：
  - `#KODIPROP:inputstream.adaptive.manifest_type=mpd`
  - `#KODIPROP:inputstream.adaptive.license_type=clearkey`
  - `#KODIPROP:inputstream.adaptive.license_key=KID:KEY`（也支持 JWK / data: / 远程 license URL）
  - `#EXTVLCOPT:http-user-agent=…`、`#EXTVLCOPT:http-referrer=…` 及任意 `#EXTVLCOPT:http-*`
  - `http://…|User-Agent=…&Referer=…`
- 同名频道自动归并为多线路，频道列表只显示一次
- 启动进入播放界面时左右边栏都隐藏；点击画面左侧切换左栏，点击右侧切换右栏，两栏互斥（显示一个时另一个自动隐藏）
- 视频区滑动：上滑频道 +1、下滑频道 -1；右滑线路 +1、左滑线路 -1
- 支持回看的频道：左右滑动改为时移（前后 30 秒），节目单中已开始的节目显示「回看」并可点播
- 回看地址支持 `&playseek=${(b)yyyyMMddHHmmss}-${(e)yyyyMMddHHmmss}` 模板（兼容 `${(b)}` / `${(e)}` 与 `&amp;`）
- 识别 m3u 回看标签：`catchup`、`catchup-source`、`catchup-days`、`timeshift`；支持完整回看地址、`?playseek=…` 后缀追加、`{utc}` / `${start}` 等占位符；频道列表与节目单会显示「回看」
- 底栏：序号、频道名称、进度条、线路、分辨率（4K / 1080P / 720P / 576P / 480P，按视频原始分辨率）、正在播放、下一节目
- EPG：XMLTV 订阅，`tvg-id` 优先、频道名归一化匹配
- DASH + ClearKey：内置解密管线（AES-CTR/CBCS → 去 CENC 信令 → 本地 fMP4 HLS），再交给当前解码器

## 解码策略

| 场景 | 自动模式 |
| --- | --- |
| HLS / MP4 | AVPlayer |
| RTMP / RTSP / UDP / FLV | VLC |
| DASH + ClearKey | 解密为本地 HLS 后交给 AVPlayer |
| AVPlayer 失败（非网络类） | 自动回退 VLC |
| 证书/网络异常 | 先走本地 HLS 代理重试 |

## 构建（GitHub Actions，未签名 IPA）

仓库推送后自动运行 `.github/workflows/build-ipa.yml`：

1. `xcodegen generate`
2. `pod install`（MobileVLCKit）
3. macOS 单元测试（解析器 / 归并 / 分辨率 / XMLTV）
4. iOS device Release 未签名构建
5. 打包 `msplayer-1.2-unsigned.ipa` 并上传 artifact

本地（macOS）构建：

```bash
brew install xcodegen
xcodegen generate
pod install
open msplayer.xcworkspace
```

## 安装

未签名 IPA 需使用 Sideloadly / AltStore / TrollStore 等工具自签安装。MobileVLCKit 为动态 framework，自签工具需要递归签名 `Frameworks/*.framework`。

## 内置演示

首次启动自动加载内置离线示例（`msplayer-bundle://demo-dash/stream.mpd`），可在无网络环境验证 ClearKey 解密链路；另附数条公开 HLS 测试流。

## 目录

```
msplayer/            应用源码
  DASH/              MPD 解析、分片、CENC 解密、本地 HLS
  HLS/               本地代理与 HTTP 服务
  EPG/               XMLTV 解析与匹配
  Player/            AVPlayer + VLC 双后端、画面视图
  UI/                左栏 / 右栏 / 底栏 / 各设置页
  Resources/         内置示例列表与离线 DASH
TestsMac/            macOS 核心逻辑测试
project.yml          XcodeGen 工程描述
Podfile              MobileVLCKit
```
