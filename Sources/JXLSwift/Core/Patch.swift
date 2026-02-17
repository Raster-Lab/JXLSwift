/// JPEG XL Patches — Rectangular region copying from reference frames
///
/// Implements patch encoding per ISO/IEC 18181-1, allowing efficient
/// compression by copying rectangular regions from reference frames
/// rather than re-encoding them.

import Foundation

/// Represents a rectangular patch copied from a reference frame
public struct Patch: Sendable, Equatable {
    /// X coordinate in the current frame where this patch should be placed
    public let destX: Int
    
    /// Y coordinate in the current frame where this patch should be placed
    public let destY: Int
    
    /// Width of the patch in pixels
    public let width: Int
    
    /// Height of the patch in pixels
    public let height: Int
    
    /// Reference frame index to copy from (1-4, corresponding to saveAsReference slots)
    public let referenceIndex: UInt32
    
    /// X coordinate in the reference frame to copy from
    public let sourceX: Int
    
    /// Y coordinate in the reference frame to copy from
    public let sourceY: Int
    
    /// Similarity score between source and destination regions (0.0-1.0)
    /// 1.0 = perfect match, 0.0 = completely different
    public let similarity: Float
    
    /// Initialize a patch
    /// - Parameters:
    ///   - destX: Destination X coordinate
    ///   - destY: Destination Y coordinate
    ///   - width: Patch width
    ///   - height: Patch height
    ///   - referenceIndex: Reference frame index (1-4)
    ///   - sourceX: Source X coordinate in reference frame
    ///   - sourceY: Source Y coordinate in reference frame
    ///   - similarity: Similarity score (0.0-1.0)
    public init(
        destX: Int,
        destY: Int,
        width: Int,
        height: Int,
        referenceIndex: UInt32,
        sourceX: Int,
        sourceY: Int,
        similarity: Float = 1.0
    ) {
        self.destX = destX
        self.destY = destY
        self.width = width
        self.height = height
        self.referenceIndex = referenceIndex
        self.sourceX = sourceX
        self.sourceY = sourceY
        self.similarity = similarity
    }
    
    /// Check if this patch overlaps with another patch
    public func overlaps(with other: Patch) -> Bool {
        let xOverlap = destX < other.destX + other.width && destX + width > other.destX
        let yOverlap = destY < other.destY + other.height && destY + height > other.destY
        return xOverlap && yOverlap
    }
    
    /// Calculate the area of this patch in pixels
    public var area: Int {
        return width * height
    }
}

/// Manages patch detection and application for a frame
public struct PatchDetector {
    /// Configuration for patch detection
    private let config: PatchConfig
    
    /// Initialize patch detector with configuration
    public init(config: PatchConfig) {
        self.config = config
    }
    
    /// Detect patches between a current frame and a reference frame
    /// - Parameters:
    ///   - currentFrame: Frame to find patches for
    ///   - referenceFrame: Reference frame to search for matching regions
    ///   - referenceIndex: Index of the reference frame (1-4)
    /// - Returns: Array of detected patches sorted by area (largest first)
    public func detectPatches(
        currentFrame: ImageFrame,
        referenceFrame: ImageFrame,
        referenceIndex: UInt32
    ) -> [Patch] {
        guard config.enabled else { return [] }
        
        // Frames must have the same dimensions
        guard currentFrame.width == referenceFrame.width &&
              currentFrame.height == referenceFrame.height &&
              currentFrame.channels == referenceFrame.channels else {
            return []
        }
        
        var patches: [Patch] = []
        let blockSize = config.blockSize
        
        // Scan through the current frame in blocks
        for destY in stride(from: 0, to: currentFrame.height - blockSize, by: blockSize) {
            for destX in stride(from: 0, to: currentFrame.width - blockSize, by: blockSize) {
                // Try to find a matching region in the reference frame
                if let patch = findBestMatch(
                    currentFrame: currentFrame,
                    referenceFrame: referenceFrame,
                    destX: destX,
                    destY: destY,
                    referenceIndex: referenceIndex
                ) {
                    // Only add patch if it meets similarity threshold
                    if patch.similarity >= config.similarityThreshold {
                        patches.append(patch)
                    }
                }
            }
        }
        
        // Merge overlapping patches if beneficial
        patches = mergePatches(patches)
        
        // Sort by area (largest first) and limit to max patches per frame
        patches.sort { $0.area > $1.area }
        if patches.count > config.maxPatchesPerFrame {
            patches = Array(patches.prefix(config.maxPatchesPerFrame))
        }
        
        return patches
    }
    
