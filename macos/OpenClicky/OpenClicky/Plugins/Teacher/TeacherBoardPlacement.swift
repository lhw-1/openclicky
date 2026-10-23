//
//  TeacherBoardPlacement.swift
//  OpenClicky
//
//  Where a lesson is drawn: the largest empty stretch of the screen the student is looking at
//  (the white margins beside a Google results page), found on the screenshot the question already
//  carries. The screen is cut into 16 pt cells; a cell is empty when its pixels barely vary; the
//  largest rectangle of empty cells that holds the board's shape wins. A plain light area gets ink
//  straight on the page, a plain dark one chalk, and a screen with no room gets a sheet of paper
//  over its quietest side. Pure apart from decoding the screenshot: unit-tested.
//

import AppKit
import CoreGraphics
import Foundation

/// How the board looks where it lands.
enum TeacherBoardStyle: Equatable, Sendable {
    /// Dark ink straight on a light, empty part of the page.
    case inkOnLightPage
    /// Light chalk straight on a dark, empty part of the screen.
    case chalkOnDarkPage
    /// A sheet of paper floating over a busy screen (or holding a picture).
    case paper
}

/// The screen cut into cells: for each, its mean brightness (0…1) and whether it is empty.
struct TeacherScreenGrid: Equatable {
    let columns: Int
    let rows: Int
    /// Row-major, `rows * columns`.
    let isEmpty: [Bool]
    let brightness: [Double]

    func index(column: Int, row: Int) -> Int { row * columns + column }
}

/// A rectangle of cells.
struct TeacherCellRect: Equatable {
    let column: Int
    let row: Int
    let width: Int
    let height: Int
}

enum TeacherBoardPlacement {
    /// One cell, in points.
    static let cellSizeInPoints: CGFloat = 16
    /// A cell whose brightest and darkest pixels differ by less than this (0…1) is empty.
    static let emptyCellContrastLimit: Double = 0.06
    /// Smaller than this and the drawing is too small to read; the paper sheet is used instead.
    static let minimumBoardWidthInPoints: CGFloat = 340
    static let maximumBoardWidthInPoints: CGFloat = 620
    /// Kept clear: the menu bar and the island at the top.
    static let topBandInPoints: CGFloat = 64

    struct Placement: Equatable {
        /// AppKit global coordinates (origin bottom-left of the main display).
        let frame: CGRect
        let style: TeacherBoardStyle
    }

    /// The board for a sketch (or a picture) of `aspectRatio` (width / height) on the captured
    /// display. Without a usable screenshot it falls back to the paper sheet on the side away from
    /// the mouse.
    @MainActor static func placement(aspectRatio: CGFloat, in capture: CompanionScreenCapture?, mouseLocation: CGPoint, forcePaper: Bool = false) -> Placement {
        let displayFrame = capture?.displayFrame ?? NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        guard let capture, let grid = grid(fromJPEG: capture.imageData, displaySizeInPoints: displayFrame.size) else {
            return paperFallback(aspectRatio: aspectRatio, displayFrame: displayFrame, mouseLocation: mouseLocation)
        }
        return placement(aspectRatio: aspectRatio, grid: grid, displayFrame: displayFrame, mouseLocation: mouseLocation, forcePaper: forcePaper)
    }

    static func placement(aspectRatio: CGFloat, grid: TeacherScreenGrid, displayFrame: CGRect, mouseLocation: CGPoint, forcePaper: Bool = false) -> Placement {
        let safeAspect = min(max(aspectRatio, 0.4), 3)
        let topRowsToSkip = Int((topBandInPoints / cellSizeInPoints).rounded(.up))
        guard !forcePaper,
              let best = largestEmptyRectangle(in: grid, aspectRatio: safeAspect, skippingTopRows: topRowsToSkip) else {
            return paperFallback(aspectRatio: safeAspect, displayFrame: displayFrame, mouseLocation: mouseLocation)
        }
        // The board inside the empty rectangle: its shape, one cell of breathing room each side,
        // centred, and no bigger than reads comfortably.
        let availableWidth = CGFloat(best.width - 2) * cellSizeInPoints
        let availableHeight = CGFloat(best.height - 2) * cellSizeInPoints
        var boardWidth = min(availableWidth, availableHeight * safeAspect, maximumBoardWidthInPoints)
        var boardHeight = boardWidth / safeAspect
        if boardWidth < minimumBoardWidthInPoints {
            return paperFallback(aspectRatio: safeAspect, displayFrame: displayFrame, mouseLocation: mouseLocation)
        }
        boardWidth = boardWidth.rounded()
        boardHeight = boardHeight.rounded()
        let rectangleMidX = (CGFloat(best.column) + CGFloat(best.width) / 2) * cellSizeInPoints
        let rectangleMidYFromTop = (CGFloat(best.row) + CGFloat(best.height) / 2) * cellSizeInPoints
        let frame = CGRect(
            x: displayFrame.minX + rectangleMidX - boardWidth / 2,
            y: displayFrame.maxY - rectangleMidYFromTop - boardHeight / 2,
            width: boardWidth,
            height: boardHeight)
        let brightness = meanBrightness(of: best, in: grid)
        let style: TeacherBoardStyle = brightness >= 0.6 ? .inkOnLightPage : (brightness <= 0.3 ? .chalkOnDarkPage : .paper)
        return Placement(frame: frame, style: style)
    }

