import SwiftUI

struct PulseView: View {
    @Environment(AppState.self) private var state
    @Environment(\.copyLang) private var lang

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.height < 600
            let hPad = geo.size.width < 920 ? S.md : S.xxl
            ScrollView {
                VStack(alignment: .leading, spacing: compact ? S.md : S.lg) {
                    header(compact: compact)
                    if let snap = state.pulse {
                        memoryCard(snap)
                        if let note = snap.tabAccess {
                            Text(note.t(lang))
                                .font(F.callout())
                                .foregroundStyle(C.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !snap.tabs.isEmpty {
                            section(Copy.tabsTitle.t(lang)) {
                                ForEach(snap.tabs) { tab in
                                    TabRow(tab: tab)
                                }
                            }
                        }
                        if !snap.apps.isEmpty {
                            section(Copy.appsTitle.t(lang)) {
                                ForEach(Array(snap.apps.prefix(12))) { app in
                                    AppRow(app: app)
                                }
                            }
                        }
                    } else if !state.liveBusy {
                        Text(Copy.pulseIdle.t(lang))
                            .font(F.body())
                            .foregroundStyle(C.secondary)
                    }
                }
                .padding(.horizontal, hPad)
                .padding(.vertical, compact ? S.lg : S.xxl)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .onAppear { state.refreshLive(.pulse) }
    }

    private func header(compact: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Copy.modulePulse.t(lang))
                    .font(F.largeTitle(compact: compact))
                Text(Copy.subPulse.t(lang))
                    .font(F.body())
                    .foregroundStyle(C.secondary)
            }
            Spacer()
            Button(Copy.liveRefresh.t(lang)) {
                state.refreshLive(.pulse)
            }
            .buttonStyle(QuietButton(enabled: !state.liveBusy))
            .disabled(state.liveBusy)
        }
    }

    private func memoryCard(_ snap: PulseSnapshot) -> some View {
        HStack(alignment: .center, spacing: S.lg) {
            DiskLikeRing(
                used: CGFloat(Double(snap.used) / Double(max(snap.total, 1))),
                reserved: 0,
                size: 96
            )
            VStack(alignment: .leading, spacing: 6) {
                Text(snap.pressure.title.t(lang))
                    .font(F.title())
                    .foregroundStyle(snap.pressure == .normal ? C.ink : C.warn)
                Text(Copy.ramLine(used: snap.used, total: snap.total).t(lang))
                    .font(F.body())
                    .foregroundStyle(C.secondary)
                if snap.swap > 0 {
                    Text(Copy.swapLine(snap.swap).t(lang))
                        .font(F.callout())
                        .foregroundStyle(C.warn)
                }
                Text(Copy.ramHonest.t(lang))
                    .font(F.micro())
                    .tracking(0.4)
                    .foregroundStyle(C.secondary.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(S.lg)
        .background(CardBackground())
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: S.xs) {
            Text(title)
                .font(F.title())
            content()
        }
        .padding(S.lg)
        .background(CardBackground())
    }
}

private struct DiskLikeRing: View {
    var used: CGFloat
    var reserved: CGFloat
    var size: CGFloat
    var line: CGFloat = 10

    var body: some View {
        let u = max(0, min(1, used))
        ZStack {
            Circle().stroke(C.glass, lineWidth: line)
            Circle()
                .trim(from: 0, to: u)
                .stroke(
                    LinearGradient(colors: [C.liquidMid, C.liquidLo], startPoint: .top, endPoint: .bottom),
                    style: StrokeStyle(lineWidth: line, lineCap: .butt)
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct TabRow: View {
    let tab: LiveTab
    @Environment(\.copyLang) private var lang
    @State private var hover = false

    var body: some View {
        HStack(spacing: S.sm) {
            CamIcon(glyph: .browsers, size: 13)
                .foregroundStyle(C.accentText)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.title)
                    .font(F.body())
                    .foregroundStyle(C.ink)
                    .lineLimit(1)
                Text("\(tab.browser) · \(shortURL(tab.url))")
                    .font(F.callout())
                    .foregroundStyle(C.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if tab.estimate > 0 {
                Text(ByteFormat.string(tab.estimate, lang))
                    .font(F.size())
                    .foregroundStyle(C.secondary)
                    .help(Copy.estimateBadge.t(lang))
            }
            MicroBadge(text: Copy.estimateBadge.t(lang), tone: .quiet)
            Button(Copy.showTab.t(lang)) {
                LiveProbe.revealTab(tab)
            }
            .buttonStyle(GhostButton())
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hover ? C.pillHover : Color.clear))
        .onHover { hover = $0 }
        .help(Copy.weDontQuitBrowsers.t(lang))
    }

    private func shortURL(_ raw: String) -> String {
        if let url = URL(string: raw), let host = url.host { return host }
        return raw
    }
}

private struct AppRow: View {
    let app: LiveApp
    @Environment(\.copyLang) private var lang

    var body: some View {
        HStack {
            Text(app.name)
                .font(F.body())
                .foregroundStyle(C.ink)
                .lineLimit(1)
            Spacer()
            Text(ByteFormat.string(app.bytes, lang))
                .font(F.size())
                .foregroundStyle(C.secondary)
            MicroBadge(text: Copy.recommendBadge.t(lang), tone: .caution)
        }
        .padding(.vertical, 4)
        .help(Copy.appRamHint.t(lang))
    }
}

struct ProtectView: View {
    @Environment(AppState.self) private var state
    @Environment(\.copyLang) private var lang

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.height < 600
            let hPad = geo.size.width < 920 ? S.md : S.xxl
            ScrollView {
                VStack(alignment: .leading, spacing: compact ? S.md : S.lg) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(Copy.moduleProtect.t(lang))
                                .font(F.largeTitle(compact: compact))
                            Text(Copy.subProtect.t(lang))
                                .font(F.body())
                                .foregroundStyle(C.secondary)
                        }
                        Spacer()
                        Button(Copy.liveRefresh.t(lang)) {
                            state.refreshLive(.protect)
                        }
                        .buttonStyle(QuietButton(enabled: !state.liveBusy))
                        .disabled(state.liveBusy)
                    }
                    Text(Copy.notAntivirus.t(lang))
                        .font(F.callout())
                        .foregroundStyle(C.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(state.protectFindings) { finding in
                        ProtectRow(finding: finding)
                    }

                    if state.protectFindings.contains(where: { $0.selected && $0.kind != .advice }) {
                        Button(Copy.clean.t(lang)) {
                            state.cleanProtect()
                        }
                        .buttonStyle(PrimaryButton())
                        .disabled(state.liveBusy)
                    }
                }
                .padding(.horizontal, hPad)
                .padding(.vertical, compact ? S.lg : S.xxl)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .onAppear { state.refreshLive(.protect) }
    }
}

private struct ProtectRow: View {
    let finding: ProtectFinding
    @Environment(AppState.self) private var state
    @Environment(\.copyLang) private var lang
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: S.sm) {
            if finding.kind != .advice {
                Button {
                    state.toggleProtect(finding.id)
                } label: {
                    CamIcon(glyph: finding.selected ? .selectOn : .selectOff, size: 16)
                        .foregroundStyle(finding.selected ? C.action : C.secondary.opacity(0.4))
                }
                .buttonStyle(.plain)
            } else {
                CamIcon(glyph: .check, size: 16)
                    .foregroundStyle(C.accentText)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(finding.title.t(lang))
                    .font(F.title())
                    .foregroundStyle(C.ink)
                Text(finding.subtitle.t(lang))
                    .font(F.callout())
                    .foregroundStyle(C.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if finding.bytes > 0 {
                Text(ByteFormat.string(finding.bytes, lang))
                    .font(F.size())
                    .foregroundStyle(C.secondary)
            }
            MicroBadge(text: badge.t(lang), tone: finding.severity == .high ? .caution : .quiet)
        }
        .padding(S.md)
        .background(CardBackground(selected: finding.selected, hover: hover))
        .onHover { hover = $0 }
        .contextMenu {
            if let url = finding.url, FinderReveal.canShow(url) {
                Button(Copy.revealFinder.t(lang)) { FinderReveal.show(url) }
            }
        }
    }

    private var badge: Line {
        switch finding.severity {
        case .high: Copy.knownPUP
        case .medium: Copy.recommendBadge
        case .info: Copy.safe
        }
    }
}

struct StartupView: View {
    @Environment(AppState.self) private var state
    @Environment(\.copyLang) private var lang

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.height < 600
            let hPad = geo.size.width < 920 ? S.md : S.xxl
            ScrollView {
                VStack(alignment: .leading, spacing: compact ? S.md : S.lg) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(Copy.moduleStartup.t(lang))
                                .font(F.largeTitle(compact: compact))
                            Text(Copy.subStartup.t(lang))
                                .font(F.body())
                                .foregroundStyle(C.secondary)
                        }
                        Spacer()
                        Button(Copy.liveRefresh.t(lang)) {
                            state.refreshLive(.startup)
                        }
                        .buttonStyle(QuietButton(enabled: !state.liveBusy))
                        .disabled(state.liveBusy)
                    }
                    ForEach(state.startupRows) { row in
                        StartupRowView(row: row)
                    }
                    if state.startupRows.contains(where: { $0.selected && !$0.ours && !$0.apple }) {
                        Button(Copy.disableAgent.t(lang)) {
                            state.cleanStartup()
                        }
                        .buttonStyle(PrimaryButton())
                        .disabled(state.liveBusy)
                    }
                }
                .padding(.horizontal, hPad)
                .padding(.vertical, compact ? S.lg : S.xxl)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .onAppear { state.refreshLive(.startup) }
    }
}

