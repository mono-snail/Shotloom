import AppKit
import ApplicationServices

struct ScrollContainerCandidate: Identifiable, Equatable, Sendable {
    let id: String
    let frame: CGRect // WindowServer / accessibility top-left coordinates.
    let depth: Int
    var title: String { L10n.text("滚动区域 \(Int(frame.width)) × \(Int(frame.height))") }
}

struct ScrollContainerScan: Sendable {
    let candidates: [ScrollContainerCandidate]
    let supported: Bool
}

enum ScrollDeliveryPoints {
    // Keep the center/quarter preference, then try distributed corners. A HUD
    // can cover four central probes while the cursor covers the fifth one.
    // Every added point still needs the same input-owner and geometry checks.
    static let fractions = [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.75, y: 0.5), CGPoint(x: 0.25, y: 0.5),
                            CGPoint(x: 0.5, y: 0.75), CGPoint(x: 0.5, y: 0.25),
                            CGPoint(x: 0.9, y: 0.1), CGPoint(x: 0.9, y: 0.9),
                            CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.1, y: 0.9)]
}

enum ScrollContainerDetector {
    static func matchesWindow(owner: pid_t, pid: pid_t, frame: CGRect, expected: CGRect) -> Bool {
        owner == pid && abs(frame.minX - expected.minX) <= 1 && abs(frame.minY - expected.minY) <= 1
        && abs(frame.width - expected.width) <= 1 && abs(frame.height - expected.height) <= 1
    }
    // Rectangle inventory cannot distinguish transparent WindowServer surfaces
    // from input obstructions. Resolve the actual accessibility window at the
    // point, without sending events or reading user content.
    static func globalTargetPoint(area: CGRect, avoiding: [CGRect], pid: pid_t, windowID: CGWindowID, windowFrame: CGRect,
                                  displayPixelsVerified: Bool = false) -> CGPoint? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.12)
        let deadline = ProcessInfo.processInfo.systemUptime + 1.2
        for fraction in ScrollDeliveryPoints.fractions {
            if Task.isCancelled || ProcessInfo.processInfo.systemUptime > deadline { return nil }
            let point = CGPoint(x: area.minX + area.width * fraction.x, y: area.minY + area.height * fraction.y)
            if avoiding.contains(where: { $0.contains(point) }) { continue }
            var element: AXUIElement?
            guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element) == .success,
                  let element else { continue }
            AXUIElementSetMessagingTimeout(element, 0.12)
            var owner: pid_t = 0
            guard AXUIElementGetPid(element, &owner) == .success, owner == pid,
                  let raw = value(element, kAXWindowAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { continue }
            let window = raw as! AXUIElement
            AXUIElementSetMessagingTimeout(window, 0.12)
            guard let bounds = frame(window), matchesWindow(owner: owner, pid: pid, frame: bounds, expected: windowFrame) else { continue }
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            // A global AX hit can omit the client's own windows. Keep ordinary
            // window geometry authoritative, even after the AX confirmation.
            // The screenshot service can retain an invisible full-screen
            // surface. Require a fresh full-region pixel comparison as well
            // as this exact global AX hit before adjudicating that surface.
            // Ordinary app/HUD windows remain authoritative obstructions.
            let first = windows.first { item in
                guard (item[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                      let rawBounds = item[kCGWindowBounds as String] as? NSDictionary,
                      let rectangle = CGRect(dictionaryRepresentation: rawBounds as CFDictionary), rectangle.contains(point) else { return false }
                if let owner = item[kCGWindowOwnerPID as String] as? Int32,
                   mayAdjudicateSystemSurface(bundlePath: NSRunningApplication(processIdentifier: owner)?.bundleURL?.path,
                                              layer: item[kCGWindowLayer as String] as? Int,
                                              displayPixelsVerified: displayPixelsVerified) { return false }
                return true
            }
            guard first?[kCGWindowNumber as String] as? UInt32 == windowID else { continue }
            return point
        }
        return nil
    }
    static func mayAdjudicateSystemSurface(bundlePath: String?, layer: Int?, displayPixelsVerified: Bool) -> Bool {
        if bundlePath == "/System/Library/CoreServices/Dock.app" { return true }
        return displayPixelsVerified && layer == 24 && bundlePath == "/System/Library/CoreServices/screencaptureui.app"
    }
    static func candidate(frame: CGRect, selection: CGRect, depth: Int) -> ScrollContainerCandidate? {
        guard [frame.minX, frame.minY, frame.width, frame.height].allSatisfy({ $0.isFinite && abs($0) < 1_000_000 }),
              frame.width > 0, frame.height > 0 else { return nil }
        let intersection = frame.intersection(selection)
        guard !intersection.isNull, intersection.width >= 20, intersection.height >= 20,
              frame.width.isFinite, frame.height.isFinite else { return nil }
        let id = [frame.minX, frame.minY, frame.width, frame.height].map { String(Int($0.rounded())) }.joined(separator: ":")
        return ScrollContainerCandidate(id: id, frame: frame, depth: depth)
    }
    static func preferred(_ candidates: [ScrollContainerCandidate], selection: CGRect) -> ScrollContainerCandidate? {
        let center = CGPoint(x: selection.midX, y: selection.midY)
        return candidates.filter { $0.frame.contains(center) }.min {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        }
    }
    static func pointRect(_ candidate: ScrollContainerCandidate, selection: CGRect) -> CGRect? {
        let intersection = candidate.frame.intersection(selection).insetBy(dx: 4, dy: 4)
        return !intersection.isNull && intersection.width > 12 && intersection.height > 12 ? intersection : nil
    }
    // Called only on a background task. No text, values, document contents or
    // accessibility actions are read. Bound both IPC duration and hierarchy depth.
    static func scan(pid: pid_t, selection: CGRect) -> ScrollContainerScan {
        guard AXIsProcessTrusted() else { return ScrollContainerScan(candidates: [], supported: false) }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.12)
        let deadline = ProcessInfo.processInfo.systemUptime + 1.5
        var candidates: [ScrollContainerCandidate] = [], supported = false
        for fraction in [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.25, y: 0.5), CGPoint(x: 0.75, y: 0.5), CGPoint(x: 0.5, y: 0.25), CGPoint(x: 0.5, y: 0.75)] {
            if ProcessInfo.processInfo.systemUptime > deadline { break }
            let point = CGPoint(x: selection.minX + fraction.x * selection.width, y: selection.minY + fraction.y * selection.height)
            var element: AXUIElement?
            guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &element) == .success else { continue }
            supported = true
            for depth in 0..<12 {
                guard let current = element, ProcessInfo.processInfo.systemUptime <= deadline else { break }
                AXUIElementSetMessagingTimeout(current, 0.12)
                var owner: pid_t = 0
                guard AXUIElementGetPid(current, &owner) == .success, owner == pid else { break }
                if value(current, kAXRoleAttribute) as? String == kAXScrollAreaRole,
                   let frame = frame(current), let found = candidate(frame: frame, selection: selection, depth: depth),
                   !candidates.contains(where: { $0.id == found.id }) { candidates.append(found) }
                guard let parent = value(current, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
                element = (parent as! AXUIElement)
            }
        }
        return ScrollContainerScan(candidates: candidates.sorted { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }, supported: supported)
    }
    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
    }
    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let rawPoint = value(element, kAXPositionAttribute), CFGetTypeID(rawPoint) == AXValueGetTypeID(),
              let rawSize = value(element, kAXSizeAttribute), CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(rawPoint as! AXValue, .cgPoint, &point), AXValueGetValue(rawSize as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
}

