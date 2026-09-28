import Foundation

public struct ForumUser: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let avatarURL: URL?
    public let unreadNotifications: Int
    public let typeUnreadNotifications: [String: Int]
    public init(id: String, name: String, avatarURL: URL?, unreadNotifications: Int = 0, typeUnreadNotifications: [String: Int] = [:]) {
        self.id = id
        self.name = name
        self.avatarURL = avatarURL
        self.unreadNotifications = unreadNotifications
        self.typeUnreadNotifications = typeUnreadNotifications
    }
}

public struct ThreadSummary: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let authorID: String?
    public let authorName: String
    public let avatarURL: URL?
    public let summary: String
    public let categoryName: String
    public let createdAt: String
    public let replyCount: Int
    public let viewCount: Int
    public let imageURLs: [URL]
    public let thumbnailURL: URL?
    public let isEssence: Bool
    public let isOriginal: Bool
    public init(id: String, title: String, authorID: String? = nil, authorName: String, avatarURL: URL?, summary: String, categoryName: String, createdAt: String, replyCount: Int, viewCount: Int, imageURLs: [URL] = [], thumbnailURL: URL? = nil, isEssence: Bool = false, isOriginal: Bool = false) {
        self.id = id
        self.title = title
        self.authorID = authorID
        self.authorName = authorName
        self.avatarURL = avatarURL
        self.summary = summary
        self.categoryName = categoryName
        self.createdAt = createdAt
        self.replyCount = replyCount
        self.viewCount = viewCount
        self.imageURLs = imageURLs
        self.thumbnailURL = thumbnailURL
        self.isEssence = isEssence
        self.isOriginal = isOriginal
    }
}

public struct ThreadDetail: Hashable, Sendable {
    public let summary: ThreadSummary
    public let html: String
    public let canView: Bool
    public let isFavorite: Bool
    public let canFavorite: Bool
    public let canReply: Bool
    public let isVoted: Bool
    public let remainingVotes: Int
    public let canVote: Bool
    public let voteCount: Int
    public init(summary: ThreadSummary, html: String, canView: Bool, isFavorite: Bool, canFavorite: Bool, canReply: Bool = false, isVoted: Bool = false, remainingVotes: Int = 0, canVote: Bool = false, voteCount: Int = 0) {
        self.summary = summary
        self.html = html
        self.canView = canView
        self.isFavorite = isFavorite
        self.canFavorite = canFavorite
        self.canReply = canReply
        self.isVoted = isVoted
        self.remainingVotes = remainingVotes
        self.canVote = canVote
        self.voteCount = voteCount
    }
}

public struct ThreadActivity: Identifiable, Hashable, Sendable {
    public let thread: ThreadSummary
    public let occurredAt: String
    public let votes: Int?
    public var id: String { thread.id + "@" + occurredAt }
    public init(thread: ThreadSummary, occurredAt: String, votes: Int? = nil) {
        self.thread = thread; self.occurredAt = occurredAt; self.votes = votes
    }
}

public struct ForumNotification: Identifiable, Hashable, Sendable {
    public let id: String
    public let type: String
    public let userID: String?
    public let userName: String
    public let userAvatarURL: URL?
    public let createdAt: String
    public let threadID: String?
    public let threadTitle: String
    public let threadUserName: String
    public let postContent: String
    public let content: String
    public let title: String
    public let templateID: Int?
    public var canOpenThread: Bool { threadID.flatMap(Int.init).map { $0 > 0 } == true && !(type == "system" && [4, 6].contains(templateID)) }
    public init(id: String, type: String, userID: String? = nil, userName: String = "", userAvatarURL: URL? = nil, createdAt: String, threadID: String? = nil, threadTitle: String = "", threadUserName: String = "", postContent: String = "", content: String = "", title: String = "", templateID: Int? = nil) {
        self.id = id; self.type = type; self.userID = userID; self.userName = userName; self.userAvatarURL = userAvatarURL; self.createdAt = createdAt; self.threadID = threadID; self.threadTitle = threadTitle; self.threadUserName = threadUserName; self.postContent = postContent; self.content = content; self.title = title; self.templateID = templateID
    }
}

public enum CommentSubmissionStatus: Hashable, Sendable {
    case published
    case pendingModeration
    case accepted
}

public struct CommentSubmission: Hashable, Sendable {
    public let comment: ForumComment?
    public let status: CommentSubmissionStatus
    public var isPendingModeration: Bool { status == .pendingModeration }
    public init(comment: ForumComment?, status: CommentSubmissionStatus) {
        self.comment = comment
        self.status = status
    }
}

public struct ForumCategory: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct FavoriteFolder: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let count: Int
    public init(id: String, name: String, count: Int) {
        self.id = id
        self.name = name
        self.count = count
    }
}

public struct ForumComment: Identifiable, Hashable, Sendable {
    public let id: String
    public let authorID: String?
    public let authorName: String
    public let avatarURL: URL?
    public let html: String
    public let createdAt: String
    public init(id: String, authorID: String? = nil, authorName: String, avatarURL: URL? = nil, html: String, createdAt: String) {
        self.id = id
        self.authorID = authorID
        self.authorName = authorName
        self.avatarURL = avatarURL
        self.html = html
        self.createdAt = createdAt
    }
}

public struct Page<Item: Sendable>: Sendable {
    public let items: [Item]
    public let hasMore: Bool
    public init(items: [Item], hasMore: Bool) { self.items = items; self.hasMore = hasMore }
}
