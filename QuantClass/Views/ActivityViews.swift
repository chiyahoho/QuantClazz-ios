import SwiftUI
import ForumCore

enum ActivityKind: Equatable {
    case viewed, voted
    var title: String { self == .viewed ? "浏览记录" : "投籽记录" }
}

struct ActivityHistoryView: View {
    private struct DayGroup: Identifiable { let id: String; let records: [ThreadActivity] }
    let kind: ActivityKind
    @EnvironmentObject private var session: AppSession
    @State private var items: [ThreadActivity] = []
    @State private var page = 0
    @State private var more = true
    @State private var loading = false
    @State private var error: String?
    @State private var requestID = 0
    @State private var selectedThread: String?
    @State private var selectedAuthor: AuthorRoute?
    var body: some View {
        List {
            ForEach(grouped) { group in
                Section(group.id) {
                    ForEach(group.records) { record in
                        VStack(alignment: .leading, spacing: 8) {
                            if let authorID = record.thread.authorID {
                                Button { selectedAuthor = AuthorRoute(id: authorID, name: record.thread.authorName, avatarURL: record.thread.avatarURL) } label: {
                                    HStack(spacing: 8) { AuthorAvatar(url: record.thread.avatarURL); Text(record.thread.authorName).font(.caption).foregroundStyle(ForumTheme.secondary) }
                                }.buttonStyle(.plain)
                            }
                            Button { selectedThread = record.thread.id } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                Text(record.thread.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(ForumTheme.navy).lineLimit(2)
                                HStack {
                                    Spacer()
                                    if let votes = record.votes { Label("投了 \(votes) 籽", systemImage: "leaf.fill").foregroundStyle(ForumTheme.accent) }
                                    Text(time(record.occurredAt))
                                }.font(.caption).foregroundStyle(ForumTheme.secondary)
                                }.padding(.vertical, 6)
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            if loading { ProgressView().frame(maxWidth: .infinity) }
            else if let error { activityFailure(error) }
            else if more { Button("加载更多") { Task { await load(reset: false) } }.frame(maxWidth: .infinity) }
            else if items.isEmpty { ContentUnavailableView(kind == .viewed ? "暂无浏览记录" : "暂无投籽记录", systemImage: kind == .viewed ? "clock.arrow.circlepath" : "leaf") }
        }.navigationTitle(kind.title).navigationBarTitleDisplayMode(.inline).scrollContentBackground(.hidden).background(ForumTheme.background)
            .navigationDestination(item: $selectedThread) { ThreadView(id: $0) }
            .navigationDestination(item: $selectedAuthor) { UserPostsView(author: $0) }
            .task { if items.isEmpty { await load(reset: true) } }.refreshable { await load(reset: true) }
    }
    private var grouped: [DayGroup] {
        var order: [String] = [], values: [String: [ThreadActivity]] = [:]
        for item in items { let key = String(item.occurredAt.prefix(10)); if values[key] == nil { order.append(key) }; values[key, default: []].append(item) }
        return order.map { DayGroup(id: $0, records: values[$0] ?? []) }
    }
    @ViewBuilder private func activityFailure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(message).foregroundStyle(.secondary); Button("重试") { Task { await load(reset: items.isEmpty) } } }.font(.subheadline)
    }
    @MainActor private func load(reset: Bool) async {
        if loading && !reset { return }
        requestID += 1; let request = requestID; let next = reset ? 1 : page + 1
        loading = true; error = nil; let version = session.identityVersion
        defer { if request == requestID { loading = false } }
        do {
            let result = try await (kind == .viewed ? session.client.viewRecords(page: next) : session.client.voteRecords(page: next))
            guard request == requestID, version == session.identityVersion, !Task.isCancelled else { return }
            items = reset ? result.items : items + result.items.filter { value in !items.contains { $0.id == value.id } }
            page = next; more = result.hasMore
        } catch { guard request == requestID, version == session.identityVersion, !Task.isCancelled else { return }; self.error = error.localizedDescription; session.handle(error) }
    }
    private func time(_ value: String) -> String { value.count >= 16 ? String(value.dropFirst(11).prefix(5)) : value }
}

struct NotificationsView: View {
    struct Category: Identifiable { let id: String; let title: String; let types: [String] }
    private let categories = [
        Category(id: "voted", title: "投籽", types: ["voted"]), Category(id: "related", title: "提及", types: ["related"]),
        Category(id: "replied", title: "回复", types: ["replied"]), Category(id: "liked", title: "点赞", types: ["liked"]),
        Category(id: "rewarded", title: "奖励", types: ["rewarded", "withdrawal", "threadrewarded", "receiveredpacket", "threadrewardedexpired"]),
        Category(id: "system", title: "系统", types: ["system"])
    ]
    @EnvironmentObject private var session: AppSession
    @State private var selected = "voted"
    @State private var items: [ForumNotification] = []
    @State private var page = 0
    @State private var more = true
    @State private var loading = false
    @State private var error: String?
    @State private var requestID = 0
    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 8) {
                ForEach(categories) { category in
                    Button { guard selected != category.id else { return }; selected = category.id } label: {
                        HStack(spacing: 5) { Text(category.title); if unread(category) > 0 { Text("\(unread(category))").font(.caption2).padding(.horizontal, 5).padding(.vertical, 2).background(.red, in: Capsule()).foregroundStyle(.white) } }
                            .font(.subheadline.weight(selected == category.id ? .semibold : .regular)).foregroundStyle(selected == category.id ? ForumTheme.accent : ForumTheme.secondary).padding(.horizontal, 13).frame(minHeight: 38).background(selected == category.id ? ForumTheme.paleBlue : ForumTheme.surface, in: Capsule())
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 14).padding(.vertical, 8) }.frame(height: 56)
            List {
                ForEach(items) { item in notificationRow(item) }
                if loading { ProgressView().frame(maxWidth: .infinity) }
                else if let error { VStack(alignment: .leading) { Text(error); Button("重试") { Task { await load(reset: items.isEmpty) } } }.foregroundStyle(.secondary) }
                else if more { Button("加载更多") { Task { await load(reset: false) } }.frame(maxWidth: .infinity) }
                else if items.isEmpty { ContentUnavailableView("暂无消息", systemImage: "bell") }
            }.listStyle(.plain).scrollContentBackground(.hidden)
        }.background(ForumTheme.background).navigationTitle("消息提醒").navigationBarTitleDisplayMode(.inline)
            .task(id: selected) { await load(reset: true); await session.refreshCurrentUser() }.refreshable { await load(reset: true); await session.refreshCurrentUser() }
    }
    private func unread(_ category: Category) -> Int { category.types.reduce(0) { $0 + (session.currentUser?.typeUnreadNotifications[$1] ?? 0) } }
    @ViewBuilder private func notificationRow(_ item: ForumNotification) -> some View {
        let content = [item.title, item.content, item.postContent].first { !$0.isEmpty } ?? (item.threadTitle.isEmpty ? "你有一条新消息" : "")
        if item.canOpenThread, let threadID = item.threadID {
            NavigationLink { ThreadView(id: threadID) } label: { notificationContent(item, content: content) }
        } else { notificationContent(item, content: content) }
    }
    private func notificationContent(_ item: ForumNotification, content: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) { AuthorAvatar(url: item.userAvatarURL, size: 30); Text(item.userName.isEmpty || item.userID == "-1" ? label(for: item.type) : item.userName).font(.subheadline.weight(.semibold)); Text(action(for: item.type)).font(.caption).foregroundStyle(ForumTheme.secondary); Spacer(); Text(listDate(item.createdAt)).font(.caption).foregroundStyle(ForumTheme.secondary) }
            if !content.isEmpty { Text(content).font(.subheadline).foregroundStyle(ForumTheme.text).lineLimit(3) }
            if !item.threadTitle.isEmpty { Text(item.threadTitle).font(.caption).foregroundStyle(ForumTheme.accent).lineLimit(1) }
        }.padding(.vertical, 7)
    }
    private func label(for type: String) -> String { categories.first { $0.types.contains(type) }?.title ?? "消息" }
    private func action(for type: String) -> String { ["voted":"给帖子投籽", "related":"提到了你", "replied":"回复了你", "liked":"赞了你", "rewarded":"奖励了你", "system":"系统通知"][type] ?? "通知你" }
    @MainActor private func load(reset: Bool) async {
        if loading && !reset { return }
        requestID += 1; let request = requestID; let next = reset ? 1 : page + 1; loading = true; error = nil
        let types = categories.first { $0.id == selected }?.types ?? [selected]
        if reset { items = []; page = 0; more = true }
        let version = session.identityVersion
        defer { if request == requestID { loading = false } }
        do { let result = try await session.client.notifications(types: types, page: next); guard request == requestID, version == session.identityVersion, !Task.isCancelled else { return }; items = reset ? result.items : items + result.items.filter { value in !items.contains { $0.id == value.id } }; page = next; more = result.hasMore }
        catch { guard request == requestID, version == session.identityVersion, !Task.isCancelled else { return }; self.error = error.localizedDescription; session.handle(error) }
    }
}
