import SwiftUI
import ForumCore
import WebKit

struct ForumRootView: View {
    @EnvironmentObject private var session: AppSession
    var body: some View {
        TabView {
            NavigationStack { FeedView() }.tabItem { Label("论坛", systemImage: "bubble.left.and.bubble.right") }
            NavigationStack { FavoritesView() }.tabItem { Label("收藏", systemImage: "bookmark") }
            NavigationStack { AccountView() }.tabItem { Label("我的", systemImage: "person.crop.circle") }.badge(session.currentUser?.unreadNotifications ?? 0)
        }.id(session.identityVersion)
    }
}

struct AuthorAvatar: View {
    let url: URL?
    var size: CGFloat = 30
    var body: some View {
        AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: {
            Image(systemName: "person.fill").font(.system(size: 15)).foregroundStyle(ForumTheme.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).background(ForumTheme.paleBlue)
        }.frame(width: size, height: size).clipShape(Circle())
    }
}

struct AuthorRoute: Identifiable, Hashable {
    let id: String
    let name: String
    let avatarURL: URL?
}

private struct EssenceFilter: View {
    @Binding var essenceOnly: Bool
    var body: some View {
        HStack(spacing: 4) {
            option("全部帖子", selected: !essenceOnly) { essenceOnly = false }
            option("精华帖子", selected: essenceOnly) { essenceOnly = true }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 3)
        .background(ForumTheme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(ForumTheme.separator).frame(height: 1) }
    }
    private func option(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? ForumTheme.accent : ForumTheme.secondary)
                .padding(.horizontal, 12).frame(minHeight: 44)
                .background(selected ? ForumTheme.paleBlue : .clear, in: Capsule())
        }.buttonStyle(.plain)
    }
}

private struct ThreadRow: View {
    let item: ThreadSummary
    let openThread: () -> Void
    let openAuthor: (AuthorRoute) -> Void
    @State private var showingImage = false
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                if let authorID = item.authorID {
                    Button { openAuthor(AuthorRoute(id: authorID, name: item.authorName, avatarURL: item.avatarURL)) } label: {
                        HStack(spacing: 8) {
                            AuthorAvatar(url: item.avatarURL)
                            Text(item.authorName).font(.system(size: 13, weight: .medium)).foregroundStyle(ForumTheme.text).lineLimit(1)
                        }.frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("查看\(item.authorName)的历史帖子")
                } else {
                    AuthorAvatar(url: item.avatarURL)
                    Text(item.authorName).font(.system(size: 13, weight: .medium)).foregroundStyle(ForumTheme.text).lineLimit(1)
                }
                Spacer()
                Text(listDate(item.createdAt)).font(.system(size: 11)).foregroundStyle(ForumTheme.secondary)
            }
            Button(action: openThread) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if item.isEssence { badge("精华", essence: true) }
                    if item.isOriginal { badge("原创", essence: false) }
                    Text(item.title).font(.system(size: 18, weight: .semibold)).foregroundStyle(ForumTheme.navy).lineLimit(3).multilineTextAlignment(.leading)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
            HStack(alignment: .top, spacing: 12) {
                if let url = item.thumbnailURL ?? item.imageURLs.first {
                    Button { showingImage = true } label: {
                        AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Rectangle().fill(ForumTheme.paleBlue).overlay(Image(systemName: "photo").foregroundStyle(ForumTheme.secondary)) }
                            .frame(width: 100, height: 76).clipShape(RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain)
                }
                if !item.summary.isEmpty {
                    Button(action: openThread) { Text(item.summary).font(.system(size: 14)).lineSpacing(4).foregroundStyle(ForumTheme.secondary).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
                }
            }
            HStack {
                Text(item.categoryName).foregroundStyle(ForumTheme.accent)
                Spacer()
                Label("\(item.replyCount)", systemImage: "bubble.right")
                Label("\(item.viewCount)", systemImage: "eye")
            }.font(.system(size: 12)).foregroundStyle(ForumTheme.secondary)
        }.padding(.horizontal, 18).padding(.vertical, 16)
            .background(ForumTheme.surface)
            .fullScreenCover(isPresented: $showingImage) { ImagePreview(urls: item.imageURLs.isEmpty ? [item.thumbnailURL].compactMap { $0 } : item.imageURLs) }
    }
    private func badge(_ text: String, essence: Bool) -> some View {
        Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(essence ? Color.white : ForumTheme.accent).padding(.horizontal, 4).padding(.vertical, 2).background(essence ? Color(red: 245 / 255, green: 108 / 255, blue: 108 / 255) : ForumTheme.paleBlue, in: RoundedRectangle(cornerRadius: 3))
    }
}

private struct FailureView: View {
    let message: String
    let retry: () -> Void
    @EnvironmentObject private var session: AppSession
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
            HStack {
                Button("重试", action: retry)
                Button("打开官方登录") { session.showLogin = true }
            }.font(.subheadline)
        }.padding(.vertical, 8)
    }
}

