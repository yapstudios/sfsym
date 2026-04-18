import Foundation
import Compression

// Read-only parser for CoreUI Assets.car (BOMStore), focused on SF Symbols.
//
// BOMStore layout (big-endian for BOM scaffolding):
//   Header (32 bytes): magic "BOMStore", version, numBlocks, indexOff, indexSize, varsOff, varsSize
//   Index at indexOff: count(u32) + (offset u32, size u32) × count → indexed by block id
//   Vars at varsOff:   count(u32) + [blockId u32, nameLen u8, name bytes] × count
//
// Named trees of interest:
//   FACETKEYS  — facet name → set of rendition-key attributes
//   RENDITIONS — rendition key (tokens of KEYFORMAT order) → CSI payload with DWAR/LZFSE SVG
//   KEYFORMAT  — list of attribute codes describing rendition-key token order (stored LE)
//
// Tree blocks:
//   "tree" header (29 bytes): magic, version, childRootBid (u32), nodeSize, pathCount, …
//   Node layout: isLeaf(u16), count(u16), forward(u32), backward(u32), entries…
//     Internal node entry: (childBid u32, keyBid u32)
//     Leaf node entry:     (valueBid u32, keyBid u32)
//
// Rendition key bytes are packed u16 LE tokens, one per KEYFORMAT slot.
// Facet value bytes: 4-byte preamble, u16 count, [u16 attrCode, u16 value] × count.

enum CarError: Error {
    case bom(String)
    case notFound(String)
}

struct CarBlock {
    let offset: Int
    let size: Int
}

// CoreUI attribute codes (seen in SF Symbols' KEYFORMAT).
enum Attr: UInt16 {
    case element = 1        // part of facet identity
    case part = 2           // part of facet identity
    case direction = 4
    case appearance = 7
    case dimension1 = 8
    case dimension2 = 9
    case state = 10
    case scale = 12         // 1 or 2
    case localization = 13
    case presentationState = 14
    case identifier = 17    // nameId → FACETKEYS name
    case previousValue = 18
    case previousState = 19
    case deploymentTarget = 25
    case glyphWeight = 26   // 1..9 (ultralight..black)
    case glyphSize = 27     // 1=S 2=M 3=L
}

final class AssetsCar {
    let data: Data
    let index: [CarBlock]
    let named: [String: Int]
    let keyFormat: [UInt16]   // attribute codes in rendition-key token order

    init(path: String) throws {
        let url = URL(fileURLWithPath: path)
        self.data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count >= 32, data.prefix(8) == Data("BOMStore".utf8) else {
            throw CarError.bom("bad magic")
        }
        let be = BEReader(data: data)
        let indexOff = Int(be.u32(16))
        let varsOff = Int(be.u32(24))

        // Index.
        var blocks: [CarBlock] = []
        let icount = Int(be.u32(indexOff))
        blocks.reserveCapacity(icount)
        for i in 0..<icount {
            let off = Int(be.u32(indexOff + 4 + i*8))
            let sz = Int(be.u32(indexOff + 4 + i*8 + 4))
            blocks.append(CarBlock(offset: off, size: sz))
        }
        self.index = blocks

        // Vars.
        var vp = varsOff
        let vcount = Int(be.u32(vp)); vp += 4
        var named: [String: Int] = [:]
        for _ in 0..<vcount {
            let bid = Int(be.u32(vp)); vp += 4
            let nlen = Int(data[vp]); vp += 1
            let nm = String(data: data.subdata(in: vp..<(vp+nlen)), encoding: .ascii) ?? ""
            vp += nlen
            named[nm] = bid
        }
        self.named = named

        // KEYFORMAT (LE).
        if let kfBid = named["KEYFORMAT"] {
            let b = blocks[kfBid]
            let o = b.offset
            // Magic stored LE as "tmfk" (bytes of u32('kfmt') in LE).
            let m = data.subdata(in: o..<(o+4))
            guard m == Data("tmfk".utf8) || m == Data("kfmt".utf8) else {
                throw CarError.bom("kfmt magic mismatch: \(m.hexPreview())")
            }
            let le = LEReader(data: data)
            let count = Int(le.u32(o + 8))
            var codes: [UInt16] = []
            codes.reserveCapacity(count)
            for i in 0..<count {
                codes.append(UInt16(le.u32(o + 12 + i*4)))
            }
            self.keyFormat = codes
        } else {
            self.keyFormat = []
        }
    }

    // MARK: - Tree walk

    /// Walks all leaves under the named tree (FACETKEYS or RENDITIONS).
    /// Calls `visit` with (keyBytes, valueBytes) for each leaf entry.
    func walk(_ treeName: String, _ visit: (Data, Data) throws -> Void) throws {
        guard let bid = named[treeName] else { throw CarError.notFound(treeName) }
        let be = BEReader(data: data)
        let root = index[bid]
        guard data.subdata(in: root.offset..<(root.offset+4)) == Data("tree".utf8) else {
            throw CarError.bom("tree magic mismatch at \(treeName)")
        }
        let rootNodeBid = Int(be.u32(root.offset + 8))
        try walkNode(bid: rootNodeBid, visit: visit)
    }

