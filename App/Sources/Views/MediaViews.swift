import AVKit
import PhotosUI
import SwiftData
import SwiftUI

/// "Take photo or video" and "Add from Photos": the two ways Dad adds pictures of the work.
struct AddMediaButtons: View {
    let job: Job
    @Environment(\.modelContext) private var context
    @State private var showCamera = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var importing = false

    var body: some View {
        HStack(spacing: 12) {
            if CameraPicker.isAvailable {
                Button { showCamera = true } label: {
                    Label("Camera", systemImage: "camera.fill")
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity, minHeight: 64)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
            PhotosPicker(selection: $picked, maxSelectionCount: 20, matching: .any(of: [.images, .videos])) {
                Group {
                    if importing {
                        ProgressView().tint(.white)
                    } else {
                        Label("Photos", systemImage: "photo.on.rectangle")
                    }
                }
                .font(.title3.bold())
                .frame(maxWidth: .infinity, minHeight: 64)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(importing)
        }
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            importing = true
            Task {
                await MediaImporter.add(items, to: job, context: context)
                picked = []
                importing = false
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker(
                onPhoto: { MediaImporter.addPhoto($0, to: job, context: context) },
                onVideo: { url in
                    importing = true
                    Task {
                        await MediaImporter.addVideo(from: url, to: job, context: context)
                        importing = false
                    }
                }
            )
            .ignoresSafeArea()
        }
    }
}

/// Thumbnails of the job's photos and videos. Tap to view, hold to delete.
struct JobMediaSection: View {
    let job: Job
    let onOpen: (JobMedia) -> Void
    let onDelete: (JobMedia) -> Void

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]

    var body: some View {
        if !job.media.isEmpty {
            Section {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(job.sortedMedia) { media in
                        Button { onOpen(media) } label: { MediaThumbnail(media: media) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) { onDelete(media) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Photos and videos")
            } footer: {
                Text("These are attached to the invoice email. Press and hold one to delete it.")
            }
        }
    }
}

struct MediaThumbnail: View {
    let media: JobMedia
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color(.secondarySystemBackground))
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            }
            if media.isVideo {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
            }
        }
        .frame(height: 100)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task { image = await Self.thumbnail(for: media.fileURL, video: media.isVideo) }
    }

    static func thumbnail(for url: URL, video: Bool) async -> UIImage? {
        if video {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 300, height: 300)
            guard let cg = try? await generator.image(at: .zero).image else { return nil }
            return UIImage(cgImage: cg)
        }
        return await UIImage(contentsOfFile: url.path)?.byPreparingThumbnail(ofSize: CGSize(width: 300, height: 300))
    }
}

/// Full-screen photo or video.
struct MediaViewer: View {
    let media: JobMedia
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if media.isVideo {
                    VideoPlayer(player: AVPlayer(url: media.fileURL))
                } else if let image = UIImage(contentsOfFile: media.fileURL.path) {
                    Image(uiImage: image).resizable().scaledToFit()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.font(.title3.bold())
                }
            }
        }
    }
}
