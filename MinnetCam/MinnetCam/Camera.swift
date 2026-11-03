import Accelerate
import AVFoundation
import SwiftUI

final class Camera: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum Status { case starting, running, denied, unavailable, noModel }

    @Published private(set) var status = Status.starting
    @Published private(set) var predictions: [Prediction] = []
    @Published private(set) var milliseconds = 0.0
    @Published private(set) var paused = false

    let session = AVCaptureSession()
    var labels: [String] { classifier?.labels ?? [] }

    private let queue = DispatchQueue(label: "minnet.camera")
    private let classifier = Classifier()
    private let lock = NSLock()
    private var viewport = CGSize.zero
    private var finder: CGFloat = 0
    private var isPaused = false
    private var smoothed: [Float] = []
    private var lastPublish: CFTimeInterval = 0
    private var pixels: [UInt8] = []
    private var input: [Float] = []

    func start() {
        guard classifier != nil else {
            status = .noModel
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { self.configure() } else { self.status = .denied }
                }
            }
        default:
            status = .denied
        }
    }

    func stop() {
        queue.async { self.session.stopRunning() }
    }

    func setViewport(_ size: CGSize, finder side: CGFloat) {
        lock.withLock {
            viewport = size
            finder = side
        }
    }

    func togglePause() {
        paused.toggle()
        let value = paused
        lock.withLock { isPaused = value }
    }

    private func configure() {
        queue.async {
            if self.session.isRunning { return }
            if self.session.inputs.isEmpty, !self.setup() {
                DispatchQueue.main.async { self.status = .unavailable }
                return
            }
            self.session.startRunning()
            DispatchQueue.main.async { self.status = .running }
        }
    }

    private func setup() -> Bool {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .hd1280x720
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddInput(input), session.canAddOutput(output) else { return false }
        session.addInput(input)
        session.addOutput(output)
        if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        return true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let classifier, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let (size, side, paused) = lock.withLock { (viewport, finder, isPaused) }
        if paused { return }
        let start = CACurrentMediaTime()
        guard preprocess(buffer, viewport: size, finder: side, width: classifier.width, height: classifier.height) else { return }
        let probs = classifier.classify(input)
        let ms = (CACurrentMediaTime() - start) * 1000
        if smoothed.count != probs.count {
            smoothed = probs
        } else {
            for i in smoothed.indices { smoothed[i] = 0.7 * smoothed[i] + 0.3 * probs[i] }
        }
        guard start - lastPublish > 0.1 else { return }
        lastPublish = start
        let top = smoothed.indices
            .sorted { smoothed[$0] > smoothed[$1] }
            .prefix(3)
            .map { Prediction(label: classifier.labels[$0], confidence: smoothed[$0]) }
        DispatchQueue.main.async {
            self.predictions = top
            self.milliseconds = ms
        }
    }

    private func preprocess(_ buffer: CVPixelBuffer, viewport: CGSize, finder: CGFloat, width ow: Int, height oh: Int) -> Bool {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)

        var side = min(w, h)
        if viewport.width > 0, viewport.height > 0, finder > 0 {
            let scale = max(viewport.width / CGFloat(w), viewport.height / CGFloat(h))
            side = min(side, max(1, Int(finder / scale)))
        }
        let x0 = (w - side) / 2
        let y0 = (h - side) / 2

        let plane = ow * oh
        if pixels.count != plane * 4 {
            pixels = [UInt8](repeating: 0, count: plane * 4)
            input = [Float](repeating: 0, count: plane * 3)
        }
        var src = vImage_Buffer(data: base + y0 * rowBytes + x0 * 4,
                                height: vImagePixelCount(side),
                                width: vImagePixelCount(side),
                                rowBytes: rowBytes)
        let error = pixels.withUnsafeMutableBytes { bytes -> vImage_Error in
            var dst = vImage_Buffer(data: bytes.baseAddress,
                                    height: vImagePixelCount(oh),
                                    width: vImagePixelCount(ow),
                                    rowBytes: ow * 4)
            return vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageHighQualityResampling))
        }
        guard error == kvImageNoError else { return false }

        for i in 0..<plane {
            input[i] = Float(pixels[i * 4 + 2]) / 255
            input[plane + i] = Float(pixels[i * 4 + 1]) / 255
            input[2 * plane + i] = Float(pixels[i * 4]) / 255
        }
        return true
    }
}
