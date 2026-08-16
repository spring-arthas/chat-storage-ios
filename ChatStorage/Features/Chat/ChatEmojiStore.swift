import Foundation

struct ChatEmojiCategory: Equatable, Sendable {
    let title: String
    let systemImage: String
    let emojis: [String]
}

enum ChatEmojiCatalog {
    // [修改] 与 macOS 表情分类保持一致，iPhone 使用触控网格展示，不新增图片表情协议。
    static let categories: [ChatEmojiCategory] = [
        ChatEmojiCategory(title: "笑脸", systemImage: "face.smiling", emojis: [
            "😀","😁","😂","🤣","😃","😄","😅","😆","😉","😊",
            "😋","😎","😍","🥰","😘","😗","😙","😚","🙂","🤗",
            "🤩","🤔","🤨","😐","😑","😶","🙄","😏","😣","😥",
            "😮","🤐","😯","😪","😫","🥱","😴","😌","😛","😜",
            "😝","🤤","😒","😓","😔","😕","🙃","🤑","😲","☹️",
            "🙁","😖","😞","😟","😤","😢","😭","😦","😧","😨",
            "😩","🤯","😬","😰","😱","🥵","🥶","😳","🤪","😠"
        ]),
        ChatEmojiCategory(title: "手势", systemImage: "hand.raised", emojis: [
            "👋","🤚","🖐","✋","🖖","👌","🤏","✌️","🤞","🤟",
            "🤘","🤙","👈","👉","👆","🖕","👇","☝️","👍","👎",
            "✊","👊","🤛","🤜","👏","🙌","👐","🤲","🤝","🙏",
            "✍️","💪","🦾","🦿","🦵","🦶","👂","🦻"
        ]),
        ChatEmojiCategory(title: "人物", systemImage: "person", emojis: [
            "👶","🧒","👦","👧","🧑","👱","👨","🧔","👩","🧓",
            "👴","👵","🙍","🙎","🙅","🙆","💁","🙋","🧏","🙇",
            "🤦","🤷","👮","💂","👷","🤴","👸","🦸","🦹"
        ]),
        ChatEmojiCategory(title: "动物", systemImage: "pawprint", emojis: [
            "🐶","🐱","🐭","🐹","🐰","🦊","🐻","🐼","🐨","🐯",
            "🦁","🐮","🐷","🐸","🐵","🙈","🙉","🙊","🐔","🐧",
            "🐦","🐤","🦆","🦅","🦉","🦇","🐺","🐴","🦄","🐢",
            "🐍","🦎","🐊","🦕","🦖","🦈","🐋","🐬","🦭","🐘"
        ]),
        ChatEmojiCategory(title: "食物", systemImage: "fork.knife", emojis: [
            "🍎","🍊","🍋","🍇","🍓","🍈","🍒","🍑","🥭","🍍",
            "🥥","🥝","🍅","🍆","🥑","🥦","🌽","🥕","🧄","🧅",
            "🍔","🍟","🍕","🌮","🌯","🥪","🥙","🧆","🥚","🍳",
            "🍿","🧂","🥞","🧇","🧈","🍱","🍜","🍣","🍦","☕️"
        ]),
        ChatEmojiCategory(title: "活动", systemImage: "sportscourt", emojis: [
            "⚽️","🏀","🏈","⚾️","🎾","🏐","🏉","🎱","🏓","🏸",
            "🥊","🥋","🎽","🛹","🛷","⛸","🏂","🏋️","🤸","🤺",
            "🏊","🚴","🧘","🎯","🎳","🎲","🎮","🎸","🎺","🎻"
        ]),
        ChatEmojiCategory(title: "旅行", systemImage: "car", emojis: [
            "🚗","🚕","🚙","🚌","🏎","🚓","🚒","🚐","🚚","✈️",
            "🚀","🛸","🚁","🛶","⛵️","🚢","🚂","🏠","🏢","🗼",
            "🗽","⛩","🎡","🎢","🎠","🌍","🌏","🌙","☀️","🌈"
        ]),
        ChatEmojiCategory(title: "符号", systemImage: "heart", emojis: [
            "❤️","🧡","💛","💚","💙","💜","🖤","🤍","🤎","💔",
            "❣️","💕","💞","💓","💗","💖","💘","💝","💯","✅",
            "❎","🔴","🟠","🟡","🟢","🔵","🟣","⚫️","⚪️","🟤",
            "🔶","🔷","🔸","🔹","🔺","🔻","💠","🔘","🔲","🔳"
        ]),
        ChatEmojiCategory(title: "物品", systemImage: "star", emojis: [
            "🎁","🎈","🎉","🎊","🎀","🏆","🥇","🥈","🥉","🎖",
            "🔑","🗝","🔒","🔓","🔔","🔕","🎵","🎶","💡","🔦",
            "📱","💻","⌨️","🖥","🖨","📷","📸","📹","🎥","📺",
            "📚","📖","✏️","🖊","📝","💼","🎒","🌂","☂️","🧲"
        ])
    ]
}

struct ChatEmojiStore {
    private static let recentEmojisKey = "chat.recentEmojis"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var recent: [String] {
        defaults.stringArray(forKey: Self.recentEmojisKey) ?? []
    }

    func storeRecent(_ emoji: String) {
        let normalized = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        var emojis = recent
        emojis.removeAll { $0 == normalized }
        emojis.insert(normalized, at: 0)
        defaults.set(Array(emojis.prefix(24)), forKey: Self.recentEmojisKey)
    }
}
