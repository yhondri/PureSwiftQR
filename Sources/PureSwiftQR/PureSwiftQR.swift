/// A dependency-free QR Code Model 2 generator written in pure Swift.
///
/// `PureSwiftQR` deliberately avoids CoreGraphics, CoreImage, UIKit and AppKit,
/// so the same package can be built on Linux (including Vapor Docker images).
public struct QRCode: Sendable, Equatable {
    public enum ErrorCorrection: Int, Sendable, CaseIterable {
        case low = 0
        case medium = 1
        case quartile = 2
        case high = 3

        fileprivate var formatBits: Int {
            switch self {
            case .low: return 1
            case .medium: return 0
            case .quartile: return 3
            case .high: return 2
            }
        }
    }

    public enum QRError: Error, Sendable, Equatable {
        case dataTooLong
        case invalidBorder
    }

    public let version: Int
    public let size: Int
    public let errorCorrection: ErrorCorrection

    private let storage: [Bool]

    /// Creates the smallest QR version that can hold the UTF-8 representation of `text`.
    /// The encoder uses QR byte mode and supports versions 1 through 40.
    public init(_ text: String, errorCorrection: ErrorCorrection = .medium) throws {
        try self.init(bytes: Array(text.utf8), errorCorrection: errorCorrection)
    }

    /// Creates the smallest QR version that can hold `bytes` in QR byte mode.
    public init(bytes: [UInt8], errorCorrection: ErrorCorrection = .medium) throws {
        var selectedVersion: Int?
        for candidate in 1...40 {
            let charCountBits = candidate <= 9 ? 8 : 16
            guard bytes.count < (1 << charCountBits) else { continue }
            let usedBits = 4 + charCountBits + bytes.count * 8
            if usedBits <= Self.numDataCodewords(version: candidate, level: errorCorrection) * 8 {
                selectedVersion = candidate
                break
            }
        }
        guard let version = selectedVersion else { throw QRError.dataTooLong }

        let dataCodewords = Self.makeDataCodewords(bytes: bytes, version: version, level: errorCorrection)
        let allCodewords = Self.addErrorCorrectionAndInterleave(dataCodewords, version: version, level: errorCorrection)

        var symbol = Builder(version: version, level: errorCorrection)
        symbol.drawFunctionPatterns()
        symbol.drawCodewords(allCodewords)
        symbol.selectAndApplyBestMask()

        self.version = version
        self.size = symbol.size
        self.errorCorrection = errorCorrection
        self.storage = symbol.modules
    }

    /// Returns whether the module at `(x, y)` is dark.
    /// Coordinates start at the upper-left corner.
    public subscript(x: Int, y: Int) -> Bool {
        precondition(x >= 0 && x < size && y >= 0 && y < size, "QR module coordinate out of bounds")
        return storage[y * size + x]
    }

    /// Returns the matrix row-by-row, where `true` means a dark module.
    public var modules: [[Bool]] {
        (0..<size).map { y in
            Array(storage[(y * size)..<((y + 1) * size)])
        }
    }

    /// Produces an SVG string without requiring any graphics framework.
    /// - Parameter border: Quiet-zone width in QR modules. The QR standard commonly uses 4.
    public func svg(border: Int = 4) throws -> String {
        guard border >= 0 else { throw QRError.invalidBorder }
        let dimension = size + border * 2
        var path = ""
        path.reserveCapacity(size * size * 4)

        for y in 0..<size {
            var x = 0
            while x < size {
                if self[x, y] {
                    let start = x
                    while x < size && self[x, y] { x += 1 }
                    let width = x - start
                    path += "M\(start + border) \(y + border)h\(width)v1h-\(width)z"
                } else {
                    x += 1
                }
            }
        }

        return """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(dimension) \(dimension)" shape-rendering="crispEdges">
        <rect width="100%" height="100%" fill="#fff"/>
        <path d="\(path)" fill="#000"/>
        </svg>
        """
    }
}

private extension QRCode {
    static func makeDataCodewords(bytes: [UInt8], version: Int, level: ErrorCorrection) -> [UInt8] {
        let capacityBits = numDataCodewords(version: version, level: level) * 8
        let charCountBits = version <= 9 ? 8 : 16
        var bits = BitBuffer()
        bits.append(value: 0b0100, count: 4) // Byte mode
        bits.append(value: bytes.count, count: charCountBits)
        for byte in bytes { bits.append(value: Int(byte), count: 8) }

        let terminator = min(4, capacityBits - bits.count)
        bits.append(value: 0, count: terminator)
        while bits.count % 8 != 0 { bits.append(value: 0, count: 1) }

        var result = bits.bytes
        var useEC = true
        while result.count < capacityBits / 8 {
            result.append(useEC ? 0xEC : 0x11)
            useEC.toggle()
        }
        return result
    }

