import AppKit
import Combine

enum CaptureMode: String, CaseIterable, Identifiable {
    case region, window, fullscreen, allScreens, text, scrolling, recording, scrollingWindow
    var id: String { rawValue }
    func isAvailable(screenCount: Int) -> Bool { self != .allScreens || screenCount > 1 }
    var title: String {
        switch self { case .region: return L10n.text("区域截图"); case .window: return L10n.text("窗口截图"); case .fullscreen: return L10n.text("当前屏幕截图"); case .allScreens: return L10n.text("所有屏幕截图"); case .text: return L10n.text("提取文字"); case .scrolling: return L10n.text("区域滚动长图"); case .recording: return L10n.text("区域录屏"); case .scrollingWindow: return L10n.text("窗口滚动长图") }
    }
    var symbol: String {
        switch self { case .region: return "viewfinder"; case .window: return "macwindow"; case .fullscreen: return "display"; case .allScreens: return "display.2"; case .text: return "text.viewfinder"; case .scrolling: return "arrow.down.to.line.compact"; case .recording: return "record.circle"; case .scrollingWindow: return "macwindow" }
    }
    var detail: String {
        switch self { case .region: return L10n.text("框选，精准捕获"); case .window: return L10n.text("保留窗口，去掉干扰"); case .fullscreen: return L10n.text("仅捕获鼠标所在的屏幕"); case .allScreens: return L10n.text("按显示器排列合成一张图片"); case .text: return L10n.text("框选文字，离线识别"); case .scrolling: return L10n.text("框选正文，自动或手动滚动拼接"); case .recording: return L10n.text("系统声音与麦克风"); case .scrollingWindow: return L10n.text("点击选窗口，自动发送滚动命令并拼接") }
    }
}

struct CaptureRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let filename: String
    let width: Int
    let height: Int
    let mode: CaptureMode.RawValue
    var backingScale: CGFloat? = nil
    var recognizedText: String?
    var projectFilename: String? = nil
    var title: String { CaptureMode(rawValue: mode)?.title ?? L10n.text("截图") }
}

struct LastCaptureSelection: Codable {
    let displayID: UInt32
    let screenSize: CGSize
    let rect: CGRect
    var identity: String? = nil
    var backingScale: CGFloat? = nil
    func selection(for screen: NSScreen) -> CGRect? {
        guard screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 == displayID,
              screen.frame.size == screenSize, identity.map({ $0 == CaptureDisplayGeometry.identifier(displayID) }) != false,
              backingScale.map({ $0 == screen.backingScaleFactor }) != false else { return nil }
        let bounded = rect.intersection(CGRect(origin: .zero, size: screenSize))
        return bounded.width >= 3 && bounded.height >= 3 ? bounded : nil
    }
}

enum CaptureAspectRatio: String, CaseIterable, Identifiable {
    case free, square, landscape, portrait, classic, classicPortrait, photo, photoPortrait
    var id: String { rawValue }
    var title: String {
        switch self {
        case .free: return L10n.text("自由尺寸")
        case .square: return L10n.text("1:1 正方形")
        case .landscape: return L10n.text("16:9 横屏")
        case .portrait: return L10n.text("9:16 竖屏")
        case .classic: return "4:3"
        case .classicPortrait: return "3:4"
        case .photo: return "3:2"
        case .photoPortrait: return "2:3"
        }
    }
    var units: CGSize? {
        switch self {
        case .free: return nil
        case .square: return CGSize(width: 1, height: 1)
        case .landscape: return CGSize(width: 16, height: 9)
        case .portrait: return CGSize(width: 9, height: 16)
        case .classic: return CGSize(width: 4, height: 3)
        case .classicPortrait: return CGSize(width: 3, height: 4)
        case .photo: return CGSize(width: 3, height: 2)
        case .photoPortrait: return CGSize(width: 2, height: 3)
        }
    }
    // Whole multiples keep the exported pixel dimensions at the exact chosen ratio.
    func pixelSize(width: CGFloat, height: CGFloat, maximum: CGSize, drivenByWidth: Bool = true) -> CGSize {
        guard let units else { return CGSize(width: min(width, maximum.width), height: min(height, maximum.height)) }
        let requested = drivenByWidth ? width / units.width : height / units.height
        let limit = floor(min(maximum.width / units.width, maximum.height / units.height))
        let multiple = min(limit, max(ceil(3 / min(units.width, units.height)), requested.rounded()))
        return CGSize(width: units.width * multiple, height: units.height * multiple)
    }
}

