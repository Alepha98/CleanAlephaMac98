import AppKit
import SwiftUI

/// Competitor-grade **App Uninstaller**: pick an installed app, see its complete on-disk footprint
/// (the `.app` plus every cache / container / preference / log / cookie the `AppFootprint` engine
/// attributes to it), then move the lot to the Trash in one move. Everything is reversible — nothing
/// is permanently deleted — matching the rest of the app's safety posture.
struct UninstallerView: View {
    @Environment(\.copyLang) private var lang
    @Environment(\.careChrome) private var careChrome

    @State private var apps: [AppRow]? = nil          // nil = still reading /Applications
    @State private var selected: AppRow? = nil        // non-nil = drill-down open
    @State private var footprint: [FootItem]? = nil   // nil while measuring the selected app
    @State private var busy = false
    @State private var toast: String? = nil

    struct AppRow: Identifiable, Equatable, Sendable {
        let app: AppFootprint.InstalledApp
        var id: String { app.url.path }
        var name: String { app.name }
    }

    struct FootItem: Identifiable, Equatable, Sendable {
        let url: URL
        let bytes: Int64
        let isApp: Bool
        var selected: Bool
        var id: String { url.path }
    }

    private var titleInk: Color { careChrome ? C.careInk : C.ink }
    private var bodyInk: Color { careChrome ? C.careSecondary : C.secondary }

    private var selectedBytes: Int64 {
        (footprint ?? []).filter(\.selected).reduce(0) { $0 + $1.bytes }
    }
    private var selectedCount: Int { (footprint ?? []).filter(\.selected).count }

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if let selected {
                    detail(selected)
                } else {
                    list
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(Motion.easeModule, value: selected)

            if let toast {
                Text(toast)
                    .font(F.callout())
                    .foregroundStyle(.white)
                    .padding(.horizontal, S.lg)
                    .padding(.vertical, 10)
                    .background(
                        Capsule().fill(C.action.opacity(0.95))
                    )
                    .padding(.bottom, S.xl)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Motion.easeMicro, value: toast)
        .task { await loadApps() }
    }

    // MARK: - App list

    private var list: some View {
        VStack(alignment: .leading, spacing: S.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Copy.moduleUninstaller.t(lang))
                    .font(F.largeTitle())
                    .foregroundStyle(titleInk)
                Text(Copy.uninstallHint.t(lang))
                    .font(F.body())
                    .foregroundStyle(bodyInk)
            }
            .padding(.top, S.trafficClearance)