    private func walkNode(bid: Int, visit: (Data, Data) throws -> Void) throws {
        // BOM tree = B+ tree with leaf forward-chains. Descend the leftmost path
        // to the first leaf, then iterate via forward links. Internal nodes'
        // non-leftmost children are range-index pointers whose subtrees are
        // already reachable through the forward chain.
        let be = BEReader(data: data)
        var curBid = bid
        while true {
            let o = index[curBid].offset
            let isLeaf = be.u16(o)
            if isLeaf != 0 { break }
            let count = Int(be.u16(o + 2))
            guard count > 0 else { return }
            curBid = Int(be.u32(o + 12))  // leftmost child: value field of entry[0]
        }
        // Iterate leaves via forward chain.
        while curBid != 0 {
            let o = index[curBid].offset
            let isLeaf = be.u16(o)
            precondition(isLeaf != 0, "forward chain should only contain leaves")
            let count = Int(be.u16(o + 2))
            let forward = Int(be.u32(o + 4))
            for i in 0..<count {
                let entry = o + 12 + i * 8
                let v = Int(be.u32(entry))
                let k = Int(be.u32(entry + 4))
                let kb = index[k]; let vb = index[v]
                let keyBytes = data.subdata(in: kb.offset..<(kb.offset + kb.size))
                let valBytes = data.subdata(in: vb.offset..<(vb.offset + vb.size))
                try visit(keyBytes, valBytes)
            }
            curBid = forward
        }
    }

    // MARK: - High-level accessors

    struct FacetAttrs {
        var attrs: [UInt16: UInt16]
        var identifier: UInt16? { attrs[Attr.identifier.rawValue] }
        var element: UInt16? { attrs[Attr.element.rawValue] }
        var part: UInt16? { attrs[Attr.part.rawValue] }
    }

    /// name → facet attributes (Element, Part, Identifier, …).
    func loadFacets() throws -> [String: FacetAttrs] {
        var out: [String: FacetAttrs] = [:]
        try walk("FACETKEYS") { key, val in
            // Facet key is raw UTF-8 name bytes. Block size is the exact name length.
            guard let name = String(data: key, encoding: .utf8) else { return }
            // Value layout (LE): u32 pad, u16 count, then (u16 code, u16 value) × count.
            guard val.count >= 6 else { return }
            let le = LEReader(data: val)
            let base = val.startIndex
            let count = Int(le.u16(base + 4))
            var attrs: [UInt16: UInt16] = [:]
            for i in 0..<count {
                let p = base + 6 + i * 4
                guard p + 4 <= val.endIndex else { break }
                attrs[le.u16(p)] = le.u16(p + 2)
            }
            out[name] = FacetAttrs(attrs: attrs)
        }
        return out
    }

    struct RenditionKey: Hashable {
        // Facet identity:
        let element: UInt16
        let part: UInt16
        let identifier: UInt16
        // Variant axes:
        let scale: UInt16       // 1 or 2
        let weight: UInt16      // 1..9
        let size: UInt16        // 1,2,3
        let localization: UInt16
    }

    /// Parse rendition key bytes into attribute map using KEYFORMAT order.
    func parseRenditionKey(_ bytes: Data) -> [UInt16: UInt16] {
        let le = LEReader(data: bytes)
        var out: [UInt16: UInt16] = [:]
        let n = min(bytes.count / 2, keyFormat.count)
        for i in 0..<n {
            let v = le.u16(bytes.startIndex + i * 2)
            out[keyFormat[i]] = v
        }
        return out
    }
}

// MARK: - Byte readers

struct BEReader {
    let data: Data
    func u16(_ o: Int) -> UInt16 {
        (UInt16(data[o]) << 8) | UInt16(data[o+1])
    }
    func u32(_ o: Int) -> UInt32 {
        (UInt32(data[o]) << 24) | (UInt32(data[o+1]) << 16) | (UInt32(data[o+2]) << 8) | UInt32(data[o+3])
    }
}

struct LEReader {
    let data: Data
    func u16(_ o: Int) -> UInt16 {
        UInt16(data[o]) | (UInt16(data[o+1]) << 8)
    }
    func u32(_ o: Int) -> UInt32 {
        UInt32(data[o]) | (UInt32(data[o+1]) << 8) | (UInt32(data[o+2]) << 16) | (UInt32(data[o+3]) << 24)
    }
}

extension Data {
    func hexPreview(limit: Int = 16) -> String {
        prefix(limit).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - DWAR/LZFSE extractor

/// Given a rendition value (CSI blob), decompress the embedded SVG payload.
func extractSVG(from value: Data) -> Data? {
    guard let r = value.range(of: Data("DWAR".utf8)) else { return nil }
    let afterHdr = r.upperBound + 8  // 4 flags + 4 length bytes after "DWAR"
    guard afterHdr < value.endIndex else { return nil }
    let magics: [Data] = ["bvxn", "bvx-", "bvx2", "bvx1"].map { Data($0.utf8) }
    var start: Int? = nil
    for m in magics {
        if let mr = value.range(of: m, in: afterHdr..<min(afterHdr + 16, value.endIndex)) {
            start = mr.lowerBound; break
        }
    }
    guard let s = start else { return nil }
    let stopMagic = Data("bvx$".utf8)
    guard let stop = value.range(of: stopMagic, in: s..<value.endIndex) else { return nil }
    let chunk = value.subdata(in: s..<stop.upperBound)
    let capacity = max(chunk.count * 40, 131072)
    var out = Data(count: capacity)
    let n = chunk.withUnsafeBytes { sb -> Int in
        out.withUnsafeMutableBytes { db -> Int in
            compression_decode_buffer(
                db.bindMemory(to: UInt8.self).baseAddress!, capacity,
                sb.bindMemory(to: UInt8.self).baseAddress!, sb.count,
                nil, COMPRESSION_LZFSE)
        }
    }
    guard n > 0 else { return nil }
    out.removeSubrange(n..<out.count)
    return out
}