struct FeedView: View {
    @EnvironmentObject private var session: AppSession
    @State private var items: [ThreadSummary] = []
    @State private var selectedThread: String?
    @State private var categories: [ForumCategory] = []
    @State private var category: String?
    @State private var essenceOnly = false
    @State private var selectedAuthor: AuthorRoute?
    @State private var loadedKey: FeedKey?
    @State private var requestID = 0
    @State private var categoryError: String?
    @State private var page = 1
    @State private var more = false
    @State private var loading = false
    @State private var error: String?
    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 24) {
                    categoryButton("全部", id: nil)
                    ForEach(visibleCategories, id: \.id) { value in categoryButton(value.name, id: value.id) }
                }.padding(.horizontal, 18)
            }.frame(height: 48).background(ForumTheme.surface)
            EssenceFilter(essenceOnly: Binding(get: { essenceOnly }, set: { value in
                guard value != essenceOnly else { return }
                invalidateFeed(); essenceOnly = value
            }))
            List {
            if let categoryError { Text(categoryError).font(.caption).foregroundStyle(.secondary) }
            ForEach(items, id: \.id) { item in ThreadRow(item: item, openThread: { selectedThread = item.id }, openAuthor: { selectedAuthor = $0 }).listRowInsets(EdgeInsets()).listRowSeparatorTint(ForumTheme.separator) }
            if let error { FailureView(message: error) { Task { await load(reset: items.isEmpty) } } }
            if loading { ProgressView().frame(maxWidth: .infinity) }
            else if more { Button("加载更多") { Task { await load(reset: false) } }.frame(maxWidth: .infinity) }
            else if items.isEmpty && error == nil { ContentUnavailableView(essenceOnly ? "暂无精华帖子" : "暂无主题", systemImage: "bubble.left") }
        }
            .listStyle(.plain).scrollContentBackground(.hidden).background(ForumTheme.background)
        }
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { HStack(spacing: 7) { Image("BrandLogo").resizable().frame(width: 119.18, height: 24).frame(width: 24, height: 24, alignment: .leading).clipped().accessibilityHidden(true); Text("QuantClazz").font(.system(size: 20, weight: .semibold)).foregroundStyle(ForumTheme.navy) } }
            ToolbarItem(placement: .topBarTrailing) { Menu {
                Button("全部分区") { selectCategory(nil) }
                ForEach(categories, id: \.id) { value in Button(value.name) { selectCategory(value.id) } }
            } label: { Label("分区", systemImage: "line.3.horizontal.decrease.circle") } }
        }
        .navigationDestination(item: $selectedThread) { ThreadView(id: $0) }
        .navigationDestination(item: $selectedAuthor) { UserPostsView(author: $0) }
        .task { await loadCategories() }
        .task(id: feedKey) {
            guard loadedKey != feedKey else { return }
            await load(reset: true)
        }
        .refreshable { await load(reset: true) }
    }
    private var visibleCategories: [ForumCategory] {
        let common = Set(["公共讨论区", "策略分享会", "大A基础课程", "B圈基础课程", "链上技术", "葫芦专区"])
        return categories.filter { common.contains($0.name) || $0.id == category }
    }
    private struct FeedKey: Hashable { let category: String?; let essenceOnly: Bool }
    private var feedKey: FeedKey { FeedKey(category: category, essenceOnly: essenceOnly) }
    private func categoryButton(_ title: String, id: String?) -> some View {
        Button { selectCategory(id) } label: {
            VStack(spacing: 9) {
                Text(title).font(.system(size: 14, weight: category == id ? .semibold : .regular)).foregroundStyle(category == id ? ForumTheme.accent : ForumTheme.secondary)
                Capsule().fill(category == id ? ForumTheme.accent : .clear).frame(width: 22, height: 3)
            }.padding(.top, 12).frame(minHeight: 44)
        }.buttonStyle(.plain)
    }
    private func selectCategory(_ id: String?) {
        guard category != id else { return }
        invalidateFeed(); category = id
    }
    private func invalidateFeed() {
        requestID += 1; items = []; page = 0; more = false; loading = false; error = nil; loadedKey = nil
    }
    @MainActor private func loadCategories() async {
        let version = session.identityVersion
        let client = session.client
        do {
            let result = try await client.categories()
            guard version == session.identityVersion, !Task.isCancelled else { return }
            categories = result; categoryError = nil
        } catch {
            guard version == session.identityVersion, !Task.isCancelled else { return }
            categoryError = "分区暂时无法加载，仍可浏览全部主题。"
        }
    }
    @MainActor private func load(reset: Bool) async {
        if loading && !reset { return }
        requestID += 1
        let request = requestID
        let key = feedKey
        if reset { items = []; page = 0; more = false; loadedKey = nil }
        loading = true; error = nil
        let version = session.identityVersion
        let client = session.client
        let selected = key.category
        let next = reset ? 1 : page + 1
        defer { if request == requestID && version == session.identityVersion { loading = false } }
        do {
            let result = try await client.threads(page: next, categoryID: selected, essenceOnly: key.essenceOnly)
            guard request == requestID, version == session.identityVersion, key == feedKey, !Task.isCancelled else { return }
            items = reset ? result.items : items + result.items.filter { value in !items.contains { $0.id == value.id } }
            page = next; more = result.hasMore; loadedKey = key
        } catch {
            guard request == requestID, version == session.identityVersion, key == feedKey, !Task.isCancelled else { return }
            self.error = error.localizedDescription; session.handle(error)
        }
    }
}

struct UserPostsView: View {
    let author: AuthorRoute
    @EnvironmentObject private var session: AppSession
    @State private var items: [ThreadSummary] = []
    @State private var selectedThread: String?
    @State private var selectedAuthor: AuthorRoute?
    @State private var essenceOnly = false
    @State private var page = 0
    @State private var more = false
    @State private var loading = false
    @State private var error: String?
    @State private var requestID = 0
    @State private var loadedFilter: Bool?
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                AuthorAvatar(url: author.avatarURL).scaleEffect(1.6).frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text(author.name.isEmpty ? "论坛用户" : author.name).font(.system(size: 18, weight: .semibold)).foregroundStyle(ForumTheme.navy)
                    Text("历史帖子").font(.system(size: 12)).foregroundStyle(ForumTheme.secondary)
                }
                Spacer()
            }.padding(.horizontal, 18).padding(.vertical, 16).background(ForumTheme.surface)
            EssenceFilter(essenceOnly: Binding(get: { essenceOnly }, set: { value in
                guard value != essenceOnly else { return }
                invalidateHistory(); essenceOnly = value
            }))
            List {
                ForEach(items, id: \.id) { item in
                    ThreadRow(item: item, openThread: { selectedThread = item.id }, openAuthor: { if $0.id != author.id { selectedAuthor = $0 } })
                        .listRowInsets(EdgeInsets()).listRowSeparatorTint(ForumTheme.separator)
                }
                if let error { FailureView(message: error) { Task { await load(reset: items.isEmpty) } } }
                if loading { ProgressView().frame(maxWidth: .infinity) }
                else if more { Button("加载更多") { Task { await load(reset: false) } }.frame(maxWidth: .infinity) }
                else if items.isEmpty && error == nil {
                    ContentUnavailableView(essenceOnly ? "暂无精华帖子" : "暂无历史帖子", systemImage: "doc.text")
                }
            }.listStyle(.plain).scrollContentBackground(.hidden).background(ForumTheme.background)
        }
        .navigationTitle("历史帖子").navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedThread) { ThreadView(id: $0) }
        .navigationDestination(item: $selectedAuthor) { UserPostsView(author: $0) }
        .task(id: essenceOnly) {
            guard loadedFilter != essenceOnly else { return }
            await load(reset: true)
        }
        .refreshable { await load(reset: true) }
    }
    private func invalidateHistory() {
        requestID += 1; items = []; page = 0; more = false; loading = false; error = nil; loadedFilter = nil
    }
    @MainActor private func load(reset: Bool) async {
        if loading && !reset { return }
        requestID += 1
        let request = requestID
        let selectedFilter = essenceOnly
        if reset { items = []; page = 0; more = false; loadedFilter = nil }
        loading = true; error = nil
        let version = session.identityVersion
        let client = session.client
        let next = reset ? 1 : page + 1
        defer { if request == requestID && version == session.identityVersion { loading = false } }
        do {
            let result = try await client.userThreads(userID: author.id, page: next, essenceOnly: selectedFilter)
            guard request == requestID, version == session.identityVersion, selectedFilter == essenceOnly, !Task.isCancelled else { return }
            items = reset ? result.items : items + result.items.filter { value in !items.contains { $0.id == value.id } }
            page = next; more = result.hasMore; loadedFilter = selectedFilter
        } catch {
            guard request == requestID, version == session.identityVersion, selectedFilter == essenceOnly, !Task.isCancelled else { return }
            self.error = error.localizedDescription; session.handle(error)
        }
    }
}

