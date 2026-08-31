import PhotosUI
import SwiftUI

enum ImagePickerError: LocalizedError, Equatable {
    case noImageData
    case loadingFailed(String)

    var errorDescription: String? {
        switch self {
        case .noImageData:
            "The selected item did not contain a readable image."
        case .loadingFailed(let message):
            "Image selection failed: \(message)"
        }
    }
}

struct PickedImage {
    let image: UIImage
}

struct ImagePicker: UIViewControllerRepresentable {
    let onResult: (Result<PickedImage, ImagePickerError>) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 1

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onResult: onResult, onCancel: onCancel)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onResult: (Result<PickedImage, ImagePickerError>) -> Void
        private let onCancel: () -> Void

        init(
            onResult: @escaping (Result<PickedImage, ImagePickerError>) -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.onResult = onResult
            self.onCancel = onCancel
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)

            guard let provider = results.first?.itemProvider else {
                onCancel()
                return
            }

            guard provider.canLoadObject(ofClass: UIImage.self) else {
                onResult(.failure(.noImageData))
                return
            }

            provider.loadObject(ofClass: UIImage.self) { [onResult] object, error in
                DispatchQueue.main.async {
                    if let error {
                        onResult(.failure(.loadingFailed(error.localizedDescription)))
                        return
                    }

                    guard let image = object as? UIImage else {
                        onResult(.failure(.noImageData))
                        return
                    }

                    onResult(.success(PickedImage(image: image)))
                }
            }
        }
    }
}