    /// Find the best matching region in the reference frame for a given position
    private func findBestMatch(
        currentFrame: ImageFrame,
        referenceFrame: ImageFrame,
        destX: Int,
        destY: Int,
        referenceIndex: UInt32
    ) -> Patch? {
        let blockSize = config.blockSize
        let searchRadius = config.searchRadius * blockSize
        
        var bestSimilarity: Float = 0.0
        var bestSourceX = destX
        var bestSourceY = destY
        var bestWidth = blockSize
        var bestHeight = blockSize
        
        // Search in a region around the current position
        let minX = max(0, destX - searchRadius)
        let maxX = min(referenceFrame.width - blockSize, destX + searchRadius)
        let minY = max(0, destY - searchRadius)
        let maxY = min(referenceFrame.height - blockSize, destY + searchRadius)
        
        for sourceY in stride(from: minY, through: maxY, by: blockSize) {
            for sourceX in stride(from: minX, through: maxX, by: blockSize) {
                // Calculate similarity for this position
                let (similarity, width, height) = calculateSimilarity(
                    currentFrame: currentFrame,
                    referenceFrame: referenceFrame,
                    destX: destX,
                    destY: destY,
                    sourceX: sourceX,
                    sourceY: sourceY,
                    initialSize: blockSize
                )
                
                if similarity > bestSimilarity {
                    bestSimilarity = similarity
                    bestSourceX = sourceX
                    bestSourceY = sourceY
                    bestWidth = width
                    bestHeight = height
                }
            }
        }
        
        // Only return a patch if similarity meets threshold
        guard bestSimilarity >= config.similarityThreshold else {
            return nil
        }
        
        return Patch(
            destX: destX,
            destY: destY,
            width: bestWidth,
            height: bestHeight,
            referenceIndex: referenceIndex,
            sourceX: bestSourceX,
            sourceY: bestSourceY,
            similarity: bestSimilarity
        )
    }
    
    /// Calculate similarity between two regions and try to expand the match
    private func calculateSimilarity(
        currentFrame: ImageFrame,
        referenceFrame: ImageFrame,
        destX: Int,
        destY: Int,
        sourceX: Int,
        sourceY: Int,
        initialSize: Int
    ) -> (similarity: Float, width: Int, height: Int) {
        var width = initialSize
        var height = initialSize
        
        // Try to expand the patch as long as similarity remains high
        let maxExpansion = min(config.maxPatchSize, 
                              min(currentFrame.width - destX, currentFrame.height - destY))
        
        while width < maxExpansion && height < maxExpansion {
            let expandedWidth = min(width + initialSize, maxExpansion, 
                                   currentFrame.width - destX, referenceFrame.width - sourceX)
            let expandedHeight = min(height + initialSize, maxExpansion,
                                    currentFrame.height - destY, referenceFrame.height - sourceY)
            
            // Stop if no growth is possible
            if expandedWidth <= width && expandedHeight <= height {
                break
            }
            
            let expandedSimilarity = computeRegionSimilarity(
                currentFrame: currentFrame,
                referenceFrame: referenceFrame,
                destX: destX,
                destY: destY,
                sourceX: sourceX,
                sourceY: sourceY,
                width: expandedWidth,
                height: expandedHeight
            )
            
            // Stop expanding if similarity drops below threshold
            if expandedSimilarity < config.similarityThreshold {
                break
            }
            
            width = expandedWidth
            height = expandedHeight
        }
        
        // Calculate final similarity for the chosen size
        let finalSimilarity = computeRegionSimilarity(
            currentFrame: currentFrame,
            referenceFrame: referenceFrame,
            destX: destX,
            destY: destY,
            sourceX: sourceX,
            sourceY: sourceY,
            width: width,
            height: height
        )
        
        return (finalSimilarity, width, height)
    }
    
