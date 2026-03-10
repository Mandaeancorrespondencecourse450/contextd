import Foundation
import CoreGraphics

/// Result of comparing two screenshots tile-by-tile.
struct TileDiff: Sendable {
    /// Coordinates of tiles that changed significantly.
    let changedTiles: [(row: Int, col: Int)]

    /// Total number of tiles in the grid.
    let totalTiles: Int

    /// Fraction of tiles that changed (0.0-1.0).
    var changePercentage: Double {
        guard totalTiles > 0 else { return 1.0 }
        return Double(changedTiles.count) / Double(totalTiles)
    }
}

/// A rectangular region of the image that changed, with a cropped image for OCR.
struct ChangedRegion: Sendable {
    /// Pixel coordinates of the region in the full image.
    let bounds: CGRect

    /// Cropped portion of the current image for partial OCR.
    let croppedImage: CGImage
}

/// Complete result of an image diff operation.
struct DiffResult: Sendable {
    /// Tile-level diff information.
    let tileDiff: TileDiff

    /// Merged and padded bounding regions for OCR.
    let changedRegions: [ChangedRegion]

    /// Whether the change is significant enough to warrant a keyframe.
    let isSignificantChange: Bool
}

/// Pixel-level tile diff engine. Compares two CGImages using a 64x64 tile grid
/// to detect which portions of the screen changed between captures.
final class ImageDiffer: Sendable {
    /// Size of each comparison tile in pixels.
    let tileSize: Int = 64

    /// Padding added around changed tile groups when cropping for OCR.
    let paddingPixels: Int = 32

    /// Per-tile mean pixel difference threshold. Tiles with a mean difference
    /// below this (as a fraction of 255) are considered unchanged.
    /// ~4% filters sub-pixel rendering, cursor blink, menu bar clock updates.
    let noiseThreshold: Double = 10.0 / 255.0

    /// Fraction of tiles that must change to trigger a keyframe.
    nonisolated(unsafe) var significantChangeThreshold: Double = 0.50

    /// Compare two screenshots. Returns diff result with changed regions.
    /// If images have different dimensions, returns 100% changed (force keyframe).
    func diff(current: CGImage, previous: CGImage) -> DiffResult {
        let currentWidth = current.width
        let currentHeight = current.height

        // Different dimensions -> force keyframe
        guard currentWidth == previous.width && currentHeight == previous.height else {
            return forceFullChange(image: current)
        }

        // Render both images into consistent 32-bit BGRA format for pixel access
        guard let currentPixels = renderToPixelBuffer(current),
              let previousPixels = renderToPixelBuffer(previous) else {
            return forceFullChange(image: current)
        }

        // Ensure pixel buffers are freed when we're done
        defer {
            currentPixels.deallocate()
            previousPixels.deallocate()
        }

        let cols = (currentWidth + tileSize - 1) / tileSize
        let rows = (currentHeight + tileSize - 1) / tileSize
        let totalTiles = rows * cols

        // Compare tiles
        var changedTiles: [(row: Int, col: Int)] = []

        for row in 0..<rows {
            for col in 0..<cols {
                let tileX = col * tileSize
                let tileY = row * tileSize
                let tileW = min(tileSize, currentWidth - tileX)
                let tileH = min(tileSize, currentHeight - tileY)

                if isTileChanged(
                    currentPixels: currentPixels,
                    previousPixels: previousPixels,
                    imageWidth: currentWidth,
                    tileX: tileX, tileY: tileY,
                    tileW: tileW, tileH: tileH
                ) {
                    changedTiles.append((row: row, col: col))
                }
            }
        }

        let tileDiff = TileDiff(changedTiles: changedTiles, totalTiles: totalTiles)
        let isSignificant = tileDiff.changePercentage >= significantChangeThreshold

        // No changes -> empty regions
        guard !changedTiles.isEmpty else {
            return DiffResult(
                tileDiff: tileDiff,
                changedRegions: [],
                isSignificantChange: false
            )
        }

        // Merge adjacent changed tiles into bounding rectangles via flood fill
        let mergedRects = mergeChangedTiles(
            changedTiles: changedTiles,
            rows: rows, cols: cols,
            imageWidth: currentWidth, imageHeight: currentHeight
        )

        // Crop regions from the current image
        let changedRegions = mergedRects.compactMap { rect -> ChangedRegion? in
            guard let cropped = current.cropping(to: rect) else { return nil }
            return ChangedRegion(bounds: rect, croppedImage: cropped)
        }

        return DiffResult(
            tileDiff: tileDiff,
            changedRegions: changedRegions,
            isSignificantChange: isSignificant
        )
    }

    // MARK: - Force Full Change

    /// Return a DiffResult indicating 100% change (used for dimension mismatch, etc.).
    private func forceFullChange(image: CGImage) -> DiffResult {
        let fullRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let allTiles = tilesForDimensions(width: image.width, height: image.height)
        let tileDiff = TileDiff(changedTiles: allTiles, totalTiles: allTiles.count)
        let region = ChangedRegion(bounds: fullRect, croppedImage: image)
        return DiffResult(
            tileDiff: tileDiff,
            changedRegions: [region],
            isSignificantChange: true
        )
    }

