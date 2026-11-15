import SwiftUI
import AppKit
import ScreenCaptureKit

enum CapturePickerOutcome {
    case selected(filter: SCContentFilter, summary: String)
    case useSystemPicker
    case cancelled
}

@MainActor
enum CaptureTargetPicker {
    static func choose(initialMode: VideoCaptureTargetMode) async throws -> CapturePickerOutcome {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return await withCheckedContinuation { continuation in
            let coordinator = PickerCoordinator(continuation: continuation)
            let panel = KeyPanel(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.titlebarAppearsTransparent = true
            panel.titleVisibility = .hidden
            panel.isMovableByWindowBackground = true
            panel.minSize = NSSize(width: 480, height: 380)
            panel.center()
            panel.delegate = coordinator
            panel.coordinator = coordinator
            coordinator.panel = panel

            let rootView = CaptureTargetPickerView(
                content: content,
                initialMode: initialMode,
                onSelect: { filter, summary in
                    coordinator.finish(with: .selected(filter: filter, summary: summary))
                },
                onUseSystemPicker: {
                    coordinator.finish(with: .useSystemPicker)
                },
                onCancel: {
                    coordinator.finish(with: .cancelled)
                }
            )

            panel.contentView = NSHostingView(rootView: rootView)
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - AppKit Window & Coordinator

@MainActor
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    var coordinator: PickerCoordinator?
}

@MainActor
private final class PickerCoordinator: NSObject, NSWindowDelegate {
    private var continuation: CheckedContinuation<CapturePickerOutcome, Never>?
    weak var panel: KeyPanel?

    init(continuation: CheckedContinuation<CapturePickerOutcome, Never>) {
        self.continuation = continuation
    }

    func finish(with outcome: CapturePickerOutcome) {
        guard let cont = continuation else { return }
        continuation = nil
        let p = panel
        panel = nil
        p?.coordinator = nil
        p?.delegate = nil
        p?.close()
        cont.resume(returning: outcome)
    }

    func windowWillClose(_ notification: Notification) {
        if let cont = continuation {
            continuation = nil
            let p = panel
            panel = nil
            p?.coordinator = nil
            p?.delegate = nil
            cont.resume(returning: .cancelled)
        }
    }
}

// MARK: - Picker Models

private enum PickerTab: String, CaseIterable, Identifiable {
    case window = "Window"
    case application = "Application"
    case display = "Full Screen"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .window: "macwindow"
        case .application: "app.dashed"
        case .display: "display"
        }
    }
}

private struct WindowItem: Identifiable {
    let window: SCWindow
    let app: SCRunningApplication
    let title: String
    let subtitle: String
    let dimensions: String
    let icon: NSImage?
    var id: CGWindowID { window.windowID }
}

private struct AppItem: Identifiable {
    let app: SCRunningApplication
    let windows: [SCWindow]
    let icon: NSImage?
    var id: pid_t { app.processID }
}

private struct DisplayItem: Identifiable {
    let display: SCDisplay
    let name: String
    var id: CGDirectDisplayID { display.displayID }
}

// MARK: - SwiftUI Picker View

private struct CaptureTargetPickerView: View {
    let content: SCShareableContent
    let sakviroApps: [SCRunningApplication]
    let sakviroWindows: [SCWindow]

    let onSelect: (SCContentFilter, String) -> Void
    let onUseSystemPicker: () -> Void
    let onCancel: () -> Void

    @State private var selectedTab: PickerTab
    @State private var searchText: String = ""

    @State private var selectedWindowID: CGWindowID?
    @State private var selectedAppPID: pid_t?
    @State private var selectedDisplayID: CGDirectDisplayID?

    private let windowItems: [WindowItem]
    private let appItems: [AppItem]
    private let displayItems: [DisplayItem]