struct ThreadView: View {
    let id: String
    @EnvironmentObject private var session: AppSession
    @State private var detail: ThreadDetail?
    @State private var comments: [ForumComment] = []
    @State private var submittedComments: [ForumComment] = []
    @State private var page = 0
    @State private var more = true
    @State private var error: String?
    @State private var loading = false
    @State private var commentsLoading = false
    @State private var commentsError: String?
    @State private var commentsStarted = false
    @State private var choosing = false
    @State private var removing = false
    @State private var composing = false
    @State private var commentDraft = ""
    @State private var commentSending = false
    @State private var commentSendError: String?
    @State private var commentNeedsLogin = false
    @State private var commentNotice: String?
    @State private var webLoading = true
    @State private var webError: String?
    @State private var documentVersion = 0
    @State private var imageSelection: ImageSelection?
    @State private var selectedAuthor: AuthorRoute?
    @State private var voting = false
    @State private var voteRequiresRefresh = false
    var body: some View {
        VStack(spacing: 0) {
            if let detail {
                if detail.canView {
                    ZStack {
                        SafeHTMLView(documentHTML: articleHTML(detail) + "<!--reload:\(documentVersion)-->", comments: comments + submittedComments, commentsLoading: commentsLoading, commentsError: commentsError, hasMoreComments: more, onLoading: { webLoading = $0 }, onFailure: { webError = $0 }, onImage: { imageSelection = ImageSelection(urls: [$0]) }, onComments: { Task { await loadComments() } }, onUser: { selectedAuthor = $0 })
                        if webLoading { ProgressView("加载正文…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
                    }
                    commentBar(detail)
                } else {
                    VStack(spacing: 20) {
                        Text(detail.summary.title).font(.system(size: 23, weight: .semibold)).foregroundStyle(ForumTheme.navy)
                        Text("此内容需要登录或相应访问权限。").foregroundStyle(ForumTheme.secondary)
                        Button("登录 QuantClazz") { session.showLogin = true }
                        Link("在官网查看", destination: officialURL)
                    }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if loading { ProgressView("加载主题…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            if let error { FailureView(message: error) { Task { await load() } }.padding(18) }
            if let webError { FailureView(message: webError) { self.webError = nil; documentVersion += 1 }.padding(18) }
            if detail == nil { Link("在官网查看", destination: officialURL).padding() }
        }.background(ForumTheme.surface)
            .navigationTitle("正文").navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if !session.isLoggedIn { session.showLogin = true } else { voting = true }
                    } label: { Label(detail?.isVoted == true ? "已投籽" : "投籽", systemImage: detail?.isVoted == true ? "leaf.fill" : "leaf") }
                    .disabled(loading || detail == nil || detail?.canView != true || detail?.isVoted == true)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if !session.isLoggedIn { session.showLogin = true }
                        else if detail?.isFavorite == true { removing = true }
                        else { choosing = true }
                    } label: { Image(systemName: detail?.isFavorite == true ? "bookmark.fill" : "bookmark") }
                    .disabled(loading || (session.isLoggedIn && detail?.canFavorite != true))
                    .accessibilityLabel(detail?.isFavorite == true ? "取消收藏" : "收藏")
                }
            }
            .task { if detail == nil { await load() } }
            .sheet(isPresented: $choosing) { FavoritePicker(threadID: id, didSave: { setFavoriteState(true) }).environmentObject(session) }
            .sheet(isPresented: $composing) { commentComposer }
            .sheet(isPresented: $voting) { if let detail { VoteSheet(detail: detail, currentUserID: session.currentUser?.id, requiresRefresh: $voteRequiresRefresh, submit: { votes in try await submitVote(votes) }, refresh: { try await refreshVoteState() }) } }
            .fullScreenCover(item: $imageSelection) { ImagePreview(urls: $0.urls) }
            .navigationDestination(item: $selectedAuthor) { UserPostsView(author: $0) }
            .alert("评论状态", isPresented: Binding(get: { commentNotice != nil }, set: { if !$0 { commentNotice = nil } })) { Button("好") { commentNotice = nil } } message: { Text(commentNotice ?? "") }
            .confirmationDialog("从所有收藏文件夹移除此主题？", isPresented: $removing, titleVisibility: .visible) {
                Button("从所有文件夹取消收藏", role: .destructive) { Task { await remove() } }
            } message: { Text("此操作会取消该主题在账号中的全部收藏。") }
    }
    private var officialURL: URL { URL(string: "https://bbs.quantclass.cn/thread/\(id)")! }
    private func articleHTML(_ detail: ThreadDetail) -> String {
        let value = detail.summary
        let avatar = value.avatarURL.map { "<img class='avatar' src='\(escapeHTML($0.absoluteString))'>" } ?? ""
        let authorBody = "\(avatar)<span>\(escapeHTML(value.authorName))</span>"
        let author = value.authorID.map { "<a class='author-link' href='\(userLink(id: $0, name: value.authorName, avatarURL: value.avatarURL))'>\(authorBody)</a>" } ?? authorBody
        var result = "<header><span class='category'>\(escapeHTML(value.categoryName))</span><h1>\(escapeHTML(value.title))</h1><div class='author'>\(author)<span> · \(escapeHTML(readableDate(value.createdAt)))</span></div></header>"
        result += detail.html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "<p class='muted'>服务器未返回正文，请在官网查看。</p>" : detail.html
        result += "<section class='comments'><h2>讨论</h2><div id='qc-comment-rows'></div><div id='qc-comment-status'></div></section>"
        result += "<footer><a href='\(escapeHTML(officialURL.absoluteString))'>在官网查看</a></footer>"
        return result
    }
    @MainActor private func load() async {
        guard !loading else { return }; loading = true; error = nil
        let version = session.identityVersion
        let client = session.client
        do {
            let value = try await client.thread(id: id)
            guard version == session.identityVersion, !Task.isCancelled else { loading = false; return }
            detail = value
            if !commentsStarted {
                commentsStarted = true; comments = []; page = 0; more = value.canView
                if value.canView { await loadComments() }
            }
        } catch { if version == session.identityVersion { self.error = error.localizedDescription; session.handle(error) } }
        loading = false
    }
    @MainActor private func loadComments() async {
        guard !commentsLoading, more else { return }; commentsLoading = true; commentsError = nil
        let version = session.identityVersion
        let client = session.client
        do {
            let result = try await client.comments(threadID: id, page: page + 1)
            guard version == session.identityVersion, !Task.isCancelled else { commentsLoading = false; return }
            let incoming = result.items.filter { value in !comments.contains { $0.id == value.id } }
            comments += incoming
            let returnedIDs = Set(result.items.map(\.id))
            submittedComments.removeAll { returnedIDs.contains($0.id) }
            page += 1; more = result.hasMore
        } catch { if version == session.identityVersion { commentsError = error.localizedDescription; session.handle(error) } }
        commentsLoading = false
    }
    @MainActor private func remove() async {
        guard !loading else { return }; loading = true
        let version = session.identityVersion
        do { try await session.client.setFavorite(threadID: id, folderIDs: [], isFavorite: false) }
        catch { if version == session.identityVersion { self.error = error.localizedDescription; session.handle(error) }; loading = false; return }
        loading = false
        if version == session.identityVersion { setFavoriteState(false) }
    }

    private func setFavoriteState(_ value: Bool) {
        guard let detail else { return }
        self.detail = ThreadDetail(summary: detail.summary, html: detail.html, canView: detail.canView, isFavorite: value, canFavorite: detail.canFavorite, canReply: detail.canReply, isVoted: detail.isVoted, remainingVotes: detail.remainingVotes, canVote: detail.canVote, voteCount: detail.voteCount)
    }

    @MainActor private func submitVote(_ votes: Int) async throws {
        guard let detail else { throw ForumError.invalidResponse }
        let version = session.identityVersion
        guard detail.summary.authorID != session.currentUser?.id else { throw ForumError.message("不能给自己投籽。") }
        guard !detail.isVoted else { throw ForumError.message("这个帖子已经投过籽了。") }
        guard detail.canVote else { throw ForumError.message("当前帖子暂时不能投籽。") }
        guard detail.remainingVotes >= votes else { throw ForumError.message("可用葫芦籽不足。") }
        do { try await session.client.vote(threadID: id, votes: votes) }
        catch {
            if version == session.identityVersion, !Task.isCancelled, case ForumError.unauthorized = error { voting = false; await Task.yield(); session.handle(error) }
            throw error
        }
        guard version == session.identityVersion, !Task.isCancelled else { throw CancellationError() }
        self.detail = ThreadDetail(summary: detail.summary, html: detail.html, canView: detail.canView, isFavorite: detail.isFavorite, canFavorite: detail.canFavorite, canReply: detail.canReply, isVoted: true, remainingVotes: detail.remainingVotes - votes, canVote: false, voteCount: detail.voteCount + votes)
    }
    @MainActor private func refreshVoteState() async throws {
        let version = session.identityVersion
        let refreshed: ThreadDetail
        do { refreshed = try await session.client.thread(id: id) }
        catch {
            if version == session.identityVersion, !Task.isCancelled, case ForumError.unauthorized = error { voting = false; await Task.yield(); session.handle(error) }
            throw error
        }
        guard version == session.identityVersion, !Task.isCancelled, let detail else { return }
        self.detail = ThreadDetail(summary: detail.summary, html: detail.html, canView: detail.canView, isFavorite: refreshed.isFavorite, canFavorite: refreshed.canFavorite, canReply: refreshed.canReply, isVoted: refreshed.isVoted, remainingVotes: refreshed.remainingVotes, canVote: refreshed.canVote, voteCount: refreshed.voteCount)
        voteRequiresRefresh = false
    }

    @ViewBuilder private func commentBar(_ detail: ThreadDetail) -> some View {
        Button {
            if !session.isLoggedIn { session.showLogin = true }
            else { commentSendError = nil; composing = true }
        } label: {
            HStack {
                Text(session.isLoggedIn ? (detail.canReply ? "写评论…" : "此主题暂不允许评论") : "登录后参与讨论")
                    .foregroundStyle(ForumTheme.secondary)
                Spacer()
                Image(systemName: "square.and.pencil").foregroundStyle(ForumTheme.accent)
            }.font(.system(size: 14)).padding(.horizontal, 14).frame(height: 40)
                .background(ForumTheme.background, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).disabled(session.isLoggedIn && !detail.canReply).padding(.horizontal, 18).padding(.vertical, 10)
            .background(ForumTheme.surface.overlay(alignment: .top) { Rectangle().fill(ForumTheme.separator).frame(height: 1) })
            .accessibilityHint(session.isLoggedIn && !detail.canReply ? "此主题暂不允许评论" : "")
    }

    private var commentComposer: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if let title = detail?.summary.title {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("回复主题").font(.caption).foregroundStyle(ForumTheme.secondary)
                        Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(ForumTheme.navy).lineLimit(2)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(ForumTheme.paleBlue, in: RoundedRectangle(cornerRadius: 12))
                }
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $commentDraft).font(.system(size: 17)).scrollContentBackground(.hidden).padding(8)
                    if commentDraft.isEmpty { Text("写下你的评论…").foregroundStyle(ForumTheme.secondary).padding(.horizontal, 13).padding(.vertical, 17).allowsHitTesting(false) }
                }.frame(minHeight: 180).background(ForumTheme.background, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(ForumTheme.separator))
                if let commentSendError {
                    Label(commentSendError, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(.red)
                    if commentNeedsLogin { Button("复制草稿并登录") { UIPasteboard.general.string = commentDraft; composing = false; session.showLogin = true } }
                }
                Spacer()
            }.padding(18).background(ForumTheme.surface)
                .navigationTitle("写评论").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { composing = false }.disabled(commentSending) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button { Task { await sendComment() } } label: { commentSending ? AnyView(ProgressView()) : AnyView(Text("发送")) }
                            .disabled(commentSending || commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }.presentationDetents([.medium, .large]).interactiveDismissDisabled(commentSending)
    }

