import SwiftUI
import UIKit

struct Chip: View {
    let text: String
    var systemImage: String?
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption2.weight(.medium))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .foregroundStyle(color)
        .background(color.opacity(0.12), in: Capsule())
    }
}

struct FitBadge: View {
    let report: FitReport

    var body: some View {
        Chip(text: label, systemImage: icon, color: color)
    }

    private var label: String {
        switch report.level {
        case .good: "Runs well"
        case .tight: "Tight fit"
        case .tooBig: "Too big"
        case .unsupported: "Unsupported"
        case .notChat: "Not a chat model"
        }
    }

    private var icon: String {
        switch report.level {
        case .good: "checkmark.circle.fill"
        case .tight: "exclamationmark.circle.fill"
        case .tooBig: "xmark.circle.fill"
        case .unsupported, .notChat: "nosign"
        }
    }

    private var color: Color {
        switch report.level {
        case .good: .green
        case .tight: .orange
        case .tooBig: .red
        case .unsupported, .notChat: .gray
        }
    }
}

struct SpeedLabel: View {
    let report: FitReport

    var body: some View {
        if let tps = report.tokensPerSecond, report.level == .good || report.level == .tight {
            Text("~\(Int(tps.rounded())) tok/s")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

struct AttachmentThumbnail: View {
    let attachment: Attachment
    var size: CGFloat = 64
    var onRemove: (() -> Void)?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if attachment.kind == .image, let url = attachment.fileURL, let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: "doc.text")
                            .font(.title3)
                        Text(attachment.name)
                            .font(.caption2)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    .padding(6)
                    .frame(width: size * 1.5, height: size)
                    .background(Color.secondary.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .offset(x: 6, y: -6)
            }
        }
    }
}