            if apps == nil {
                loading(Copy.uninstallReading.t(lang))
            } else if apps?.isEmpty == true {
                Text(Copy.uninstallEmpty.t(lang))
                    .font(F.body())
                    .foregroundStyle(bodyInk)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 4) {
                        ForEach(apps ?? []) { row in
                            appRow(row)
                        }
                    }
                    .padding(.bottom, S.xl)
                }
            }
        }
        .padding(.horizontal, S.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func appRow(_ row: AppRow) -> some View {
        Button { open(row) } label: {
            HStack(spacing: 12) {
                AppIcon(path: row.app.url.path, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name)
                        .font(F.body())
                        .foregroundStyle(titleInk)
                        .lineLimit(1)
                    if !row.app.bundleID.isEmpty {
                        Text(row.app.bundleID)
                            .font(F.micro())
                            .foregroundStyle(bodyInk)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Text("›")
                    .font(F.body())
                    .foregroundStyle(bodyInk.opacity(0.7))
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(C.pillHover.opacity(0.001)) // hit area; hover handled by style
            )
        }
        .buttonStyle(CardPressStyle())
        .help(row.app.url.path)
    }

    // MARK: - Drill-down

    private func detail(_ row: AppRow) -> some View {
        VStack(alignment: .leading, spacing: S.md) {
            Button { back() } label: {
                Text(Copy.uninstallBack.t(lang))
            }
            .buttonStyle(QuietButton())
            .padding(.top, S.trafficClearance)

            HStack(spacing: 14) {
                AppIcon(path: row.app.url.path, size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name)
                        .font(F.largeTitle(compact: true))
                        .foregroundStyle(titleInk)
                    Text(footprint == nil
                        ? Copy.uninstallMeasuring.t(lang)
                        : Copy.uninstallFootprint(max(0, selectedCount), selectedBytes).t(lang))
                        .font(F.body())
                        .foregroundStyle(bodyInk)
                }
                Spacer(minLength: 0)
            }

            if isRunning(row) {
                warnLine(Copy.uninstallRunning.t(lang))
            }

            if footprint == nil {
                loading(Copy.uninstallMeasuring.t(lang))
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 4) {
                        ForEach(footprint ?? []) { item in
                            footRow(item)
                        }
                    }
                    .padding(.bottom, 4)
                }
                if (footprint?.count ?? 0) <= 1 {
                    Text(Copy.uninstallNoLeftovers.t(lang))
                        .font(F.micro())
                        .foregroundStyle(bodyInk)
                }
                HStack(spacing: 12) {
                    Button(Copy.uninstallMove.t(lang)) { trash(row) }
                        .buttonStyle(PrimaryButton(enabled: selectedCount > 0 && !busy))
                        .disabled(selectedCount == 0 || busy)
                    Text(Copy.uninstallTrashHint.t(lang))
                        .font(F.micro())
                        .foregroundStyle(bodyInk)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, S.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func footRow(_ item: FootItem) -> some View {
        Button { toggle(item) } label: {
            HStack(spacing: 10) {
                CamIcon(glyph: item.selected ? .selectOn : .selectOff, size: 18)
                    .foregroundStyle(item.selected ? C.action : bodyInk.opacity(0.7))
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.isApp ? Copy.uninstallAppItself.t(lang) : item.url.lastPathComponent)
                        .font(F.callout())
                        .foregroundStyle(titleInk)
                        .lineLimit(1)
                    Text(PathFormat.tilde(item.url.deletingLastPathComponent()))
                        .font(F.micro())
                        .foregroundStyle(bodyInk)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(ByteFormat.string(item.bytes, lang))
                    .font(F.size())
                    .foregroundStyle(bodyInk)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(CardPressStyle())
    }

    // MARK: - Bits

    private func loading(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).font(F.body()).foregroundStyle(bodyInk)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func warnLine(_ text: String) -> some View {
        HStack(spacing: 8) {
            CamIcon(glyph: .warn, size: 14).foregroundStyle(C.warn)
            Text(text).font(F.callout()).foregroundStyle(C.warn)
        }
    }

    // MARK: - Actions

    private func isRunning(_ row: AppRow) -> Bool {
        guard !row.app.bundleID.isEmpty else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: row.app.bundleID).isEmpty
    }

    private func toggle(_ item: FootItem) {
        guard let i = footprint?.firstIndex(where: { $0.id == item.id }) else { return }
        footprint?[i].selected.toggle()
    }

    private func back() {
        selected = nil
        footprint = nil
    }

    private func loadApps() async {
        guard apps == nil else { return }
        let found = await Task.detached(priority: .utility) {
            AppFootprint.installedApps()
        }.value
        apps = found
            .map(AppRow.init)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func open(_ row: AppRow) {
        selected = row
        footprint = nil
        Task { @MainActor in
            let items = await Task.detached(priority: .utility) { () -> [FootItem] in
                var out: [FootItem] = [
                    FootItem(url: row.app.url, bytes: DiskSizer.bytes(at: row.app.url), isApp: true, selected: true)
                ]
                for url in AppFootprint.footprint(bundleID: row.app.bundleID, name: row.app.name) {
                    out.append(FootItem(url: url, bytes: sizeOf(url), isApp: false, selected: true))
                }
                // App first, then heaviest leftovers.
                return out.sorted {
                    if $0.isApp != $1.isApp { return $0.isApp }
                    return $0.bytes > $1.bytes
                }
            }.value
            guard selected == row else { return }   // user navigated away while measuring
            footprint = items
        }
    }

    private func trash(_ row: AppRow) {
        let targets = (footprint ?? []).filter(\.selected)
        guard !targets.isEmpty else { return }
        busy = true
        Task { @MainActor in
            let freed = await Task.detached(priority: .utility) { () -> Int64 in
                var f: Int64 = 0
                for t in targets {
                    do {
                        try FileManager.default.trashItem(at: t.url, resultingItemURL: nil)
                        f += t.bytes
                    } catch { /* skip what we cannot move (e.g. needs admin) */ }
                }
                return f
            }.value
            apps?.removeAll { $0.id == row.id }
            toast = Copy.uninstallDone(row.name, freed).t(lang)
            busy = false
            back()
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            toast = nil
        }
    }
}

/// The single-file / directory size a footprint entry contributes.
private func sizeOf(_ url: URL) -> Int64 {
    let rv = try? url.resourceValues(forKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
    if rv?.isDirectory == true {
        return DiskSizer.bytes(at: url)
    }
    return Int64(rv?.totalFileAllocatedSize ?? rv?.fileAllocatedSize ?? 0)
}

/// A real app icon rendered from disk.
private struct AppIcon: View {
    let path: String
    var size: CGFloat = 30

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