    @MainActor private func sendComment() async {
        let text = commentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !commentSending, detail?.canReply == true else { return }
        commentSending = true; commentSendError = nil; commentNeedsLogin = false
        let version = session.identityVersion
        do {
            let submission = try await session.client.createComment(threadID: id, text: text)
            guard version == session.identityVersion, !Task.isCancelled else { commentSending = false; return }
            if submission.status == .published, let comment = submission.comment, !comments.contains(where: { $0.id == comment.id }), !submittedComments.contains(where: { $0.id == comment.id }) { submittedComments.append(comment) }
            commentDraft = ""; composing = false
            switch submission.status {
            case .published: commentNotice = "评论已发布。"
            case .pendingModeration: commentNotice = "评论已提交，审核通过后会显示。"
            case .accepted: commentNotice = "评论已提交。"
            }
        } catch {
            if version == session.identityVersion {
                if case ForumError.unauthorized = error { commentSendError = "登录状态已失效，请复制草稿后重新登录。"; commentNeedsLogin = true }
                else if case ForumError.verificationRequired = error { commentSendError = "需要完成官网验证，请先复制草稿。"; commentNeedsLogin = true }
                else { commentSendError = error.localizedDescription }
            }
        }
        commentSending = false
    }
}

private struct VoteSheet: View {
    let detail: ThreadDetail
    let currentUserID: String?
    @Binding var requiresRefresh: Bool
    let submit: (Int) async throws -> Void
    let refresh: () async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var votes = 1
    @State private var working = false
    @State private var error: String?
    private let options = [(1, "很有帮助"), (2, "受益匪浅"), (3, "醍醐灌顶")]
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text(detail.summary.title).font(.headline).foregroundStyle(ForumTheme.navy).lineLimit(2)
                HStack { Label("可用 \(detail.remainingVotes) 籽", systemImage: "leaf"); Spacer(); Text("帖子已有 \(detail.voteCount) 籽") }.font(.subheadline).foregroundStyle(ForumTheme.secondary)
                ForEach(options, id: \.0) { option in
                    Button { votes = option.0 } label: {
                        HStack { Image(systemName: votes == option.0 ? "checkmark.circle.fill" : "circle"); Text("\(option.0) 籽").fontWeight(.semibold); Text(option.1); Spacer() }
                            .padding(14).background(votes == option.0 ? ForumTheme.paleBlue : ForumTheme.background, in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain).disabled(working || requiresRefresh)
                }
                if detail.summary.authorID == currentUserID { Label("不能给自己的帖子投籽。", systemImage: "exclamationmark.circle").foregroundStyle(.red) }
                else if detail.isVoted { Label("这个帖子已经投过籽了。", systemImage: "checkmark.circle").foregroundStyle(ForumTheme.secondary) }
                else if !detail.canVote { Label("当前帖子暂时不能投籽。", systemImage: "exclamationmark.circle").foregroundStyle(.red) }
                else if detail.remainingVotes < votes { Label("可用葫芦籽不足。", systemImage: "exclamationmark.circle").foregroundStyle(.red) }
                if let error { Text(error).font(.subheadline).foregroundStyle(.red) }
                if requiresRefresh { Button("刷新投籽状态") { Task { await refreshState() } }.buttonStyle(.bordered) }
                Spacer()
                Button { Task { await confirm() } } label: { HStack { if working { ProgressView().tint(.white) }; Text("确认投 \(votes) 籽") }.frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).disabled(working || requiresRefresh || detail.isVoted || !detail.canVote || detail.summary.authorID == currentUserID || detail.remainingVotes < votes)
            }.padding(20).navigationTitle("给帖子投籽").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(working) } }
        }.interactiveDismissDisabled(working)
    }
    @MainActor private func confirm() async {
        guard !working else { return }; working = true; error = nil
        do { try await submit(votes); working = false; dismiss() }
        catch { self.error = error.localizedDescription + " 请刷新状态后再试。"; requiresRefresh = true; working = false }
    }
    @MainActor private func refreshState() async {
        guard !working else { return }; working = true; error = nil
        do { try await refresh(); working = false; dismiss() }
        catch { self.error = error.localizedDescription; working = false }
    }
}

