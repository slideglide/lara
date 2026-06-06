//
//  PosterBoardWallpapersView.swift
//  lara
//

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct PosterBoardWallpapersView: View {
    @ObservedObject var mgr: laramgr
    @ObservedObject private var wallpaperManager = PosterBoardWallpaperManager.shared

    @AppStorage("pbHash") private var posterBoardHash = ""
    @AppStorage("cpHash") private var carPlayHash = ""

    @State private var isRefreshingHashes = false

    var body: some View {
        TabView {
            PosterBoardLockScreenView(posterBoardHash: $posterBoardHash, carPlayHash: $carPlayHash)
                .tabItem {
                    Label("PosterBoard", systemImage: "lock")
                }

            if wallpaperManager.supportsCarPlay() {
                PosterBoardCarPlayView(carPlayHash: $carPlayHash)
                    .tabItem {
                        Label("CarPlay", systemImage: "car")
                    }
            }

            PosterBoardWallpaperIndexView()
                .tabItem {
                    Label("Index", systemImage: "safari")
                }
        }
        .navigationTitle("PosterBoard Wallpapers")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    refreshHashes()
                } label: {
                    if isRefreshingHashes {
                        ProgressView()
                    } else {
                        Image(systemName: "key")
                    }
                }
                .disabled(isRefreshingHashes || !mgr.dsready)
            }
        }
    }

    private func refreshHashes() {
        guard !isRefreshingHashes else { return }
        isRefreshingHashes = true

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try wallpaperManager.refreshHashes() }
            DispatchQueue.main.async {
                isRefreshingHashes = false
                switch result {
                case .success(let hashes):
                    posterBoardHash = hashes.posterBoard
                    if !hashes.carPlay.isEmpty {
                        carPlayHash = hashes.carPlay
                    }
                    Haptic.shared.notify(.success)
                    Alertinator.shared.alert(title: "Hashes Updated", body: "PosterBoard hashes were refreshed with DarkSword.")
                case .failure(let error):
                    Haptic.shared.notify(.error)
                    Alertinator.shared.alert(title: "Hash Refresh Failed", body: error.localizedDescription)
                }
            }
        }
    }
}

private struct PosterBoardLockScreenView: View {
    @ObservedObject private var wallpaperManager = PosterBoardWallpaperManager.shared
    @Binding var posterBoardHash: String
    @Binding var carPlayHash: String

    @State private var showImporter = false
    @State private var isApplying = false
    @State private var isResetting = false
    @State private var isRefreshingHashes = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("PosterBoard")
                        Spacer()
                        Text(shortHash(posterBoardHash))
                            .foregroundStyle(posterBoardHash.isEmpty ? .red : .secondary)
                            .font(.system(.footnote, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    HStack {
                        Text("CarPlayWallpaper")
                        Spacer()
                        Text(shortHash(carPlayHash))
                            .foregroundStyle(carPlayHash.isEmpty ? .red : .secondary)
                            .font(.system(.footnote, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Button {
                        refreshHashes()
                    } label: {
                        Label(isRefreshingHashes ? "Refreshing..." : "Refresh Hashes with DarkSword", systemImage: "key")
                    }
                    .disabled(isRefreshingHashes)
                } header: {
                    Text("App Hash")
                } footer: {
                    Text("Hashes are stored locally and reused by the PosterBoard and CarPlay tabs.")
                }

                Section {
                    Button {
                        showImporter = true
                    } label: {
                        Label("Import Tendies", systemImage: "doc.badge.plus")
                    }

                    if wallpaperManager.selectedTendies.isEmpty {
                        Text("No tendies selected.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(wallpaperManager.selectedTendies, id: \.self) { url in
                            Text(url.deletingPathExtension().lastPathComponent)
                                .lineLimit(1)
                        }
                        .onDelete { offsets in
                            wallpaperManager.selectedTendies.remove(atOffsets: offsets)
                        }
                    }
                } header: {
                    Text("Lock Screen Wallpapers")
                }

                Section {
                    Button {
                        applyPosterBoard()
                    } label: {
                        Label(isApplying ? "Applying..." : "Apply PosterBoard Wallpapers", systemImage: "checkmark.circle")
                    }
                    .disabled(isApplying || posterBoardHash.isEmpty || wallpaperManager.selectedTendies.isEmpty)

                    Button(role: .destructive) {
                        resetCollections()
                    } label: {
                        Label(isResetting ? "Resetting..." : "Reset Collections", systemImage: "arrow.clockwise.circle")
                    }
                    .disabled(isResetting || posterBoardHash.isEmpty)
                } header: {
                    Text("Actions")
                }
            }
            .navigationTitle("PosterBoard")
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [UTType(filenameExtension: "tendies") ?? .data],
                allowsMultipleSelection: true
            ) { result in
                handleImport(result)
            }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            do {
                guard wallpaperManager.selectedTendies.count + urls.count <= PosterBoardWallpaperManager.maxTendies else {
                    throw PosterBoardApplyError.unexpected("You can only apply \(PosterBoardWallpaperManager.maxTendies) descriptors at once.")
                }
                for url in urls {
                    wallpaperManager.selectedTendies.append(try wallpaperManager.importTendies(from: url))
                }
                Haptic.shared.notify(.success)
            } catch {
                Haptic.shared.notify(.error)
                Alertinator.shared.alert(title: "Import Failed", body: error.localizedDescription)
            }
        case .failure(let error):
            Haptic.shared.notify(.error)
            Alertinator.shared.alert(title: "Import Failed", body: error.localizedDescription)
        }
    }