enum CaptureGeometry {
    static func rect(from start: CGPoint, to end: CGPoint, in bounds: CGRect) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y)).intersection(bounds)
    }
    static func rect(from start: CGPoint, to end: CGPoint, in bounds: CGRect,
                     aspectRatio: CaptureAspectRatio, pixelScale: CGSize) -> CGRect {
        guard let units = aspectRatio.units else { return rect(from: start, to: end, in: bounds) }
        let anchor = CGPoint(x: min(bounds.maxX, max(bounds.minX, start.x)),
                             y: min(bounds.maxY, max(bounds.minY, start.y)))
        let right = end.x >= anchor.x, up = end.y >= anchor.y
        let available = CGSize(width: (right ? bounds.maxX - anchor.x : anchor.x - bounds.minX) * pixelScale.width,
                               height: (up ? bounds.maxY - anchor.y : anchor.y - bounds.minY) * pixelScale.height)
        let requested = max(abs(end.x - anchor.x) * pixelScale.width / units.width,
                            abs(end.y - anchor.y) * pixelScale.height / units.height)
        let multiple = max(0, min(requested.rounded(), floor(min(available.width / units.width, available.height / units.height))))
        let width = units.width * multiple / pixelScale.width, height = units.height * multiple / pixelScale.height
        return CGRect(x: right ? anchor.x : anchor.x - width, y: up ? anchor.y : anchor.y - height,
                      width: width, height: height)
    }
    // NSView bottom-left coordinates → CGImage top-left pixel coordinates.
    static func pixelRect(_ selection: CGRect, viewSize: CGSize, imageSize: CGSize) -> CGRect {
        let sx = imageSize.width / viewSize.width
        let sy = imageSize.height / viewSize.height
        let left = (selection.minX * sx).rounded(), right = (selection.maxX * sx).rounded()
        let top = ((viewSize.height - selection.maxY) * sy).rounded()
        let bottom = ((viewSize.height - selection.minY) * sy).rounded()
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
            .intersection(CGRect(origin: .zero, size: imageSize))
    }
}

final class CaptureStore: ObservableObject {
    @Published private(set) var records: [CaptureRecord] = [] { didSet { contentRevision = UUID() } }
    @Published private(set) var contentRevision = UUID()
    @Published private(set) var retentionDays: Int
    private let preferences: UserDefaults
    let directory: URL
    private var index: URL { directory.appendingPathComponent("history.json") }
    private let thumbnails = NSCache<NSString, NSImage>()
    private var damagedIndex: Data?
    private let writeGate = HistoryWriteGate()
    @Published private(set) var writeInProgress = false
    @Published private(set) var transactionError: String?
    @Published private(set) var transactionWarning: String?
    private var needsRecovery = false
    @Published private(set) var isLoading = false
    private var initialLoadPending = false

