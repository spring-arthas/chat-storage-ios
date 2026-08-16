import Foundation
import Observation

@MainActor
@Observable
final class DynamicTimelineViewModel {
    private(set) var posts: [DynamicPost] = []
    private(set) var nextBeforeId: Int64?
    private(set) var hasMore = true
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    let scope: DynamicTimelineScope
    private let repository: any DynamicRepository
    private let pageSize: Int

    init(repository: any DynamicRepository, scope: DynamicTimelineScope, pageSize: Int = 20) {
        self.repository = repository
        self.scope = scope
        self.pageSize = pageSize
    }

    func loadInitial() async {
        guard posts.isEmpty else { return }
        await load(replacing: true, beforeId: nil)
    }

    func refresh() async {
        await load(replacing: true, beforeId: nil)
    }

    func loadNextPage() async {
        guard hasMore, !isLoading else { return }
        await load(replacing: false, beforeId: nextBeforeId)
    }

    func toggleLike(postID: Int64) async {
        guard let index = posts.firstIndex(where: { $0.id == postID }) else { return }
        let original = posts[index]
        let action: DynamicAction = original.liked ? .unlike : .like
            posts[index] = DynamicPostCopy.updating(original,
            likeCount: max(0, original.likeCount + (original.liked ? -1 : 1)),
            liked: !original.liked
        )
        errorMessage = nil
        do {
            let result = try await repository.action(dynamicId: postID, action: action)
            apply(result)
        } catch {
            if let currentIndex = posts.firstIndex(where: { $0.id == postID }) {
                posts[currentIndex] = original
            }
            errorMessage = Self.message(for: error)
        }
    }

    func toggleRepost(postID: Int64) async {
        guard let index = posts.firstIndex(where: { $0.id == postID }) else { return }
        let original = posts[index]
        let action: DynamicAction = original.reposted ? .unrepost : .repost
            posts[index] = DynamicPostCopy.updating(original,
            repostCount: max(0, original.repostCount + (original.reposted ? -1 : 1)),
            reposted: !original.reposted
        )
        errorMessage = nil
        do {
            let result = try await repository.action(dynamicId: postID, action: action)
            apply(result)
        } catch {
            if let currentIndex = posts.firstIndex(where: { $0.id == postID }) {
                posts[currentIndex] = original
            }
            errorMessage = Self.message(for: error)
        }
    }

    func delete(postID: Int64) async {
        guard let post = posts.first(where: { $0.id == postID }), post.isMine else { return }
        errorMessage = nil
        do {
            try await repository.delete(dynamicId: postID)
            posts.removeAll { $0.id == postID }
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    func clearError() {
        errorMessage = nil
    }

    private func load(replacing: Bool, beforeId: Int64?) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let page = try await repository.timeline(scope: scope, beforeId: beforeId, limit: pageSize)
            posts = replacing ? Self.unique(page.posts) : Self.merging(posts, page.posts)
            nextBeforeId = page.nextBeforeId
            hasMore = page.hasMore
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    private func apply(_ result: DynamicActionResult) {
        guard let index = posts.firstIndex(where: { $0.id == result.dynamicId }) else { return }
        posts[index] = DynamicPostCopy.updating(posts[index],
            likeCount: result.likeCount,
            replyCount: result.replyCount,
            repostCount: result.repostCount,
            liked: result.liked,
            reposted: result.reposted
        )
    }

    private static func unique(_ values: [DynamicPost]) -> [DynamicPost] {
        var identifiers = Set<Int64>()
        return values.filter { identifiers.insert($0.id).inserted }
    }

    private static func merging(_ existing: [DynamicPost], _ additional: [DynamicPost]) -> [DynamicPost] {
        var identifiers = Set(existing.map(\.id))
        return existing + additional.filter { identifiers.insert($0.id).inserted }
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "动态操作失败"
    }
}

private enum DynamicPostCopy {
    static func updating(
        _ post: DynamicPost,
        likeCount: Int? = nil,
        replyCount: Int? = nil,
        repostCount: Int? = nil,
        liked: Bool? = nil,
        reposted: Bool? = nil
    ) -> DynamicPost {
        DynamicPost(
            id: post.id,
            author: post.author,
            content: post.content,
            media: post.media,
            reference: post.reference,
            likeCount: likeCount ?? post.likeCount,
            replyCount: replyCount ?? post.replyCount,
            repostCount: repostCount ?? post.repostCount,
            liked: liked ?? post.liked,
            reposted: reposted ?? post.reposted,
            originalPost: post.originalPost?.value,
            createdAt: post.createdAt,
            isMine: post.isMine
        )
    }
}
