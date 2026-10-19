import Foundation
#if canImport(Compression)
import Compression
#endif

/// .mxl = zip 压缩的 MusicXML。这里是一个只读、够用的最小 zip 解压：
/// 支持"不压缩"和 deflate 两种方式，不支持加密、分卷、zip64。
enum MXLArchive {

    /// 找到 META-INF/container.xml 指向的主乐谱并解压
    static func rootScore(in data: Data) throws -> Data {
        let bytes = Array(data)
        let entries = try centralDirectory(bytes)

        var path: String?
        if let container = entries.first(where: { $0.name == "META-INF/container.xml" }),
           let tree = XMLTree.parse(try extract(container, from: bytes)) {
            path = tree.first(where: { $0.name == "rootfile" })?.attributes["full-path"]
        }
        let target = entries.first { $0.name == path }
            ?? entries.first { !$0.name.hasPrefix("META-INF/")
                && ($0.name.hasSuffix(".xml") || $0.name.hasSuffix(".musicxml")) }
        guard let entry = target else { throw MusicXMLError.badArchive("压缩包里没有乐谱文件") }
        return try extract(entry, from: bytes)
    }

    struct Entry {
        let name: String
        let method: Int
        let compressedSize: Int
        let size: Int
        let localHeaderOffset: Int
    }

    static func centralDirectory(_ b: [UInt8]) throws -> [Entry] {
        // 从尾部找 End of Central Directory（0x06054b50）
        var eocd = -1
        var i = b.count - 22
        while i >= max(0, b.count - 22 - 65_535) {
            if u32(b, i) == 0x0605_4b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw MusicXMLError.badArchive("找不到目录") }

        let count = u16(b, eocd + 10)
        var p = u32(b, eocd + 16)
        var entries: [Entry] = []
        for _ in 0..<count {
            guard p + 46 <= b.count, u32(b, p) == 0x0201_4b50 else {
                throw MusicXMLError.badArchive("目录损坏")
            }
            let nameLength = u16(b, p + 28)
            let extraLength = u16(b, p + 30)
            let commentLength = u16(b, p + 32)
            guard p + 46 + nameLength <= b.count else { throw MusicXMLError.badArchive("目录损坏") }
            let name = String(decoding: b[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self)
            entries.append(Entry(name: name,
                                 method: u16(b, p + 10),
                                 compressedSize: u32(b, p + 20),
                                 size: u32(b, p + 24),
                                 localHeaderOffset: u32(b, p + 42)))
            p += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    static func extract(_ e: Entry, from b: [UInt8]) throws -> Data {
        let h = e.localHeaderOffset
        guard h + 30 <= b.count, u32(b, h) == 0x0403_4b50 else {
            throw MusicXMLError.badArchive("文件头损坏")
        }
        let start = h + 30 + u16(b, h + 26) + u16(b, h + 28)
        guard start + e.compressedSize <= b.count else { throw MusicXMLError.badArchive("数据不完整") }
        let payload = Array(b[start..<(start + e.compressedSize)])

        switch e.method {
        case 0:
            return Data(payload)
        case 8:
            #if canImport(Compression)
            guard e.size > 0 else { return Data() }
            var out = [UInt8](repeating: 0, count: e.size)
            // COMPRESSION_ZLIB 在 Apple 平台上就是不带头的原始 deflate，正好是 zip 用的格式
            let written = compression_decode_buffer(&out, e.size, payload, payload.count,
                                                    nil, COMPRESSION_ZLIB)
            guard written == e.size else { throw MusicXMLError.badArchive("解压失败") }
            return Data(out)
            #else
            throw MusicXMLError.badArchive("当前平台不支持 deflate")
            #endif
        default:
            throw MusicXMLError.badArchive("不支持的压缩方式 \(e.method)")
        }
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> Int {
        guard i + 2 <= b.count else { return 0 }
        return Int(b[i]) | Int(b[i + 1]) << 8
    }

    private static func u32(_ b: [UInt8], _ i: Int) -> Int {
        guard i + 4 <= b.count else { return 0 }
        return Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24
    }
}
