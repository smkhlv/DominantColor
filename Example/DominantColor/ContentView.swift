import SwiftUI
import PhotosUI
import DominantColorKit

struct ContentView: View {
    @State private var selectedItem: PhotosPickerItem?
    @State private var selectedImage: UIImage?
    @State private var result: DominantColorResult?
    @State private var extractionTimeMs: Double?
    @State private var isProcessing = false

    private let extractor = DominantColorExtractor()

    var body: some View {
        ZStack {
            gradientBackground
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    headerSection
                    imageSection
                    pickerButton
                    if let result {
                        paletteSection(result)
                    }
                    if let extractionTimeMs {
                        performanceLabel(extractionTimeMs)
                    }
                }
                .padding()
            }
        }
    }

    // MARK: - Gradient Background

    @ViewBuilder
    private var gradientBackground: some View {
        if let stops = result?.gradientStops, stops.count >= 3 {
            LinearGradient(
                colors: stops.map { Color(simd: $0) },
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            Color.black
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        Text("DominantColorKit")
            .font(.largeTitle.bold())
            .foregroundStyle(.white)
    }

    @ViewBuilder
    private var imageSection: some View {
        if let selectedImage {
            Image(uiImage: selectedImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 300)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(radius: 10)
        } else {
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .frame(height: 200)
                .overlay {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 48))
                        Text("Pick an image to analyse")
                            .font(.headline)
                    }
                    .foregroundStyle(.secondary)
                }
        }
    }

    private var pickerButton: some View {
        PhotosPicker(
            selection: $selectedItem,
            matching: .images,
            photoLibrary: .shared()
        ) {
            Label(
                isProcessing ? "Processing…" : "Choose Image",
                systemImage: "photo.badge.plus"
            )
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .disabled(isProcessing)
        .onChange(of: selectedItem) { _, newItem in
            Task { await loadAndExtract(item: newItem) }
        }
    }

    private func paletteSection(_ result: DominantColorResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Palette")
                .font(.headline)
                .foregroundStyle(.white)

            HStack(spacing: 12) {
                ForEach(Array(result.colors.enumerated()), id: \.offset) { idx, color in
                    VStack(spacing: 4) {
                        Circle()
                            .fill(Color(simd: color))
                            .frame(width: 48, height: 48)
                            .overlay {
                                Circle().stroke(.white.opacity(0.3), lineWidth: 1)
                            }
                            .shadow(color: Color(simd: color).opacity(0.5), radius: 4)

                        Text(idx == 0 ? "P" : idx == 1 ? "S" : "\(idx + 1)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func performanceLabel(_ ms: Double) -> some View {
        HStack {
            Image(systemName: "speedometer")
            Text(String(format: "%.2f ms", ms))
                .monospacedDigit()
        }
        .font(.subheadline.bold())
        .foregroundStyle(.white.opacity(0.8))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    // MARK: - Logic

    private func loadAndExtract(item: PhotosPickerItem?) async {
        guard let item else { return }
        isProcessing = true
        defer { isProcessing = false }

        guard let data = try? await item.loadTransferable(type: Data.self),
              let uiImage = UIImage(data: data) else { return }

        selectedImage = uiImage

        let start = CFAbsoluteTimeGetCurrent()
        do {
            let extracted = try await extractor.extract(from: data)
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
            withAnimation(.easeInOut(duration: 0.4)) {
                result = extracted
                extractionTimeMs = elapsed
            }
        } catch {
            print("Extraction failed: \(error)")
        }
    }
}

// MARK: - Color helpers

extension Color {
    init(simd c: SIMD3<Float>) {
        self.init(
            red: Double(c.x),
            green: Double(c.y),
            blue: Double(c.z)
        )
    }
}

#Preview {
    ContentView()
}