    static func addErrorCorrectionAndInterleave(_ data: [UInt8], version: Int, level: ErrorCorrection) -> [UInt8] {
        let numBlocks = numErrorCorrectionBlocks[level.rawValue][version]
        let eccLength = eccCodewordsPerBlock[level.rawValue][version]
        let rawCodewords = numRawDataModules(version: version) / 8
        let numShortBlocks = numBlocks - rawCodewords % numBlocks
        let shortBlockLength = rawCodewords / numBlocks
        let shortDataLength = shortBlockLength - eccLength
        let divisor = reedSolomonDivisor(degree: eccLength)

        var dataBlocks = [[UInt8]]()
        var eccBlocks = [[UInt8]]()
        dataBlocks.reserveCapacity(numBlocks)
        eccBlocks.reserveCapacity(numBlocks)

        var cursor = 0
        for blockIndex in 0..<numBlocks {
            let dataLength = shortDataLength + (blockIndex < numShortBlocks ? 0 : 1)
            let block = Array(data[cursor..<(cursor + dataLength)])
            cursor += dataLength
            dataBlocks.append(block)
            eccBlocks.append(reedSolomonRemainder(data: block, divisor: divisor))
        }

        var result = [UInt8]()
        result.reserveCapacity(rawCodewords)
        let maxDataLength = dataBlocks.map(\.count).max() ?? 0
        for index in 0..<maxDataLength {
            for block in dataBlocks where index < block.count {
                result.append(block[index])
            }
        }
        for index in 0..<eccLength {
            for block in eccBlocks { result.append(block[index]) }
        }
        precondition(result.count == rawCodewords)
        return result
    }

    static func numRawDataModules(version: Int) -> Int {
        var result = (16 * version + 128) * version + 64
        if version >= 2 {
            let align = version / 7 + 2
            result -= (25 * align - 10) * align - 55
            if version >= 7 { result -= 36 }
        }
        return result
    }

    static func numDataCodewords(version: Int, level: ErrorCorrection) -> Int {
        numRawDataModules(version: version) / 8
            - eccCodewordsPerBlock[level.rawValue][version] * numErrorCorrectionBlocks[level.rawValue][version]
    }

    static func reedSolomonDivisor(degree: Int) -> [UInt8] {
        precondition(degree >= 1 && degree <= 255)
        var result = [UInt8](repeating: 0, count: degree)
        result[degree - 1] = 1
        var root: UInt8 = 1
        for _ in 0..<degree {
            for index in 0..<degree {
                result[index] = reedSolomonMultiply(result[index], root)
                if index + 1 < degree { result[index] ^= result[index + 1] }
            }
            root = reedSolomonMultiply(root, 0x02)
        }
        return result
    }

    static func reedSolomonRemainder(data: [UInt8], divisor: [UInt8]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: divisor.count)
        for byte in data {
            let factor = byte ^ result[0]
            if result.count > 1 {
                for index in 0..<(result.count - 1) { result[index] = result[index + 1] }
            }
            result[result.count - 1] = 0
            for index in divisor.indices {
                result[index] ^= reedSolomonMultiply(divisor[index], factor)
            }
        }
        return result
    }

    static func reedSolomonMultiply(_ x: UInt8, _ y: UInt8) -> UInt8 {
        var z = 0
        for bit in stride(from: 7, through: 0, by: -1) {
            z = (z << 1) ^ ((z >> 7) * 0x11D)
            z ^= ((Int(y) >> bit) & 1) * Int(x)
        }
        return UInt8(z)
    }

    static let eccCodewordsPerBlock: [[Int]] = [
        [-1, 7,10,15,20,26,18,20,24,30,18,20,24,26,30,22,24,28,30,28,28,28,28,30,30,26,28,30,30,30,30,30,30,30,30,30,30,30,30,30,30],
        [-1,10,16,26,18,24,16,18,22,22,26,30,22,22,24,24,28,28,26,26,26,26,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28],
        [-1,13,22,18,26,18,24,18,22,20,24,28,26,24,20,30,24,28,28,26,30,28,30,30,30,30,28,30,30,30,30,30,30,30,30,30,30,30,30,30,30],
        [-1,17,28,22,16,22,28,26,26,24,28,24,28,22,24,24,30,28,28,26,28,30,24,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30]
    ]

    static let numErrorCorrectionBlocks: [[Int]] = [
        [-1,1,1,1,1,1,2,2,2,2,4,4,4,4,4,6,6,6,6,7,8,8,9,9,10,12,12,12,13,14,15,16,17,18,19,19,20,21,22,24,25],
        [-1,1,1,1,2,2,4,4,4,5,5,5,8,9,9,10,10,11,13,14,16,17,17,18,20,21,23,25,26,28,29,31,33,35,37,38,40,43,45,47,49],
        [-1,1,1,2,2,4,4,6,6,8,8,8,10,12,16,12,17,16,18,21,20,23,23,25,27,29,34,34,35,38,40,43,45,48,51,53,56,59,62,65,68],
        [-1,1,1,2,4,4,4,5,6,8,8,11,11,16,16,18,16,19,21,25,25,25,34,30,32,35,37,40,42,45,48,51,54,57,60,63,66,70,74,77,81]
    ]
}

