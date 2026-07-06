import SwiftUI

// Root: screen routing + the custom three-tab bar from the design
// (考卷 / big center 掃描 button / 結果). The tab bar is hidden on the
// scan screen so the camera runs full-bleed.
struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
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

    var body: some View {
        HStack(spacing: 8) {
            tabButton(screen: .templates, icon: "folder", label: "考卷")
            scanButton
            tabButton(screen: .results, icon: "chart.bar", label: "結果",
                      disabled: !model.hasResults)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(alignment: .top) {
                    AG.border1.frame(height: 0.5)
                }
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private func tabButton(screen: AppScreen, icon: String, label: String,
                           disabled: Bool = false) -> some View {
        let isActive = model.screen == screen
        return Button {
            guard !disabled else { return }
            model.screen = screen
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: isActive ? .semibold : .regular))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(disabled ? AG.fg4 : (isActive ? AG.brand : AG.fg2))
            .opacity(disabled ? 0.5 : 1)
            .frame(maxWidth: .infinity)
        }
        .disabled(disabled)
    }

    private var scanButton: some View {
        Button {
            model.screen = .scan
        } label: {
            VStack(spacing: 2) {
                ZStack {
                    Circle()
                        .fill(AG.brand)
                        .frame(width: 50, height: 50)
                        .shadow(color: AG.brand.opacity(0.35), radius: 9, y: 8)
                        .overlay(
                            Circle().stroke(AG.bg2, lineWidth: 3)
                        )
                    Image(systemName: "viewfinder")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text("掃描")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(model.screen == .scan ? AG.brand : AG.fg2)
            }
            .frame(maxWidth: .infinity)
            .offset(y: -6)
        }
    }
}
