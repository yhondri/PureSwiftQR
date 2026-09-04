# PureSwiftQR


![](https://img.shields.io/badge/license-MIT-green) ![](https://img.shields.io/badge/maintained%3F-Yes-green) ![](https://img.shields.io/badge/swift-6.3-green) ![](https://img.shields.io/badge/Linux-supported-green) ![](https://img.shields.io/badge/iOS-16.0-red) ![](https://img.shields.io/badge/macOS-13.0-red) ![](https://img.shields.io/badge/tvOS-16.0-red) ![](https://img.shields.io/badge/watchOS-9.0-red) ![](https://img.shields.io/badge/visionOS-1.0-red)

A dependency-free **QR Code Model 2 generator written in pure Swift**.

Designed for server-side Swift and Vapor deployments where Apple-only graphics frameworks are unavailable.

* Swift Package Manager
* Linux compatible
* No `CoreGraphics`
* No `CoreImage`
* No `UIKit`
* No `AppKit`
* No third-party runtime dependencies
* QR versions 1–40
* Error correction L / M / Q / H
* UTF-8 byte mode
* Automatic version selection
* Automatic mask selection
* Built-in SVG output

## Add with Swift Package Manager

```swift
.package(
    url: "https://github.com/yhondri/PureSwiftQR.git",
    from: "1.0.0"
)
```

Then add the product to your target:

```swift
.product(
    name: "PureSwiftQR",
    package: "PureSwiftQR"
)
```

## Basic usage

```swift
import PureSwiftQR

let qr = try QRCode(
    "https://order.example.com/r/1234/t/12",
    errorCorrection: .medium
)

let svg = try qr.svg()
```

`svg` is a regular Swift `String`, so no image or graphics framework is required.

## Matrix access

```swift
let isDark = qr[3, 7]
let matrix = qr.modules
```

## Server-side / Linux

The target uses only the Swift standard library. It does not import Foundation or any Apple graphics framework.

A normal Linux build is enough:

```bash
swift build -c release
```

It is suitable for Swift server applications, including Vapor projects running inside Linux Docker containers.

## Platform support

PureSwiftQR is designed to work anywhere Swift itself is available because it does not depend on platform-specific graphics frameworks.

Supported targets include:

* Linux
* macOS
* iOS / iPadOS
* tvOS
* watchOS
* visionOS

The package is particularly useful for Linux deployments where `CoreGraphics` and `CoreImage` are unavailable.

## Scope

The package encodes arbitrary bytes using QR **byte mode**, which is a good fit for URLs, identifiers and server-generated payloads.

It does not currently optimize numeric or alphanumeric input into their more compact QR encoding modes.