private struct BitBuffer {
    private(set) var bytes = [UInt8]()
    private(set) var count = 0

    mutating func append(value: Int, count bitCount: Int) {
        precondition(bitCount >= 0 && bitCount <= 31)
        precondition(bitCount == 31 || value >= 0 && value < (1 << bitCount))
        for bit in stride(from: bitCount - 1, through: 0, by: -1) {
            let valueBit = (value >> bit) & 1
            if count % 8 == 0 { bytes.append(0) }
            bytes[bytes.count - 1] |= UInt8(valueBit << (7 - count % 8))
            count += 1
        }
    }
}

private struct Builder {
    let version: Int
    let level: QRCode.ErrorCorrection
    let size: Int
    var modules: [Bool]
    var isFunction: [Bool]

    init(version: Int, level: QRCode.ErrorCorrection) {
        self.version = version
        self.level = level
        self.size = version * 4 + 17
        self.modules = [Bool](repeating: false, count: size * size)
        self.isFunction = [Bool](repeating: false, count: size * size)
    }

    mutating func setFunction(x: Int, y: Int, dark: Bool) {
        modules[y * size + x] = dark
        isFunction[y * size + x] = true
    }

    mutating func drawFunctionPatterns() {
        for index in 0..<size {
            setFunction(x: 6, y: index, dark: index % 2 == 0)
            setFunction(x: index, y: 6, dark: index % 2 == 0)
        }

        drawFinder(centerX: 3, centerY: 3)
        drawFinder(centerX: size - 4, centerY: 3)
        drawFinder(centerX: 3, centerY: size - 4)

        let positions = alignmentPatternPositions()
        let last = positions.count - 1
        for (row, y) in positions.enumerated() {
            for (column, x) in positions.enumerated() {
                let overlapsFinder =
                    (row == 0 && column == 0) ||
                    (row == 0 && column == last) ||
                    (row == last && column == 0)
                if !overlapsFinder {
                    drawAlignment(centerX: x, centerY: y)
                }
            }
        }

        drawFormatBits(mask: 0)
        drawVersionBits()
    }

    mutating func drawFinder(centerX: Int, centerY: Int) {
        for dy in -4...4 {
            for dx in -4...4 {
                let x = centerX + dx
                let y = centerY + dy
                guard x >= 0, x < size, y >= 0, y < size else { continue }
                let distance = max(abs(dx), abs(dy))
                setFunction(x: x, y: y, dark: distance != 2 && distance != 4)
            }
        }
    }

    mutating func drawAlignment(centerX: Int, centerY: Int) {
        for dy in -2...2 {
            for dx in -2...2 {
                setFunction(x: centerX + dx, y: centerY + dy, dark: max(abs(dx), abs(dy)) != 1)
            }
        }
    }

    func alignmentPatternPositions() -> [Int] {
        guard version != 1 else { return [] }
        let count = version / 7 + 2
        let step = (version * 8 + count * 3 + 5) / (count * 4 - 4) * 2

        var result = [6]
        var position = size - 7
        while result.count < count {
            result.insert(position, at: 1)
            position -= step
        }
        return result
    }

    mutating func drawFormatBits(mask: Int) {
        let data = (level.formatBits << 3) | mask
        var remainder = data
        for _ in 0..<10 { remainder = (remainder << 1) ^ ((remainder >> 9) * 0x537) }
        let bits = ((data << 10) | remainder) ^ 0x5412
        func bit(_ i: Int) -> Bool { ((bits >> i) & 1) != 0 }

        for i in 0...5 { setFunction(x: 8, y: i, dark: bit(i)) }
        setFunction(x: 8, y: 7, dark: bit(6))
        setFunction(x: 8, y: 8, dark: bit(7))
        setFunction(x: 7, y: 8, dark: bit(8))
        for i in 9..<15 { setFunction(x: 14 - i, y: 8, dark: bit(i)) }

        for i in 0..<8 { setFunction(x: size - 1 - i, y: 8, dark: bit(i)) }
        for i in 8..<15 { setFunction(x: 8, y: size - 15 + i, dark: bit(i)) }
        setFunction(x: 8, y: size - 8, dark: true)
    }

