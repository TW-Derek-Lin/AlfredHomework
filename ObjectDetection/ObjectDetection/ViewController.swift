import CoreMedia
import CoreML
import UIKit
import Vision
import AVFoundation
import Photos

struct Recording {
    var personPrediction: VNRecognizedObjectObservation?
    var startRecording: Bool = false
    var firstTimeStamp: CMTime?
    var readDone: Bool = false
    let debounceTimeConstant: Double = 5
}

class ViewController: UIViewController {
    var reader: AVAssetReader?
    var writer: AVAssetWriter?
    let operationQueue = DispatchQueue(label: "com.writeMovew.queue")
    var recording = Recording()

    var displayLayer = AVSampleBufferDisplayLayer()

    @IBOutlet var videoPreview: UIView!
    var currentBuffer: CVPixelBuffer?

    let coreMLModel = MobileNetV2_SSDLite()

    lazy var visionModel: VNCoreMLModel = {
        do {
            return try VNCoreMLModel(for: coreMLModel.model)
        } catch {
            fatalError("Failed to create VNCoreMLModel: \(error)")
        }
    }()

    lazy var visionRequest: VNCoreMLRequest = {
        let request = VNCoreMLRequest(model: visionModel, completionHandler: {
            [weak self] request, error in
            self?.processObservations(for: request, error: error)
        })

        // NOTE: If you use another crop/scale option, you must also change
        // how the BoundingBoxView objects get scaled when they are drawn.
        // Currently they assume the full input image is used.
        request.imageCropAndScaleOption = .scaleFill
        return request
    }()

    let maxBoundingBoxViews = 10
    var boundingBoxViews = [BoundingBoxView]()
    var colors: [String: UIColor] = [:]