    private func refreshHashes() {
        guard !isRefreshingHashes else { return }
        isRefreshingHashes = true

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try wallpaperManager.refreshHashes() }
            DispatchQueue.main.async {
                isRefreshingHashes = false
                switch result {
                case .success(let hashes):
                    posterBoardHash = hashes.posterBoard
                    if !hashes.carPlay.isEmpty {
                        carPlayHash = hashes.carPlay
                    }
                    Haptic.shared.notify(.success)
                    Alertinator.shared.alert(title: "Hashes Updated", body: "PosterBoard hashes were refreshed with DarkSword.")
                case .failure(let error):
                    Haptic.shared.notify(.error)
                    Alertinator.shared.alert(title: "Hash Refresh Failed", body: error.localizedDescription)
                }
            }
        }
    }

    private func applyPosterBoard() {
        guard !isApplying else { return }
        isApplying = true
        let tendies = wallpaperManager.selectedTendies
        let hash = posterBoardHash

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try wallpaperManager.applyPosterBoard(appHash: hash, tendies: tendies) }
            DispatchQueue.main.async {
                isApplying = false
                switch result {
                case .success:
                    try? FileManager.default.removeItem(at: wallpaperManager.tendiesStoreURL())
                    wallpaperManager.selectedTendies.removeAll()
                    Haptic.shared.notify(.success)
                    Alertinator.shared.alert(
                        title: "Applied",
                        body: "The PosterBoard app will now open. Close it from the app switcher after it refreshes.",
                        showCancel: false,
                        actionLabel: "Open"
                    ) {
                        if !wallpaperManager.openPosterBoard() {
                            Alertinator.shared.alert(title: "PosterBoard", body: "PosterBoard could not be opened directly.")
                        }
                    }
                case .failure(let error):
                    Haptic.shared.notify(.error)
                    Alertinator.shared.alert(title: "Apply Failed", body: mappedApplyError(error).localizedDescription)
                }
            }
        }
    }

    private func resetCollections() {
        guard !isResetting else { return }
        isResetting = true

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try wallpaperManager.clearPosterBoardCache()
                if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 18,
                   let language = UserDefaults.standard.stringArray(forKey: "AppleLanguages")?.first,
                   wallpaperManager.setSystemLanguage(to: language) {
                    return "PosterBoard will refresh automatically."
                }
                return "Collections cache was cleared. Open PosterBoard if it does not refresh."
            }

            DispatchQueue.main.async {
                isResetting = false
                switch result {
                case .success(let message):
                    wallpaperManager.selectedTendies.removeAll()
                    Haptic.shared.notify(.success)
                    Alertinator.shared.alert(title: "Collections Reset", body: message)
                case .failure(let error):
                    Haptic.shared.notify(.error)
                    Alertinator.shared.alert(title: "Reset Failed", body: error.localizedDescription)
                }
            }
        }
    }

    private func mappedApplyError(_ error: Error) -> Error {
        if let cocoa = error as? CocoaError {
            switch cocoa.code {
            case .fileWriteUnknown:
                return PosterBoardApplyError.wrongHash
            case .fileWriteFileExists:
                return PosterBoardApplyError.collectionsNeedReset
            default:
                return cocoa
            }
        }
        return error
    }

    private func shortHash(_ hash: String) -> String {
        hash.isEmpty ? "Missing" : hash
    }
}

