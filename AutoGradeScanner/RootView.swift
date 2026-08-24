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
        ZStack(alignment: .bottom) {
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
        .padding(.vertical, 6)
        .floatingGlass(in: Capsule())
        .centeredContent(AG.Width.tabBar)
        .padding(.horizontal, 16)
        // Measured from the physical bottom, not from the safe area. Sitting
        // above the inset put the bar 40pt clear of the screen edge, and on a
        // floating bar that gap is just bare background — the old full-width
        // slab hid it by running to the edge. 16pt keeps the home indicator
        // clear while closing most of it.
        .padding(.bottom, 16)
        .ignoresSafeArea(edges: .bottom)
    }

    private func tabButton(screen: AppScreen, icon: String, label: String,
                           disabled: Bool = false) -> some View {
        let isActive = model.screen == screen
        return Button {
            guard !disabled else { return }
            model.screen = screen
        } label: {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 21, weight: isActive ? .semibold : .regular))
                    .frame(height: 44)
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(disabled ? AG.fg4 : (isActive ? AG.brand : AG.fg2))
            .opacity(disabled ? 0.5 : 1)
            .frame(maxWidth: .infinity)
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
            VStack(spacing: 2) {
                ZStack {
                    Circle()
                        .fill(AG.brand)
                        .frame(width: 44, height: 44)
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