    /// The sheet of paper: about a third of the display, on the half away from the mouse, under
    /// the top band.
    static func paperFallback(aspectRatio: CGFloat, displayFrame: CGRect, mouseLocation: CGPoint) -> Placement {
        let safeAspect = min(max(aspectRatio, 0.4), 3)
        var width = min(displayFrame.width * 0.36, maximumBoardWidthInPoints)
        var height = width / safeAspect
        let maximumHeight = displayFrame.height - topBandInPoints - 48
        if height > maximumHeight {
            height = maximumHeight
            width = height * safeAspect
        }
        let margin: CGFloat = 32
        let mouseIsOnTheRight = mouseLocation.x > displayFrame.midX
        let x = mouseIsOnTheRight ? displayFrame.minX + margin : displayFrame.maxX - margin - width
        let usableMidY = displayFrame.minY + (displayFrame.height - topBandInPoints) / 2
        return Placement(frame: CGRect(x: x.rounded(), y: (usableMidY - height / 2).rounded(), width: width.rounded(), height: height.rounded()), style: .paper)
    }

    /// The empty rectangle that holds the biggest board of `aspectRatio` (cells are square), found
    /// with the histogram method: every maximal empty rectangle is seen once per row it ends on.
    static func largestEmptyRectangle(in grid: TeacherScreenGrid, aspectRatio: CGFloat, skippingTopRows: Int = 0) -> TeacherCellRect? {
        guard grid.columns > 0, grid.rows > 0 else { return nil }
        var heights = [Int](repeating: 0, count: grid.columns)
        var best: TeacherCellRect?
        var bestBoardWidth: CGFloat = 0

        func consider(column: Int, width: Int, height: Int, bottomRow: Int) {
            guard width >= 3, height >= 3 else { return }
            // Inside a margin of one cell each side, the widest board of this shape that fits.
            let boardWidth = min(CGFloat(width - 2), CGFloat(height - 2) * aspectRatio)
            // Between two that hold the same board, the roomier one: the board sits in its middle
            // with more white around it.
            let isRoomierTie = boardWidth == bestBoardWidth && width * height > (best.map { $0.width * $0.height } ?? 0)
            if boardWidth > bestBoardWidth || isRoomierTie {
                bestBoardWidth = boardWidth
                best = TeacherCellRect(column: column, row: bottomRow - height + 1, width: width, height: height)
            }
        }

        for row in 0..<grid.rows {
            for column in 0..<grid.columns {
                let empty = row >= skippingTopRows && grid.isEmpty[grid.index(column: column, row: row)]
                heights[column] = empty ? heights[column] + 1 : 0
            }
            // Largest rectangles under the histogram of `heights`.
            var stack: [Int] = []
            for column in 0...grid.columns {
                let currentHeight = column == grid.columns ? 0 : heights[column]
                while let top = stack.last, heights[top] >= currentHeight {
                    stack.removeLast()
                    let height = heights[top]
                    let leftEdge = (stack.last ?? -1) + 1
                    let width = column - leftEdge
                    if height > 0 { consider(column: leftEdge, width: width, height: height, bottomRow: row) }
                }
                stack.append(column)
            }
        }
        return best
    }

    static func meanBrightness(of rectangle: TeacherCellRect, in grid: TeacherScreenGrid) -> Double {
        var total = 0.0
        var count = 0
        for row in rectangle.row..<(rectangle.row + rectangle.height) {
            for column in rectangle.column..<(rectangle.column + rectangle.width) {
                total += grid.brightness[grid.index(column: column, row: row)]
                count += 1
            }
        }
        return count == 0 ? 0 : total / Double(count)
    }

    /// The screenshot drawn small in greys (two pixels per cell-row of 16 pt would lose captions,
    /// so eight pixels per cell side), then each cell's contrast and brightness.
    static func grid(fromJPEG imageData: Data, displaySizeInPoints: CGSize) -> TeacherScreenGrid? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let columns = Int(displaySizeInPoints.width / cellSizeInPoints)
        let rows = Int(displaySizeInPoints.height / cellSizeInPoints)
        guard columns > 0, rows > 0 else { return nil }
        let pixelsPerCell = 8
        let width = columns * pixelsPerCell
        let height = rows * pixelsPerCell
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }
        return grid(fromGreyPixels: pixels, width: width, height: height, pixelsPerCell: pixelsPerCell)
    }

    /// `pixels` row 0 is the top of the screen (CGContext's memory order for a bitmap).
    static func grid(fromGreyPixels pixels: [UInt8], width: Int, height: Int, pixelsPerCell: Int) -> TeacherScreenGrid {
        let columns = width / pixelsPerCell
        let rows = height / pixelsPerCell
        var isEmpty = [Bool](repeating: false, count: columns * rows)
        var brightness = [Double](repeating: 0, count: columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                var darkest: UInt8 = 255
                var brightest: UInt8 = 0
                var total = 0
                for y in (row * pixelsPerCell)..<((row + 1) * pixelsPerCell) {
                    for x in (column * pixelsPerCell)..<((column + 1) * pixelsPerCell) {
                        let value = pixels[y * width + x]
                        darkest = min(darkest, value)
                        brightest = max(brightest, value)
                        total += Int(value)
                    }
                }
                let index = row * columns + column
                isEmpty[index] = Double(brightest - darkest) / 255 < emptyCellContrastLimit
                brightness[index] = Double(total) / Double(pixelsPerCell * pixelsPerCell) / 255
            }
        }
        return TeacherScreenGrid(columns: columns, rows: rows, isEmpty: isEmpty, brightness: brightness)
    }
}
