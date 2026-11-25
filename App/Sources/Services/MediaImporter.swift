import AVFoundation
import CoreTransferable
import PhotosUI
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Saves photos and videos to a job, shrunk so several fit in one email:
/// photos to about 1600 px JPEG, videos to 960x540 MP4.
@MainActor
enum MediaImporter {
    static func addPhoto(_ image: UIImage, to job: Job, context: ModelContext) {
        guard let data = shrink(image) else { return }
        let fileName = "\(UUID().uuidString).jpg"
        guard (try? data.write(to: MediaStorage.directory.appendingPathComponent(fileName))) != nil else { return }
        insert(JobMedia(fileName: fileName, kind: "photo", byteSize: data.count), job: job, context: context)
    }

    /// `source` is a temporary movie file; it is compressed into the job's media folder.
    static func addVideo(from source: URL, to job: Job, context: ModelContext) async {
        let fileName = "\(UUID().uuidString).mp4"
        let destination = MediaStorage.directory.appendingPathComponent(fileName)
        let asset = AVURLAsset(url: source)
        if let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset960x540) {
            do {
                try await export.export(to: destination, as: .mp4)
            } catch {
                // Fall back to the original file if compressing fails.
                try? FileManager.default.copyItem(at: source, to: destination)
            }
        } else {
            try? FileManager.default.copyItem(at: source, to: destination)
        }
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0 else { return }
        insert(JobMedia(fileName: fileName, kind: "video", byteSize: size), job: job, context: context)
    }

    /// Items chosen with the Photos picker.
    static func add(_ items: [PhotosPickerItem], to job: Job, context: ModelContext) async {
        for item in items {
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                if let movie = try? await item.loadTransferable(type: PickedMovie.self) {
                    await addVideo(from: movie.url, to: job, context: context)
                    try? FileManager.default.removeItem(at: movie.url)
                }
            } else if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                addPhoto(image, to: job, context: context)
            }
        }
    }

    static func delete(_ media: JobMedia, context: ModelContext) {
        try? FileManager.default.removeItem(at: media.fileURL)
        context.delete(media)
        try? context.save()
    }

    /// Deletes files whose job was deleted (deleting a job removes its media records, not files).
    static func removeOrphanedFiles(context: ModelContext) {
        let known = Set(((try? context.fetch(FetchDescriptor<JobMedia>())) ?? []).map(\.fileName))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: MediaStorage.directory.path)) ?? []
        for file in files where !known.contains(file) {
            try? FileManager.default.removeItem(at: MediaStorage.directory.appendingPathComponent(file))
        }
    }

    private static func insert(_ media: JobMedia, job: Job, context: ModelContext) {
        context.insert(media)
        media.job = job
        try? context.save()
    }

    private static func shrink(_ image: UIImage, maxSide: CGFloat = 1600) -> Data? {
        let longest = max(image.size.width, image.size.height)
        let scale = longest > maxSide ? maxSide / longest : 1
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: 0.7)
    }
}

/// A video from the Photos picker, copied to a temporary file.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

/// The camera, for taking a photo or a short video right at the job.
struct CameraPicker: UIViewControllerRepresentable {
    let onPhoto: (UIImage) -> Void
    let onVideo: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
        picker.videoQuality = .typeMedium
        picker.videoMaximumDuration = 120
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let url = info[.mediaURL] as? URL {
                parent.onVideo(url)
            } else if let image = info[.originalImage] as? UIImage {
                parent.onPhoto(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
