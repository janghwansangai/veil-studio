import AppKit
import CoreImage
import CoreText

// Pure image operations shared by the photo renderer, the video compositor and tests.
final class MaskRenderer: @unchecked Sendable {
    let context = CIContext(options: [.cacheIntermediates: false])
    private let cache: NSCache<NSString, CIImage> = { let c = NSCache<NSString, CIImage>(); c.countLimit = 400; return c }()
    func shapeMask(_ shape: MaskShape) -> CIImage {
        let key = shape.rawValue as NSString
        if let image = cache.object(forKey:key) { return image }
        let n = 256.0
        guard let ctx = CGContext(data:nil,width:256,height:256,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return CIImage(color:.white).cropped(to:CGRect(x:0,y:0,width:256,height:256))
        }
        ctx.setFillColor(CGColor(gray:1,alpha:1)); let r = CGRect(x:0,y:0,width:n,height:n)
        switch shape {
        case .oval: ctx.fillEllipse(in:r)
        case .rectangle: ctx.fill(r)
        case .rounded: ctx.addPath(CGPath(roundedRect:r,cornerWidth:42,cornerHeight:42,transform:nil)); ctx.fillPath()
        case .heart:
            ctx.move(to:CGPoint(x:128,y:10)); ctx.addCurve(to:CGPoint(x:12,y:158),control1:CGPoint(x:25,y:90),control2:CGPoint(x:12,y:115))
            ctx.addCurve(to:CGPoint(x:128,y:203),control1:CGPoint(x:12,y:247),control2:CGPoint(x:90,y:267))
            ctx.addCurve(to:CGPoint(x:244,y:158),control1:CGPoint(x:166,y:267),control2:CGPoint(x:244,y:247))
            ctx.addCurve(to:CGPoint(x:128,y:10),control1:CGPoint(x:244,y:115),control2:CGPoint(x:230,y:90)); ctx.fillPath()
        case .star:
            for i in 0..<10 { let a = Double(i)*Double.pi/5+Double.pi/2; let radius = i%2 == 0 ? 127.0 : 65.0
                let p = CGPoint(x:128+cos(a)*radius,y:128+sin(a)*radius); if i == 0 { ctx.move(to:p) } else { ctx.addLine(to:p) } }; ctx.closePath(); ctx.fillPath()
        }
        guard let cg = ctx.makeImage() else { return CIImage(color:.white).cropped(to:r) }
        let image = CIImage(cgImage:cg); cache.setObject(image,forKey:key); return image
    }
    func textImage(_ text: String, width: Int, height: Int, fontSize: Double, background: Bool) -> CIImage? {
        let key = "\(text)|\(width)|\(height)|\(fontSize)|\(background)" as NSString
        if let image = cache.object(forKey:key) { return image }
        guard width > 0, height > 0, width <= 16384, height <= 16384, fontSize.isFinite, fontSize > 0,
              let ctx = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if background { ctx.setFillColor(CGColor(gray:0,alpha:0.72)); ctx.addPath(CGPath(roundedRect:CGRect(x:0,y:0,width:width,height:height),cornerWidth:Double(height)*0.1,cornerHeight:Double(height)*0.1,transform:nil)); ctx.fillPath() }
        let style = NSMutableParagraphStyle(); style.alignment = .center; style.lineBreakMode = .byWordWrapping
        let attributed = NSAttributedString(string:text,attributes:[.font:NSFont.systemFont(ofSize:fontSize,weight:.semibold),.foregroundColor:NSColor.white,.paragraphStyle:style])
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let padding = background ? fontSize*0.3 : 0
        let measured = CTFramesetterSuggestFrameSizeWithConstraints(setter,CFRange(location:0,length:0),nil,CGSize(width:max(1,Double(width)-padding*2),height:Double(height)),nil)
        let rect = CGRect(x:padding,y:max(0,(Double(height)-measured.height)/2),width:max(1,Double(width)-padding*2),height:min(Double(height),measured.height+4))
        CTFrameDraw(CTFramesetterCreateFrame(setter,CFRange(location:0,length:0),CGPath(rect:rect,transform:nil),nil),ctx)
        guard let cg = ctx.makeImage() else { return nil }; let image = CIImage(cgImage:cg); cache.setObject(image,forKey:key); return image
    }
    // Title text sized to its content; the result's origin is (0,0).
    func titleImage(_ title: TitleItem, frame: CGSize) -> CIImage? {
        let fontSize = max(8,min(frame.width,frame.height)*title.size)
        let key = "title|\(title.text)|\(fontSize)|\(title.red)|\(title.green)|\(title.blue)|\(title.bold)|\(title.background)|\(Int(frame.width))" as NSString
        if let image = cache.object(forKey:key) { return image }
        let style = NSMutableParagraphStyle(); style.alignment = .center; style.lineBreakMode = .byWordWrapping
        let color = NSColor(red:title.red,green:title.green,blue:title.blue,alpha:1)
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.55); shadow.shadowBlurRadius = fontSize*0.08; shadow.shadowOffset = NSSize(width:0,height:-fontSize*0.03)
        var attributes: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:fontSize,weight:title.bold ? .bold : .regular),.foregroundColor:color,.paragraphStyle:style]
        if !title.background { attributes[.shadow] = shadow }
        let attributed = NSAttributedString(string:title.text.isEmpty ? " " : title.text,attributes:attributes)
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let maxWidth = max(20,frame.width*0.92)
        let measured = CTFramesetterSuggestFrameSizeWithConstraints(setter,CFRange(location:0,length:0),nil,CGSize(width:maxWidth,height:CGFloat.greatestFiniteMagnitude),nil)
        let padding = fontSize*(title.background ? 0.45 : 0.15)
        let width = Int(ceil(min(maxWidth,measured.width)+padding*2)), height = Int(ceil(measured.height+padding*2))
        guard width > 0, height > 0, width <= 16384, height <= 16384,
              let ctx = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if title.background { ctx.setFillColor(CGColor(gray:0,alpha:0.6)); ctx.addPath(CGPath(roundedRect:CGRect(x:0,y:0,width:width,height:height),cornerWidth:fontSize*0.25,cornerHeight:fontSize*0.25,transform:nil)); ctx.fillPath() }
        CTFrameDraw(CTFramesetterCreateFrame(setter,CFRange(location:0,length:0),CGPath(rect:CGRect(x:padding,y:padding,width:Double(width)-padding*2,height:measured.height+1),transform:nil),nil),ctx)
        guard let cg = ctx.makeImage() else { return nil }; let image = CIImage(cgImage:cg); cache.setObject(image,forKey:key); return image
    }

    // Draws one mask of `design` into normalized rect `normal` of `image` (origin at 0,0).
    func applyMask(_ image: CIImage, normal: NormalRect, design d: MaskDesign) -> CIImage {
        let extent = image.extent
        let r = normal.scaled(to:extent.size).intersection(extent); guard r.width > 1, r.height > 1 else { return image }
        let mask = shapeMask(d.shape).transformed(by:CGAffineTransform(scaleX:r.width/256,y:r.height/256)).transformed(by:CGAffineTransform(translationX:r.minX,y:r.minY))
        var effect: CIImage
        switch d.effect {
        case .pixel: effect = image.clampedToExtent().applyingFilter("CIPixellate",parameters:[kCIInputScaleKey:max(6,min(r.width,r.height)*(0.07+d.strength*0.25)),kCIInputCenterKey:CIVector(x:r.midX,y:r.midY)])
        case .blur: effect = image.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:max(8,min(r.width,r.height)*(0.06+d.strength*0.22))])
        case .solid, .sticker: effect = CIImage(color:CIColor(red:d.red,green:d.green,blue:d.blue)).cropped(to:r)
        }
        if d.effect == .sticker, let emoji = textImage(d.sticker,width:256,height:256,fontSize:180,background:false) {
            let placed = emoji.transformed(by:CGAffineTransform(scaleX:r.width/256,y:r.height/256)).transformed(by:CGAffineTransform(translationX:r.minX,y:r.minY))
            effect = placed.composited(over:effect)
        }
        return effect.cropped(to:r).applyingFilter("CIBlendWithAlphaMask",parameters:[kCIInputBackgroundImageKey:image,kCIInputMaskImageKey:mask]).cropped(to:extent)
    }
    func faceRects(_ faces: [FaceTrack], time: Double, still: Bool, fps: Double, bridge: Double, hold: Double, margin: Double) -> [NormalRect] {
        faces.filter(\.selected).compactMap { $0.rect(at:time,still:still,tolerance:max(0.06,1.5/max(1,fps)),bridge:bridge,hold:hold)?.expanded(margin) }
    }
    func applyFaceMasks(_ image: CIImage, faces: [FaceTrack], time: Double, still: Bool, fps: Double, design: MaskDesign, bridge: Double, hold: Double) -> CIImage {
        var result = image
        for rect in faceRects(faces,time:time,still:still,fps:fps,bridge:bridge,hold:hold,margin:design.margin) { result = applyMask(result,normal:rect,design:design) }
        return result
    }
    func applyRegions(_ image: CIImage, project: Project, time: Double) -> CIImage {
        var result = image
        for region in project.regions.sorted(by:{($0.lane ?? 0) < ($1.lane ?? 0)}) where region.enabled && (project.isImage || (time >= region.start && time < region.end)) {
            result = applyMask(result,normal:region.rect(at:time),design:project.effectiveRegionDesign)
        }
        return result
    }
    func applyColor(_ image: CIImage, _ adjust: ColorAdjust?) -> CIImage {
        guard let c = adjust, !c.isIdentity else { return image }
        var out = image
        if c.exposure != 0 { out = out.applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:c.exposure]) }
        if c.brightness != 0 || c.contrast != 1 || c.saturation != 1 {
            out = out.applyingFilter("CIColorControls",parameters:[kCIInputBrightnessKey:c.brightness,kCIInputContrastKey:c.contrast,kCIInputSaturationKey:c.saturation])
        }
        if c.temperature != 0 || c.tint != 0 {
            // Positive temperature warms the picture, positive tint moves toward magenta.
            out = out.applyingFilter("CITemperatureAndTint",parameters:["inputNeutral":CIVector(x:6500,y:0),"inputTargetNeutral":CIVector(x:6500+c.temperature*3500,y:c.tint*60)])
        }
        return out.cropped(to:image.extent)
    }
    // Multiplies colour toward black (0 = black) without touching transparency.
    func dim(_ image: CIImage, _ amount: Double) -> CIImage {
        guard amount < 0.999 else { return image }
        return image.applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:log2(max(0.0005,amount))]).cropped(to:image.extent)
    }
    // Composites `layer` over `base` at the given opacity (premultiplication-safe).
    func composite(_ layer: CIImage, over base: CIImage, opacity: Double) -> CIImage {
        let over = layer.composited(over:base)
        guard opacity < 0.999 else { return over }
        guard opacity > 0.001 else { return base }
        return base.applyingFilter("CIDissolveTransition",parameters:[kCIInputTargetImageKey:over,kCIInputTimeKey:opacity]).cropped(to:base.extent)
    }
    func drawCaptions(_ image: CIImage, captions: [Caption], time: Double, sizeFraction: Double) -> CIImage {
        var image = image
        for c in captions.sorted(by:{($0.lane ?? 0) < ($1.lane ?? 0)}) where time >= c.start && time < c.end && !c.text.isEmpty {
            let s = image.extent.size; let font = max(12,min(s.width,s.height)*sizeFraction)
            let width = Int(s.width*max(0.1,min(1,c.boxWidth ?? 0.86))); let lineCount = max(1,min(5,Int(ceil(Double(c.text.count)*font*0.8/Double(max(1,width)))) + c.text.filter({$0 == "\n"}).count))
            if let text = textImage(c.text,width:width,height:Int(font*(Double(lineCount)*1.35+0.7)),fontSize:font,background:true) {
                image = text.transformed(by:CGAffineTransform(translationX:(s.width-Double(width))*max(0,min(1,c.horizontal ?? 0.5)),y:max(0,s.height-Double(text.extent.height))*max(0,min(1,c.vertical ?? (s.height*0.055/max(1,s.height-text.extent.height)))))).composited(over:image)
            }
        }
        return image
    }
    func drawTitles(_ image: CIImage, titles: [TitleItem], time: Double) -> CIImage {
        var image = image
        let s = image.extent.size
        for t in titles.sorted(by:{($0.lane ?? 0) < ($1.lane ?? 0)}) {
            let opacity = t.opacity(at:time); guard opacity > 0.001, let text = titleImage(t,frame:s) else { continue }
            let w = text.extent.width, h = text.extent.height
            let x = min(max(0,s.width-w),max(0,s.width*t.x-w/2)), y = min(max(0,s.height-h),max(0,s.height*t.y-h/2))
            image = composite(text.transformed(by:CGAffineTransform(translationX:x,y:y)),over:image,opacity:opacity)
        }
        return image
    }
    // Single-frame renderer used for photo projects and for single-source checks.
    // `time` is the source time for face masks; overlays use `overlayTime` on the timeline.
    func render(_ source: CIImage, project: Project, time: Double, crop: Bool, overlayTime: Double? = nil) -> CIImage {
        var image = source.transformed(by:CGAffineTransform(translationX:-source.extent.minX,y:-source.extent.minY))
        let extent = image.extent; let size = extent.size
        if !project.isImage && time < 0 { image = CIImage(color:.black).cropped(to:extent) }
        if project.maskApplied {
            image = applyFaceMasks(image,faces:project.faces,time:time,still:project.isImage,fps:project.fps,design:project.effectiveFaceDesign,bridge:project.faceBridge,hold:project.faceHold)
        }
        let overlayTime = project.overlaysOnTimeline == true ? (overlayTime ?? time) : time
        image = applyRegions(image,project:project,time:overlayTime)
        if crop {
            let rect = project.export.cropRect(size); let target = project.export.outputSize(size,even:!project.isImage)
            image = image.cropped(to:rect).transformed(by:CGAffineTransform(translationX:-rect.minX,y:-rect.minY)).transformed(by:CGAffineTransform(scaleX:target.width/rect.width,y:target.height/rect.height))
        }
        if project.export.burnCaptions { image = drawCaptions(image,captions:project.captions,time:overlayTime,sizeFraction:project.export.captionSize) }
        image = drawTitles(image,titles:project.titles,time:overlayTime)
        return image
    }
}

