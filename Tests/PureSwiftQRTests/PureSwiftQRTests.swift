import Testing
@testable import PureSwiftQR

@Test func createsVersionOneForShortPayload() throws {
    let qr = try QRCode("HELLO", errorCorrection: .medium)
    #expect(qr.version == 1)
    #expect(qr.size == 21)
    #expect(qr.modules.count == 21)
    #expect(qr.modules.allSatisfy { $0.count == 21 })
}

@Test func finderPatternsArePresent() throws {
    let qr = try QRCode("https://atlas.example/r/1234/t/12")
    #expect(qr[0, 0])
    #expect(qr[6, 0])
    #expect(qr[0, 6])
    #expect(qr[qr.size - 1, 0])
    #expect(qr[0, qr.size - 1])
}

@Test func generatesPortableSVG() throws {
    let qr = try QRCode("https://atlas.example/table/42")
    let svg = try qr.svg()
    #expect(svg.contains("<svg"))
    #expect(svg.contains("viewBox=\"0 0 \(qr.size + 8) \(qr.size + 8)\""))
    #expect(svg.contains("<path"))
}

@Test func supportsUnicodeAndAllErrorCorrectionLevels() throws {
    for level in QRCode.ErrorCorrection.allCases {
        let qr = try QRCode("Mesa 12 · Café ☕️", errorCorrection: level)
        #expect(qr.size >= 21)
    }
}

@Test func supportsLargePayloadsBeyondVersionNine() throws {
    let text = String(repeating: "atlas-restaurant-table-", count: 40)
    let qr = try QRCode(text, errorCorrection: .medium)
    #expect(qr.version > 9)
}