private struct PosterBoardCarPlayView: View {
    @ObservedObject private var wallpaperManager = PosterBoardWallpaperManager.shared
    @Binding var carPlayHash: String

    @State private var wallpapers: [PosterBoardCarPlayWallpaper] = []
    @State private var activeWallpapers: [String] = []
    @State private var showDark = false
    @State private var didChange = false
    @State private var isApplying = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ScrollView {
                    if wallpapers.isEmpty {
                        ProgressView()
                            .padding(.top, 48)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 240))], spacing: 14) {
                            ForEach($wallpapers) { wallpaper in
                                PosterBoardCarPlayWallpaperTile(
                                    wallpaper: wallpaper,
                                    showDark: $showDark,
                                    didChange: $didChange,
                                    isActive: activeWallpapers.contains(wallpaper.name.wrappedValue)
                                )
                            }
                        }
                        .padding()
                        .padding(.bottom, didChange ? 88 : 0)
                    }
                }

                if didChange {
                    Button {
                        applyCarPlay()
                    } label: {
                        Label(isApplying ? "Applying..." : "Apply CarPlay Wallpapers", systemImage: "checkmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isApplying || carPlayHash.isEmpty)
                    .padding()
                    .background(.bar)
                }
            }
            .navigationTitle("CarPlay")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation {
                            showDark.toggle()
                        }
                    } label: {
                        Image(systemName: showDark ? "moon" : "sun.max")
                    }
                }
            }
            .task {
                loadCarPlay()
            }
        }
    }

    private func loadCarPlay() {
        guard wallpapers.isEmpty else { return }
        do {
            activeWallpapers = UserDefaults.standard.array(forKey: "PosterBoardActiveCarPlayWallpapers") as? [String] ?? []
            wallpapers = try wallpaperManager.loadCarPlayWallpapers()
        } catch {
            Alertinator.shared.alert(title: "CarPlay", body: error.localizedDescription)
        }
    }

    private func applyCarPlay() {
        guard !isApplying else { return }
        isApplying = true
        let hash = carPlayHash
        let selectedWallpapers = wallpapers

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try wallpaperManager.applyCarPlay(appHash: hash, wallpapers: selectedWallpapers) }
            DispatchQueue.main.async {
                isApplying = false
                switch result {
                case .success(let active):
                    activeWallpapers = active
                    didChange = false
                    Haptic.shared.notify(.success)
                    Alertinator.shared.alert(title: "Applied", body: "You can now choose these wallpapers in CarPlay settings.")
                case .failure(let error):
                    Haptic.shared.notify(.error)
                    Alertinator.shared.alert(title: "Apply Failed", body: error.localizedDescription)
                }
            }
        }
    }
}

private struct PosterBoardCarPlayWallpaperTile: View {
    @Binding var wallpaper: PosterBoardCarPlayWallpaper
    @Binding var showDark: Bool
    @Binding var didChange: Bool
    var isActive: Bool

    @State private var selectedItem: PhotosPickerItem?

    var body: some View {
        PhotosPicker(selection: $selectedItem, matching: .images, photoLibrary: .shared()) {
            ZStack {
                let selectedData = showDark ? wallpaper.selectedDarkData : wallpaper.selectedLightData
                let fallback = showDark ? wallpaper.darkImage : wallpaper.lightImage
                let image = selectedData.flatMap(UIImage.init(data:)) ?? fallback

                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(1.35, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: 118)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.secondary.opacity(0.35), lineWidth: 1)
                    }

                if isActive {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.black.opacity(0.35))
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title)
                        .foregroundStyle(.green)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isActive)
        .overlay(alignment: .bottomLeading) {
            Text(wallpaper.name)
                .font(.caption)
                .lineLimit(1)
                .padding(6)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                .padding(6)
        }
        .onChange(of: selectedItem) { item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await MainActor.run {
                        if showDark {
                            wallpaper.selectedDarkData = data
                        } else {
                            wallpaper.selectedLightData = data
                        }
                        selectedItem = nil
                        withAnimation {
                            didChange = true
                        }
                    }
                }
            }
        }
    }
}

