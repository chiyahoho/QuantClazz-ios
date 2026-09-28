# 量化小论坛 iOS 接入调研

调研日期：2026-09-26。范围：登录、浏览、收藏。后续开发已创建 App，并由用户扫码完成账号联调；测试收藏已恢复原状。

## 结论与证据边界

网站为 Nuxt/Vue 前端，页面标注 Powered By Discuz! Q，具有课程权限及收藏夹等定制。适合 SwiftUI 原生界面直接接入网站现有 API。这里的“官方 API”指官网前端实际调用的服务器接口；尚未找到面向第三方、承诺兼容性的公开开发文档。

通过 Chrome 原生界面确认账号已登录、帖子富文本/代码/图片/评论、个人中心和多收藏夹页面。浏览器扩展连接超时，未获取登录态网络记录。公开 JS 已分析并进行了少量无认证 GET 检查；没有复制 Chrome 凭证、发送验证码或调用写接口。

## 接口清单

基址：`https://bbs.quantclass.cn`。下表路径来自当前公开前端代码，除标明实测者外尚未进行完整接口联调。

| 功能 | 方法和路径 | 参数及说明 |
| --- | --- | --- |
| 帖子列表 | GET `/api/threads.v2` | `page`、`perPage`、嵌套 `filter`、可选 `homeSequence`；无认证实测 HTTP 200、Code=0 |
| 用户历史发帖 | GET `/api/threads` | JSON:API；官网用户页使用 `filter[userId]`、`filter[isEssence]=0/1`、`filter[isApproved]=1`、`filter[isDeleted]=no`、`filter[isDisplay]=yes`、`filter[type]=0,1,2,3,4,6`、`sort=-createdAt` |
| 帖子详情 | GET `/api/threads.detail.v2` | `pid` |
| 评论/回复列表 | GET `/api/posts.v2` | `page`、`perPage`、`filter[thread]`、`sort` |
| 发表评论 | POST `/api/posts` | JSON:API `data.type=posts`；`attributes.content` 为纯文本；`relationships.thread.data={type:threads,id}`；需 Bearer 登录态 |
| 分类 | GET `/api/categories.v2` | 分类模型待联调 |
| 我的收藏夹 | GET `/api/user/favorites` | `page[number]`、`page[limit]`、`isAll=1`；无认证实测 HTTP 401、not_authenticated |
| 收藏夹内容 | GET `/api/favorites` | `favorite_id`、`page[number]`、`page[limit]`、`include`；总量来自 `meta.threadCount` |
| 添加收藏 | 逻辑 PATCH `/api/threads/{id}` | JSON:API attributes：`isFavorite:true`、`favorite_id:[收藏夹ID]` |
| 取消收藏 | 逻辑 PATCH `/api/threads/{id}` | `isFavorite:false`；网页未附带收藏夹 ID，应按可能全局取消处理，不能假设只移出一个收藏夹 |
| 登录代码入口 | POST `/api/login`、POST `/api/sms/verify` | auth store 中存在；不证明当前站点启用所有登录方式，请求参数、实际登录入口和刷新机制待核实 |

浏览 v2 接口采用 `Code / Message / Data`，列表实测包含 `Data.pageData`。收藏内容等接口使用 JSON:API `data / attributes / relationships / included / meta / errors`。收藏夹列表另有定制格式 `code:200 / msg / data:{favorites:[...],total}`，每行使用 `id/name/count`。需要分别解码，统一转换为 App 内部模型。

JSON:API 客户端从 localStorage 中的 access_token 构造 `Authorization: Bearer ...`，设置 `Accept: application/vnd.api+json`。逻辑 PATCH 在网页中实际转为 POST，并附加 `x-http-method-override: patch`。iOS 初期应与网页保持一致，写请求外层 JSON:API 编码仍须核对。

公开帖子页 JS 已确认发表评论使用上述 `posts` JSON:API 资源，正文限制为 40000 字符。官网普通评论输入组件并未受 `Data.thread.canComment` 控制：该字段用于另一项原帖点评操作；普通评论提交函数只先检查登录。App 在已登录且可阅读正文时提供输入入口，最终发表评论权限由 `POST /api/posts` 服务端检查。创建响应的 `isApproved == 0` 会被官网提示“审核中”，因此 App 应把它作为待审核结果展示。此次仅分析公开代码和构造本地桩测试，未使用浏览器凭证或发送真实评论。

前端包含 `list_captcha` / 浏览频繁处理和 `thread/list/verify-captcha` 验证流程；access_denied 会清除 token 并返回首页。需要按需分页、去重、缓存、有限重试，以及交互式官方验证回退。

## 实现建议

