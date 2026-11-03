import SwiftUI

struct ContentView: View {
    @StateObject private var camera = Camera()
    @State private var showInfo = false
    @Environment(\.scenePhase) private var phase

    var body: some View {
        ZStack {
            GeometryReader { geo in
                let side = Self.finderSide(geo.size)
                ZStack {
                    CameraPreview(session: camera.session)
                    Finder(side: side, paused: camera.paused)
                }
                .onAppear { camera.setViewport(geo.size, finder: side) }
                .onChange(of: geo.size) { _, size in camera.setViewport(size, finder: Self.finderSide(size)) }
            }
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { camera.togglePause() }

            VStack {
                header
                Spacer()
                if camera.status == .running {
                    ResultCard(predictions: camera.predictions, milliseconds: camera.milliseconds)
                }
            }
            .padding()

            if camera.status != .running && camera.status != .starting {
                StatusView(status: camera.status)
            }
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .task { camera.start() }
        .onChange(of: phase) { _, phase in
            if phase == .active { camera.start() } else if phase == .background { camera.stop() }
        }
        .sheet(isPresented: $showInfo) {
            InfoView(labels: camera.labels)
        }
    }

    private var header: some View {
        HStack {
            Text("minnet")
                .font(.system(.headline, design: .monospaced))
            if camera.paused {
                Text("PAUSED")
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.yellow, in: Capsule())
                    .foregroundStyle(.black)
            }
            Spacer()
            Button {
                showInfo = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.title2)
            }
        }
        .foregroundStyle(.white)
    }

    static func finderSide(_ size: CGSize) -> CGFloat {
        min(size.width, size.height) * 0.78
    }
}

struct Finder: View {
    let side: CGFloat
    let paused: Bool

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.45))
            RoundedRectangle(cornerRadius: 28)
                .frame(width: side, height: side)
                .blendMode(.destinationOut)
        }
        .compositingGroup()
        .overlay {
            RoundedRectangle(cornerRadius: 28)
                .stroke(paused ? Color.yellow : Color.white.opacity(0.9), lineWidth: 3)
                .frame(width: side, height: side)
        }
        .allowsHitTesting(false)
    }
}

struct ResultCard: View {
    let predictions: [Prediction]
    let milliseconds: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let best = predictions.first {
                HStack(alignment: .firstTextBaseline) {
                    Text(best.confidence < 0.5 ? "\(best.label)?" : best.label)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Spacer()
                    Text(percent(best.confidence))
                        .font(.title2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ForEach(predictions) { p in
                    HStack(spacing: 10) {
                        Text(p.label)
                            .frame(width: 96, alignment: .leading)
                        ProgressView(value: Double(min(max(p.confidence, 0), 1)))
                            .tint(p == best ? .green : .gray)
                        Text(percent(p.confidence))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                    .font(.subheadline)
                }
                Text(String(format: "%.1f ms on device", milliseconds))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Point the camera at something")
                    .font(.title3)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private func percent(_ value: Float) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

struct StatusView: View {
    let status: Camera.Status

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 44))
            Text(message)
                .multilineTextAlignment(.center)
            if status == .denied {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .foregroundStyle(.white)
    }

    private var icon: String {
        switch status {
        case .denied: "camera.badge.ellipsis"
        case .unavailable: "video.slash"
        default: "exclamationmark.triangle"
        }
    }

    private var message: String {
        switch status {
        case .denied: "Camera access is off. Allow it in Settings to recognize objects."
        case .unavailable: "No camera available on this device."
        case .noModel: "The model file is missing from the app."
        default: ""
        }
    }
}

struct InfoView: View {
    let labels: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("What it knows") {
                    ForEach(labels, id: \.self) { Text($0) }
                }
                Section("How it works") {
                    Text("A convolutional neural network written from scratch in C and trained on CIFAR-10. The square in the middle of the screen is shrunk to 32×32 pixels and classified on your phone. Nothing leaves the device.")
                    Text("Tap the screen to freeze the result.")
                }
            }
            .navigationTitle("minnet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