struct FavoritesView: View {
    @EnvironmentObject private var session: AppSession
    @State private var folders: [FavoriteFolder] = []
    @State private var error: String?
    @State private var loading = false
    var body: some View {
        List {
            if !session.isLoggedIn { ContentUnavailableView("收藏你的研究灵感", systemImage: "bookmark", description: Text("通过官方网页登录后查看收藏。")); Button("官方登录") { session.showLogin = true } }
            else {
                Section {
                    ForEach(folders, id: \.id) { folder in
                        NavigationLink { FavoriteThreadsView(folder: folder) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder").font(.system(size: 20)).foregroundStyle(ForumTheme.accent).frame(width: 44, height: 44).background(ForumTheme.paleBlue, in: RoundedRectangle(cornerRadius: 10))
                                Text(folder.name).font(.system(size: 16, weight: .medium)).foregroundStyle(ForumTheme.text)
                                Spacer()
                                Text("\(folder.count) 篇").font(.system(size: 12)).foregroundStyle(ForumTheme.secondary)
                            }.padding(.vertical, 4)
                        }
                    }
                } header: { Text("\(folders.count) 个收藏文件夹").font(.system(size: 12)).foregroundStyle(ForumTheme.secondary) }
                if folders.isEmpty && !loading && error == nil { ContentUnavailableView("暂无收藏文件夹", systemImage: "folder") }
            }
            if loading { ProgressView() }
            if let error { FailureView(message: error) { Task { await load() } } }
        }.navigationTitle("我的收藏").navigationBarTitleDisplayMode(.inline).scrollContentBackground(.hidden).background(ForumTheme.background).onAppear { Task { await load() } }.refreshable { await load() }
    }
    @MainActor private func load() async {
        guard session.isLoggedIn, !loading else { return }; loading = true; error = nil
        let version = session.identityVersion
        do { let result = try await session.client.favoriteFolders(); if version == session.identityVersion && !Task.isCancelled { folders = result } }
        catch { if version == session.identityVersion { self.error = error.localizedDescription; session.handle(error) } }
        loading = false
    }
}

private struct FavoriteThreadsView: View {
    let folder: FavoriteFolder
    @EnvironmentObject private var session: AppSession
    @State private var items: [ThreadSummary] = []
    @State private var selectedThread: String?
    @State private var page = 0
    @State private var more = true
    @State private var loading = false
    @State private var error: String?
    @State private var selectedAuthor: AuthorRoute?
    var body: some View {
        List {
            ForEach(items, id: \.id) { item in ThreadRow(item: item, openThread: { selectedThread = item.id }, openAuthor: { selectedAuthor = $0 }).listRowInsets(EdgeInsets()).listRowSeparatorTint(ForumTheme.separator) }
            if let error { FailureView(message: error) { Task { await load(reset: false) } } }
            if loading { ProgressView() } else if more { Button("加载更多") { Task { await load(reset: false) } } }
            else if items.isEmpty { ContentUnavailableView("文件夹为空", systemImage: "bookmark") }
        }.listStyle(.plain).scrollContentBackground(.hidden).background(ForumTheme.background).navigationTitle(folder.name).navigationBarTitleDisplayMode(.inline).navigationDestination(item: $selectedThread) { ThreadView(id: $0) }.navigationDestination(item: $selectedAuthor) { UserPostsView(author: $0) }.onAppear { if items.isEmpty { Task { await load(reset: true) } } }.refreshable { await load(reset: true) }
    }
    @MainActor private func load(reset: Bool) async {
        guard !loading else { return }; loading = true; error = nil
        let version = session.identityVersion; let next = reset ? 1 : page + 1
        do { let result = try await session.client.favorites(folderID: folder.id, page: next)
            if version == session.identityVersion && !Task.isCancelled { items = reset ? result.items : items + result.items.filter { value in !items.contains { $0.id == value.id } }; page = next; more = result.hasMore }
        } catch { if version == session.identityVersion { self.error = error.localizedDescription; session.handle(error) } }
        loading = false
    }
}