    mutating func drawVersionBits() {
        guard version >= 7 else { return }
        var remainder = version
        for _ in 0..<12 { remainder = (remainder << 1) ^ ((remainder >> 11) * 0x1F25) }
        let bits = (version << 12) | remainder
        for index in 0..<18 {
            let dark = ((bits >> index) & 1) != 0
            let a = size - 11 + index % 3
            let b = index / 3
            setFunction(x: a, y: b, dark: dark)
            setFunction(x: b, y: a, dark: dark)
        }
    }

    mutating func drawCodewords(_ codewords: [UInt8]) {
        var bitIndex = 0
        var right = size - 1
        while right >= 1 {
            if right == 6 { right = 5 }
            for vertical in 0..<size {
                let upward = ((right + 1) & 2) == 0
                let y = upward ? size - 1 - vertical : vertical
                for offset in 0..<2 {
                    let x = right - offset
                    let index = y * size + x
                    if !isFunction[index] && bitIndex < codewords.count * 8 {
                        modules[index] = ((codewords[bitIndex >> 3] >> (7 - (bitIndex & 7))) & 1) != 0
                        bitIndex += 1
                    }
                }
            }
            right -= 2
        }
        precondition(bitIndex == codewords.count * 8)
    }

    mutating func selectAndApplyBestMask() {
        var bestMask = 0
        var bestScore = Int.max
        for mask in 0..<8 {
            applyMask(mask)
            drawFormatBits(mask: mask)
            let score = penaltyScore()
            if score < bestScore {
                bestScore = score
                bestMask = mask
            }
            applyMask(mask)
        }
        applyMask(bestMask)
        drawFormatBits(mask: bestMask)
    }

    mutating func applyMask(_ mask: Int) {
        for y in 0..<size {
            for x in 0..<size {
                let index = y * size + x
                guard !isFunction[index] else { continue }
                let invert: Bool
                switch mask {
                case 0: invert = (x + y) % 2 == 0
                case 1: invert = y % 2 == 0
                case 2: invert = x % 3 == 0
                case 3: invert = (x + y) % 3 == 0
                case 4: invert = (x / 3 + y / 2) % 2 == 0
                case 5: invert = (x * y % 2 + x * y % 3) == 0
                case 6: invert = (x * y % 2 + x * y % 3) % 2 == 0
                case 7: invert = ((x + y) % 2 + x * y % 3) % 2 == 0
                default: preconditionFailure("Invalid QR mask")
                }
                if invert { modules[index].toggle() }
            }
        }
    }

    func penaltyScore() -> Int {
        var score = 0

        // N1: Runs of five or more modules of the same color.
        for y in 0..<size {
            var runColor = modules[y * size]
            var runLength = 1
            for x in 1..<size {
                let color = modules[y * size + x]
                if color == runColor {
                    runLength += 1
                    if runLength == 5 { score += 3 }
                    else if runLength > 5 { score += 1 }
                } else {
                    runColor = color
                    runLength = 1
                }
            }
        }
        for x in 0..<size {
            var runColor = modules[x]
            var runLength = 1
            for y in 1..<size {
                let color = modules[y * size + x]
                if color == runColor {
                    runLength += 1
                    if runLength == 5 { score += 3 }
                    else if runLength > 5 { score += 1 }
                } else {
                    runColor = color
                    runLength = 1
                }
            }
        }

        // N2: 2x2 blocks of the same color.
        if size >= 2 {
            for y in 0..<(size - 1) {
                for x in 0..<(size - 1) {
                    let color = modules[y * size + x]
                    if modules[y * size + x + 1] == color,
                       modules[(y + 1) * size + x] == color,
                       modules[(y + 1) * size + x + 1] == color {
                        score += 3
                    }
                }
            }
        }

        // N3: Finder-like 1:1:3:1:1 patterns with four light modules on one side.
        let patternA: [Bool] = [false,false,false,false,true,false,true,true,true,false,true]
        let patternB: [Bool] = [true,false,true,true,true,false,true,false,false,false,false]
        if size >= 11 {
            for y in 0..<size {
                for x in 0...(size - 11) {
                    var a = true, b = true
                    for i in 0..<11 {
                        let value = modules[y * size + x + i]
                        a = a && value == patternA[i]
                        b = b && value == patternB[i]
                    }
                    if a || b { score += 40 }
                }
            }
            for x in 0..<size {
                for y in 0...(size - 11) {
                    var a = true, b = true
                    for i in 0..<11 {
                        let value = modules[(y + i) * size + x]
                        a = a && value == patternA[i]
                        b = b && value == patternB[i]
                    }
                    if a || b { score += 40 }
                }
            }
        }

        // N4: Distance from a 50/50 dark/light balance in 5% steps.
        let dark = modules.reduce(0) { $0 + ($1 ? 1 : 0) }
        let total = size * size
        let deviationPercent = abs(dark * 100 - total * 50) / total
        score += (deviationPercent / 5) * 10
        return score
    }
}