private struct StartupRowView: View {
    let row: StartupRow
    @Environment(AppState.self) private var state
    @Environment(\.copyLang) private var lang
    @State private var hover = false

    var body: some View {
        HStack(spacing: S.sm) {
            if row.ours || row.apple {
                CamIcon(glyph: .lock, size: 14)
                    .foregroundStyle(C.accentText)
                    .frame(width: 16)
            } else {
                Button {
                    state.toggleStartup(row.id)
                } label: {
                    CamIcon(glyph: row.selected ? .selectOn : .selectOff, size: 16)
                        .foregroundStyle(row.selected ? C.action : C.secondary.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(F.body())
                    .foregroundStyle(C.ink)
                    .lineLimit(1)
                Text(row.detail.t(lang))
                    .font(F.callout())
                    .foregroundStyle(C.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if row.ours {
                MicroBadge(text: Copy.ourAgent.t(lang), tone: .safe)
            } else if row.apple {
                MicroBadge(text: Copy.safe.t(lang), tone: .safe)
            } else {
                MicroBadge(text: Copy.recommendBadge.t(lang), tone: .quiet)
            }
        }
        .padding(S.md)
        .background(CardBackground(selected: row.selected, hover: hover))
        .onHover { hover = $0 }
        .contextMenu {
            if FinderReveal.canShow(row.url) {
                Button(Copy.revealFinder.t(lang)) { FinderReveal.show(row.url) }
            }
        }
    }
}
