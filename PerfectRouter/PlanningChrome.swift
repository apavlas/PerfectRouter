import SwiftUI
import UIKit

/// Where the route list sits.
///
/// iPad landscape and Mac use a sidebar. iPad portrait and iPhone keep the
/// bottom sheet. iPad portrait is a regular width, so size class alone cannot
/// tell the two iPad orientations apart — the window also has to be wider
/// than it is tall. A compact iPad split (Slide Over, narrow Split View)
/// stays on the sheet.
enum PlanningChrome: Equatable {
    case sheet
    case sidebar

    /// Mac Catalyst, and an iOS app running on Apple silicon Mac.
    static var runsOnMac: Bool {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return ProcessInfo.processInfo.isiOSAppOnMac
        #endif
    }

    static func resolve(
        container: CGSize,
        horizontalSizeClass: UserInterfaceSizeClass?,
        idiom: UIUserInterfaceIdiom,
        runsOnMac: Bool
    ) -> PlanningChrome {
        if runsOnMac { return .sidebar }
        guard idiom == .pad else { return .sheet }
        guard horizontalSizeClass != .compact else { return .sheet }
        guard container.width > container.height else { return .sheet }
        return .sidebar
    }
}

private struct PlanningUsesSidebarKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True when the planning list is the sidebar column. Row taps center
    /// the map only in that layout. iPhone and iPad portrait leave it false
    /// so their rows keep today's actions and backgrounds.
    var planningUsesSidebar: Bool {
        get { self[PlanningUsesSidebarKey.self] }
        set { self[PlanningUsesSidebarKey.self] = newValue }
    }
}

/// Paints the selected stop.
///
/// The `if` follows the layout, not the selection. While the list is a
/// sidebar every row takes the background branch, and a tap only changes
/// the color. iPhone and iPad portrait take the other branch and keep the
/// list's own background. Selection does not add or remove a container,
/// which is what aborted iPad focus updates.
private struct SidebarStopHighlight: ViewModifier {
    var selected: Bool

    @Environment(\.planningUsesSidebar) private var sidebar

    @ViewBuilder
    func body(content: Content) -> some View {
        if let rowFill {
            content.listRowBackground(rowFill)
        } else {
            content
        }
    }

    private var rowFill: Color? {
        guard sidebar else { return nil }
        if selected {
            return Color.accentColor.opacity(0.24)
        }
        return Color(.secondarySystemGroupedBackground)
    }
}

extension View {
    func sidebarStopHighlight(selected: Bool) -> some View {
        modifier(SidebarStopHighlight(selected: selected))
    }
}