import SwiftUI

struct ScrollContainerPicker: View {
    @ObservedObject var scroll: ScrollCapture
    @Environment(\.dismiss) private var dismiss
    @State private var x = 0.5
    @State private var y = 0.5
    @State private var candidateID: String?
    @State private var usesPoint = false
    @State private var resumeOnDismiss = false
    private var busy: Bool { scroll.finishing || scroll.choosingFile || scroll.processingSegment || scroll.scanningContainers }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.text("选择滚动正文")).font(.headline)
                Spacer()
                Button(scroll.scanningContainers ? L10n.text("识别中…") : L10n.text("刷新")) {
                    Task {
                        await scroll.refreshContainers()
                        if !usesPoint { candidateID = scroll.selectedContainerID }
                    }
                }.disabled(busy)
            }
            targetPreview
            if scroll.containers.isEmpty {
                Label(L10n.text("未识别到滚动区域"), systemImage: "viewfinder").font(.system(size: 12)).foregroundStyle(Palette.muted)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(scroll.containers.enumerated()), id: \.element.id) { index, item in
                            Button { candidateID = item.id; usesPoint = false } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: !usesPoint && item.id == candidateID ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(!usesPoint && item.id == candidateID ? Palette.ice : Palette.muted)
                                    Text(L10n.text("区域 \(index + 1)"))
                                    Spacer()
                                    Text("\(Int(item.frame.width)) × \(Int(item.frame.height))").monospacedDigit().foregroundStyle(Palette.muted)
                                }.font(.system(size: 12)).padding(8).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .background(!usesPoint && item.id == candidateID ? Palette.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
                        }
                    }
                }.frame(maxHeight: 128)
            }
            InspectorGroup(L10n.text("精确位置")) {
                InspectorSlider(title: L10n.text("横向"), value: $x, range: 0.05...0.95, scale: 100, unit: "%")
                    .onChange(of: x) { _, _ in usesPoint = true; candidateID = nil }
                InspectorSlider(title: L10n.text("纵向"), value: $y, range: 0.05...0.95, scale: 100, unit: "%")
                    .onChange(of: y) { _, _ in usesPoint = true; candidateID = nil }
            }
            Divider()
            HStack(spacing: 8) {
                Button(L10n.text("手动滚动")) { resumeOnDismiss = false; scroll.continueManually(); dismiss() }
                Spacer(minLength: 0)
                Button(L10n.text("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text("采用并继续")) { apply() }.buttonStyle(StudioButtonStyle(primary: true, command: true))
                    .disabled(!usesPoint && !scroll.containers.contains(where: { $0.id == candidateID }))
                    .keyboardShortcut(.defaultAction)
            }.controlSize(.small)
        }.padding(20).frame(width: 360).foregroundStyle(Palette.white).background(Palette.paper)
            .disabled(busy)
            .onAppear {
                candidateID = scroll.selectedContainerID
                if let point = scroll.manualScrollPoint {
                    let selection = scroll.containerSelection
                    x = min(0.95, max(0.05, (point.x - selection.minX) / max(1, selection.width)))
                    y = min(0.95, max(0.05, (point.y - selection.minY) / max(1, selection.height)))
                    usesPoint = true
                }
                resumeOnDismiss = !scroll.paused
                if resumeOnDismiss { scroll.togglePause() }
            }
            .onDisappear {
                if resumeOnDismiss && scroll.active && scroll.paused { scroll.togglePause() }
            }
    }
    private var targetPreview: some View {
        GeometryReader { geometry in
            let selection = scroll.containerSelection
            let fit = ImageCleanupView.fittedSize(selection.size, in: geometry.size)
            ZStack(alignment: .topLeading) {
                Palette.canvas
                if let image = scroll.targetThumbnail {
                    Image(decorative: image, scale: 1).resizable().frame(width: fit.width, height: fit.height)
                }
                ForEach(Array(scroll.containers.enumerated()), id: \.element.id) { index, item in
                    let area = item.frame.intersection(selection)
                    if !area.isNull {
                        let rect = CGRect(x: (area.minX - selection.minX) / max(1, selection.width) * fit.width,
                                          y: (area.minY - selection.minY) / max(1, selection.height) * fit.height,
                                          width: area.width / max(1, selection.width) * fit.width,
                                          height: area.height / max(1, selection.height) * fit.height)
                        Rectangle().fill(!usesPoint && candidateID == item.id ? Palette.ice.opacity(0.12) : .clear)
                            .overlay(Rectangle().strokeBorder(!usesPoint && candidateID == item.id ? Palette.ice : .orange, lineWidth: 2))
                            .overlay(alignment: .topLeading) {
                                Text("\(index + 1)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.onAccent)
                                    .padding(3).background(Palette.ice, in: RoundedRectangle(cornerRadius: 3))
                            }
                            .frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
                    }
                }
                if usesPoint {
                    Image(systemName: "scope").font(.system(size: 20, weight: .semibold)).foregroundStyle(.orange)
                        .background(.black.opacity(0.5), in: Circle()).frame(width: 24, height: 24)
                        .offset(x: x * fit.width - 12, y: y * fit.height - 12)
                }
            }.frame(width: fit.width, height: fit.height).clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
                .onTapGesture { point in
                    guard fit.width > 0, fit.height > 0 else { return }
                    x = min(0.95, max(0.05, point.x / fit.width)); y = min(0.95, max(0.05, point.y / fit.height))
                    usesPoint = true; candidateID = nil
                }
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                .help(L10n.text("点击实际画面指定滚动位置，或选择带编号的正文区域"))
                .accessibilityLabel(L10n.text("滚动正文预览；可使用下方区域列表或精确位置选择"))
        }.frame(height: 190)
    }
    private func apply() {
        guard !busy else { return }
        resumeOnDismiss = false
        if usesPoint { scroll.setManualScrollPoint(x: x, y: y) }
        else if let candidateID { scroll.selectContainer(candidateID) }
        else { return }
        _ = scroll.setAutomatic(true)
        dismiss()
    }
}

