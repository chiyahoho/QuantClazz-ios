# QuantClazz

QuantClazz 是 iOS 17+ SwiftUI 论坛客户端，连接量化小论坛官网现有接口。正文使用 Swift 官方 [swift-markdown](https://github.com/swiftlang/swift-markdown) 0.9.0 解析；依赖通过 Swift Package Manager 获取。

本项目是社区开发的非官方客户端，与量化小论坛官网及其运营方不存在隶属、授权或背书关系。项目中保留的官网名称、品牌标志等素材用于识别所连接的服务，其权利归各自权利人所有；论坛用户发布的内容也归相应权利人所有。

## 在 Xcode 运行

1. 用支持 Swift 6.2 的 Xcode 26 或更新版本直接打开 `QuantClazz.xcodeproj`（不要打开仓库文件夹），选择共享方案 `QuantClazz`。`QuantClazz` 是应用；`Packages/ForumCore` 是应用依赖的本地库。如果 Xcode 仍显示之前从仓库根目录打开的 `ForumCore` Swift 包窗口，请关闭该窗口，再打开 `QuantClazz.xcodeproj`。本机使用 Xcode 27 验证。
2. 选择 iPhone 模拟器并运行。真机运行时，在 Signing & Capabilities 中选择自己的 Apple 开发团队；项目使用自动签名。
3. 应用包标识为 `io.github.chiyahoho.QuantClazz`。正式发布前需补充隐私说明等发布材料。

命令行构建（本机 Xcode 路径）：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project QuantClazz.xcodeproj -scheme QuantClazz -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/QuantClazzDerivedData CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --package-path Packages/ForumCore
```

模拟器也需要签名以获得钥匙串身份；上面的命令使用临时签名。不要添加 `CODE_SIGNING_ALLOWED=NO`，否则钥匙串可能返回 `-34018`（缺少身份授权）。真机签名由 Xcode 和你选择的开发团队处理。

## 登录

登录界面为原生二维码页面。应用在后台加载官网已确认的桌面微信认证流程 `/user/wechat?preurl=%2F`，从官方扫码子页面取得真实二维码并展示；微信确认后，检测论坛会话、验证收藏夹接口，成功后自动关闭登录页，无需再点“完成登录”。二维码过期或网络失败时可刷新；官网要求额外验证时，才提供明确的官网验证入口。

原生二维码显示、刷新以及扫码后自动完成登录均已验证，其中自动登录由用户实际扫码确认。

采用桌面认证流程是因为官网移动登录页面要求在微信内部打开。桥接只接受精确官网来源和当前登录轮次；token 只从 `https://bbs.quantclass.cn` 主页面读取，保存于仅本机解锁时可用的钥匙串。启动时重新验证保存的凭据，验证成功前不显示已登录。退出登录会清除凭据和应用专用网页存储。

网页使用应用专用的临时 WebKit 数据存储，不读取浏览器凭据。外部网站链接交给系统浏览器；未经确认的跨域 SSO 导航不会在登录视图中自动继续，已确认的官网微信登录使用 `api.quantclass.cn` 内嵌扫码页面，允许此官方子页面加载，但不会读取其存储。已由用户在模拟器完成微信扫码，并验证原生登录、收藏接口和重启恢复。同一手机识别截图的扫码方式尚未验证。官网页面或风控变化可能使登录、验证及接口暂时不可用；应用展示错误，不绕过验证，也不收集用户密码。

核心网络及数据模型在本地 Swift 包 `Packages/ForumCore` 中。接口兼容性取决于官网当前行为；开发用应用尚不具备正式商店发布所需的完整发布材料。

## 阅读与视觉

视觉规格见 [VISUAL_DESIGN.md](VISUAL_DESIGN.md)，沿用官网蓝白配色、深蓝标题、头像及缩略图。点标题直接打开完整正文；列表缩略图及正文图片可进入原生全屏预览，支持双击和双指缩放。列表使用官网缩略图，大图优先加载官网提供的原图地址。正文和评论采用单一滚动页面。进入帖子自动加载首批评论，后续评论只更新评论区。正文末尾的隐藏 HTML 标记会被过滤，代码示例中的 HTML 保持原样。

底部“写评论”打开原生纯文本输入页，通过官网 `POST /api/posts` 提交；支持发送状态、错误提示及审核状态。关闭输入页后，草稿保留在当前帖子内；不会自动重试发送。

## 用户历史与精华帖

“我的”页面在登录后显示官网账号的头像和用户名，点击进入自己的历史帖子页，也可筛选自己的精华帖。账号资料加载失败时可单独重试，无需重新扫码。

点击帖子列表、收藏、正文或评论里的作者头像/名字，可进入原生历史帖子页。页面支持分页、刷新及该作者的精华筛选；缺少真实用户 ID 时不显示跳转入口。论坛分类栏下方的“全部帖子 / 精华帖子”可与当前分区组合筛选，打开正文再返回时保留筛选和已加载内容。

## 浏览记录、投籽和消息

“我的”提供官网同步的浏览记录、投籽记录和消息提醒。记录按日期分组，可刷新、分页，点击标题直接阅读。投籽入口位于正文收藏按钮旁，沿用官网 1、2、3 籽选项，显示可用数量，用户确认后才提交；自己的帖子、已投过或余额不足时不能提交。

消息提醒包含投籽、提及、回复、点赞、奖励及系统通知，显示官网返回的未读数，可打开相关帖子。登录、回到前台和进入“我的”时更新未读状态。此版本提供站内提醒，不包含私信聊天、后台或锁屏推送。

投籽请求不自动重试；若响应不确定，需要先刷新服务端状态再继续。实际投籽由用户操作，开发验收不会消耗账号葫芦籽。

## 许可证

本仓库中由项目作者编写的源码与文档采用 [MIT License](LICENSE)，Copyright © 2026 chiyahoho。

MIT 授权不涵盖官网名称、品牌标志与其他品牌素材，不涵盖论坛用户内容，也不改变第三方依赖各自的许可证。`swift-markdown` 等第三方组件仍受其原始许可证约束。
