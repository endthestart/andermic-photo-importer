import AppKit
import ImageCaptureCore

protocol CameraImportSource: AnyObject {
    var name: String { get }
    var url: URL { get }
    func prepare(cancellation: Cancellation, progress: @escaping (ImportProgress) -> Void,
                 completion: @escaping (Result<CameraSnapshot, Error>) -> Void)
}

/// Image Capture/PTP sources are not mounted volumes. Discovery alone never opens
/// a session or transfers media. Only selecting a camera starts a read-only session.
final class CameraMonitor: NSObject, ICDeviceBrowserDelegate {
    let browser = ICDeviceBrowser()
    private(set) var cameras: [CameraSource] = []
    var onChange: (([CameraSource], CameraSource?) -> Void)?
    var onRemove: ((CameraSource) -> Void)?

    func start() {
        #if UI_AUTOMATION
        // GUI fixtures must never discover/open the owner's connected cameras.
        if UserDefaults.standard.string(forKey: "CorvusUIScript") != nil { return }
        #endif
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        browser.start()
    }
    func camera(for url: URL) -> CameraSource? { cameras.first { $0.url == url } }
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice, camera.transportType == ICDeviceTransport.transportTypeUSB.rawValue else { return }
        let source = CameraSource(camera)
        cameras.append(source)
        cameras.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        onChange?(cameras, source)
    }
    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        guard let source = cameras.first(where: { $0.device === device }) else { return }
        source.disconnected()
        cameras.removeAll { $0 === source }
        onRemove?(source); onChange?(cameras, nil)
    }
}

final class CameraSource: NSObject, ICCameraDeviceDelegate, CameraImportSource {
    let device: ICCameraDevice
    let name: String
    let url: URL
    private var connected = true
    private var ready = false
    private var opening = false
    private var pending: (() -> Void)?
    private var failed: ((Error) -> Void)?
    private var token: Cancellation?
    private var sessionTimer: Timer?
    private var revision = 0

    init(_ device: ICCameraDevice) {
        self.device = device; name = device.name ?? "USB camera"
        var parts = URLComponents(); parts.scheme = "corvus-camera"; parts.host = UUID().uuidString
        parts.path = "/" + (device.name ?? "USB camera")
        url = parts.url!
        super.init()
        device.delegate = self
        device.mediaPresentation = .originalAssets
    }

