// fconv — batch image converter for macOS, built on ImageIO (no dependencies).
//
//   fconv png *.heic              convert, output lands next to each source
//   fconv jpg -q 85 -r ~/shoot    whole folder tree
//   fconv *.png                   no format given -> asks in the terminal
//   fconv --pick <files>          GUI format picker (used by the Finder Quick Action)

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Formats

struct Format {
    let name: String  // canonical name, also the default output extension
    let aliases: [String]
    let uti: String
    let label: String
    let alpha: Bool  // can store transparency
    let multi: Bool  // can store several frames/pages in one file
    var maxDim: Int? = nil  // hard pixel cap imposed by the format
}

let allFormats: [Format] = [
    Format(name: "png", aliases: [], uti: "public.png", label: "PNG", alpha: true, multi: false),
    Format(name: "jpg", aliases: ["jpeg"], uti: "public.jpeg", label: "JPEG", alpha: false, multi: false),
    Format(name: "heic", aliases: [], uti: "public.heic", label: "HEIC", alpha: true, multi: false),
    Format(name: "tiff", aliases: ["tif"], uti: "public.tiff", label: "TIFF", alpha: true, multi: true),
    Format(name: "gif", aliases: [], uti: "com.compuserve.gif", label: "GIF", alpha: true, multi: true),
    Format(name: "bmp", aliases: [], uti: "com.microsoft.bmp", label: "BMP", alpha: false, multi: false),
    Format(name: "pdf", aliases: [], uti: "com.adobe.pdf", label: "PDF", alpha: true, multi: true),
    Format(name: "avif", aliases: [], uti: "public.avif", label: "AVIF", alpha: true, multi: false),
    Format(name: "webp", aliases: [], uti: "org.webmproject.webp", label: "WebP", alpha: true, multi: false),
    Format(name: "jp2", aliases: [], uti: "public.jpeg-2000", label: "JPEG 2000", alpha: true, multi: false),
    Format(name: "ico", aliases: [], uti: "com.microsoft.ico", label: "ICO", alpha: true, multi: false, maxDim: 256),
]

/// What this macOS can actually encode. WebP, for one, is read-only in ImageIO.
let writableUTIs = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
let writableFormats = allFormats.filter { writableUTIs.contains($0.uti) }

func lookupFormat(_ token: String) -> Format? {
    let t = token.lowercased()
    return allFormats.first { $0.name == t || $0.aliases.contains(t) }
}

// MARK: - Options / errors

struct Options {
    var quality = 0.9
    var outDir: URL?
    var recursive = false
    var maxSize: Int?
    var force = false
    var trash = false
    var strip = false
    var dpi = 144.0
    var pick = false
}

struct Fail: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

func die(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("fconv: \(message)\n".utf8))
    exit(code)
}

let usage = """
    fconv — batch image converter

    USAGE
      fconv <format> [options] <files or folders>...
      fconv [options] <files or folders>...      (asks which format)
      fconv --pick <files or folders>...         (GUI picker, for Finder)

    FORMATS
      \(writableFormats.map(\.name).joined(separator: ", "))
      Reads anything macOS can open (HEIC, PNG, JPEG, WebP, AVIF, RAW, PSD, ...) plus PDF.

    OPTIONS
      -q, --quality N    lossy quality 1-100 for jpg/heic/avif (default 90)
      -o, --out DIR      write into DIR instead of next to each source
      -r, --recursive    descend into subfolders
      -m, --max N        shrink so the longest side is at most N pixels
      -f, --force        overwrite existing files (default: add -1, -2, ...)
          --trash        move originals to the Trash once converted
          --strip        drop metadata (EXIF, GPS)
          --dpi N        resolution for rendering PDF pages (default 144)
      -l, --formats      list writable formats
      -h, --help

    Output keeps the source name and swaps the extension: IMG_1.HEIC -> IMG_1.png
    """

// MARK: - Input collection

func isPDF(_ url: URL) -> Bool { url.pathExtension.lowercased() == "pdf" }

func looksConvertible(_ url: URL) -> Bool {
    guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
    return type.conforms(to: .image) || type.conforms(to: .pdf)
}

