import UIKit
import CoreML
import Vision
import ImageIO
import Photos


class StaticViewController: UIViewController {
    
    /* User interface */
    @IBOutlet private weak var classificationLabel: UILabel?
    @IBOutlet private weak var imageView: UIImageView?
    @IBOutlet private weak var imagePlaceholder: UIView?
    
    
    /// A request that uses a CoreML Model to process images.
    lazy var classificationRequest: VNCoreMLRequest? = {
        guard let model = try? VNCoreMLModel(for: CaltechClassifier().model) else { return nil }
        
        let request = VNCoreMLRequest(model: model, completionHandler: { [weak self] request, error in
            DispatchQueue.main.async(execute: { [weak self] in
                self?.processClassifications(for: request.results, error: error)
            })
        })
        
        request.imageCropAndScaleOption = .centerCrop
        return request
    }()
    
    
    /* ViewController Lifecycle */
    override func viewDidLoad() {
        super.viewDidLoad()
        
        switch PHPhotoLibrary.authorizationStatus() {
            case .authorized, .restricted, .denied: break
            case .notDetermined: PHPhotoLibrary.requestAuthorization { _ in }
        }
    }
    
    @IBAction func imageButtonTouched(_ sender: UIButton) {
        let picker = UIImagePickerController()
        picker.modalPresentationStyle = .popover
        picker.delegate = self
        picker.sourceType = .photoLibrary
        present(picker, animated: true)
    }
}



extension StaticViewController {
    
    func updateClassifications(for image: UIImage) {
        classificationLabel?.text = "Classifying..."
        guard let ciImage = CIImage(image: image),
            let classificationRequest = classificationRequest else {
            fatalError("Unable to create \(CIImage.self) from \(image).")
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            let handler = VNImageRequestHandler(ciImage: ciImage, orientation: .up)
            do {
                try handler.perform([classificationRequest])
            } catch { }
        }
    }
    
    func processClassifications(for results: [Any]?, error: Error?) {
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



extension StaticViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    
    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
        guard let image = info[.originalImage] as? UIImage else {
            imagePlaceholder?.isHidden = false
            picker.dismiss(animated: true)
            return
        }

        imagePlaceholder?.isHidden = true
        imageView?.image = image
        updateClassifications(for: image)
        
        picker.dismiss(animated: true)
    }
}
