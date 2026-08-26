import SwiftUI

// Root: screen routing + the custom three-tab bar from the design
// (考卷 / big center 掃描 button / 結果). The tab bar is hidden on the
// scan screen so the camera runs full-bleed.
struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if model.needsLogin {
            LoginView()
        } else {
            main
        }
    }

    private var main: some View {
        Group {
            switch model.screen {
            case .templates:
                TemplatesView()
            case .scan:
                ScannerView()
            case .results:
                ResultsView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // An overlay, not a sibling in a ZStack.
        //
        // The bar reaches past the safe area to sit near the home indicator,
        // and inside a ZStack that expanded the whole stack to the physical
        // bottom — which the SCREEN then inherited. Its own bottom-anchored
        // controls, positioned against what they thought was the safe area,
        // dropped by the height of the inset and landed under the bar. An
        // overlay is sized by what it covers, so it can hang below without
        // moving anything.
        .overlay(alignment: .bottom) {
            if model.screen != .scan {
                TabBarView()
            }
        }
    }
}

private struct TabBarView: View {
    @EnvironmentObject private var model: AppModel
    // Reads the stack directly rather than through AppModel: the tab should
    // light up because a paper was actually filed, not because something
    // remembered to mirror that fact.
    @StateObject private var papers = GradingStore.shared

    var body: some View {
        HStack(spacing: 8) {
            tabButton(screen: .templates, icon: "folder", label: "考卷")
            scanButton
            tabButton(screen: .results, icon: "chart.bar", label: "結果",
                      disabled: papers.papers.isEmpty)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, AG.tabBarPadding)
        .floatingGlass(in: Capsule())
        .centeredContent(AG.Width.tabBar)
        .padding(.horizontal, 16)
        // Land the bar's bottom edge `bottomGap` above the PHYSICAL screen
        // edge, so it sits just clear of the home indicator rather than a
        // whole safe-area inset above it.
        //
        // `.ignoresSafeArea` was the obvious way to do this and it does not
        // work here: inside an overlay on a view that already respects the
        // safe area, there is no inset left for it to reclaim, so the bar
        // stayed where it was. Measuring the inset and moving by the
        // difference does not depend on that behaviour at all.
        //
        // Exactly one of these is ever non-zero: padding when the device has
        // less inset than the gap we want, offset when it has more.
        .padding(.bottom, AG.padding(above: AG.tabBarBottomGap))
        .offset(y: max(0, AG.bottomSafeInset - AG.tabBarBottomGap))
    }

    private func tabButton(screen: AppScreen, icon: String, label: String,
                           disabled: Bool = false) -> some View {
        let isActive = model.screen == screen
        return Button {
            guard !disabled else { return }
            model.screen = screen
        } label: {
            VStack(spacing: AG.tabBarLabelGap) {
                Image(systemName: icon)
                    .font(.system(size: AG.tabBarIconSize,
                                  weight: isActive ? .semibold : .regular))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(disabled ? AG.fg4 : (isActive ? AG.brand : AG.fg2))
            .opacity(disabled ? 0.5 : 1)
            // The group sizes itself and is centred in the row's height, which
            // is set by the scan button's circle. Padding the glyph out to that
            // height instead is what pushed the label down to begin with.
            .frame(maxWidth: .infinity, minHeight: AG.tabBarContentHeight)
        }
        .disabled(disabled)
    }

    // Solid, not glass, and that is a constraint rather than a preference:
    // glass cannot sample other glass, so a glass circle sitting inside the
    // glass bar would render as an artifact rather than a button. Two glass
    // shapes may sit BESIDE each other inside a `GlassEffectContainer`, but
    // this one belongs in the middle of the row, which means overlapping.
    //
    // Solid brand also keeps the one saturated colour in the app doing its
    // job: on a surface that takes its colour from whatever scrolls beneath
    // it, the fixed green is what stays recognisable.
    private var scanButton: some View {
        Button {
            model.screen = .scan
        } label: {
            VStack(spacing: AG.tabBarItemSpacing) {
                ZStack {
                    Circle()
                        .fill(AG.brand)
                        .frame(width: AG.tabBarIconSlot, height: AG.tabBarIconSlot)
                        .shadow(color: AG.brand.opacity(0.28), radius: 6, y: 3)
                    Image(systemName: "viewfinder")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text("掃描")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(model.screen == .scan ? AG.brand : AG.fg2)
            }
            .frame(maxWidth: .infinity)
        }
    }
}