/// Expands folders into the images inside them. Explicitly named files are
/// always taken unless `filterExplicit` (Finder selections can be mixed).
func collectInputs(_ paths: [String], recursive: Bool, filterExplicit: Bool, excluding outDir: URL?) -> (
    files: [URL], missing: [String]
) {
    let fm = FileManager.default
    var files: [URL] = []
    var missing: [String] = []
    var seen = Set<String>()
    // Don't re-convert earlier output when --out sits inside a scanned folder.
    let excluded = outDir.map { $0.standardizedFileURL.path + "/" }

    func add(_ url: URL) {
        let key = url.standardizedFileURL.path
        if seen.insert(key).inserted { files.append(url.standardizedFileURL) }
    }

    for path in paths {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            missing.append(path)
            continue
        }
        guard isDir.boolValue else {
            if !filterExplicit || looksConvertible(url) { add(url) }
            continue
        }
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        if !recursive { options.insert(.skipsSubdirectoryDescendants) }
        let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: options)
        var found: [URL] = []
        while let item = walker?.nextObject() as? URL {
            let regular = (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            if let excluded, item.standardizedFileURL.path.hasPrefix(excluded) { continue }
            if regular && looksConvertible(item) { found.append(item) }
        }
        found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }.forEach(add)
    }
    return (files, missing)
}

// MARK: - Planning

enum Frame {
    case all  // every frame/page into one multi-frame file
    case best  // the single most useful frame of an image
    case page(Int)  // one zero-based PDF page
}

struct Job {
    let src: URL
    let out: URL
    let frame: Frame
}

struct Plan {
    var jobs: [Job] = []
    var skipped: [(URL, String)] = []
    var failed: [(URL, String)] = []
}

func makePlan(files: [URL], fmt: Format, ext: String, opts: Options) -> Plan {
    let fm = FileManager.default
    var plan = Plan()
    var claimed = Set<String>()  // outputs taken by earlier jobs in this run

    /// Picks the output path; never collides with another job, and never with
    /// an existing file unless --force.
    func output(for src: URL, suffix: String) -> URL {
        let dir = opts.outDir ?? src.deletingLastPathComponent()
        let base = src.deletingPathExtension().lastPathComponent + suffix
        var candidate = dir.appendingPathComponent("\(base).\(ext)")
        var n = 1
        while claimed.contains(candidate.path.lowercased())
            || (!opts.force && fm.fileExists(atPath: candidate.path))
        {
            candidate = dir.appendingPathComponent("\(base)-\(n).\(ext)")
            n += 1
        }
        claimed.insert(candidate.path.lowercased())
        return candidate
    }

    let rewrites = opts.maxSize != nil || opts.strip  // same-format runs still do something

    for src in files {
        if isPDF(src) {
            if fmt.name == "pdf" {
                plan.skipped.append((src, "already PDF"))
                continue
            }
            guard let doc = CGPDFDocument(src as CFURL) else {
                plan.failed.append((src, "not a readable PDF"))
                continue
            }
            if doc.isEncrypted && !doc.unlockWithPassword("") {
                plan.failed.append((src, "PDF is password-protected"))
                continue
            }
            let pages = doc.numberOfPages
            if pages < 1 {
                plan.failed.append((src, "PDF has no pages"))
            } else if fmt.multi {
                plan.jobs.append(Job(src: src, out: output(for: src, suffix: ""), frame: .all))
            } else if pages == 1 {
                plan.jobs.append(Job(src: src, out: output(for: src, suffix: ""), frame: .page(0)))
            } else {
                let width = String(pages).count
                for p in 0..<pages {
                    let num = String(repeating: "0", count: width - String(p + 1).count) + String(p + 1)
                    plan.jobs.append(Job(src: src, out: output(for: src, suffix: "-\(num)"), frame: .page(p)))
                }
            }
            continue
        }

        if !rewrites, UTType(filenameExtension: src.pathExtension)?.identifier == fmt.uti {
            plan.skipped.append((src, "already \(fmt.label)"))
            continue
        }
        plan.jobs.append(Job(src: src, out: output(for: src, suffix: ""), frame: fmt.multi ? .all : .best))
    }
    return plan
}