private struct FavoritePicker: View {
    let threadID: String
    let didSave: () -> Void
    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [FavoriteFolder] = []
    @State private var selected: Set<String> = []
    @State private var loading = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                Section { Text("选择一个或多个收藏文件夹。保存成功后主题才会加入收藏。").font(.subheadline).foregroundStyle(.secondary) }
                ForEach(folders, id: \.id) { folder in Button { if selected.contains(folder.id) { selected.remove(folder.id) } else { selected.insert(folder.id) } } label: { HStack { Text(folder.name).foregroundStyle(.primary); Spacer(); Image(systemName: selected.contains(folder.id) ? "checkmark.circle.fill" : "circle") } }.disabled(loading) }
                if loading { ProgressView() }
                if let error { FailureView(message: error) { Task { await load() } } }
                if folders.isEmpty && !loading && error == nil { Text("暂无文件夹，请在官网创建收藏文件夹。") }
            }.navigationTitle("收藏到").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(loading) }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { Task { await save() } }.disabled(selected.isEmpty || loading) }
            }.task { await load() }
        }.interactiveDismissDisabled(loading)
    }
    @MainActor private func load() async {
        loading = true; error = nil; let version = session.identityVersion
        do { let values = try await session.client.favoriteFolders(); if version == session.identityVersion && !Task.isCancelled { folders = values } }
        catch { if version == session.identityVersion { self.error = error.localizedDescription; session.handle(error) } }
        loading = false
    }
    @MainActor private func save() async {
        loading = true; error = nil; let version = session.identityVersion
        do { try await session.client.setFavorite(threadID: threadID, folderIDs: selected.sorted(), isFavorite: true)
            if version == session.identityVersion { didSave(); dismiss() }
        } catch { if version == session.identityVersion { self.error = error.localizedDescription; session.handle(error) } }
        loading = false
    }
}

struct AccountView: View {
    @EnvironmentObject private var session: AppSession
    @State private var confirming = false
    @State private var selectedAuthor: AuthorRoute?
    var body: some View {
        List {
            Section {
                if session.isLoggedIn {
                    if let user = session.currentUser {
                        Button {
                            selectedAuthor = AuthorRoute(id: user.id, name: user.name, avatarURL: user.avatarURL)
                        } label: {
                            HStack(spacing: 14) {
                                AuthorAvatar(url: user.avatarURL, size: 52)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(user.name).font(.system(size: 20, weight: .semibold)).foregroundStyle(ForumTheme.navy).lineLimit(1)
                                    Text("查看我的主页与历史帖子").font(.system(size: 13)).foregroundStyle(ForumTheme.secondary)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(ForumTheme.secondary)
                            }.padding(.vertical, 8).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("查看\(user.name)的主页与历史帖子")
                    } else if session.profileLoading {
                        HStack(spacing: 14) {
                            ProgressView().frame(width: 52, height: 52)
                            Text("正在加载账号资料…").foregroundStyle(ForumTheme.secondary)
                        }.padding(.vertical, 8)
                    } else if let error = session.profileError {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(error).font(.footnote).foregroundStyle(.red)
                            Button("重试加载账号资料") { Task { await session.refreshCurrentUser() } }
                        }.padding(.vertical, 8)
                    }
                } else {
                    Label("访客模式", systemImage: "person.crop.circle.fill").font(.system(size: 20, weight: .semibold)).foregroundStyle(ForumTheme.navy).padding(.vertical, 12)
                    Text("登录后同步你的收藏。").foregroundStyle(.secondary)
                }
                if session.isLoggedIn { Button("退出登录", role: .destructive) { confirming = true } }
                else { Button("微信扫码登录") { session.showLogin = true } }
                if session.isValidating { ProgressView("验证登录状态…") }
                if let error = session.authError { Text(error).foregroundStyle(.red) }
            }
            Section {
                NavigationLink { FeedView() } label: { Label("浏览论坛", systemImage: "bubble.left.and.bubble.right").foregroundStyle(ForumTheme.text) }
                NavigationLink { FavoritesView() } label: { Label("我的收藏", systemImage: "bookmark").foregroundStyle(ForumTheme.text) }
                Link(destination: URL(string: "https://bbs.quantclass.cn")!) { Label("量化论坛官网", systemImage: "safari").foregroundStyle(ForumTheme.text) }
            }
            Section("我的活动") {
                if session.isLoggedIn {
                    NavigationLink { ActivityHistoryView(kind: .viewed) } label: { Label("浏览记录", systemImage: "clock.arrow.circlepath") }
                    NavigationLink { ActivityHistoryView(kind: .voted) } label: { Label("投籽记录", systemImage: "leaf") }
                    NavigationLink { NotificationsView() } label: { HStack { Label("消息提醒", systemImage: "bell"); Spacer(); if let count = session.currentUser?.unreadNotifications, count > 0 { Text("\(count)").font(.caption.weight(.semibold)).foregroundStyle(.white).padding(.horizontal, 7).padding(.vertical, 3).background(.red, in: Capsule()) } } }
                } else { Button("登录后查看活动记录") { session.showLogin = true } }
            }
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("第三方客户端", systemImage: "info.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(ForumTheme.navy)
                    Text("QuantClazz 是第三方客户端，与量化小论坛官方无隶属、授权或背书关系。")
                        .font(.footnote)
                        .foregroundStyle(ForumTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
            }
        }.navigationTitle("我的").navigationBarTitleDisplayMode(.inline).scrollContentBackground(.hidden).background(ForumTheme.background)
            .task { if session.isLoggedIn { await session.refreshCurrentUser(force: false) } }
            .navigationDestination(item: $selectedAuthor) { UserPostsView(author: $0) }
            .confirmationDialog("退出当前账号？", isPresented: $confirming, titleVisibility: .visible) { Button("退出登录", role: .destructive) { Task { await session.signOut() } } }
    }
}

private func parsedForumDate(_ value: String) -> Date? {
    let parser = ISO8601DateFormatter()
    if let date = parser.date(from: value) { return date }
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = parser.date(from: value) { return date }
    let legacy = DateFormatter()
    legacy.locale = Locale(identifier: "en_US_POSIX")
    legacy.timeZone = TimeZone(identifier: "Asia/Shanghai")
    legacy.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return legacy.date(from: value)
}
func listDate(_ value: String) -> String {
    guard let date = parsedForumDate(value) else { return value }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = formatter.timeZone
    formatter.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: Date()) ? "M月d日 HH:mm" : "yyyy年M月d日"
    return formatter.string(from: date)
}
private func readableDate(_ value: String) -> String {
    guard let date = parsedForumDate(value) else { return value }
    return date.formatted(.dateTime.year().month().day().hour().minute().locale(Locale(identifier: "zh_CN")))
}

