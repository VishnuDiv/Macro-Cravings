import SwiftUI
import PhotosUI
#if os(iOS)
import AVFoundation
import UIKit

/// Thumbnails and full images from the progress folder.
enum ProgressImage {
    static func thumbnail(_ url: URL, maxPixel: Int = 400) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary).map { UIImage(cgImage: $0) }
    }
}

/// Owns the AVFoundation session. Photos (and the hair / skin mattes, where the camera supports them) are returned as data and go nowhere else.
@MainActor @Observable
final class CameraController: NSObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private(set) var position: AVCaptureDevice.Position = .front
    private(set) var available = false
    private(set) var denied = false
    var onPhoto: ((Data, [String: Data]) -> Void)?

    func start() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined: if !(await AVCaptureDevice.requestAccess(for: .video)) { denied = true; return }
        default: denied = true; return
        }
        configure(position)
        let s = session
        Task.detached { if !s.isRunning { s.startRunning() } }
    }

    func stop() { let s = session; Task.detached { if s.isRunning { s.stopRunning() } } }

    private func configure(_ pos: AVCaptureDevice.Position) {
        session.beginConfiguration()
        session.sessionPreset = .photo
        session.inputs.forEach { session.removeInput($0) }
        if let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: pos), let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) {
            session.addInput(input); position = pos; available = true
        } else { available = false }
        if !session.outputs.contains(output), session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        // Hair / skin segmentation mattes only where the connected camera offers them; otherwise the photo is measured with the Vision fallback.
        output.enabledSemanticSegmentationMatteTypes = MatteExport.types.filter { output.availableSemanticSegmentationMatteTypes.contains($0) }
    }

    func flip() { configure(position == .front ? .back : .front) }

    func capture() {
        guard available else { return }
        let settings = AVCapturePhotoSettings()
        settings.enabledSemanticSegmentationMatteTypes = output.enabledSemanticSegmentationMatteTypes
        output.capturePhoto(with: settings, delegate: self)
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        var mattes: [String: Data] = [:]
        for t in MatteExport.types { if let png = MatteExport.png(from: photo, type: t) { mattes[MatteExport.kind(t)] = png } }
        Task { @MainActor in self.onPhoto?(data, mattes) }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var layerRef: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView(); v.layerRef.session = session; v.layerRef.videoGravity = .resizeAspectFill; return v
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

/// Camera with a ghost of the previous photo, center and eye-line guides, front/back toggle and a 3 second timer.
struct CaptureView: View {
    let series: PhotoSeries
    @Environment(UserStore.self) private var user
    @Environment(ProgressLibrary.self) private var lib
    @Environment(\.dismiss) private var dismiss
    @State private var camera = CameraController()
    @State private var ghostOpacity = 0.35
    @State private var timerOn = false
    @State private var countdown: Int?
    @State private var captured: CapturedPhoto?
    @State private var picked: PhotosPickerItem?

    private var ghost: UIImage? { lib.entries(series).last.flatMap { ProgressImage.thumbnail(lib.store.photoURL($0), maxPixel: 1400) } }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if camera.available {
                CameraPreview(session: camera.session).ignoresSafeArea()
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "camera.slash").font(.largeTitle)
                    Text(camera.denied ? "Camera access is off. Turn it on in Settings, or import a photo." : "No camera here. Import a photo instead.")
                        .multilineTextAlignment(.center).padding(.horizontal, 30)
                }
                .foregroundStyle(.white)
            }
            if let g = ghost {
                Image(uiImage: g).resizable().scaledToFill().ignoresSafeArea().opacity(ghostOpacity)
                    .scaleEffect(x: camera.position == .front && camera.available ? -1 : 1, y: 1).allowsHitTesting(false)
            }
            guides
            if let c = countdown { Text("\(c)").font(.system(size: 120, weight: .bold)).foregroundStyle(.white).shadow(radius: 8) }
            VStack {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title) }
                    Spacer()
                    Text(series.title).font(.headline)
                    Spacer()
                    Button { camera.flip() } label: { Image(systemName: "camera.rotate").font(.title2) }.disabled(!camera.available)
                }
                .padding().foregroundStyle(.white)
                Text(series.tip + " Use the same light each time.").font(.footnote).foregroundStyle(.white).padding(8)
                    .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 8)).padding(.horizontal)
                Spacer()
                if ghost != nil {
                    HStack { Image(systemName: "square.on.square").foregroundStyle(.white); Slider(value: $ghostOpacity, in: 0...0.8) }.padding(.horizontal, 30)
                }
                HStack(spacing: 36) {
                    PhotosPicker(selection: $picked, matching: .images) { Image(systemName: "photo.on.rectangle").font(.title).frame(width: 52, height: 52) }
                    Button { shoot() } label: {
                        Circle().strokeBorder(.white, lineWidth: 4).background(Circle().fill(.white.opacity(0.85)).padding(6)).frame(width: 72, height: 72)
                    }
                    .disabled(!camera.available || countdown != nil)
                    Button { timerOn.toggle() } label: {
                        Image(systemName: timerOn ? "timer.circle.fill" : "timer").font(.title).frame(width: 52, height: 52)
                    }
                }
                .foregroundStyle(.white).padding(.bottom, 24)
            }
        }
        .task {
            camera.onPhoto = { captured = CapturedPhoto(data: $0, mattes: $1) }
            await camera.start()
        }
        .onDisappear { camera.stop() }
        .onChange(of: picked) { _, item in
            Task { if let d = try? await item?.loadTransferable(type: Data.self) { captured = CapturedPhoto(data: d) } }
        }
        .sheet(item: $captured) { p in
            EntryEditorSheet(series: series, jpeg: p.data, mattes: p.mattes) { saved in
                captured = nil
                if saved { dismiss() }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var guides: some View {
        GeometryReader { g in
            Path { p in
                p.move(to: CGPoint(x: g.size.width / 2, y: 0)); p.addLine(to: CGPoint(x: g.size.width / 2, y: g.size.height))
                if series.isSkin { p.move(to: CGPoint(x: 0, y: g.size.height * 0.4)); p.addLine(to: CGPoint(x: g.size.width, y: g.size.height * 0.4)) }
            }
            .stroke(.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
        }
        .ignoresSafeArea().allowsHitTesting(false)
    }

    private func shoot() {
        guard timerOn else { camera.capture(); return }
        Task {
            for n in stride(from: 3, through: 1, by: -1) { countdown = n; try? await Task.sleep(for: .seconds(1)) }
            countdown = nil
            camera.capture()
        }
    }
}

struct CapturedPhoto: Identifiable { let id = UUID(); let data: Data; var mattes: [String: Data] = [:] }

/// Date, note and quick ratings for a new photo; saving writes it to the progress folder.
struct EntryEditorSheet: View {
    let series: PhotoSeries
    let jpeg: Data
    var mattes: [String: Data] = [:]
    let done: (Bool) -> Void
    @Environment(RecipeStore.self) private var store
    @Environment(UserStore.self) private var user
    @Environment(ProgressLibrary.self) private var lib
    @State private var date = Date()
    @State private var note = ""
    @State private var ratings: [String: Int] = [:]

    var body: some View {
        NavigationStack {
            Form {
                if let img = UIImage(data: jpeg) {
                    Section { Image(uiImage: img).resizable().scaledToFit().frame(maxHeight: 260).frame(maxWidth: .infinity) }
                }
                Section { DatePicker("Date", selection: $date, in: ...Date(), displayedComponents: .date); TextField("Note (optional)", text: $note, axis: .vertical) }
                if series.isSkin {
                    Section("How is your skin today? (0 none, 5 a lot)") {
                        ForEach(["breakouts", "redness", "oiliness"], id: \.self) { k in
                            Stepper("\(k.capitalized): \(ratings[k] ?? 0)", value: Binding(get: { ratings[k] ?? 0 }, set: { ratings[k] = $0 }), in: 0...5)
                        }
                    }
                } else {
                    Section("Shedding today") {
                        Picker("Shedding", selection: Binding(get: { ratings["shedding"] ?? 0 }, set: { ratings["shedding"] = $0 })) {
                            Text("Low").tag(0); Text("Medium").tag(1); Text("High").tag(2)
                        }.pickerStyle(.segmented)
                    }
                }
                Section { Text("Saved only on this phone.").font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("Save photo").inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Discard") { done(false) } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
        }
    }

    private func save() {
        let jpg = UIImage(data: jpeg).flatMap { $0.jpegData(compressionQuality: 0.9) } ?? jpeg
        let adherence = Adherence.score(user.data, on: date, content: store.catalog.skincare)
        let e = ProgressEntry(series: series, date: date, note: note, ratings: ratings, adherence: adherence)
        if let saved = lib.save(jpeg: jpg, entry: e, mattes: mattes, backup: user.data.progressInBackup) { lib.analyze(saved) }
        Task { await lib.rearmReminders(user) }
        done(true)
    }
}
#endif