private struct PosterBoardWallpaperIndexView: View {
    @ObservedObject private var wallpaperManager = PosterBoardWallpaperManager.shared

    @State private var selectedType: PosterBoardWallpaper.WallpaperType = .custom
    @State private var selectedFilter: PosterBoardWallpaperFilter = .random
    @State private var searchTerm = ""
    @State private var downloadingID: UUID?

    private var filteredWallpapers: [PosterBoardWallpaper] {
        guard !searchTerm.isEmpty else {
            return wallpaperManager.downloadableWallpapers
        }
        return wallpaperManager.downloadableWallpapers.filter {
            $0.name.localizedCaseInsensitiveContains(searchTerm) ||
            ($0.authors ?? "").localizedCaseInsensitiveContains(searchTerm)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Picker("Type", selection: $selectedType) {
                        Text("Custom").tag(PosterBoardWallpaper.WallpaperType.custom)
                        Text("Apple").tag(PosterBoardWallpaper.WallpaperType.apple)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)

                    if filteredWallpapers.isEmpty {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text(wallpaperManager.downloadableStatus)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 48)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 165))], spacing: 12) {
                            ForEach(filteredWallpapers) { wallpaper in
                                Button {
                                    download(wallpaper)
                                } label: {
                                    PosterBoardWallpaperIndexTile(
                                        wallpaper: wallpaper,
                                        previewURL: URL(string: wallpaper.preview),
                                        isDownloading: downloadingID == wallpaper.id
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding()
                    }
                }
            }
            .searchable(text: $searchTerm)
            .navigationTitle("Wallpaper Index")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(PosterBoardWallpaperFilter.allCases, id: \.self) { filter in
                            Button {
                                selectedFilter = filter
                                reload()
                            } label: {
                                if selectedFilter == filter {
                                    Label(filter.rawValue, systemImage: "checkmark")
                                } else {
                                    Text(filter.rawValue)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .task {
                if wallpaperManager.downloadableWallpapers.isEmpty {
                    reload()
                }
            }
            .onChange(of: selectedType) { _ in
                reload()
            }
        }
    }

    private func reload() {
        wallpaperManager.downloadableWallpapers = []
        wallpaperManager.loadWallpaperIndex(type: selectedType, filter: selectedFilter)
    }

    private func download(_ wallpaper: PosterBoardWallpaper) {
        guard downloadingID == nil else { return }
        downloadingID = wallpaper.id

        Task {
            do {
                let url = try await wallpaperManager.downloadWallpaper(wallpaper)
                await MainActor.run {
                    downloadingID = nil
                    wallpaperManager.selectedTendies.append(url)
                    Haptic.shared.notify(.success)
                    Alertinator.shared.alert(title: "Downloaded", body: "\(wallpaper.name) was added to PosterBoard.")
                }
            } catch {
                await MainActor.run {
                    downloadingID = nil
                    Haptic.shared.notify(.error)
                    Alertinator.shared.alert(title: "Download Failed", body: error.localizedDescription)
                }
            }
        }
    }
}

private struct PosterBoardWallpaperIndexTile: View {
    var wallpaper: PosterBoardWallpaper
    var previewURL: URL?
    var isDownloading: Bool

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.secondary.opacity(0.18)
                AsyncImage(url: previewURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity)
                    case .failure:
                        Image(systemName: "photo")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    case .empty:
                        ProgressView()
                    @unknown default:
                        EmptyView()
                    }
                }
                if isDownloading {
                    Color.black.opacity(0.25)
                    ProgressView()
                        .tint(.white)
                }
            }
            .frame(minHeight: 150)

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(wallpaper.name)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let authors = wallpaper.authors {
                        Text(authors)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.blue)
            }
            .padding(10)
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