    /// Compute similarity between two rectangular regions
    /// Returns a value between 0.0 (completely different) and 1.0 (identical)
    /// Uses early termination if similarity drops below threshold
    private func computeRegionSimilarity(
        currentFrame: ImageFrame,
        referenceFrame: ImageFrame,
        destX: Int,
        destY: Int,
        sourceX: Int,
        sourceY: Int,
        width: Int,
        height: Int
    ) -> Float {
        var totalDifference: Double = 0.0
        var maxPossibleDifference: Double = 0.0
        let channels = currentFrame.channels
        let maxValue = Double((1 << currentFrame.bitsPerSample) - 1)
        let pixelCount = width * height * channels
        
        // Early termination threshold: if we've exceeded the allowed difference
        // for the configured similarity threshold, stop calculating
        let maxAllowedDifference = Double(pixelCount) * maxValue * (1.0 - Double(config.similarityThreshold))
        
        // Calculate per-pixel difference with early termination
        for y in 0..<height {
            for x in 0..<width {
                let currentPixelX = destX + x
                let currentPixelY = destY + y
                let refPixelX = sourceX + x
                let refPixelY = sourceY + y
                
                // Check bounds
                guard currentPixelX < currentFrame.width && currentPixelY < currentFrame.height &&
                      refPixelX < referenceFrame.width && refPixelY < referenceFrame.height else {
                    continue
                }
                
                for channel in 0..<channels {
                    let currentValue = currentFrame.getPixel(
                        x: currentPixelX, 
                        y: currentPixelY, 
                        channel: channel
                    )
                    let refValue = referenceFrame.getPixel(
                        x: refPixelX,
                        y: refPixelY,
                        channel: channel
                    )
                    
                    // Calculate absolute difference
                    let diff = abs(Double(currentValue) - Double(refValue))
                    totalDifference += diff
                    maxPossibleDifference += maxValue
                    
                    // Early termination: if difference already exceeds threshold, stop
                    if totalDifference > maxAllowedDifference {
                        return 0.0  // Definitely below threshold
                    }
                }
            }
        }
        
        // Avoid division by zero
        guard maxPossibleDifference > 0 else { return 0.0 }
        
        // Convert difference to similarity (1.0 = identical, 0.0 = maximum difference)
        let similarity = 1.0 - (totalDifference / maxPossibleDifference)
        return Float(similarity)
    }
    
    /// Merge overlapping patches to reduce overhead
    private func mergePatches(_ patches: [Patch]) -> [Patch] {
        var merged: [Patch] = []
        var used = Set<Int>()
        
        for i in 0..<patches.count {
            guard !used.contains(i) else { continue }
            
            var currentPatch = patches[i]
            used.insert(i)
            
            // Try to merge with other patches
            var didMerge = true
            while didMerge {
                didMerge = false
                
                for j in 0..<patches.count where !used.contains(j) {
                    let otherPatch = patches[j]
                    
                    // Only merge patches from the same reference frame
                    guard currentPatch.referenceIndex == otherPatch.referenceIndex else {
                        continue
                    }
                    
                    // Check if patches are adjacent or overlapping
                    if canMerge(currentPatch, otherPatch) {
                        currentPatch = mergeTwoPatches(currentPatch, otherPatch)
                        used.insert(j)
                        didMerge = true
                    }
                }
            }
            
            merged.append(currentPatch)
        }
        
        return merged
    }
    
    /// Check if two patches can be merged
    private func canMerge(_ p1: Patch, _ p2: Patch) -> Bool {
        // Must be from same reference
        guard p1.referenceIndex == p2.referenceIndex else { return false }
        
        // Check if horizontally adjacent
        if p1.destY == p2.destY && p1.height == p2.height &&
           p1.sourceY == p2.sourceY &&
           (p1.destX + p1.width == p2.destX || p2.destX + p2.width == p1.destX) {
            return true
        }
        
        // Check if vertically adjacent
        if p1.destX == p2.destX && p1.width == p2.width &&
           p1.sourceX == p2.sourceX &&
           (p1.destY + p1.height == p2.destY || p2.destY + p2.height == p1.destY) {
            return true
        }
        
        return false
    }
    
    /// Merge two adjacent patches into one
    private func mergeTwoPatches(_ p1: Patch, _ p2: Patch) -> Patch {
        let minDestX = min(p1.destX, p2.destX)
        let minDestY = min(p1.destY, p2.destY)
        let maxDestX = max(p1.destX + p1.width, p2.destX + p2.width)
        let maxDestY = max(p1.destY + p1.height, p2.destY + p2.height)
        
        let minSourceX = min(p1.sourceX, p2.sourceX)
        let minSourceY = min(p1.sourceY, p2.sourceY)
        
        return Patch(
            destX: minDestX,
            destY: minDestY,
            width: maxDestX - minDestX,
            height: maxDestY - minDestY,
            referenceIndex: p1.referenceIndex,
            sourceX: minSourceX,
            sourceY: minSourceY,
            similarity: min(p1.similarity, p2.similarity)
        )
    }
}