    init(
        content: SCShareableContent,
        initialMode: VideoCaptureTargetMode,
        onSelect: @escaping (SCContentFilter, String) -> Void,
        onUseSystemPicker: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.content = content
        self.onSelect = onSelect
        self.onUseSystemPicker = onUseSystemPicker
        self.onCancel = onCancel

        let myPID = ProcessInfo.processInfo.processIdentifier
        let myBundleID = Bundle.main.bundleIdentifier

        let sApps = content.applications.filter {
            $0.processID == myPID || (myBundleID != nil && $0.bundleIdentifier == myBundleID)
        }
        let sWins = content.windows.filter {
            $0.owningApplication?.processID == myPID || (myBundleID != nil && $0.owningApplication?.bundleIdentifier == myBundleID)
        }
        self.sakviroApps = sApps
        self.sakviroWindows = sWins

        let systemDaemons: Set<String> = [
            "Dock", "Window Server", "Control Center", "Notification Center", "SystemUIServer", "Spotlight"
        ]

        let validWindows = content.windows.filter { win in
            guard win.isOnScreen else { return false }
            guard win.frame.width >= 120, win.frame.height >= 90 else { return false }
            guard win.windowLayer == 0 else { return false }
            guard let app = win.owningApplication else { return false }
            if app.processID == myPID || (myBundleID != nil && app.bundleIdentifier == myBundleID) {
                return false
            }
            guard !app.applicationName.isEmpty else { return false }
            if systemDaemons.contains(app.applicationName) { return false }
            return true
        }

        self.windowItems = validWindows.map { win in
            let app = win.owningApplication!
            let rawTitle = win.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let displayTitle = rawTitle.isEmpty ? app.applicationName : rawTitle
            let icon = NSRunningApplication(processIdentifier: app.processID)?.icon
            let dims = "\(Int(win.frame.width))×\(Int(win.frame.height))"
            return WindowItem(
                window: win,
                app: app,
                title: displayTitle,
                subtitle: app.applicationName,
                dimensions: dims,
                icon: icon
            )
        }

        var appsMap: [pid_t: (SCRunningApplication, [SCWindow])] = [:]
        for win in validWindows {
            guard let app = win.owningApplication else { continue }
            if var entry = appsMap[app.processID] {
                entry.1.append(win)
                appsMap[app.processID] = entry
            } else {
                appsMap[app.processID] = (app, [win])
            }
        }

        let priorityKeywords = ["zoom", "teams", "chrome", "safari", "arc", "slack", "discord"]
        func priority(for app: SCRunningApplication) -> Int {
            let lowerName = app.applicationName.lowercased()
            let lowerBundle = app.bundleIdentifier.lowercased()
            for (idx, kw) in priorityKeywords.enumerated() {
                if lowerName.contains(kw) || lowerBundle.contains(kw) { return idx }
            }
            return 1000
        }

        var appsList = appsMap.values.map { entry in
            AppItem(
                app: entry.0,
                windows: entry.1,
                icon: NSRunningApplication(processIdentifier: entry.0.processID)?.icon
            )
        }
        appsList.sort { a, b in
            let pa = priority(for: a.app)
            let pb = priority(for: b.app)
            if pa != pb { return pa < pb }
            return a.app.applicationName.localizedStandardCompare(b.app.applicationName) == .orderedAscending
        }
        self.appItems = appsList

        self.displayItems = content.displays.enumerated().map { idx, display in
            var displayName = "Display \(idx + 1)"
            for screen in NSScreen.screens {
                let num = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                    ?? (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
                if num == display.displayID {
                    displayName = screen.localizedName
                    break
                }
            }
            return DisplayItem(display: display, name: displayName)
        }

        let initialTab: PickerTab
        switch initialMode {
        case .window, .any:
            initialTab = .window
        case .application:
            initialTab = .application
        case .display:
            initialTab = .display
        }
        _selectedTab = State(initialValue: initialTab)
        _selectedWindowID = State(initialValue: self.windowItems.first?.id)
        _selectedAppPID = State(initialValue: self.appItems.first?.id)
        _selectedDisplayID = State(initialValue: self.displayItems.first?.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider().overlay(Theme.Colors.line)
            searchBar
            Divider().overlay(Theme.Colors.line)
            contentView
            Divider().overlay(Theme.Colors.line)
            footerView
        }
        .frame(width: 560, height: 460)
        .background(Theme.Colors.canvas)
    }

    private var headerView: some View {
        HStack {
            Text("Select Recording Target")
                .font(Theme.Typography.body.weight(.semibold))
                .foregroundStyle(Theme.Colors.ink)

            Spacer()

            Picker("", selection: $selectedTab) {
                ForEach(PickerTab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.icon).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 280)
        }
        .padding(.horizontal, Theme.Metrics.pad)
        .padding(.vertical, 12)
        .background(Theme.Colors.panel)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.Colors.ink3)
                .font(Theme.Typography.secondary)

            TextField("Filter by name or title...", text: $searchText)
                .textFieldStyle(.plain)
                .font(Theme.Typography.body)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.Colors.ink3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.Metrics.pad)
        .padding(.vertical, 8)
        .background(Theme.Colors.canvas)
    }

