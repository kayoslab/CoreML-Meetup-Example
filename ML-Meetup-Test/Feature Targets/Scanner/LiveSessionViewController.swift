import UIKit
import AVFoundation
import Vision

class LiveSessionViewController: UIViewController {
    @IBOutlet private weak var previewView: UIView?
    @IBOutlet private weak var classificationLabel: UILabel?

    /* Input */
    private let session = AVCaptureSession()
    private var videoDevice: AVCaptureDevice?
    private var deviceInput: AVCaptureDeviceInput?
    /* Output */
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let videoDataOutputQueue = DispatchQueue(
        label: "VideoDataOutput",
        qos: .userInitiated,
        attributes: [],
        autoreleaseFrequency: .workItem
    )
    /* Buffering */
    // private var bufferSize: CGSize = .zero
    private var previousPixelBuffer: CVPixelBuffer?
    private var transpositionHistoryPoints = [CGPoint]()
    private let maximumHistoryLength = 15
    /* Preview */
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var rootLayer: CALayer?
    /* Vision */
    private let sequenceRequestHandler = VNSequenceRequestHandler()
    

    private lazy var classificationRequests: [VNRequest] = {
        guard let model = try? VNCoreMLModel(for: EveClassifier().model) else { return [] }
        
        let objectRecognition = VNCoreMLRequest(model: model, completionHandler: { (request, error) in
            // Perform UI updates on the main queue
            DispatchQueue.main.async(execute: { [weak self] in
                if let results = request.results {
                    self?.drawVisionRequestResults(results)
                }
            })
        })
        return [objectRecognition]
    }()
    
    
    override func viewDidLoad() {
        super.viewDidLoad()
        do {
            try setupDeviceInput()
            configureCameraSession()
            configurePreview()
        } catch {
            return
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        session.startRunning()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        session.stopRunning()
    }
}

extension LiveSessionViewController {

    private func setupDeviceInput() throws {
        guard let captureDevice = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .back
        ).devices.first else {
            return
        }

        videoDevice = captureDevice
        deviceInput = try AVCaptureDeviceInput(device: captureDevice)
    }
    
    private func configureCameraSession() {
        guard let deviceInput = deviceInput else { return } //, let videoDevice = videoDevice
        
        session.beginConfiguration()
        session.sessionPreset = .vga640x480
        
        guard session.canAddInput(deviceInput) else {
            session.commitConfiguration()
            return
        }
        session.addInput(deviceInput)
        
        if session.canAddOutput(videoDataOutput) {
            session.addOutput(videoDataOutput)

            videoDataOutput.alwaysDiscardsLateVideoFrames = true
            videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)]
            videoDataOutput.setSampleBufferDelegate(self, queue: videoDataOutputQueue)
        } else {
            session.commitConfiguration()
            return
        }
        
        let captureConnection = videoDataOutput.connection(with: .video)
        captureConnection?.isEnabled = true
        
//        do {
//            try videoDevice.lockForConfiguration()
//            let dimensions = CMVideoFormatDescriptionGetDimensions(videoDevice.activeFormat.formatDescription)
//            bufferSize.width = CGFloat(dimensions.width)
//            bufferSize.height = CGFloat(dimensions.height)
//            videoDevice.unlockForConfiguration()
//        } catch { }

        session.commitConfiguration()
    }
    
    private func configurePreview() {
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = AVLayerVideoGravity.resizeAspectFill
        guard let rootLayer = previewView?.layer else { return }
        previewLayer.frame = rootLayer.bounds
        rootLayer.addSublayer(previewLayer)
        
        self.previewLayer = previewLayer
        self.rootLayer = rootLayer
    }
}

extension LiveSessionViewController {
    
    private func sceneStabilityAchieved() -> Bool {
        // Determine if we have enough evidence of stability.
        if transpositionHistoryPoints.count == maximumHistoryLength {
            // Calculate the moving average.
            var movingAverage: CGPoint = CGPoint.zero
            for currentPoint in transpositionHistoryPoints {
                movingAverage.x += currentPoint.x
                movingAverage.y += currentPoint.y
            }
            let distance = abs(movingAverage.x) + abs(movingAverage.y)
            if distance < 20 {
                return true
            }
        }
        return false
    }
    
    private func recordTransposition(_ point: CGPoint) {
        transpositionHistoryPoints.append(point)
        
        if transpositionHistoryPoints.count > maximumHistoryLength {
            transpositionHistoryPoints.removeFirst()
        }
    }
    
    func drawVisionRequestResults(_ results: [Any]) {
        guard let classifications = results as? [VNClassificationObservation] else { return }
        
        if classifications.isEmpty {
            classificationLabel?.text = "Nothing recognized."
        } else {
            let topClassifications = classifications.prefix(2)
            let descriptions = topClassifications.map { classification in
                return String(format: "(%.2f): %@", classification.confidence, classification.identifier)
            }
            classificationLabel?.text = "Classification:\n" + descriptions.joined(separator: "\n")
        }
    }
}

extension LiveSessionViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard let previousPixelBuffer = previousPixelBuffer else {
            self.previousPixelBuffer = pixelBuffer
            transpositionHistoryPoints.removeAll()
            return
        }
        
        let registrationRequest = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: pixelBuffer)
        do {
            try sequenceRequestHandler.perform([registrationRequest], on: previousPixelBuffer)
        } catch { return }
        
        self.previousPixelBuffer = pixelBuffer
        
        if let results = registrationRequest.results {
            if let alignmentObservation = results.first as? VNImageTranslationAlignmentObservation {
                let alignmentTransform = alignmentObservation.alignmentTransform
                self.recordTransposition(CGPoint(x: alignmentTransform.tx, y: alignmentTransform.ty))
            }
        }
        
        if self.sceneStabilityAchieved() {
            let imageRequestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
            do {
                try imageRequestHandler.perform(classificationRequests)
            } catch { return }
        }
    }
}