    func prepare(cancellation: Cancellation, progress: @escaping (ImportProgress) -> Void,
                 completion: @escaping (Result<CameraSnapshot, Error>) -> Void) {
        token?.cancel(); token = cancellation
        let finish: (Result<CameraSnapshot, Error>) -> Void = { result in
            DispatchQueue.main.async { completion(result) }
        }
        guard connected else { finish(.failure(ImportError("The camera was disconnected. Reconnect it and scan again."))); return }
        failed = { error in finish(.failure(error)) }
        pending = { [self] in
            pending = nil; failed = nil; sessionTimer?.invalidate(); sessionTimer = nil
            do {
                try cancellation.check()
                let (objects, files) = try catalog()
                let catalogRevision = revision
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    do {
                        let snapshot = try CameraStaging.prepare(objects, camera: url.absoluteString, cancellation: cancellation,
                            read: { object, offset, length in
                                try read(files[object.id]!, offset: offset, length: length, revision: catalogRevision, cancellation: cancellation)
                            }, progress: progress)
                        DispatchQueue.main.async { [self] in
                            guard connected, ready, revision == catalogRevision, !cancellation.isCancelled else {
                                finish(.failure(ImportError("The camera changed or was disconnected during transfer. Scan again."))); return
                            }
                            finish(.success(snapshot))
                        }
                    } catch { finish(.failure(error)) }
                }
            } catch { finish(.failure(error)) }
        }
        if ready { pending?(); return }
        progress(ImportProgress("Opening “\(name)” and listing its originals… If the camera is busy, close Photos or Image Capture and scan again.", fraction: nil))
        // Opening/catalog timeouts and cancellation cannot leave the UI stuck scanning.
        let deadline = Date().addingTimeInterval(60)
        sessionTimer?.invalidate()
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if cancellation.isCancelled || Date() >= deadline {
                timer.invalidate(); self.pending = nil
                let callback = self.failed; self.failed = nil
                callback?(ImportError(cancellation.isCancelled ? "Camera scan stopped." : "The camera did not become ready. Close Photos or Image Capture, check the camera, and scan again."))
            }
        }
        if !opening {
            opening = true
            device.requestOpenSession()
        }
    }

    /// Combine Image Capture's hierarchy and media list. Some PTP cameras have
    /// no hierarchy at all; their files still retain usable parent-folder links.
    func catalog() throws -> ([CameraObject], [String: ICCameraFile]) {
        var items: [String: CameraCatalogItem] = [:], files: [String: ICCameraFile] = [:]
        func key(_ item: ICCameraItem) -> String {
            item.ptpObjectHandle == 0 ? "local-\(ObjectIdentifier(item))" : "ptp-\(item.ptpObjectHandle)"
        }
        func add(_ item: ICCameraItem, depth: Int = 0) throws {
            let id = key(item)
            guard items[id] == nil else { return }
            guard depth < 64 else { throw ImportError("The camera folder hierarchy is invalid.") }
            let folder = item as? ICCameraFolder, file = item as? ICCameraFile
            guard folder != nil || file != nil else { throw ImportError("The camera returned an unsupported catalog item.") }
            let children = folder?.contents ?? []
            let parent = item.parentFolder
            // Record before traversing parent/child links: their two-way links
            // are expected. CameraCatalog separately rejects ancestry cycles.
            items[id] = CameraCatalogItem(id: id, folder: folder != nil, name: item.name,
                originalName: file?.originalFilename, size: Int64(file?.fileSize ?? 0),
                parent: parent.map(key), children: children.map(key), handle: item.ptpObjectHandle)
            if let file { files[id] = file }
            if let parent { try add(parent, depth: depth + 1) }
            for child in children { try add(child, depth: depth + 1) }
        }
        let roots = device.contents ?? [], media = device.mediaFiles ?? []
        for item in roots + media { try add(item) }
        return (try CameraCatalog.collect(hierarchy: roots.map(key), media: media.map(key), items: items), files)
    }

    /// Bridge an asynchronous framework read to the staging worker. Main stays free.
    private func read(_ file: ICCameraFile, offset: Int64, length: Int, revision expected: Int, cancellation: Cancellation) throws -> Data {
        final class Reply {
            let lock = NSLock()
            var result: Result<Data, Error>?
            func set(_ value: Result<Data, Error>) { lock.lock(); result = value; lock.unlock() }
            func get() -> Result<Data, Error>? { lock.lock(); defer { lock.unlock() }; return result }
        }
        let reply = Reply(), semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { [self] in
            guard connected, ready, revision == expected, !cancellation.isCancelled else {
                reply.set(.failure(ImportError("The camera changed or was disconnected. Scan again."))); semaphore.signal(); return
            }
            file.requestReadData(atOffset: off_t(offset), length: off_t(length)) { data, error in
                if let error { reply.set(.failure(error)) }
                else if let data { reply.set(.success(data)) }
                else { reply.set(.failure(ImportError("The camera did not return original data."))) }
                semaphore.signal()
            }
        }
        let deadline = Date().addingTimeInterval(60)
        while semaphore.wait(timeout: .now() + 0.1) == .timedOut {
            try cancellation.check()
            if Date() >= deadline { throw ImportError("Reading the camera timed out. Check the USB connection and scan again.") }
        }
        try cancellation.check()
        return try reply.get()!.get()
    }

    func disconnected() {
        connected = false; ready = false; revision += 1; token?.cancel()
        fail(ImportError("The camera was disconnected. Verified destination copies are kept."))
    }
    private func fail(_ error: Error) {
        pending = nil; sessionTimer?.invalidate(); sessionTimer = nil
        let callback = failed; failed = nil; callback?(error)
    }
    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        opening = false
        if let error { fail(ImportError("Could not open the camera: \(error.localizedDescription). Close Photos or Image Capture and scan again.")) }
    }
    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        ready = false; opening = false; revision += 1; token?.cancel()
        fail(error ?? ImportError("The camera session closed. Scan again."))
    }
    func didRemove(_ device: ICDevice) { disconnected() }
    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) { ready = true; pending?() }
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) { revision += 1 }
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) { revision += 1; token?.cancel() }
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) { revision += 1; token?.cancel() }
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) { token?.cancel(); fail(ImportError("Unlock the camera and scan again.")) }
}