    @ViewBuilder
    private var contentView: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                switch selectedTab {
                case .window:
                    let items = filteredWindows
                    if items.isEmpty {
                        emptyState(text: "No windows found")
                    } else {
                        ForEach(items) { item in
                            windowRow(item)
                        }
                    }
                case .application:
                    let items = filteredApps
                    if items.isEmpty {
                        emptyState(text: "No applications found")
                    } else {
                        ForEach(items) { item in
                            appRow(item)
                        }
                    }
                case .display:
                    let items = filteredDisplays
                    if items.isEmpty {
                        emptyState(text: "No displays found")
                    } else {
                        ForEach(items) { item in
                            displayRow(item)
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    private var filteredWindows: [WindowItem] {
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return windowItems
        }
        let query = searchText.lowercased()
        return windowItems.filter {
            $0.title.lowercased().contains(query) ||
            $0.subtitle.lowercased().contains(query) ||
            $0.app.bundleIdentifier.lowercased().contains(query)
        }
    }

    private var filteredApps: [AppItem] {
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return appItems
        }
        let query = searchText.lowercased()
        return appItems.filter {
            $0.app.applicationName.lowercased().contains(query) ||
            $0.app.bundleIdentifier.lowercased().contains(query)
        }
    }

    private var filteredDisplays: [DisplayItem] {
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return displayItems
        }
        let query = searchText.lowercased()
        return displayItems.filter {
            $0.name.lowercased().contains(query)
        }
    }

    private func emptyState(text: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Text(text)
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Colors.ink3)
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private func windowRow(_ item: WindowItem) -> some View {
        let isSelected = selectedWindowID == item.id
        return Button {
            selectedWindowID = item.id
        } label: {
            HStack(spacing: 12) {
                if let icon = item.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 32, height: 32)
                } else {
                    Image(systemName: "macwindow")
                        .font(.system(size: 24))
                        .frame(width: 32, height: 32)
                        .foregroundStyle(Theme.Colors.ink3)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(Theme.Typography.rowTitle.weight(.medium))
                        .foregroundStyle(Theme.Colors.ink)
                        .lineLimit(1)
                    Text(item.subtitle)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.ink2)
                        .lineLimit(1)
                }

                Spacer()

