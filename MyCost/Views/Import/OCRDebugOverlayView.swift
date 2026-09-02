import SwiftUI

/// Developer-only diagnostic: draws every OCR observation's bounding box and the
/// detected transaction-region boundaries on top of the screenshot, so grouping
/// mistakes are visible. Reached from a `#if DEBUG` button on the Import screen.
struct OCRDebugOverlayView: View {
    let image: UIImage
    let observations: [OCRTextObservation]
    let regions: [TransactionRegion]

    @Environment(\.dismiss) private var dismiss
    @State private var showObservations = true
    @State private var showRegions = true

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let fitted = fittedImageRect(in: geometry.size)
                ZStack(alignment: .topLeading) {
                    Color(.systemBackground)

                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()

                    if showRegions {
                        ForEach(Array(regions.enumerated()), id: \.element.id) { index, region in
                            let rect = pixelRect(region.frame, in: fitted)
                            Rectangle()
                                .stroke(Color.orange, lineWidth: 2)
                                .frame(width: rect.width, height: rect.height)
                                .overlay(alignment: .topLeading) {
                                    Text("R\(index + 1)")
                                        .font(.caption2.bold())
                                        .padding(2)
                                        .background(Color.orange.opacity(0.85))
                                        .foregroundStyle(.black)
                                }
                                .offset(x: rect.minX, y: rect.minY)
                        }
                    }

                    if showObservations {
                        ForEach(observations) { observation in
                            let rect = pixelRect(observation.frame, in: fitted)
                            Rectangle()
                                .stroke(color(for: observation.confidence), lineWidth: 1)
                                .frame(width: rect.width, height: rect.height)
                                .offset(x: rect.minX, y: rect.minY)
                        }
                    }
                }
            }
            .navigationTitle("OCR Layout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("Observations (\(observations.count))", isOn: $showObservations)
                        Toggle("Regions (\(regions.count))", isOn: $showRegions)
                    } label: {
                        Image(systemName: "eye")
                    }
                }
            }
        }
    }

    private func color(for confidence: Double) -> Color {
        confidence >= 0.6 ? .blue : .red
    }

    /// The rect the `.scaledToFit()` image actually occupies inside `size`.
    private func fittedImageRect(in size: CGSize) -> CGRect {
        guard image.size.width > 0, image.size.height > 0 else { return .zero }
        let scale = min(size.width / image.size.width, size.height / image.size.height)
        let width = image.size.width * scale
        let height = image.size.height * scale
        return CGRect(
            x: (size.width - width) / 2,
            y: (size.height - height) / 2,
            width: width,
            height: height
        )
    }

    private func pixelRect(_ normalized: CGRect, in fitted: CGRect) -> CGRect {
        CGRect(
            x: fitted.minX + normalized.minX * fitted.width,
            y: fitted.minY + normalized.minY * fitted.height,
            width: normalized.width * fitted.width,
            height: normalized.height * fitted.height
        )
    }
}