1. SwiftUI 构建论坛、收藏、我的三个主要入口；论坛支持分类、分页、详情和评论。搜索在确认实际接口后接入。
2. 使用 URLSession + async/await。分开实现 V2APIClient 和 JSONAPIClient，由 Repository 向界面提供统一 Thread、Post、FavoriteFolder 模型。不需要自建代理服务器。
3. 首先做登录原型：在 App 内完成官方登录，验证自己的会话能调用收藏 GET。不能直接复用桌面 Chrome 登录态。若官网支持 App 回调，优先 ASWebAuthenticationSession；否则验证 WKWebView 官方登录的兼容性及会话桥接。由于当前网站使用 localStorage token，不能仅同步 cookie 就认为原生请求已登录。
4. 仅在 App 自己的官方域登录上下文内取得必要会话，原生 token 保存在 Keychain；不保存密码，不写入日志。退出时清理 token、相关 WebView 会话和账号私有缓存。刷新机制未查明前，过期引导重新登录。
5. 列表、导航、收藏操作原生实现。文章正文使用经过清理的 HTML 在隔离 WKWebView 渲染，以兼容代码、表格和图片；不向正文 WebView 注入认证 token，不执行帖子提供的任意脚本。无法兼容的特殊内容提供官网打开入口。
6. 收藏与官网同步，支持收藏夹列表、夹内分页、选夹收藏及取消收藏。服务器确认成功后更新 UI；若乐观更新则失败回滚。第一版不必实现收藏夹删除、排序、导出等扩展功能。
7. 服务端课程/内容权限为准；缓存按账号隔离，权限错误不能呈现为普通空列表。

## 开发顺序及验收

- 第一阶段：登录 + 收藏夹只读原型。验收重新启动会话、退出、过期、无权限；确认当前正式登录方式和 token 生命周期。
- 第二阶段：论坛列表、分类、正文、评论。验收分页无重复、错误可恢复、代码/图片/表格可阅读、受限内容行为一致。
- 第三阶段：收藏同步。选定测试帖子完成添加、官网对照、取消和再次对照；验证多收藏夹语义与失败回滚。
- 后续：搜索、阅读位置、缓存等体验优化。

仍待验证：token 刷新与实际过期恢复；特殊附件的认证方式；多收藏夹的跨夹取消语义。

## 开发中补充确认

- 桌面未登录首页点击“登录”实际进入 `/user/wechat?preurl=%2F`，页面嵌入 `https://api.quantclass.cn/user/login-page` 微信扫码页。旧密码登录路由存在于代码中，但对应 chunk 返回404，不应作为主入口。
- URLSession 可正常读取详情；本机 curl 对详情曾返回403。因此不能仅根据 curl 结果判断真实 App 的可用性。
- 详情实际字段：`Data.author.username/avatar`、`Data.category.name`、`Data.thread.id`；与首页数据结构不同。登录联调发现 `firstPost.contentHtml` 可仅为动态渲染容器，`parseContentHtml` 可为空；官网使用 Vditor 渲染 `firstPost.threadContent` Markdown，App 应优先使用该字段。
- 详情收藏状态与操作权限在 `Data.isFavorite/canFavorite`；正文权限在 `Data.thread.canViewPosts`。App 仍要求自身已登录才展示收藏操作。
- Xcode 模拟器构建应保留 ad-hoc 签名。`CODE_SIGNING_ALLOWED=NO` 虽可启动，但会导致钥匙串返回 -34018；使用 `CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES`。
- 官网移动端登录脚本显示“请在微信中打开登录”，普通 WKWebView 不能直接沿用该入口。App 登录视图使用桌面内容模式和桌面 UA 加载已验证的微信扫码路由；原生论坛页面仍按手机尺寸呈现。移动端 runtime 也使用字符串 `localStorage.access_token`。
- 用户扫码后，原生收藏夹验证与 Keychain 保存成功，重新启动仍为已登录。收藏夹、夹内帖子和评论均已用真实账号读取。
- 在原本未收藏的测试帖子上完成添加、刷新详情与收藏夹计数、取消及再次刷新验证，收藏数量已恢复原值。此次仅验证单收藏夹流程，未改动原有收藏。
- 官网用户页当前从 JSON:API `/api/threads` 读取作者历史，使用 `filter[userId]`，精华开关使用数值 `filter[isEssence]=0/1`。公开 GET 实测指定用户的首屏 5 条资源，其 `relationships.user.data.id` 均等于请求用户，`meta.threadCount=40`。V2 首页传 `filter[essence]=1` 时仍会额外注入一条非精华置顶规则帖；App 的精华列表需按响应 `thread.isEssence` 再过滤，同时保留服务端分页状态。

