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

struct PickedImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// Multi-select photo picker. `selectionLimit = 0` allows any number of
/// screenshots; the results are delivered in the order the user picked them.
/// If some items fail to load the rest are still returned, along with the
/// first load error so the caller can tell the user.
struct ImagePicker: UIViewControllerRepresentable {
    var selectionLimit: Int = 0
    let onResult: (Result<[PickedImage], ImagePickerError>) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = selectionLimit

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onResult: onResult, onCancel: onCancel)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onResult: (Result<[PickedImage], ImagePickerError>) -> Void
        private let onCancel: () -> Void

        init(
            onResult: @escaping (Result<[PickedImage], ImagePickerError>) -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.onResult = onResult
            self.onCancel = onCancel
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)

            guard !results.isEmpty else {
                onCancel()
                return
            }

            let providers = results.map(\.itemProvider)
            var loaded = [Int: UIImage]()
            var firstError: String?
            let group = DispatchGroup()
            let lock = NSLock()

            for (index, provider) in providers.enumerated() {
                guard provider.canLoadObject(ofClass: UIImage.self) else {
                    lock.lock(); firstError = firstError ?? "One item was not a readable image."; lock.unlock()
                    continue
                }
                group.enter()
                provider.loadObject(ofClass: UIImage.self) { object, error in
                    lock.lock()
                    if let image = object as? UIImage {
                        loaded[index] = image
                    } else if let error {
                        firstError = firstError ?? error.localizedDescription
                    } else {
                        firstError = firstError ?? "One item did not contain a readable image."
                    }
                    lock.unlock()
                    group.leave()
                }
            }

            group.notify(queue: .main) { [onResult, onCancel] in
                let ordered = loaded.keys.sorted().map { PickedImage(image: loaded[$0]!) }
                if ordered.isEmpty {
                    if let firstError {
                        onResult(.failure(.loadingFailed(firstError)))
                    } else {
                        onCancel()
                    }
                    return
                }
                onResult(.success(ordered))
            }
        }
    }
}