/// Untrusted forum markup is isolated in a credential-free, script-free web view.
private struct SafeHTMLView: UIViewRepresentable {
    let documentHTML: String
    let comments: [ForumComment]
    let commentsLoading: Bool
    let commentsError: String?
    let hasMoreComments: Bool
    let onLoading: (Bool) -> Void
    let onFailure: (String) -> Void
    var onImage: (URL) -> Void = { _ in }
    var onComments: () -> Void = {}
    var onUser: (AuthorRoute) -> Void = { _ in }
    func makeCoordinator() -> Coordinator { Coordinator(onLoading: onLoading, onFailure: onFailure, onImage: onImage, onComments: onComments, onUser: onUser) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false; view.backgroundColor = .clear
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onImage = onImage
        context.coordinator.onComments = onComments
        context.coordinator.onUser = onUser
        let snapshot = CommentSnapshot(comments: comments, loading: commentsLoading, error: commentsError, hasMore: hasMoreComments)
        if context.coordinator.pendingSnapshot != snapshot {
            context.coordinator.pendingSnapshot = snapshot
            context.coordinator.pendingRevision += 1
        }
        if context.coordinator.previousDocument == documentHTML {
            context.coordinator.patchComments(in: view)
            return
        }
        context.coordinator.previousDocument = documentHTML
        context.coordinator.documentReady = false
        let document = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src https: http: data:; media-src 'none'; frame-src 'none'; connect-src 'none'; form-action 'none'; base-uri 'none'"><style>:root{color-scheme:light dark}body{color:#252B36;font:17px -apple-system;line-height:1.8;margin:20px 18px 88px;overflow-wrap:anywhere}h1,h2,h3,h4{line-height:1.35;margin:1.4em 0 .6em}h1{font-size:1.6em}h2{font-size:1.35em}h3{font-size:1.15em}p,ul,ol{margin:.8em 0}img{max-width:100%;height:auto;border-radius:6px}blockquote{margin:1em 0;padding:2px 14px;border-left:3px solid #1878F3;background:rgba(128,128,128,.08)}code{font: .88em ui-monospace,Menlo,monospace;background:rgba(128,128,128,.12);padding:2px 4px;border-radius:4px}pre{overflow:auto;padding:14px;background:rgba(128,128,128,.12);border-radius:8px;line-height:1.55}pre code{padding:0;background:none;white-space:pre}table{display:block;overflow:auto;border-collapse:collapse;font-size:.9em;margin:1em 0}th,td{padding:8px 12px;border:1px solid rgba(128,128,128,.3);white-space:normal}th{background:rgba(128,128,128,.1)}hr{border:0;border-top:1px solid rgba(128,128,128,.25);margin:1.5em 0}a{color:#1878F3}header{border-bottom:1px solid #EBEEF2;padding-bottom:20px;margin-bottom:24px}header h1{font-size:23px;color:#073763;margin:10px 0 16px;font-weight:600}.category{font-size:12px;color:#1878F3}.author,.author-link,.comment-author{display:flex;align-items:center;gap:8px;color:#8590A6;font-size:12px}.author-link,.comment-author{min-height:44px;text-decoration:none}.avatar{width:30px;height:30px;object-fit:cover;border-radius:50%}.muted{color:#8590A6;font-size:13px}.comments{border-top:1px solid #EBEEF2;margin-top:32px;padding-top:12px}.comments h2{font-size:18px;color:#073763}.comment{padding:16px 0;border-bottom:1px solid #EBEEF2}.load-comments{display:block;padding:14px;text-align:center;background:#EEF5FF;border-radius:8px;font-size:14px}.comment-error{padding:12px;color:#B42318;background:#FFF2F0;border-radius:8px}.comment-empty{padding:8px 0}.status-spinner{padding:12px;text-align:center}footer{margin-top:28px;font-size:12px;text-align:center}</style></head><body>\(documentHTML)</body></html>
        """
        view.loadHTMLString(document, baseURL: nil)
    }
    struct CommentSnapshot: Equatable {
        let comments: [ForumComment]
        let loading: Bool
        let error: String?
        let hasMore: Bool
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var previousDocument: String?
        var documentReady = false
        var pendingSnapshot: CommentSnapshot?
        var pendingRevision = 0
        var appliedRevision = -1
        var renderedCommentIDs = Set<String>()
        var patchInFlight = false
        var documentGeneration = 0
        let onLoading: (Bool) -> Void
        let onFailure: (String) -> Void
        var onImage: (URL) -> Void
        var onComments: () -> Void
        var onUser: (AuthorRoute) -> Void
        init(onLoading: @escaping (Bool) -> Void, onFailure: @escaping (String) -> Void, onImage: @escaping (URL) -> Void, onComments: @escaping () -> Void, onUser: @escaping (AuthorRoute) -> Void) {
            self.onLoading = onLoading; self.onFailure = onFailure; self.onImage = onImage; self.onComments = onComments; self.onUser = onUser
        }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            documentGeneration += 1; documentReady = false; renderedCommentIDs.removeAll(); appliedRevision = -1; patchInFlight = false; onLoading(true)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            documentReady = true; renderedCommentIDs.removeAll(); patchComments(in: webView)
            onLoading(false)
        }
        func patchComments(in webView: WKWebView) {
            guard documentReady, !patchInFlight, appliedRevision != pendingRevision, let snapshot = pendingSnapshot else { return }
            patchInFlight = true
            let revision = pendingRevision
            let generation = documentGeneration
            let additions = snapshot.comments.filter { !renderedCommentIDs.contains($0.id) }
            let desiredIDs = snapshot.comments.map(\.id)
            let rows: [[String: String]] = additions.map { comment in
                let index = desiredIDs.firstIndex(of: comment.id) ?? desiredIDs.endIndex
                let following = desiredIDs.dropFirst(index + 1).first(where: { renderedCommentIDs.contains($0) }) ?? ""
                let avatar = comment.avatarURL.map { "<img class='avatar' src='\(escapeHTML($0.absoluteString))'>" } ?? ""
                let authorBody = "\(avatar)<span>\(escapeHTML(comment.authorName)) · \(escapeHTML(readableDate(comment.createdAt)))</span>"
                let author = comment.authorID.map { "<a class='comment-author' href='\(userLink(id: $0, name: comment.authorName, avatarURL: comment.avatarURL))'>\(authorBody)</a>" } ?? "<div class='muted'>\(authorBody)</div>"
                let html = "<div class='comment' data-comment-id='\(escapeHTML(comment.id))'>\(author)\(comment.html)</div>"
                return ["html": html, "before": following]
            }
            let status: String
            if snapshot.loading { status = "<div class='status-spinner muted'>正在加载评论…</div>" }
            else if let error = snapshot.error { status = "<div class='comment-error'>\(escapeHTML(error))<br><a href='qc-comments://load'>重试</a></div>" }
            else if snapshot.hasMore { status = "<a class='load-comments' href='qc-comments://load'>加载更多评论</a>" }
            else if snapshot.comments.isEmpty { status = "<p class='muted comment-empty'>暂无评论</p>" }
            else { status = "" }
            let script = """
            const y = window.scrollY;
            const container = document.getElementById('qc-comment-rows');
            const status = document.getElementById('qc-comment-status');
            if (container) {
                for (const addition of additions) {
                    const next = addition.before ? container.querySelector(`[data-comment-id="${CSS.escape(addition.before)}"]`) : null;
                    if (next) { next.insertAdjacentHTML('beforebegin', addition.html); }
                    else { container.insertAdjacentHTML('beforeend', addition.html); }
                }
            }
            if (status) { status.innerHTML = statusHTML; }
            window.scrollTo(0, y);
            return true;
            """
            webView.callAsyncJavaScript(script, arguments: ["additions": rows, "statusHTML": status], in: nil, in: .defaultClient) { [weak self, weak webView] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard self.documentGeneration == generation else { return }
                    self.patchInFlight = false
                    if case .success = result {
                        self.renderedCommentIDs.formUnion(additions.map(\.id)); self.appliedRevision = revision
                    }
                    else { self.appliedRevision = revision; self.onFailure("评论显示失败，请重新加载正文。"); return }
                    if let webView, self.appliedRevision != self.pendingRevision { self.patchComments(in: webView) }
                }
            }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            onLoading(false); onFailure("正文加载中断，请重新加载。")
        }
        private func failed(_ error: Error) {
            let code = (error as NSError).code
            if code == NSURLErrorCancelled { return }
            onLoading(false); onFailure("正文加载失败，请重新加载。")
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated {
                if let url = navigationAction.request.url, url.scheme == "qc-image", url.host == "open",
                   let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value,
                   let imageURL = URL(string: value), safeImageURL(imageURL) { onImage(imageURL) }
                else if navigationAction.request.url?.scheme == "qc-comments", navigationAction.request.url?.host == "load" { onComments() }
                else if let url = navigationAction.request.url, url.scheme == "qc-user", url.host == "open",
                        let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                        let id = components.queryItems?.first(where: { $0.name == "id" })?.value, !id.isEmpty {
                    let name = components.queryItems?.first(where: { $0.name == "name" })?.value ?? ""
                    let avatar = components.queryItems?.first(where: { $0.name == "avatar" })?.value.flatMap(URL.init(string:)).flatMap { safeImageURL($0) ? $0 : nil }
                    onUser(AuthorRoute(id: id, name: name, avatarURL: avatar))
                }
                else if let url = navigationAction.request.url, ["https", "http"].contains(url.scheme?.lowercased() ?? "") { UIApplication.shared.open(url) }
                decisionHandler(.cancel); return
            }
            let scheme = navigationAction.request.url?.scheme?.lowercased()
            // WebKit uses an internal applewebdata URL for loadHTMLString on some OS versions.
            // Only the non-link internal document load is allowed; file/javascript and remote navigation remain denied.
            let internalDocument = navigationAction.navigationType == .other && (scheme == "about" || scheme == "applewebdata" || scheme == nil)
            decisionHandler(internalDocument ? .allow : .cancel)
        }
    }
}

private func escapeHTML(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
}
private func userLink(id: String, name: String, avatarURL: URL?) -> String {
    var components = URLComponents()
    components.scheme = "qc-user"; components.host = "open"
    components.queryItems = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "name", value: name)]
    if let avatarURL { components.queryItems?.append(URLQueryItem(name: "avatar", value: avatarURL.absoluteString)) }
    return escapeHTML(components.string ?? "")
}
private func safeImageURL(_ url: URL) -> Bool {
    ["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.host != nil && url.user == nil && url.password == nil
}
private struct ImageSelection: Identifiable {
    let id = UUID()
    let urls: [URL]
}
private struct ImagePreview: View {
    let urls: [URL]
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0
    private var validURLs: [URL] { urls.filter(safeImageURL) }
    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            if validURLs.isEmpty { ContentUnavailableView("图片无法打开", systemImage: "photo").foregroundStyle(.white) }
            else {
                TabView(selection: $page) {
                    ForEach(Array(validURLs.enumerated()), id: \.offset) { index, url in RemoteZoomImage(url: url).tag(index) }
                }.tabViewStyle(.page(indexDisplayMode: .never))
            }
            HStack {
                Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 18, weight: .semibold)).frame(width: 44, height: 44).background(.white.opacity(0.12), in: Circle()) }.accessibilityLabel("关闭图片")
                Spacer()
                if validURLs.count > 1 { Text("\(page + 1) / \(validURLs.count)").font(.subheadline) }
            }.foregroundStyle(.white).padding(.horizontal, 18).padding(.top, 12)
        }
    }
}
private struct RemoteZoomImage: View {
    let url: URL
    @State private var image: UIImage?
    @State private var failed = false
    @State private var retry = 0
    var body: some View {
        ZStack {
            if let image { ZoomImage(image: image) }
            else if failed {
                VStack(spacing: 16) { Label("图片加载失败", systemImage: "photo"); Button("重试") { retry += 1 } }.foregroundStyle(.white)
            } else { ProgressView().tint(.white) }
        }.task(id: retry) {
            failed = false
            guard safeImageURL(url) else { failed = true; return }
            do {
                var request = URLRequest(url: url); request.httpShouldHandleCookies = false
                let (data, response) = try await URLSession.shared.data(for: request)
                guard !Task.isCancelled else { return }
                guard let response = response as? HTTPURLResponse, let finalURL = response.url, safeImageURL(finalURL), (200..<300).contains(response.statusCode), let decoded = UIImage(data: data) else { failed = true; return }
                image = decoded
            } catch { if !Task.isCancelled { failed = true } }
        }
    }
}
private struct ZoomImage: UIViewRepresentable {
    let image: UIImage
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIScrollView {
        let scroll = ImageScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1; scroll.maximumZoomScale = 5
        scroll.showsHorizontalScrollIndicator = false; scroll.showsVerticalScrollIndicator = false
        scroll.imageView.image = image; scroll.imageView.contentMode = .scaleAspectFit
        scroll.addSubview(scroll.imageView)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        tap.numberOfTapsRequired = 2; scroll.addGestureRecognizer(tap)
        return scroll
    }
    func updateUIView(_ view: UIScrollView, context: Context) { (view as? ImageScrollView)?.imageView.image = image }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { (scrollView as? ImageScrollView)?.imageView }
        @objc func doubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? UIScrollView else { return }
            if scroll.zoomScale > 1 { scroll.setZoomScale(1, animated: true) }
            else {
                let point = gesture.location(in: (scroll as? ImageScrollView)?.imageView)
                let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
            }
        }
    }
    final class ImageScrollView: UIScrollView {
        let imageView = UIImageView()
        private var lastSize = CGSize.zero
        override func layoutSubviews() {
            super.layoutSubviews()
            if bounds.size != lastSize { lastSize = bounds.size; zoomScale = 1; imageView.frame = CGRect(origin: .zero, size: bounds.size); contentSize = bounds.size }
        }
    }
}
