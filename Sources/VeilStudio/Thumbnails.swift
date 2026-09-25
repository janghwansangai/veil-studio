import AVFoundation
import AppKit
import ImageIO

// Filmstrip and poster frames, generated on demand (newest request first) and kept in a
// bounded cache so long timelines do not grow memory.
@MainActor final class ThumbnailCache {
    private var images: [String:CGImage] = [:]
    private var order: [String] = []
    private var pending: [(source: MediaSource, key: String, time: Double, tolerance: Double)] = []
    private var queued = Set<String>()
    private var generators: [UUID:AVAssetImageGenerator] = [:]
    private var failed = Set<UUID>()
    private var worker: Task<Void,Never>?
    private var generation = 0
    var onUpdate: (() -> Void)?
    private let limit = 900
    func reset() { generation += 1; worker?.cancel(); worker = nil; images = [:]; order = []; pending = []; queued = []; generators = [:]; failed = [] }
    // Seconds per thumbnail rounded to a power of two, so zooming reuses cached frames.
    static func step(for seconds: Double) -> Double { pow(2,(log2(max(0.05,seconds))).rounded(.up)) }
    func frame(_ source: MediaSource, at time: Double, step: Double) -> CGImage? {
        let bucket = Int(max(0,time)/step)
        let key = "\(source.id)|\(step)|\(bucket)"
        return lookup(key) ?? { request(source,key:key,time:min(max(0,source.duration-0.05),(Double(bucket)+0.5)*step),tolerance:step/2); return nil }()
    }
    func poster(_ source: MediaSource) -> CGImage? {
        let key = "\(source.id)|poster"
        return lookup(key) ?? { request(source,key:key,time:min(1,source.duration/2),tolerance:0.5); return nil }()
    }
    private func lookup(_ key: String) -> CGImage? { images[key] }
    private func request(_ source: MediaSource, key: String, time: Double, tolerance: Double) {
        guard !failed.contains(source.id), !queued.contains(key), source.isVisual else { return }
        queued.insert(key); pending.append((source,key,time,tolerance))
        if pending.count > 240 { let dropped = pending.removeFirst(); queued.remove(dropped.key) }
        if worker == nil { start() }
    }
    private func start() {
        let token = generation
        worker = Task { [weak self] in
            var lastNotify = Date.distantPast
            while let self, token == self.generation, let job = self.pending.popLast() {
                self.queued.remove(job.key)
                if let image = await self.render(job.source,time:job.time,tolerance:job.tolerance), token == self.generation {
                    self.store(job.key,image)
                    if Date().timeIntervalSince(lastNotify) > 0.15 { lastNotify = Date(); self.onUpdate?() }
                }
            }
            guard let self, token == self.generation else { return }
            self.worker = nil; self.onUpdate?()
        }
    }
    private func store(_ key: String, _ image: CGImage) {
        images[key] = image; order.append(key)
        while order.count > limit { images.removeValue(forKey:order.removeFirst()) }
    }
    private func render(_ source: MediaSource, time: Double, tolerance: Double) async -> CGImage? {
        guard FileManager.default.fileExists(atPath:source.path) else { failed.insert(source.id); return nil }
        if source.isImage {
            return await Task.detached {
                guard let s = CGImageSourceCreateWithURL(URL(fileURLWithPath:source.path) as CFURL,nil) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(s,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:240,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary)
            }.value
        }
        let generator = generators[source.id] ?? {
            let g = AVAssetImageGenerator(asset:AVURLAsset(url:URL(fileURLWithPath:source.path)))
            g.appliesPreferredTrackTransform = true; g.maximumSize = CGSize(width:240,height:240)
            generators[source.id] = g; return g
        }()
        generator.requestedTimeToleranceBefore = CMTime(seconds:tolerance,preferredTimescale:600)
        generator.requestedTimeToleranceAfter = CMTime(seconds:tolerance,preferredTimescale:600)
        do { return try await generator.image(at:CMTime(seconds:time,preferredTimescale:600)).image }
        catch { return nil }
    }
}