    init(directory: URL? = nil, pruneOnInit: Bool = true, preferences: UserDefaults = AppPreferences.standard, deferLoading: Bool = false, automaticRecovery: Bool = true) {
        self.preferences = preferences; retentionDays = preferences.integer(forKey: "historyRetentionDays")
        let diagnostic = ProcessInfo.processInfo.environment["DESKCAPTURE_DIAGNOSTIC_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("captures", isDirectory: true)
        }
        self.directory = directory ?? diagnostic ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeskCapture/Captures", isDirectory: true)
        thumbnails.countLimit = 80; thumbnails.totalCostLimit = 40 * 1024 * 1024
        if deferLoading { initialLoadPending = true; isLoading = true; return }
        if FileManager.default.fileExists(atPath: index.path),
           ((try? index.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max) > 64_000_000 {
            transactionError = L10n.text("历史索引超过64MB，未加载或改写。"); return
        }
        if let data = try? Data(contentsOf: index), let decoded = try? JSONDecoder().decode([CaptureRecord].self, from: data) {
            do { records = try HistoryTransactions.validatedRecords(decoded) }
            catch { transactionError = error.localizedDescription; return }
        } else if let data = try? Data(contentsOf: index) {
            damagedIndex = data
            records = (try? FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: [.creationDateKey]))?.compactMap { url in
                guard url.pathExtension.lowercased() == "png", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
                      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = info[kCGImagePropertyPixelWidth] as? Int, let height = info[kCGImagePropertyPixelHeight] as? Int else { return nil }
                return CaptureRecord(id: UUID(uuidString: url.deletingPathExtension().lastPathComponent) ?? UUID(),
                                     createdAt: (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date(),
                                     filename: url.lastPathComponent, width: width, height: height, mode: CaptureMode.region.rawValue)
            }.sorted { $0.createdAt > $1.createdAt } ?? []
        }
        needsRecovery = FileManager.default.fileExists(atPath: self.directory.appendingPathComponent(".history-transaction.json").path)
        if needsRecovery && automaticRecovery {
            Task { @MainActor [weak self] in try? await self?.recoverHistory() }
        } else if pruneOnInit && !needsRecovery { try? pruneExpired() }
    }

    @discardableResult
    func add(_ image: CGImage, mode: CaptureMode, document: AnnotationDocument? = nil, backingScale: CGFloat? = nil) throws -> CaptureRecord {
        try requireSynchronousWriteAvailable()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        let projectFilename = document.flatMap { $0.marks.isEmpty && $0.tutorialPreset == nil ? nil : "\(id.uuidString).deskcap" }
        let record = CaptureRecord(id: id, createdAt: Date(), filename: "\(id.uuidString).png",
                                   width: image.width, height: image.height, mode: mode.rawValue,
                                   backingScale: backingScale ?? document?.backingScale, projectFilename: projectFilename)
        let url = directory.appendingPathComponent(record.filename)
        let projectURL = projectFilename.map { directory.appendingPathComponent($0) }
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CaptureError.message(L10n.text("无法编码图片，请重新截图。"))
        }
        try png.write(to: url, options: .atomic)
        do {
            if let document, let projectURL { try document.projectData().write(to: projectURL, options: .atomic) }
        } catch { try? FileManager.default.removeItem(at: url); throw error }
        records.insert(record, at: 0)
        do { try persist() } catch {
            records.removeAll { $0.id == record.id }
            try? FileManager.default.removeItem(at: url)
            if let projectURL { try? FileManager.default.removeItem(at: projectURL) }
            throw error
        }
        try? pruneExpired()
        return record
    }

    func setRetentionDays(_ days: Int) throws {
        try requireSynchronousWriteAvailable()
        guard [0, 7, 30, 90].contains(days) else { throw CaptureError.message(L10n.text("不支持这个历史保留周期。")) }
        let previous = retentionDays
        retentionDays = days
        do { try pruneExpired(); preferences.set(days, forKey: "historyRetentionDays") }
        catch { retentionDays = previous; throw error }
    }