// AVFoundation's preferredTransform is expressed with a top-left origin; Core Image uses a
// bottom-left origin. Conjugating by a vertical flip gives the transform that shows a raw
// decoded frame upright in Core Image space, with the result's origin at (0,0).
func orientedTransform(_ t: CGAffineTransform, natural: CGSize) -> (transform: CGAffineTransform, size: CGSize) {
    let box = CGRect(origin:.zero,size:natural).applying(t)
    let size = CGSize(width:abs(box.width).rounded(),height:abs(box.height).rounded())
    let normalized = t.concatenating(CGAffineTransform(translationX:-box.minX,y:-box.minY))
    let flipIn = CGAffineTransform(a:1,b:0,c:0,d:-1,tx:0,ty:natural.height)
    let flipOut = CGAffineTransform(a:1,b:0,c:0,d:-1,tx:0,ty:size.height)
    return (flipIn.concatenating(normalized).concatenating(flipOut),size)
}

// Fits an oriented source frame (origin 0,0) into the canvas and applies the clip transform.
func placeLayer(_ image: CIImage, canvas: CGSize, transform t: ClipTransform?) -> CIImage {
    let s = image.extent.size
    guard s.width > 0, s.height > 0, canvas.width > 0, canvas.height > 0 else { return image }
    var img = image
    let t = t ?? ClipTransform()
    if t.cropLeft+t.cropRight+t.cropTop+t.cropBottom > 0 {
        let r = CGRect(x:s.width*t.cropLeft,y:s.height*t.cropBottom,width:s.width*max(0.05,1-t.cropLeft-t.cropRight),height:s.height*max(0.05,1-t.cropTop-t.cropBottom))
        img = img.cropped(to:r)
    }
    let base = t.fill ? max(canvas.width/s.width,canvas.height/s.height) : min(canvas.width/s.width,canvas.height/s.height)
    let k = base*t.scale
    let m = CGAffineTransform(translationX:-s.width/2,y:-s.height/2)
        .concatenating(CGAffineTransform(scaleX:k,y:k))
        .concatenating(CGAffineTransform(rotationAngle:-t.rotation*Double.pi/180))
        .concatenating(CGAffineTransform(translationX:canvas.width/2+t.x*canvas.width,y:canvas.height/2+t.y*canvas.height))
    if abs(k-1) < 0.0001, t.rotation == 0, abs(canvas.width-s.width) < 0.5, abs(canvas.height-s.height) < 0.5, t.x == 0, t.y == 0 { return img }
    return img.transformed(by:m).cropped(to:CGRect(origin:.zero,size:canvas))
}