    // MARK: - Pixel Buffer Rendering

    /// Render a CGImage into a consistent 32-bit BGRA pixel buffer for comparison.
    private func renderToPixelBuffer(_ image: CGImage) -> UnsafeMutablePointer<UInt8>? {
        let width = image.width
        let height = image.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let totalBytes = bytesPerRow * height

        let pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: totalBytes)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
              ) else {
            pixels.deallocate()
            return nil
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    // MARK: - Tile Comparison

    /// Check if a single tile has changed beyond the noise threshold.
    /// Computes mean absolute per-channel pixel difference for the tile.
    private func isTileChanged(
        currentPixels: UnsafeMutablePointer<UInt8>,
        previousPixels: UnsafeMutablePointer<UInt8>,
        imageWidth: Int,
        tileX: Int, tileY: Int,
        tileW: Int, tileH: Int
    ) -> Bool {
        let bytesPerPixel = 4
        let bytesPerRow = imageWidth * bytesPerPixel
        var totalDiff: UInt64 = 0
        let pixelCount = tileW * tileH
        // 3 channels (skip alpha)
        let sampleCount = UInt64(pixelCount) * 3

        for y in tileY..<(tileY + tileH) {
            let rowOffset = y * bytesPerRow + tileX * bytesPerPixel
            for x in 0..<tileW {
                let offset = rowOffset + x * bytesPerPixel
                // BGRA layout: [B, G, R, A]
                let diffB = abs(Int(currentPixels[offset]) - Int(previousPixels[offset]))
                let diffG = abs(Int(currentPixels[offset + 1]) - Int(previousPixels[offset + 1]))
                let diffR = abs(Int(currentPixels[offset + 2]) - Int(previousPixels[offset + 2]))
                totalDiff += UInt64(diffB + diffG + diffR)
            }
        }

        guard sampleCount > 0 else { return false }
        let meanDiff = Double(totalDiff) / Double(sampleCount) / 255.0
        return meanDiff > noiseThreshold
    }

    // MARK: - Tile Merging

    /// Merge adjacent changed tiles into rectangular bounding regions via flood fill
    /// on the tile grid. Each connected component becomes one bounding rect, padded
    /// by `paddingPixels` on all sides (clamped to image bounds).
    private func mergeChangedTiles(
        changedTiles: [(row: Int, col: Int)],
        rows: Int, cols: Int,
        imageWidth: Int, imageHeight: Int
    ) -> [CGRect] {
        // Build a grid of changed/unchanged tiles
        var grid = Array(repeating: Array(repeating: false, count: cols), count: rows)
        for tile in changedTiles {
            grid[tile.row][tile.col] = true
        }

        var visited = Array(repeating: Array(repeating: false, count: cols), count: rows)
        var regions: [CGRect] = []

        // Flood fill to find connected components
        for tile in changedTiles {
            guard !visited[tile.row][tile.col] else { continue }

            var minRow = tile.row, maxRow = tile.row
            var minCol = tile.col, maxCol = tile.col
            var queue = [(tile.row, tile.col)]
            visited[tile.row][tile.col] = true

            while !queue.isEmpty {
                let (r, c) = queue.removeFirst()
                minRow = min(minRow, r)
                maxRow = max(maxRow, r)
                minCol = min(minCol, c)
                maxCol = max(maxCol, c)

                // Check 4-connected neighbors
                for (dr, dc) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let nr = r + dr, nc = c + dc
                    guard nr >= 0, nr < rows, nc >= 0, nc < cols else { continue }
                    guard grid[nr][nc] && !visited[nr][nc] else { continue }
                    visited[nr][nc] = true
                    queue.append((nr, nc))
                }
            }

            // Convert tile coordinates to pixel coordinates with padding
            let x = max(0, minCol * tileSize - paddingPixels)
            let y = max(0, minRow * tileSize - paddingPixels)
            let right = min(imageWidth, (maxCol + 1) * tileSize + paddingPixels)
            let bottom = min(imageHeight, (maxRow + 1) * tileSize + paddingPixels)

            regions.append(CGRect(
                x: x, y: y,
                width: right - x, height: bottom - y
            ))
        }

        return regions
    }

    // MARK: - Helpers

    /// Generate all tile coordinates for a given image size.
    private func tilesForDimensions(width: Int, height: Int) -> [(row: Int, col: Int)] {
        let cols = (width + tileSize - 1) / tileSize
        let rows = (height + tileSize - 1) / tileSize
        var tiles: [(row: Int, col: Int)] = []
        tiles.reserveCapacity(rows * cols)
        for row in 0..<rows {
            for col in 0..<cols {
                tiles.append((row: row, col: col))
            }
        }
        return tiles
    }
}