    @MainActor func loadInitial() async throws {
        guard initialLoadPending else { return }
        try await writeGate.acquire()
        guard initialLoadPending else { await writeGate.release(); return }
        isLoading = true
        let root = directory, settings = preferences
        writeInProgress = true
        let worker = Task.detached(priority: .userInitiated) { () throws -> ([CaptureRecord], Data?) in
            if FileManager.default.fileExists(atPath: root.appendingPathComponent(".history-transaction.json").path) { _ = try HistoryTransactions.load(root) }
            try Task.checkCancellation()
            let snapshot = CaptureStore(directory: root, pruneOnInit: false, preferences: settings, automaticRecovery: false)
            if let error = snapshot.transactionError { throw CaptureError.message(error) }
            try Task.checkCancellation()
            return (snapshot.records, snapshot.damagedIndex)
        }
        do {
            let snapshot = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            try Task.checkCancellation()
            records = snapshot.0; damagedIndex = snapshot.1; transactionError = nil; needsRecovery = false; initialLoadPending = false; isLoading = false; writeInProgress = false
            await writeGate.release()
        } catch {
            isLoading = false; writeInProgress = false; transactionError = error.localizedDescription
            await writeGate.release(); throw error
        }
    }

    @MainActor
    private func mutateHistory<T>(_ work: @escaping () throws -> T, publish: (T) -> Void) async throws -> T {
        try await loadInitial()
        try await writeGate.acquire()
        writeInProgress = true
        let fallback = damagedIndex, recovered = records, root = directory
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            if let fallback { try HistoryTransactions.repairLegacy(root, original: fallback, recovered: recovered) }
            return try work()
        }
        do {
            let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            publish(result); damagedIndex = nil; transactionError = nil; needsRecovery = false; writeInProgress = false
            await writeGate.release(); return result
        } catch {
            writeInProgress = false
            transactionError = error.localizedDescription
            needsRecovery = FileManager.default.fileExists(atPath: directory.appendingPathComponent(".history-transaction.json").path)
            await writeGate.release(); throw error
        }
    }
    @MainActor func recoverHistory() async throws {
        let root = directory
        _ = try await mutateHistory({ try HistoryTransactions.load(root) }, publish: { records = $0 })
    }
    @MainActor @discardableResult
    func addAsync(_ image: CGImage, mode: CaptureMode, document: AnnotationDocument? = nil, backingScale: CGFloat? = nil,
                  projectSnapshot: CaptureProjectSnapshot? = nil) async throws -> CaptureRecord {
        let snapshot = projectSnapshot ?? document.map(CaptureProjectSnapshot.init)
        let marks = snapshot?.marks ?? [], original = snapshot?.original
        let preset = snapshot?.preset, scale = snapshot?.backingScale ?? 1
        let id = UUID(), root = directory
        let projectFilename = marks.isEmpty && preset == nil ? nil : "\(id).deskcap"
        let record = CaptureRecord(id: id, createdAt: Date(), filename: "\(id).png", width: image.width, height: image.height,
            mode: mode.rawValue, backingScale: backingScale ?? snapshot?.backingScale, projectFilename: projectFilename)
        _ = try await mutateHistory({
            let stage = root.appendingPathComponent(".incoming-\(UUID())")
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
            defer {
                if !FileManager.default.fileExists(atPath: root.appendingPathComponent(".history-transaction.json").path) {
                    try? FileManager.default.removeItem(at: stage)
                }
            }
            try CaptureImageExport.png(image, to: stage.appendingPathComponent(record.filename))
            if let original, let projectFilename {
                let data = try AnnotationDocument.encodeProject(original: original, marks: marks, backingScale: scale, tutorialPreset: preset)
                try Task.checkCancellation(); try data.write(to: stage.appendingPathComponent(projectFilename), options: .atomic)
            }
            return try HistoryTransactions.append(record, incoming: stage, directory: root)
        }, publish: { records = $0 })
        if retentionDays > 0 { Task { try? await self.pruneExpiredAsync() } }
        return record
    }
    @MainActor func setTextAsync(_ text: String, for id: UUID, onlyIfMissing: Bool = false) async throws {
        let root = directory
        _ = try await mutateHistory({ try HistoryTransactions.setText(text, id: id, directory: root, onlyIfMissing: onlyIfMissing) }, publish: { records = $0 })
    }
    @MainActor @discardableResult
    func removeBatch(_ ids: Set<UUID>) async throws -> HistoryArchive {
        let root = directory
        let result = try await mutateHistory({ try HistoryTransactions.remove(ids, directory: root) }, publish: {
            records = $0.0
            for record in $0.1.records { thumbnails.removeObject(forKey: record.filename as NSString) }
        })
        return result.1
    }
    @MainActor func restoreBatch(_ id: UUID) async throws {
        let root = directory
        _ = try await mutateHistory({ try HistoryTransactions.restore(id, directory: root) }, publish: { records = $0 })
    }
    @MainActor func clearAllAsync() async throws {
        let root = directory
        _ = try await mutateHistory({ try HistoryTransactions.permanentlyRemove(directory: root) }, publish: { records = $0.records; transactionWarning = $0.warning; thumbnails.removeAllObjects() })
    }
    @MainActor func pruneExpiredAsync(now: Date = Date()) async throws {
        guard retentionDays > 0, let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: now) else { return }
        let root = directory
        _ = try await mutateHistory({ try HistoryTransactions.permanentlyRemove(directory: root, olderThan: cutoff) }, publish: { records = $0.records; transactionWarning = $0.warning; thumbnails.removeAllObjects() })
    }
    @MainActor func setRetentionDaysAsync(_ days: Int) async throws {
        guard [0, 7, 30, 90].contains(days) else { throw CaptureError.message(L10n.text("不支持这个历史保留周期。")) }
        let root = directory, settings = preferences
        let cutoff = days > 0 ? Calendar.current.date(byAdding: .day, value: -days, to: Date()) : nil
        guard days == 0 || cutoff != nil else { throw CaptureError.message(L10n.text("无法计算保留周期，未改变历史或设置。")) }
        _ = try await mutateHistory({
            let result: HistoryLegacyResult
            if let cutoff { result = try HistoryTransactions.permanentlyRemove(directory: root, olderThan: cutoff) }
            else { result = HistoryLegacyResult(records: try HistoryTransactions.load(root), warning: nil) }
            settings.set(days, forKey: "historyRetentionDays")
            return result
        }, publish: { records = $0.records; retentionDays = days; transactionWarning = $0.warning; thumbnails.removeAllObjects() })
    }

    private func requireSynchronousWriteAvailable() throws {
        guard !writeInProgress, !needsRecovery, !initialLoadPending else { throw CaptureError.message(L10n.text("历史事务正在进行，未覆盖本次数据。")) }
    }

    func pruneExpired(now: Date = Date()) throws {
        try requireSynchronousWriteAvailable()
        guard retentionDays > 0, let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: now) else { return }
        try deleteRecords(records.filter { $0.createdAt < cutoff })
    }

    func setText(_ text: String, for id: UUID) throws {
        try requireSynchronousWriteAvailable()
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        let old = records[i].recognizedText
        records[i].recognizedText = text
        do { try persist() } catch { records[i].recognizedText = old; throw error }
    }

    func delete(_ record: CaptureRecord) throws {
        try requireSynchronousWriteAvailable()
        try deleteRecords([record])
    }
    private func deleteRecords(_ removed: [CaptureRecord]) throws {
        guard !removed.isEmpty else { return }
        let manager = FileManager.default
        let stage = directory.appendingPathComponent(".delete-history-\(UUID())", isDirectory: true)
        try manager.createDirectory(at: stage, withIntermediateDirectories: true)
        let old = records
        var moved: [(URL, URL)] = []
        do {
            for record in removed {
                for filename in [record.filename] + (record.projectFilename.map { [$0] } ?? []) {
                    guard filename == (filename as NSString).lastPathComponent else { throw CaptureError.message(L10n.text("历史文件路径异常。")) }
                    let source = directory.appendingPathComponent(filename), target = stage.appendingPathComponent(filename)
                    guard manager.fileExists(atPath: source.path) else { continue }
                    try manager.moveItem(at: source, to: target); moved.append((source, target))
                }
            }
            let ids = Set(removed.map(\.id)); records = old.filter { !ids.contains($0.id) }
            try persist()
        } catch {
            records = old
            var failed = false
            for (source, target) in moved.reversed() { do { try manager.moveItem(at: target, to: source) } catch { failed = true } }
            if failed { throw CaptureError.message(L10n.text("删除未完成，部分文件保留在 \(stage.path)。")) }
            try? manager.removeItem(at: stage)
            throw error
        }
        for record in removed { thumbnails.removeObject(forKey: record.filename as NSString) }
        do { try manager.removeItem(at: stage) }
        catch { transactionError = L10n.text("历史索引已更新，部分文件保留在 \(stage.path)。") }
    }

    func clearAll() throws {
        try requireSynchronousWriteAvailable()
        guard !records.isEmpty else { return }
        let manager = FileManager.default
        let staging = directory.appendingPathComponent(".clear-history-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        let old = records
        var moved: [(original: URL, staged: URL)] = []
        do {
            // Stage only indexed originals/projects; exports and other files
            // in this directory are not part of the history deletion.
            let filenames = Set(old.flatMap { [$0.filename] + ($0.projectFilename.map { [$0] } ?? []) })
            for filename in filenames {
                guard filename == (filename as NSString).lastPathComponent else {
                    throw CaptureError.message(L10n.text("历史文件路径异常，清空已取消。"))
                }
                let source = directory.appendingPathComponent(filename)
                guard manager.fileExists(atPath: source.path) else { continue }
                let target = staging.appendingPathComponent(filename)
                try manager.moveItem(at: source, to: target)
                moved.append((source, target))
            }
            records = []
            try persist()
        } catch {
            records = old
            var rollbackFailed = false
            for item in moved.reversed() {
                do { try manager.moveItem(at: item.staged, to: item.original) }
                catch { rollbackFailed = true }
            }
            if rollbackFailed {
                throw CaptureError.message(L10n.text("清空未完成，部分文件保留在 \(staging.path)，请勿删除该目录。"))
            }
            try? manager.removeItem(at: staging)
            throw error
        }
        thumbnails.removeAllObjects()
        do { try manager.removeItem(at: staging) }
        catch { transactionError = L10n.text("历史索引已清空，但部分文件未能删除，保留在 \(staging.path)。") }
    }

    func url(for record: CaptureRecord) -> URL { directory.appendingPathComponent(record.filename) }
    func projectURL(for record: CaptureRecord) -> URL? { record.projectFilename.map { directory.appendingPathComponent($0) } }
    func document(for record: CaptureRecord) throws -> AnnotationDocument? {
        guard let url = projectURL(for: record) else { return nil }
        return try AnnotationDocument(projectData: Data(contentsOf: url))
    }
    func image(for record: CaptureRecord) -> NSImage? { NSImage(contentsOf: url(for: record)) }
    func thumbnail(for record: CaptureRecord) -> NSImage? {
        if let cached = thumbnails.object(forKey: record.filename as NSString) { return cached }
        guard let source = CGImageSourceCreateWithURL(url(for: record) as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 280, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        let result = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        thumbnails.setObject(result, forKey: record.filename as NSString, cost: image.width * image.height * 4)
        return result
    }
    private func persist() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let damagedIndex {
            try damagedIndex.write(to: directory.appendingPathComponent("history-recovery-\(Int(Date().timeIntervalSince1970)).json"), options: .atomic)
            self.damagedIndex = nil
        }
        try JSONEncoder().encode(records).write(to: index, options: .atomic)
    }
}

enum CaptureError: LocalizedError {
    case permission, message(String)
    var errorDescription: String? {
        switch self {
        case .permission: return L10n.text("系统拒绝了屏幕捕获。若 DeskCapture 已显示开启，请关闭再开启这项授权，并按系统提示重新启动 App。")
        case .message(let text): return text
        }
    }
}