struct ScrollPositionEvidence: Equatable, Sendable {
    let minimum: Double
    let maximum: Double
    let value: Double
    let container: CGRect
    var valid: Bool {
        [minimum, maximum, value, maximum - minimum].allSatisfy(\.isFinite) && maximum > minimum
            && value >= minimum && value <= maximum
            && [container.minX, container.minY, container.width, container.height].allSatisfy(\.isFinite)
            && container.width > 0 && container.height > 0
    }
    func atBoundary(direction: ScrollDirection) -> Bool {
        guard valid else { return false }
        let tolerance = max((maximum - minimum) * 0.000001, 0.000000001)
        return direction == .forward ? maximum - value <= tolerance : value - minimum <= tolerance
    }
}

extension ScrollContainerDetector {
    /// Read only the numeric scrollbar position of the exact target under the last
    /// delivered wheel. Missing AX support is unknown, never proof of completion.
    /// No scroll action or document text is read. Call off the main thread.
    static func position(pid: pid_t, point: CGPoint, windowFrame: CGRect, selectedFrame: CGRect?,
                         axis: ScrollAxis) -> ScrollPositionEvidence? {
        guard AXIsProcessTrusted(), !Task.isCancelled else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)
        let deadline = ProcessInfo.processInfo.systemUptime + 1.2
        var current: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &current) == .success,
              let first = current else { return nil }
        AXUIElementSetMessagingTimeout(first, 0.1)
        var owner: pid_t = 0
        guard AXUIElementGetPid(first, &owner) == .success, owner == pid,
              let rawWindow = value(first, kAXWindowAttribute), CFGetTypeID(rawWindow) == AXUIElementGetTypeID() else { return nil }
        let window = rawWindow as! AXUIElement
        AXUIElementSetMessagingTimeout(window, 0.1)
        guard let bounds = frame(window), matchesWindow(owner: owner, pid: pid, frame: bounds, expected: windowFrame) else { return nil }
        for _ in 0..<12 {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline, let element = current else { return nil }
            AXUIElementSetMessagingTimeout(element, 0.1)
            guard AXUIElementGetPid(element, &owner) == .success, owner == pid else { return nil }
            if value(element, kAXRoleAttribute) as? String == kAXScrollAreaRole, let bounds = frame(element) {
                // An inner scroll container can consume the wheel even if its
                // enclosing page is at its end. Never use an ancestor's bar to
                // declare the selected child complete, or skip an unreadable child.
                if let selectedFrame, !sameRectangle(bounds, selectedFrame) { return nil }
                let attribute = axis == .vertical ? kAXVerticalScrollBarAttribute : kAXHorizontalScrollBarAttribute
                guard let raw = value(element, attribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
                let bar = raw as! AXUIElement
                AXUIElementSetMessagingTimeout(bar, 0.1)
                guard AXUIElementGetPid(bar, &owner) == .success, owner == pid,
                      value(bar, kAXRoleAttribute) as? String == kAXScrollBarRole,
                      let rawMin = value(bar, kAXMinValueAttribute), CFGetTypeID(rawMin) == CFNumberGetTypeID(),
                      let rawMax = value(bar, kAXMaxValueAttribute), CFGetTypeID(rawMax) == CFNumberGetTypeID(),
                      let rawPosition = value(bar, kAXValueAttribute), CFGetTypeID(rawPosition) == CFNumberGetTypeID(),
                      let min = rawMin as? NSNumber, let max = rawMax as? NSNumber,
                      let position = rawPosition as? NSNumber else { return nil }
                let evidence = ScrollPositionEvidence(minimum: min.doubleValue, maximum: max.doubleValue,
                                                      value: position.doubleValue, container: bounds)
                return evidence.valid ? evidence : nil
            }
            guard let parent = value(element, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            current = (parent as! AXUIElement)
        }
        return nil
    }
    private static func sameRectangle(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1 && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
    }
}