                Text(item.dimensions)
                    .font(Theme.Typography.receipt)
                    .foregroundStyle(Theme.Colors.ink3)
                    .padding(.horizontal, Theme.Metrics.chipInsetH)
                    .padding(.vertical, Theme.Metrics.chipInsetV)
                    .background(Theme.Colors.chip)
                    .cornerRadius(Theme.Metrics.chipRadius)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? Theme.Colors.selection : Color.clear)
            .cornerRadius(Theme.Metrics.radius)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            selectedWindowID = item.id
            confirmSelection()
        })
    }

    private func appRow(_ item: AppItem) -> some View {
        let isSelected = selectedAppPID == item.id
        let count = item.windows.count
        let countStr = "\(count) \(count == 1 ? "window" : "windows")"
        return Button {
            selectedAppPID = item.id
        } label: {
            HStack(spacing: 12) {
                if let icon = item.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 32, height: 32)
                } else {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 24))
                        .frame(width: 32, height: 32)
                        .foregroundStyle(Theme.Colors.ink3)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.app.applicationName)
                        .font(Theme.Typography.rowTitle.weight(.medium))
                        .foregroundStyle(Theme.Colors.ink)
                        .lineLimit(1)
                    Text(item.app.bundleIdentifier)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.ink2)
                        .lineLimit(1)
                }

                Spacer()

                Text(countStr)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.ink3)
                    .padding(.horizontal, Theme.Metrics.chipInsetH)
                    .padding(.vertical, Theme.Metrics.chipInsetV)
                    .background(Theme.Colors.chip)
                    .cornerRadius(Theme.Metrics.chipRadius)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? Theme.Colors.selection : Color.clear)
            .cornerRadius(Theme.Metrics.radius)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            selectedAppPID = item.id
            confirmSelection()
        })
    }

    private func displayRow(_ item: DisplayItem) -> some View {
        let isSelected = selectedDisplayID == item.id
        return Button {
            selectedDisplayID = item.id
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "display")
                    .font(.system(size: 24))
                    .frame(width: 32, height: 32)
                    .foregroundStyle(Theme.Colors.ink2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(Theme.Typography.rowTitle.weight(.medium))
                        .foregroundStyle(Theme.Colors.ink)
                        .lineLimit(1)
                    Text("\(item.display.width) × \(item.display.height)")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.ink2)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? Theme.Colors.selection : Color.clear)
            .cornerRadius(Theme.Metrics.radius)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            selectedDisplayID = item.id
            confirmSelection()
        })
    }

    private var footerView: some View {
        HStack {
            Button("System Picker…") {
                onUseSystemPicker()
            }
            .buttonStyle(.plain)
            .font(Theme.Typography.secondary)
            .foregroundStyle(Theme.Colors.ink2)

            Spacer()

            Button("Cancel") {
                onCancel()
            }
            .keyboardShortcut(.cancelAction)

            Button("Record Selected") {
                confirmSelection()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canConfirm)
        }
        .padding(.horizontal, Theme.Metrics.pad)
        .padding(.vertical, 12)
        .background(Theme.Colors.panel)
    }

    private var canConfirm: Bool {
        switch selectedTab {
        case .window:
            return selectedWindowID != nil && windowItems.contains(where: { $0.id == selectedWindowID })
        case .application:
            return selectedAppPID != nil && appItems.contains(where: { $0.id == selectedAppPID })
        case .display:
            return selectedDisplayID != nil && displayItems.contains(where: { $0.id == selectedDisplayID })
        }
    }

    private func confirmSelection() {
        switch selectedTab {
        case .window:
            guard let id = selectedWindowID, let item = windowItems.first(where: { $0.id == id }) else { return }
            let filter = SCContentFilter(desktopIndependentWindow: item.window)
            let rawTitle = item.window.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let titleSuffix = (!rawTitle.isEmpty && rawTitle != item.app.applicationName) ? " — \(rawTitle)" : ""
            let summary = "Window · \(item.app.applicationName)\(titleSuffix)"
            onSelect(filter, summary)

        case .application:
            guard let pid = selectedAppPID, let item = appItems.first(where: { $0.id == pid }) else { return }
            let largestWin = item.windows.max(by: { ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height) })
            let targetDisplay = largestWin.flatMap { win in
                content.displays.first { $0.frame.intersects(win.frame) }
            } ?? content.displays.first
            guard let display = targetDisplay else { return }
            let filter = SCContentFilter(display: display, including: [item.app], exceptingWindows: sakviroWindows)
            let summary = "App · \(item.app.applicationName)"
            onSelect(filter, summary)

        case .display:
            guard let id = selectedDisplayID, let item = displayItems.first(where: { $0.id == id }) else { return }
            let filter = SCContentFilter(display: item.display, excludingApplications: sakviroApps, exceptingWindows: sakviroWindows)
            let summary = "Screen · \(item.name) (\(item.display.width)×\(item.display.height))"
            onSelect(filter, summary)
        }
    }
}

