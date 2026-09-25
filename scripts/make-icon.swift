import AppKit
import ImageIO
import UniformTypeIdentifiers
import Foundation

let folder = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".build/Veil.iconset")
try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
for (name,size) in [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024)] {
    let ctx = CGContext(data:nil,width:size,height:size,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x:Double(size)/1024,y:Double(size)/1024)
    let frame = CGRect(x:55,y:55,width:914,height:914)
    ctx.setShadow(offset:CGSize(width:0,height:-8),blur:30,color:CGColor(gray:0,alpha:0.25))
    ctx.setFillColor(CGColor(red:0.075,green:0.085,blue:0.11,alpha:1)); ctx.addPath(CGPath(roundedRect:frame,cornerWidth:205,cornerHeight:205,transform:nil)); ctx.fillPath(); ctx.setShadow(offset:.zero,blur:0,color:nil)
    ctx.setStrokeColor(CGColor(gray:1,alpha:0.08)); ctx.setLineWidth(4); ctx.addPath(CGPath(roundedRect:frame.insetBy(dx:2,dy:2),cornerWidth:203,cornerHeight:203,transform:nil)); ctx.strokePath()
    for i in 0..<7 {
        let a = Double(i)*Double.pi/3
        let x = i == 6 ? 512 : 512+cos(a)*226
        let y = i == 6 ? 512 : 512+sin(a)*226
        ctx.setFillColor(i == 1 ? CGColor(red:0.70,green:0.62,blue:1,alpha:1) : CGColor(red:0.73,green:0.92,blue:0.61,alpha:i == 6 ? 0.95 : 0.84))
        ctx.fillEllipse(in:CGRect(x:x-102,y:y-102,width:204,height:204))
    }
    let url = folder.appendingPathComponent(name+".png")
    let destination = CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil)!
    CGImageDestinationAddImage(destination,ctx.makeImage()!,nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Icon export failed") }
}
// ICNS supports PNG payloads. Write the container directly, avoiding iconutil's
// dependency on graphics services in restricted build environments.
func be32(_ value: Int) -> Data { var word = UInt32(value).bigEndian; return withUnsafeBytes(of:&word) { Data($0) } }
var chunks = Data()
for (type,name) in [("icp4","icon_16x16"),("icp5","icon_32x32"),("icp6","icon_32x32@2x"),("ic07","icon_128x128"),("ic08","icon_256x256"),("ic09","icon_512x512"),("ic10","icon_512x512@2x"),("ic11","icon_16x16@2x"),("ic12","icon_32x32@2x"),("ic13","icon_128x128@2x"),("ic14","icon_256x256@2x")] {
    let png = try Data(contentsOf:folder.appendingPathComponent(name+".png"))
    chunks.append(Data(type.utf8)); chunks.append(be32(png.count+8)); chunks.append(png)
}
var icon = Data("icns".utf8); icon.append(be32(chunks.count+8)); icon.append(chunks)
try icon.write(to:folder.deletingLastPathComponent().appendingPathComponent("Veil.icns"))
