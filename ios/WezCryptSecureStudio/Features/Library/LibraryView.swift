import SwiftUI

struct LibraryView: View {
    enum Section: String, CaseIterable, Identifiable {
        case all, recent, days, months, years
        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return String(localized: "All Photos")
            case .recent: return String(localized: "Recent")
            case .days: return String(localized: "Days")
            case .months: return String(localized: "Months")
            case .years: return String(localized: "Years")
            }
        }

        var shortTitle: String {
            switch self {
            case .all: return String(localized: "All")
            default: return title
            }
        }
    }

    enum Source: String, CaseIterable, Identifiable {
        case vault, device
        var id: String { rawValue }

        var title: String {
            switch self {
            case .vault: return String(localized: "Vault")
            case .device: return String(localized: "On This iPhone")
            }
        }

        var symbol: String {
            switch self {
            case .vault: return "lock.shield"
            case .device: return "iphone"
            }
        }
    }

    @Environment(AppEnvironment.self) private var env
    @State private var section: Section = .all
    @State private var source: Source = .vault
    @State private var recentSince = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()

    var body: some View {
        NavigationStack {
            Group {
                switch source {
                case .vault:
                    vaultContent
                case .device:
                    DeviceLibraryView()
                }
            }
            .navigationTitle(source == .vault ? section.title : Source.device.title)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker(String(localized: "Source"), selection: $source) {
                            ForEach(Source.allCases) { source in
                                Label(source.title, systemImage: source.symbol).tag(source)
                            }
                        }
                    } label: {
                        Label(source.title, systemImage: source.symbol)
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityLabel(String(localized: "Library Source"))
                }
            }
            .safeAreaInset(edge: .bottom) {
                if source == .vault {
                    sectionPicker
                }
            }
        }
    }

    @ViewBuilder
    private var vaultContent: some View {
        switch section {
        case .all:
            VaultCollectionScreen(title: Section.all.title, query: .all, api: env.api)
                .id("all")
        case .recent:
            VaultCollectionScreen(
                title: Section.recent.title,
                query: LibraryQuery(from: recentSince),
                api: env.api,
                emptyTitle: String(localized: "Nothing Recent"),
                emptyMessage: String(localized: "Items taken in the last 30 days appear here.")
            )
            .id("recent")
        case .days:
            BucketListView(granularity: .day, api: env.api).id("day")
        case .months:
            BucketListView(granularity: .month, api: env.api).id("month")
        case .years:
            BucketListView(granularity: .year, api: env.api).id("year")
        }
    }

    private var sectionPicker: some View {
        Picker(String(localized: "Section"), selection: $section.animation(.snappy)) {
            ForEach(Section.allCases) { section in
                Text(section.shortTitle).tag(section)
            }
        }
        .pickerStyle(.segmented)
        .padding(6)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }
}

/// Day / month / year groupings of the vault.
struct BucketListView: View {
    @State private var model: SummaryModel
    @Environment(AppEnvironment.self) private var env

    init(granularity: SummaryGranularity, api: APIClient) {
        _model = State(initialValue: SummaryModel(api: api, granularity: granularity))
    }

    var body: some View {
        ScrollView {
            if let error = model.error, model.buckets.isEmpty {
                ErrorBanner(message: error) { Task { await model.reload() } }.padding()
            }
            LazyVStack(spacing: model.granularity == .day ? 10 : 16) {
                ForEach(model.buckets) { bucket in
                    NavigationLink {
                        VaultCollectionScreen(
                            title: title(for: bucket),
                            query: LibraryQuery(from: bucket.start, to: bucket.end),
                            api: env.api
                        )
                    } label: {
                        BucketCard(bucket: bucket, title: title(for: bucket), granularity: model.granularity)
                    }
                    .buttonStyle(.plain)
                    .task { await model.loadMoreIfNeeded(current: bucket) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            if model.isLoading { ProgressView().padding() }
        }
        .overlay {
            if !model.isLoading, model.buckets.isEmpty, model.error == nil {
                ContentUnavailableView(String(localized: "No Photos or Videos"), systemImage: "calendar", description: Text(String(localized: "Synced items are grouped by date here.")))
            }
        }
        .refreshable { await model.reload() }
        .task { if model.buckets.isEmpty { await model.reload() } }
    }

    private func title(for bucket: SummaryBucket) -> String {
        switch model.granularity {
        case .day: return bucket.start.formatted(date: .complete, time: .omitted)
        case .month: return bucket.start.formatted(.dateTime.month(.wide).year())
        case .year: return bucket.start.formatted(.dateTime.year())
        }
    }
}

private struct BucketCard: View {
    let bucket: SummaryBucket
    let title: String
    let granularity: SummaryGranularity

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CoverThumbnail(mediaID: bucket.coverMediaId)
                .frame(height: height)
                .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(granularity == .year ? .largeTitle.bold() : .title3.bold())
                Text(String(localized: "\(bucket.count) items · \(Formatters.bytes(bucket.totalBytes))"))
                    .font(.subheadline)
                    .opacity(0.85)
            }
            .foregroundStyle(.white)
            .padding(16)
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var height: CGFloat {
        switch granularity {
        case .day: return 120
        case .month: return 180
        case .year: return 240
        }
    }
}
