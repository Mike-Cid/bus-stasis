import AppKit
import Defaults
import SwiftUI

/// The MenuBarExtra label. On macOS 26 Tahoe the MenuBarExtra label only renders
/// `Image` content (SF Symbols / bitmaps) — custom SwiftUI shape views are silently
/// dropped. So we render the dynamic `BatteryIndicatorView` to an `NSImage` via
/// `ImageRenderer` and present it as a template `Image`, which both renders reliably
/// and adapts to the menu bar's light/dark tint.
struct BatteryLabelView: View {
    let viewModel: MenuViewModel
    @Default(.showBatteryPercentageInStatusIcon) private var showPercentage
    @Default(.showBatteryStateInStatusIcon) private var showState

    @State private var renderedImage: NSImage?

    var body: some View {
        Group {
            if let renderedImage {
                Image(nsImage: renderedImage)
            } else {
                Image(systemName: "battery.100")
            }
        }
        .onAppear(perform: render)
        .onChange(of: viewModel.displayPercentage) { _, _ in render() }
        .onChange(of: viewModel.chargingMode) { _, _ in render() }
        .onChange(of: showPercentage) { _, _ in render() }
        .onChange(of: showState) { _, _ in render() }
    }

    @MainActor
    private func render() {
        let content = BatteryIndicatorView(
            batteryLevel: viewModel.displayPercentage,
            chargingMode: viewModel.chargingMode,
            showPercentage: showPercentage,
            showState: showState
        )
        // Render in light scheme so .primary resolves to opaque black; the template
        // flag then re-tints it to the menu bar's foreground color.
        .environment(\.colorScheme, .light)

        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0

        guard let image = renderer.nsImage else { return }
        image.isTemplate = true
        renderedImage = image
    }
}
