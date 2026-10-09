import AppKit
import Photos
import SwiftUI
import DateGuessCore

// Views keep their local state in plain `State<T>` properties (`var _x = State(...)` plus an
// `x` accessor) instead of `@State`. Newer SDKs implement `@State` as a macro whose plugin ships
// only with full Xcode, so `@State` breaks builds that use just the Command Line Tools.

enum Theme {
    static let accent = Color(red: 0.93, green: 0.42, blue: 0.40)
    static let peach = Color(red: 1.0, green: 0.86, blue: 0.76)
    static let blush = Color(red: 0.98, green: 0.74, blue: 0.80)
    static let sky = Color(red: 0.70, green: 0.84, blue: 0.98)
    static let background = Color(nsColor: .windowBackgroundColor)
    static let headerGradient = LinearGradient(colors: [peach, blush], startPoint: .topLeading, endPoint: .bottomTrailing)

    static func color(for level: ConfidenceLevel) -> Color {
        switch level {
        case .high: return Color(red: 0.30, green: 0.70, blue: 0.45)
        case .medium: return Color(red: 0.95, green: 0.65, blue: 0.25)
        case .low: return Color(red: 0.75, green: 0.75, blue: 0.78)
        }
    }

    static func color(for season: Season) -> Color {
        switch season {
        case .winter: return Color(red: 0.45, green: 0.65, blue: 0.95)
        case .spring: return Color(red: 0.45, green: 0.78, blue: 0.50)
        case .summer: return Color(red: 0.98, green: 0.70, blue: 0.20)
        case .fall: return Color(red: 0.88, green: 0.48, blue: 0.25)
        }
    }
}

/// Big friendly page header.
struct StepHeader: View {
    var step: Int?
    var title: String
    var subtitle: String
    var systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.headerGradient)
                    .frame(width: 58, height: 58)
                Image(systemName: systemImage)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: Theme.accent.opacity(0.4), radius: 2)
            }
            VStack(alignment: .leading, spacing: 4) {
                if let step {
                    Text("STEP \(step)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.accent)
                }
                Text(title)
                    .font(.largeTitle.weight(.semibold))
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Rounded card container.
struct Card<Content: View>: View {
    var title: String?
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Label {
                    Text(title).font(.headline)
                } icon: {
                    if let systemImage { Image(systemName: systemImage).foregroundStyle(Theme.accent) }
                }
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        )
    }
}

// MARK: Thumbnails

@MainActor
@Observable
final class ThumbnailLoader {
    var image: NSImage?
    @ObservationIgnored private var requestID: PHImageRequestID?
    @ObservationIgnored private var loadedID: String?

    func load(_ assetID: String, side: CGFloat) {
        guard loadedID != assetID else { return }
        cancel()
        loadedID = assetID
        image = nil
        guard let asset = PhotoLibraryService.shared.asset(for: assetID) else { return }
        requestID = PhotoLibraryService.shared.requestThumbnail(for: asset, side: side) { [weak self] img in
            guard let img else { return }
            Task { @MainActor in
                guard self?.loadedID == assetID else { return }
                self?.image = img
            }
        }
    }

    func cancel() {
        if let requestID { PhotoLibraryService.shared.cancel(requestID) }
        requestID = nil
        loadedID = nil
    }
}

struct AssetThumbnail: View {
    var assetID: String
    var side: CGFloat
    var height: CGFloat?
    var cornerRadius: CGFloat = 10
    var _loader = State<ThumbnailLoader>(initialValue: ThumbnailLoader())
    private var loader: ThumbnailLoader { get { _loader.wrappedValue } nonmutating set { _loader.wrappedValue = newValue } }

    var body: some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.12))
            if let image = loader.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: side, height: height ?? side)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .onAppear { loader.load(assetID, side: max(side, height ?? side)) }
        .onDisappear { loader.cancel() }
        .onChange(of: assetID) { _, new in loader.load(new, side: max(side, height ?? side)) }
    }
}

/// A larger, aspect-fit preview.
struct AssetPreview: View {
    var assetID: String
    var maxSide: CGFloat
    var _loader = State<ThumbnailLoader>(initialValue: ThumbnailLoader())
    private var loader: ThumbnailLoader { get { _loader.wrappedValue } nonmutating set { _loader.wrappedValue = newValue } }

    var body: some View {
        Group {
            if let image = loader.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
                    .frame(width: maxSide, height: maxSide * 0.7)
            }
        }
        .frame(maxWidth: maxSide, maxHeight: maxSide)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear { loader.load(assetID, side: maxSide) }
        .onDisappear { loader.cancel() }
    }
}

// MARK: Estimate display

struct ConfidenceBadge: View {
    var estimate: DateEstimate

    var body: some View {
        let level = estimate.confidenceLevel
        Text(level.displayName)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Theme.color(for: level).opacity(0.2), in: Capsule())
            .foregroundStyle(Theme.color(for: level))
            .help("About \(Int(estimate.confidence * 100))% likely to be within 2 years")
    }
}

struct SeasonIcon: View {
    var season: Season

    var body: some View {
        Image(systemName: season.symbolName)
            .foregroundStyle(Theme.color(for: season))
    }
}

/// The list of clues behind an estimate.
struct EvidenceList: View {
    var evidence: [DateEvidence]

    var body: some View {
        let used = evidence.filter { $0.hasYearInfo || $0.seasonWeight > 0 }
            .sorted { ($0.isHardConstraint ? 1 : $0.weight) + $0.seasonWeight * 0.3 > ($1.isHardConstraint ? 1 : $1.weight) + $1.seasonWeight * 0.3 }
        let notes = evidence.filter { !($0.hasYearInfo || $0.seasonWeight > 0) }
        VStack(alignment: .leading, spacing: 10) {
            if used.isEmpty && notes.isEmpty {
                Text("No clues were found for this photo. The guess is a placeholder — set the year yourself or leave it unchecked.")
                    .foregroundStyle(.secondary)
            }
            ForEach(used) { row($0, strong: true) }
            if !notes.isEmpty {
                Text("Other observations")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                ForEach(notes) { row($0, strong: false) }
            }
        }
    }

    private func row(_ e: DateEvidence, strong: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: e.source.symbolName)
                .frame(width: 18)
                .foregroundStyle(strong ? Theme.accent : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.summary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(e.source.displayName)
                    if let range = e.yearRangeText, e.hasYearInfo { Text("· \(range)") }
                    if let s = e.season, e.seasonWeight > 0 { Text("· \(s.displayName)") }
                    if e.isHardConstraint { Text("· certain") }
                    else if e.weight > 0 { StrengthDots(value: e.weight) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

struct StrengthDots: View {
    var value: Double

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5) { i in
                Circle()
                    .fill(Double(i) < value * 5 ? Theme.accent : Color.secondary.opacity(0.25))
                    .frame(width: 5, height: 5)
            }
        }
        .help("Clue strength")
    }
}

extension Date {
    var shortDay: String { formatted(date: .abbreviated, time: .omitted) }
}