// MARK: - Conversion

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func hasAlpha(_ image: CGImage) -> Bool {
    switch image.alphaInfo {
    case .none, .noneSkipFirst, .noneSkipLast: return false
    default: return true
    }
}

/// Composites onto white for formats that cannot store transparency.
func flatten(_ image: CGImage) throws -> CGImage {
    func context(_ space: CGColorSpace) -> CGContext? {
        CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    }
    // Keep the source's colour space (e.g. Display P3) when it can be drawn into.
    let preferred = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
    guard let ctx = preferred.flatMap(context) ?? context(sRGB) else { throw Fail("could not allocate bitmap") }
    let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    ctx.fill(rect)
    ctx.draw(image, in: rect)
    guard let flat = ctx.makeImage() else { throw Fail("could not flatten transparency") }
    return flat
}

func renderPDFPage(_ doc: CGPDFDocument, index: Int, opts: Options, cap: Int?) throws -> CGImage {
    guard let page = doc.page(at: index + 1) else { throw Fail("missing PDF page \(index + 1)") }
    var size = page.getBoxRect(.cropBox).size
    if page.rotationAngle % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
    guard size.width > 0, size.height > 0 else { throw Fail("PDF page \(index + 1) is empty") }

    var scale = CGFloat(opts.dpi / 72)
    if let cap { scale = min(scale, CGFloat(cap) / max(size.width, size.height)) }
    let width = max(1, Int((size.width * scale).rounded()))
    let height = max(1, Int((size.height * scale).rounded()))

    guard
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { throw Fail("could not allocate bitmap") }
    ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.interpolationQuality = .high
    // getDrawingTransform never scales up, so scale the context ourselves and
    // let the transform handle only rotation and the crop-box offset.
    ctx.scaleBy(x: scale, y: scale)
    ctx.concatenate(
        page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
    ctx.drawPDFPage(page)
    guard let image = ctx.makeImage() else { throw Fail("could not render PDF page \(index + 1)") }
    return image
}

/// Animation frame duration, whichever container it came from.
func frameDelay(_ props: [String: Any]) -> Double? {
    let sources: [(CFString, CFString, CFString)] = [
        (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
        (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
        (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
        (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime),
    ]
    for (dict, unclamped, clamped) in sources {
        guard let d = props[dict as String] as? [String: Any] else { continue }
        for key in [unclamped, clamped] {
            if let v = (d[key as String] as? NSNumber)?.doubleValue, v > 0 { return v }
        }
    }
    return nil
}

func pixelSize(_ src: CGImageSource, _ index: Int) -> (Int, Int) {
    let props = (CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [String: Any]) ?? [:]
    let w = (props[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue ?? 0
    let h = (props[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue ?? 0
    return (w, h)
}

/// Icon files hold many sizes; frame 0 is often the smallest. Take the largest.
func bestFrame(_ src: CGImageSource) -> Int {
    let count = CGImageSourceGetCount(src)
    let type = (CGImageSourceGetType(src) as String?) ?? ""
    guard count > 1, type == "com.apple.icns" || type == "com.microsoft.ico" else { return 0 }
    return (0..<count).max { a, b in
        let (aw, ah) = pixelSize(src, a)
        let (bw, bh) = pixelSize(src, b)
        return aw * ah < bw * bh
    } ?? 0
}

func addImageFrame(
    _ dest: CGImageDestination, from src: CGImageSource, index: Int, fmt: Format, opts: Options, animated: Bool
) throws {
    let props = (CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [String: Any]) ?? [:]
    var (w, h) = pixelSize(src, index)
    let orientation = (props[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
    let srcAlpha = (props[kCGImagePropertyHasAlpha as String] as? Bool) ?? false

    var extra: [String: Any] = [kCGImageDestinationLossyCompressionQuality as String: opts.quality]
    if animated && fmt.name == "gif" {
        let delay = frameDelay(props) ?? 0.1
        extra[kCGImagePropertyGIFDictionary as String] = [
            kCGImagePropertyGIFDelayTime as String: delay,
            kCGImagePropertyGIFUnclampedDelayTime as String: delay,
        ]
    }

    let cap = [opts.maxSize, fmt.maxDim].compactMap { $0 }.min()
    let resize = cap.map { max(w, h) > $0 || max(w, h) == 0 } ?? false
    let rotate = orientation != 1  // bake rotation in: many viewers ignore the tag outside JPEG
    let redraw = resize || rotate || opts.strip || (srcAlpha && !fmt.alpha)

    if !redraw {
        // Fast path: ImageIO transcodes straight from the source, metadata intact.
        CGImageDestinationAddImageFromSource(dest, src, index, extra as CFDictionary)
        return
    }

    var image: CGImage
    if resize || rotate {
        if w == 0 || h == 0, let probe = CGImageSourceCreateImageAtIndex(src, index, nil) {
            (w, h) = (probe.width, probe.height)
        }
        let target = min(cap ?? Int.max, max(w, h))
        let thumb: [String: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways as String: true,
            kCGImageSourceCreateThumbnailWithTransform as String: true,
            kCGImageSourceThumbnailMaxPixelSize as String: target,
        ]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(src, index, thumb as CFDictionary) else {
            throw Fail("could not decode image")
        }
        image = scaled
    } else {
        guard let full = CGImageSourceCreateImageAtIndex(src, index, nil) else { throw Fail("could not decode image") }
        image = full
    }
    if !fmt.alpha && hasAlpha(image) { image = try flatten(image) }

    var out: [String: Any] = opts.strip ? [:] : props
    if !opts.strip {
        // Pixels are now upright and possibly resized; drop the stale geometry.
        out[kCGImagePropertyOrientation as String] = 1
        out.removeValue(forKey: kCGImagePropertyPixelWidth as String)
        out.removeValue(forKey: kCGImagePropertyPixelHeight as String)
        if var tiff = out[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            out[kCGImagePropertyTIFFDictionary as String] = tiff
        }
    }
    out.merge(extra) { _, new in new }
    CGImageDestinationAddImage(dest, image, out as CFDictionary)
}

func convert(_ job: Job, fmt: Format, opts: Options) throws {
    let fm = FileManager.default
    let dir = job.out.deletingLastPathComponent()
    // Encode to a hidden temp file, then move into place: no half-written outputs.
    let tmp = dir.appendingPathComponent(".fconv-\(UUID().uuidString).tmp")
    defer { try? fm.removeItem(at: tmp) }

    func destination(frames: Int) throws -> CGImageDestination {
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, fmt.uti as CFString, frames, nil) else {
            throw Fail("cannot write \(fmt.label) into \(dir.path)")
        }
        return dest
    }

    let dest: CGImageDestination
    if isPDF(job.src) {
        guard let doc = CGPDFDocument(job.src as CFURL) else { throw Fail("not a readable PDF") }
        if doc.isEncrypted { _ = doc.unlockWithPassword("") }
        let pages: [Int]
        switch job.frame {
        case .page(let p): pages = [p]
        default: pages = Array(0..<doc.numberOfPages)
        }
        dest = try destination(frames: pages.count)
        let cap = [opts.maxSize, fmt.maxDim].compactMap { $0 }.min()
        var props: [String: Any] = [kCGImageDestinationLossyCompressionQuality as String: opts.quality]
        if !opts.strip {
            props[kCGImagePropertyDPIWidth as String] = opts.dpi
            props[kCGImagePropertyDPIHeight as String] = opts.dpi
        }
        for p in pages {
            try autoreleasepool {
                let image = try renderPDFPage(doc, index: p, opts: opts, cap: cap)
                CGImageDestinationAddImage(dest, image, props as CFDictionary)
            }
        }
    } else {
        guard let src = CGImageSourceCreateWithURL(job.src as CFURL, nil), CGImageSourceGetCount(src) > 0 else {
            throw Fail("not a readable image")
        }
        let frames: [Int]
        switch job.frame {
        case .all: frames = Array(0..<CGImageSourceGetCount(src))
        case .best: frames = [bestFrame(src)]
        case .page(let p): frames = [p]
        }
        dest = try destination(frames: frames.count)
        let animated = frames.count > 1
        if animated && fmt.name == "gif" {
            let loop = [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]]
            CGImageDestinationSetProperties(dest, loop as CFDictionary)
        }
        for f in frames {
            try autoreleasepool {
                try addImageFrame(dest, from: src, index: f, fmt: fmt, opts: opts, animated: animated)
            }
        }
    }

    guard CGImageDestinationFinalize(dest) else { throw Fail("encoding to \(fmt.label) failed") }
    if fm.fileExists(atPath: job.out.path) {
        _ = try fm.replaceItemAt(job.out, withItemAt: tmp)
    } else {
        try fm.moveItem(at: tmp, to: job.out)
    }
}

// MARK: - Running

func fileSize(_ url: URL) -> Int64 {
    Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
}

func human(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var converted = 0
    private(set) var failures: [(URL, String)] = []
    private var failedSources = Set<String>()

    func ok(_ job: Job) {
        lock.lock()
        defer { lock.unlock() }
        converted += 1
        print("✓ \(job.src.lastPathComponent) → \(job.out.lastPathComponent)  (\(human(fileSize(job.src))) → \(human(fileSize(job.out))))")
    }

    func fail(_ src: URL, _ reason: String) {
        lock.lock()
        defer { lock.unlock() }
        failures.append((src, reason))
        failedSources.insert(src.path)
        print("✗ \(src.lastPathComponent): \(reason)")
    }

    func sourceFailed(_ src: URL) -> Bool { failedSources.contains(src.path) }
}

// MARK: - Pickers

@discardableResult
func osascript(_ lines: [String]) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = lines.flatMap { ["-e", $0] }
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

func quoted(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

func notify(_ message: String) {
    osascript(["display notification \(quoted(message)) with title \"fconv\""])
}

let pickerFormats = writableFormats.filter { ["png", "jpg", "heic", "tiff", "gif", "bmp", "pdf", "avif"].contains($0.name) }

func pickInDialog(count: Int) -> Format? {
    let list = pickerFormats.map { quoted($0.label) }.joined(separator: ", ")
    let prompt = "Convert \(count) file\(count == 1 ? "" : "s") to:"
    let answer = osascript([
        "try",
        "tell me to activate",
        "end try",
        "set r to choose from list {\(list)} with title \"fconv\" with prompt \(quoted(prompt)) default items {\"PNG\"} OK button name \"Convert\"",
        "if r is false then return \"\"",
        "return item 1 of r",
    ])
    return pickerFormats.first { $0.label == answer }
}

func pickInTerminal(count: Int) -> Format? {
    let err = FileHandle.standardError
    err.write(Data("Convert \(count) file\(count == 1 ? "" : "s") to:\n".utf8))
    for (i, f) in writableFormats.enumerated() { err.write(Data("  \(i + 1)) \(f.name)\n".utf8)) }
    err.write(Data("> ".utf8))
    guard let line = readLine()?.trimmingCharacters(in: .whitespaces), !line.isEmpty else { return nil }
    if let n = Int(line), writableFormats.indices.contains(n - 1) { return writableFormats[n - 1] }
    return lookupFormat(line)
}

// MARK: - Main

setvbuf(stdout, nil, _IOLBF, 0)

var opts = Options()
var positional: [String] = []
let argv = Array(CommandLine.arguments.dropFirst())
var cursor = 0

func value(for flag: String) -> String {
    cursor += 1
    guard cursor < argv.count else { die("\(flag) needs a value") }
    return argv[cursor]
}

func number(for flag: String, in range: ClosedRange<Double>) -> Double {
    guard let n = Double(value(for: flag)), range.contains(n) else {
        die("\(flag) expects a number from \(Int(range.lowerBound)) to \(Int(range.upperBound))")
    }
    return n
}

while cursor < argv.count {
    let arg = argv[cursor]
    switch arg {
    case "-h", "--help":
        print(usage)
        exit(0)
    case "-l", "--formats":
        for f in writableFormats {
            print(([f.name] + f.aliases).joined(separator: ", ").padding(toLength: 12, withPad: " ", startingAt: 0) + f.label)
        }
        exit(0)
    case "-q", "--quality": opts.quality = number(for: arg, in: 1...100) / 100
    case "-m", "--max": opts.maxSize = Int(number(for: arg, in: 1...100_000))
    case "--dpi": opts.dpi = number(for: arg, in: 18...1200)
    case "-o", "--out": opts.outDir = URL(fileURLWithPath: (value(for: arg) as NSString).expandingTildeInPath).standardizedFileURL
    case "-r", "--recursive": opts.recursive = true
    case "-f", "--force": opts.force = true
    case "--trash": opts.trash = true
    case "--strip": opts.strip = true
    case "--pick": opts.pick = true
    case "--":
        positional += argv[(cursor + 1)...]
        cursor = argv.count
    default:
        if arg.hasPrefix("-") && arg.count > 1 && !FileManager.default.fileExists(atPath: arg) {
            die("unknown option \(arg) (try --help)")
        }
        positional.append(arg)
    }
    cursor += 1
}

var format: Format?
var ext = ""
if let first = positional.first, let f = lookupFormat(first) {
    format = f
    ext = first.lowercased()  // `fconv jpeg` writes .jpeg, `fconv jpg` writes .jpg
    positional.removeFirst()
}
guard !positional.isEmpty else {
    print(usage)
    exit(2)
}
if opts.pick { opts.recursive = true }  // a folder picked in Finder means everything in it

let (files, missing) = collectInputs(
    positional, recursive: opts.recursive, filterExplicit: opts.pick, excluding: opts.outDir)
for path in missing { FileHandle.standardError.write(Data("fconv: no such file: \(path)\n".utf8)) }
guard !files.isEmpty else {
    if opts.pick { notify("No images in the selection.") }
    die("no images found", code: 1)
}

if format == nil {
    if opts.pick {
        format = pickInDialog(count: files.count)
    } else if isatty(STDIN_FILENO) != 0 {
        format = pickInTerminal(count: files.count)
    } else {
        die("no format given (e.g. fconv png <files>)")
    }
    guard let chosen = format else { exit(0) }  // cancelled
    ext = chosen.name
}
let fmt = format!
guard writableUTIs.contains(fmt.uti) else {
    die("this macOS cannot write \(fmt.label). Writable: \(writableFormats.map(\.name).joined(separator: ", "))")
}

if let dir = opts.outDir {
    do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
        die("cannot create \(dir.path): \(error.localizedDescription)")
    }
}

let started = Date()
let plan = makePlan(files: files, fmt: fmt, ext: ext, opts: opts)
let tally = Tally()
for (src, reason) in plan.skipped { print("– \(src.lastPathComponent): \(reason)") }
for (src, reason) in plan.failed { tally.fail(src, reason) }

let queue = OperationQueue()
queue.maxConcurrentOperationCount = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 8))
for job in plan.jobs {
    queue.addOperation {
        autoreleasepool {
            do {
                try convert(job, fmt: fmt, opts: opts)
                tally.ok(job)
            } catch {
                tally.fail(job.src, (error as? Fail)?.description ?? error.localizedDescription)
            }
        }
    }
}
queue.waitUntilAllOperationsAreFinished()

var trashed = 0
if opts.trash {
    // Only originals whose every output succeeded, and never a file we just wrote.
    let outputs = Set(plan.jobs.map { $0.out.path.lowercased() })
    for src in Set(plan.jobs.map(\.src)) where !tally.sourceFailed(src) && !outputs.contains(src.path.lowercased()) {
        do {
            try FileManager.default.trashItem(at: src, resultingItemURL: nil)
            trashed += 1
        } catch {
            print("! could not trash \(src.lastPathComponent): \(error.localizedDescription)")
        }
    }
}

var parts = ["\(tally.converted) converted"]
if !plan.skipped.isEmpty { parts.append("\(plan.skipped.count) skipped") }
if !tally.failures.isEmpty { parts.append("\(tally.failures.count) failed") }
if trashed > 0 { parts.append("\(trashed) original\(trashed == 1 ? "" : "s") trashed") }
let summary = parts.joined(separator: ", ")
print(summary + String(format: " in %.1fs", Date().timeIntervalSince(started)))

if opts.pick {
    if tally.failures.isEmpty {
        notify("\(summary) → \(fmt.label)")
    } else {
        let detail = tally.failures.prefix(8).map { "\($0.0.lastPathComponent): \($0.1)" }.joined(separator: "\n")
        osascript(["try", "tell me to activate", "end try", "display alert \(quoted(summary)) message \(quoted(detail))"])
    }
}
exit(tally.failures.isEmpty ? 0 : 1)