    func requestAuthorization(completion: @escaping () -> Void) {
        let status = PHPhotoLibrary.authorizationStatus()
        switch status {
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization { (status) in
                switch status {
                case .authorized, .limited:
                    DispatchQueue.main.async {
                        completion()
                    }
                default:
                    break
                }
            }
        case .authorized:
            completion()
        case .limited:
            completion()
        default:
            break
        }
    }
    func saveVideoToAlbum(_ outputURL: URL, _ completion: ((Error?) -> Void)?) {
        requestAuthorization {
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, fileURL: outputURL, options: nil)
            }) { (result, error) in
                DispatchQueue.main.async {
                    if let error = error {
                        print(error.localizedDescription)
                    } else {
                        print("Saved successfully")
                    }
                    completion?(error)
                }
            }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setUpBoundingBoxViews()
        videoPreview.layer.addSublayer(displayLayer)
        for box in self.boundingBoxViews {
            box.addToLayer(self.videoPreview.layer)
        }
        self.requestAuthorization { [weak self] in
            self?.loadVideoFile()
        }
    }

    func setUpBoundingBoxViews() {
        for _ in 0..<maxBoundingBoxViews {
            boundingBoxViews.append(BoundingBoxView())
        }

        // The label names are stored inside the MLModel's metadata.
        guard let userDefined = coreMLModel.model.modelDescription.metadata[MLModelMetadataKey.creatorDefinedKey] as? [String: String],
              let allLabels = userDefined["classes"] else {
            fatalError("Missing metadata")
        }

        let labels = allLabels.components(separatedBy: ",")

        // Assign random colors to the classes.
        for label in labels {
            colors[label] = UIColor(red: CGFloat.random(in: 0...1),
                                    green: CGFloat.random(in: 0...1),
                                    blue: CGFloat.random(in: 0...1),
                                    alpha: 1)
        }
    }
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        displayLayer.frame = videoPreview.bounds
    }

    func predict(sampleBuffer: CMSampleBuffer) {
        if currentBuffer == nil, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            currentBuffer = pixelBuffer

            // Get additional info from the camera.
            var options: [VNImageOption : Any] = [:]
            if let cameraIntrinsicMatrix = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, attachmentModeOut: nil) {
                options[.cameraIntrinsics] = cameraIntrinsicMatrix
            }

            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: options)
            do {
                try handler.perform([self.visionRequest])
            } catch {
                print("Failed to perform Vision request: \(error)")
            }

            currentBuffer = nil
        }
    }

    func processObservations(for request: VNRequest, error: Error?) {
        if let results = request.results as? [VNRecognizedObjectObservation], let prediction = results.first(where: { ($0.labels.first?.identifier == "person") && ($0.labels.first?.confidence ?? 0) > 0.9 }) {
            recording.startRecording = true
            recording.personPrediction = prediction
        } else {
            recording.personPrediction = nil
        }
        DispatchQueue.main.async {
            if let results = request.results as? [VNRecognizedObjectObservation] {
                self.show(predictions: results)
            } else {
                self.show(predictions: [])
            }
        }
    }

    func show(predictions: [VNRecognizedObjectObservation]) {
        for i in 0..<boundingBoxViews.count {
            if i < predictions.count {
                let prediction = predictions[i]

                /*
                 The predicted bounding box is in normalized image coordinates, with
                 the origin in the lower-left corner.

                 Scale the bounding box to the coordinate system of the video preview,
                 which is as wide as the screen and has a 16:9 aspect ratio. The video
                 preview also may be letterboxed at the top and bottom.

                 Based on code from https://github.com/Willjay90/AppleFaceDetection

                 NOTE: If you use a different .imageCropAndScaleOption, or a different
                 video resolution, then you also need to change the math here!
                 */

                let width = view.bounds.width
                let height = width * 16 / 9
                let offsetY = (view.bounds.height - height) / 2
                let scale = CGAffineTransform.identity.scaledBy(x: width, y: height)
                let transform = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -height - offsetY)
                let rect = prediction.boundingBox.applying(scale).applying(transform)

                // The labels array is a list of VNClassificationObservation objects,
                // with the highest scoring class first in the list.
                let bestClass = prediction.labels[0].identifier
                let confidence = prediction.labels[0].confidence

                // Show the bounding box.
                let label = String(format: "%@ %.1f", bestClass, confidence * 100)
                let color = colors[bestClass] ?? UIColor.red
                boundingBoxViews[i].show(frame: rect, label: label, color: color)
            } else {
                boundingBoxViews[i].hide()
            }
        }
    }
}
// - MARK: main functions
extension ViewController {
    var documentDir: String {
        return NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? (NSHomeDirectory() + "/Document")
    }
    func configAssetReader() -> (reader: AVAssetReader, trackOutput: AVAssetReaderTrackOutput)? {
        let videoURL = URL(fileURLWithPath: Bundle.main.path(forResource: "IMG_6281", ofType: "mp4") ?? "")
        let asset = AVAsset(url: videoURL)
        guard let track = asset.tracks(withMediaType: .video).first, let assetReader = try? AVAssetReader(asset: asset) else {
            print("Load source fail")
            return nil
        }
        let assetOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [String(kCVPixelBufferPixelFormatTypeKey): kCVPixelFormatType_32BGRA])
        if assetReader.canAdd(assetOutput) {
            assetReader.add(assetOutput)
            return (assetReader, assetOutput)
        } else {
            print("Asset can't add output")
            return nil
        }
    }
    func configAssetWriter() -> (writer: AVAssetWriter, input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor)? {
        let outputURL = URL(fileURLWithPath: (documentDir as NSString).appendingPathComponent("\(Date().timeIntervalSince1970).mp4"))
        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else {
            return nil
        }

        let writerOutputSettings = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 720, AVVideoHeightKey: 1280, AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 10, AVVideoAverageBitRateKey: 1280 * 720 * 7.5, AVVideoProfileLevelKey: AVVideoProfileLevelH264Main31]] as [String : Any]

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: writerOutputSettings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: writerInput, sourcePixelBufferAttributes: nil)
        writerInput.expectsMediaDataInRealTime = false

        if writer.canAdd(writerInput) {
            writer.add(writerInput)
            return (writer, writerInput, adaptor)
        } else {
            return nil
        }
    }
    func loadVideoFile() {
        guard let readerCombination = configAssetReader() else {
            print("Config reader fail")
            return
        }
        let reader = readerCombination.reader
        let readerOutput = readerCombination.trackOutput
        self.reader = reader
        reader.startReading()
        operationRecording(reader: reader, readerOutput: readerOutput)
    }
    func operationRecording(reader: AVAssetReader, readerOutput: AVAssetReaderTrackOutput) {
        guard let writerCombination = configAssetWriter() else {
            print("Config writer fail")
            return
        }
        let writer = writerCombination.writer
        let adaptor = writerCombination.adaptor

        self.writer = writer
        writer.startWriting()

        operationQueue.async { [weak self] in
            guard let self = self else { return }
            var finish = false
            var debounceTime: TimeInterval = self.recording.debounceTimeConstant
            while adaptor.assetWriterInput.isReadyForMoreMediaData && finish == false {
                autoreleasepool {
                    if let sampleBuffer = readerOutput.copyNextSampleBuffer() {
                        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                        self.predict(sampleBuffer: sampleBuffer)
                        self.displayLayer.enqueue(sampleBuffer)
                        if self.recording.startRecording {
                            if self.recording.firstTimeStamp == nil {
                                self.recording.firstTimeStamp = time
                                writer.startSession(atSourceTime: time)
                            }
                            var cvPixelBuffer: CVPixelBuffer?
                            if let prediction = self.recording.personPrediction, let image = self.sampleBufferToImage(sampleBuffer) {
                                debounceTime = time.seconds + self.recording.debounceTimeConstant
                                cvPixelBuffer = self.imageToCVPixelBuffer(image.addBoundingBox(prediction: prediction))
                            } else {
                                cvPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
                            }
                            if let baseTime = self.recording.firstTimeStamp?.seconds {
                                let gapTime = time.seconds - baseTime
                                if let cvPixelBuffer = cvPixelBuffer {
                                    finish = !adaptor.append(cvPixelBuffer, withPresentationTime: time)
                                }
                                if gapTime > 10.0 || time.seconds > debounceTime {
                                    finish = true
                                }
                            }
                        }
                    } else {
                        finish = true
                        self.recording.readDone = true
                    }
                    if finish {
                        adaptor.assetWriterInput.markAsFinished()
                        writer.finishWriting {
                            if writer.status == .completed {
                                print("!!! write movie finish")
                                self.saveVideoToAlbum(writer.outputURL) { _ in
                                    try? FileManager.default.removeItem(at: writer.outputURL)
                                }
                            } else {
                                try? FileManager.default.removeItem(at: writer.outputURL)
                            }
                            self.recording.startRecording = false
                            self.recording.firstTimeStamp = nil
                            if !self.recording.readDone {
                                DispatchQueue.main.async {
                                    self.operationRecording(reader: reader, readerOutput: readerOutput)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
// - MARK: sample buffer transform
extension UIViewController {
    func sampleBufferToImage(_ sampleBuffer: CMSampleBuffer) -> UIImage? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        CVPixelBufferLockBaseAddress(imageBuffer, CVPixelBufferLockFlags(rawValue: 0))
        let baseAddress = CVPixelBufferGetBaseAddress(imageBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer)
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        let context = CGContext(data: baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        guard let quartzImage = context?.makeImage() else { return nil }
        CVPixelBufferUnlockBaseAddress(imageBuffer, CVPixelBufferLockFlags(rawValue: 0))
        return UIImage(cgImage: quartzImage)
    }
    func imageToCVPixelBuffer(_ image: UIImage) -> CVPixelBuffer? {
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue, kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue] as CFDictionary
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, Int(image.size.width), Int(image.size.height), kCVPixelFormatType_32BGRA, attrs, &pixelBuffer)
        guard status == kCVReturnSuccess else { return nil }
        guard let pixelBuffer = pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, CVPixelBufferLockFlags(rawValue: 0))
        let pixelData = CVPixelBufferGetBaseAddress(pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let context = CGContext(data: pixelData, width: Int(image.size.width), height: Int(image.size.height), bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        context.translateBy(x: 0, y: image.size.height)
        context.scaleBy(x: 1.0, y: -1.0)
        UIGraphicsPushContext(context)
        image.draw(in: CGRect(x: 0, y: 0, width: image.size.width, height: image.size.height))
        UIGraphicsPopContext()
        CVPixelBufferUnlockBaseAddress(pixelBuffer, CVPixelBufferLockFlags(rawValue: 0))
        return pixelBuffer
    }
}