## 来源

- [官网](https://bbs.quantclass.cn/) 与 Chrome 登录态页面 `/my/profile`、`/my/favorite`、`/thread/88175`。
- [API client 与 auth store](https://bbs.quantclass.cn/_nuxt/app~24120820.6a6dc5d.js)
- [首页及 v2 API 定义](https://bbs.quantclass.cn/_nuxt/pages/index~01e7b97c.36a2cfd.js)
- [收藏选择组件](https://bbs.quantclass.cn/_nuxt/pages/thread/_id~01e7b97c.d538fef.js)
- [收藏夹管理](https://bbs.quantclass.cn/_nuxt/my.favorite.index~f075b844.5601b3e.js)
- [收藏夹内容](https://bbs.quantclass.cn/_nuxt/pages/my/favorite/_id~f075b844.709fbde.js)
- [Apple ASWebAuthenticationSession](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession)
- [Apple HTTPCookieStorage](https://developer.apple.com/documentation/foundation/httpcookiestorage)

网站 JS URL 含构建 hash，未来部署可能替换；本报告描述的是本次观察到的版本。
# Authenticated account profile

- The cached official forum bundle defines `user/getUserInfo` as an authenticated `GET /api/users/{id}` and reads the JSON:API resource from `data`.
- No verified `/api/user` or `/api/users/me` endpoint was found in the cached official assets. The app therefore reads the numeric `sub` claim from the bearer JWT locally and uses it only as the path id for the official user resource. It does not log or persist decoded token contents.
- Profile response fields used by the app are `data.id`, `data.attributes.username` (with observed casing fallbacks), and `data.attributes.avatar`/`avatarUrl`.

## 浏览记录、投籽与通知（2026-09-28）

重新读取官网 HTML 与当前 runtime 后核实以下前端契约，均复用 App 内已有官网 bearer，不读取浏览器凭据。

| 功能 | 官方接口与关键字段 |
| --- | --- |
| 浏览记录 | `GET /api/user/viewrecords`，`page[number]`、`page[limit]=20`；JSON:API 帖子资源带 `viewAt`，`meta.threadCount` 分页 |
| 投籽记录 | `GET /api/user/vote/records`，同样分页；资源带 `voteAt`、`votes` |
| 投籽 | `POST /api/thread/vote/records`，JSON `{thread_id, votes}`；官网要求 HTTP 200 且业务 `code=200` |
| 站内通知 | `GET /api/notification`，`filter[type]`、`page[number]`、`page[limit]=10`，`meta.total` 分页 |
| 未读数 | 用户资料 `unreadNotifications`、`typeUnreadNotifications`，不通过后台读取通知列表计算未读 |

投籽沿用官网 1/2/3 籽三个选项，描述为“很有帮助 / 受益匪浅 / 醍醐灌顶”。详情根对象 `isVoted`、`remainingVotes` 与 `thread.canVote`、`thread.voteCount` 决定当前状态；不能给自己或已投过的帖子再次投籽。提交不自动重试，避免不确定的网络结果造成重复消费。

通知分类为投籽、提及、回复、点赞、奖励和系统；奖励查询合并 `rewarded,withdrawal,threadrewarded,receiveredpacket,threadrewardedexpired`。消息属性包括 `type/user_name/user_avatar/created_at/thread_id/thread_title/post_content/content`；系统消息 `raw.tpl_id=4/6` 分别为审核中/已删除，不直接导航到帖子。官网在读取通知列表后刷新用户资料，App 沿用这个顺序，不臆造标已读接口。官网私信使用独立的 `dialog` 系统，本次站内通知不包含聊天功能。

官网详情只调用现有详情读取接口，未发现另行写入浏览记录的前端调用。本次先沿用服务端浏览记录，实际同步效果见验收记录。已查阅代码未发现可供第三方 iOS App 使用的 APNs 接入；本次消息提醒为前台站内未读提示，不承诺后台或锁屏推送。

来源：[浏览记录页面](https://bbs.quantclass.cn/_nuxt/my.viewrecords~d0ae3f07.e1f2340.js)、[投籽记录页面](https://bbs.quantclass.cn/_nuxt/my.voterecords~d0ae3f07.9255bb3.js)、[通知页面](https://bbs.quantclass.cn/_nuxt/pages/my/notice~c98f95f3.4a50a2f.js)、[通知组件](https://bbs.quantclass.cn/_nuxt/pages/my/notice~01e7b97c.6f5de17.js)、[投籽操作](https://bbs.quantclass.cn/_nuxt/pages/thread/_id~c98f95f3.c2c8572.js)。