// MARK: - VideoCaptureService UI & Detection Extensions

extension VideoCaptureService {
    @MainActor
    func chooseSource(windowOnly: Bool = false) async throws -> SCContentFilter? {
        try await chooseSource(mode: .current)
    }

    @MainActor
    func chooseSource(mode: VideoCaptureTargetMode) async throws -> SCContentFilter? {
        do {
            let outcome = try await CaptureTargetPicker.choose(initialMode: mode)
            switch outcome {
            case .selected(let filter, let summary):
                await applySelectedTarget(summary: summary)
                return filter
            case .cancelled:
                return nil
            case .useSystemPicker:
                return try await chooseWithSystemPicker(mode: mode)
            }
        } catch {
            return try await chooseWithSystemPicker(mode: mode)
        }
    }

    @MainActor
    func presentChangeTargetPicker() {
        Task { @MainActor in
            do {
                let outcome = try await CaptureTargetPicker.choose(initialMode: .current)
                switch outcome {
                case .selected(let filter, let summary):
                    await applySelectedTarget(summary: summary, updateStreamWith: filter)
                case .cancelled:
                    break
                case .useSystemPicker:
                    presentSystemTargetPicker(mode: .current)
                }
            } catch {
                presentSystemTargetPicker(mode: .current)
            }
        }
    }

    @MainActor
    func selectTargetForDetectedCall(appID: String?, mode: VideoCaptureTargetMode = .current) async -> SCContentFilter? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            return nil
        }

        let myPID = ProcessInfo.processInfo.processIdentifier
        let myBundleID = Bundle.main.bundleIdentifier
        let sakviroApps = content.applications.filter {
            $0.processID == myPID || (myBundleID != nil && $0.bundleIdentifier == myBundleID)
        }
        let sakviroWindows = content.windows.filter {
            $0.owningApplication?.processID == myPID || (myBundleID != nil && $0.owningApplication?.bundleIdentifier == myBundleID)
        }

        if mode == .display {
            guard let display = content.displays.first else { return nil }
            let filter = SCContentFilter(display: display, excludingApplications: sakviroApps, exceptingWindows: sakviroWindows)
            let summary = "Screen · \(display.width)×\(display.height)"
            await applySelectedTarget(summary: summary)
            return filter
        }

        if let appID, !appID.isEmpty {
            let matchingApp = content.applications.first {
                $0.bundleIdentifier == appID || $0.bundleIdentifier.hasPrefix(appID)
            }

            if CallDetector.isBrowserApp(appID) || mode == .window {
                let candidateWindows = content.windows.filter { win in
                    guard win.isOnScreen, win.windowLayer == 0 else { return false }
                    guard let owning = win.owningApplication else { return false }
                    return owning.bundleIdentifier == appID || owning.bundleIdentifier.hasPrefix(appID) || (matchingApp != nil && owning.processID == matchingApp?.processID)
                }

                if let win = candidateWindows.first(where: { BrowserCallInspector.isMeetingWindowTitle($0.title ?? "") })
                    ?? candidateWindows.max(by: { ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height) }) {
                    let filter = SCContentFilter(desktopIndependentWindow: win)
                    let appName = win.owningApplication?.applicationName ?? matchingApp?.applicationName ?? appID
                    let summary = "Window · \(appName)"
                    await applySelectedTarget(summary: summary)
                    return filter
                }
            }

            if let app = matchingApp, let display = content.displays.first {
                let filter = SCContentFilter(display: display, including: [app], exceptingWindows: sakviroWindows)
                let summary = "App · \(app.applicationName)"
                await applySelectedTarget(summary: summary)
                return filter
            }
        }

        return nil
    }
}
