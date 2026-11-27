import AppKit
import SwiftUI

/// Branded header at the top of the menu-bar menu: product name, live state as an evidence
/// label, and the signed-in account. Items below use Figtree via attributed titles.
@MainActor
final class MenuHeaderModel: ObservableObject {
    @Published var state = ""
    @Published var account: String?
}

struct MenuHeader: View {
    @ObservedObject var model: MenuHeaderModel
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: AppIdentity.name).font(Theme.display(16))
            Text(verbatim: model.state.uppercased()).font(Theme.label(10.5)).foregroundStyle(Theme.muted(scheme))
            if let account = model.account {
                Text(verbatim: account).font(Theme.text(12)).foregroundStyle(Theme.muted(scheme)).lineLimit(1)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(width: 260, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel(scheme)).padding(.horizontal, 5))
        .foregroundStyle(Theme.text(scheme))
    }
}

enum MenuStyle {
    static var quitTitle: String { L("menu.quit", AppIdentity.name) }

    /// Menu items in Figtree (the brand text face) instead of the system font.
    static func apply(_ item: NSMenuItem) {
        item.attributedTitle = NSAttributedString(string: item.title, attributes: [.font: Theme.nsText(13.5)])
    }
    /// The favicon letterform as a template image (small-space app use of the supplied mark).
    static var statusImage: NSImage? {
        let image = Theme.brandImage("menubar-mark")
        image?.size = NSSize(width: 15, height: 18)
        image?.isTemplate = true
        return image
    }
}
