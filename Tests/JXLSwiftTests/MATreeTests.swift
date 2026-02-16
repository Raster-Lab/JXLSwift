import XCTest
@testable import JXLSwift

final class MATreeTests: XCTestCase {

    // MARK: - Setup

    private func makeEncoder(effort: EncodingEffort = .squirrel) -> ModularEncoder {
        var options = EncodingOptions.lossless
        options.effort = effort
        return ModularEncoder(
            hardware: HardwareCapabilities.detect(),
            options: options
        )
    }

    // MARK: - MAProperty Tests

    func testMAProperty_AllCases_HaveUniqueRawValues() {
        var seen = Set<Int>()
        for prop in MAProperty.allCases {
            XCTAssertTrue(seen.insert(prop.rawValue).inserted,
                          "Duplicate rawValue \(prop.rawValue) for \(prop)")
        }
    }

    func testMAProperty_CaseCount() {
        XCTAssertEqual(MAProperty.allCases.count, 10,
                       "Should have 10 property types")
    }

    // MARK: - MAPredictor Tests

    func testMAPredictor_AllCases_HaveUniqueRawValues() {
        var seen = Set<Int>()
        for pred in MAPredictor.allCases {
            XCTAssertTrue(seen.insert(pred.rawValue).inserted,
                          "Duplicate rawValue \(pred.rawValue) for \(pred)")
        }
    }

    func testMAPredictor_CaseCount() {
        XCTAssertEqual(MAPredictor.allCases.count, 8,
                       "Should have 8 predictor modes")
    }

    // MARK: - MANode Tests

    func testMANode_Decision_StoresFields() {
        let node = MANode.decision(property: .gradientH, threshold: 42, left: 1, right: 2)
        if case let .decision(property, threshold, left, right) = node {
            XCTAssertEqual(property, .gradientH)
            XCTAssertEqual(threshold, 42)
            XCTAssertEqual(left, 1)
            XCTAssertEqual(right, 2)
        } else {
            XCTFail("Expected decision node")
        }
    }

    func testMANode_Leaf_StoresFields() {
        let node = MANode.leaf(predictor: .med, context: 5)
        if case let .leaf(predictor, context) = node {
            XCTAssertEqual(predictor, .med)
            XCTAssertEqual(context, 5)
        } else {
            XCTFail("Expected leaf node")
        }
    }

    // MARK: - MATree Build Tests

    func testBuildDefault_NodeCount() {
        let tree = MATree.buildDefault()
        XCTAssertEqual(tree.nodes.count, 7, "Default tree should have 7 nodes")
    }

    func testBuildDefault_ContextCount() {
        let tree = MATree.buildDefault()
        XCTAssertEqual(tree.contextCount, 4, "Default tree should have 4 contexts")
    }

    func testBuildDefault_RootIsDecision() {
        let tree = MATree.buildDefault()
        if case .decision = tree.nodes[0] {
            // OK
        } else {
            XCTFail("Root should be a decision node")
        }
    }

    func testBuildDefault_AllLeafContextsValid() {
        let tree = MATree.buildDefault()
        for node in tree.nodes {
            if case let .leaf(_, context) = node {
                XCTAssertGreaterThanOrEqual(context, 0)
                XCTAssertLessThan(context, tree.contextCount)
            }
        }
    }

    func testBuildDefault_AllDecisionChildrenInBounds() {
        let tree = MATree.buildDefault()
        for node in tree.nodes {
            if case let .decision(_, _, left, right) = node {
                XCTAssertGreaterThanOrEqual(left, 0)
                XCTAssertLessThan(left, tree.nodes.count)
                XCTAssertGreaterThanOrEqual(right, 0)
                XCTAssertLessThan(right, tree.nodes.count)
            }
        }
    }

    func testBuildExtended_NodeCount() {
        let tree = MATree.buildExtended()
        XCTAssertEqual(tree.nodes.count, 15, "Extended tree should have 15 nodes")
    }

    func testBuildExtended_ContextCount() {
        let tree = MATree.buildExtended()
        XCTAssertEqual(tree.contextCount, 8, "Extended tree should have 8 contexts")
    }

    func testBuildExtended_AllLeafContextsValid() {
        let tree = MATree.buildExtended()
        for node in tree.nodes {
            if case let .leaf(_, context) = node {
                XCTAssertGreaterThanOrEqual(context, 0)
                XCTAssertLessThan(context, tree.contextCount)
            }
        }
    }

    func testBuildExtended_AllDecisionChildrenInBounds() {
        let tree = MATree.buildExtended()
        for node in tree.nodes {
            if case let .decision(_, _, left, right) = node {
                XCTAssertGreaterThanOrEqual(left, 0)
                XCTAssertLessThan(left, tree.nodes.count)
                XCTAssertGreaterThanOrEqual(right, 0)
                XCTAssertLessThan(right, tree.nodes.count)
            }
        }
    }

    func testBuildExtended_LeafContextsAreUnique() {
        let tree = MATree.buildExtended()
        var contexts = Set<Int>()
        for node in tree.nodes {
            if case let .leaf(_, context) = node {
                contexts.insert(context)
            }
        }
        XCTAssertEqual(contexts.count, tree.contextCount,
                       "Each leaf should have a unique context index")
    }

    // MARK: - MATree Traversal Tests

    func testTraverse_SmoothArea_DefaultTree_SelectsMED() {
        let tree = MATree.buildDefault()
        // Smooth area: low gradients
        let (predictor, context) = tree.traverse { property in
            switch property {
            case .gradientH: return 0     // low horizontal gradient
            case .gradientV: return 0     // low vertical gradient
            default: return 0
            }
        }
        XCTAssertEqual(predictor, .med,
                       "Smooth area should select MED predictor")
        XCTAssertEqual(context, 0)
    }

    func testTraverse_VerticalEdge_DefaultTree_SelectsWest() {
        let tree = MATree.buildDefault()
        // Vertical edge: low horizontal gradient, high vertical gradient
        let (predictor, _) = tree.traverse { property in
            switch property {
            case .gradientH: return 5     // low
            case .gradientV: return 50    // high (> 16)
            default: return 0
            }
        }
        XCTAssertEqual(predictor, .west,
                       "Vertical edge should select West predictor")
    }

    func testTraverse_HorizontalEdge_DefaultTree_SelectsNorth() {
        let tree = MATree.buildDefault()
        // Horizontal edge: high horizontal gradient, low vertical gradient
        let (predictor, _) = tree.traverse { property in
            switch property {
            case .gradientH: return 50    // high (> 16)
            case .gradientV: return 5     // low
            default: return 0
            }
        }
        XCTAssertEqual(predictor, .north,
                       "Horizontal edge should select North predictor")
    }

    func testTraverse_TexturedArea_DefaultTree_SelectsSelectGradient() {
        let tree = MATree.buildDefault()
        // Textured: both gradients high
        let (predictor, _) = tree.traverse { property in
            switch property {
            case .gradientH: return 50    // high
            case .gradientV: return 50    // high
            default: return 0
            }
        }
        XCTAssertEqual(predictor, .selectGradient,
                       "Textured area should select gradient-adaptive predictor")
    }

    func testTraverse_ExtendedTree_VerySmoothArea_SelectsMED() {
        let tree = MATree.buildExtended()
        // Very smooth: low gradients, very low residuals
        let (predictor, context) = tree.traverse { property in
            switch property {
            case .gradientH: return 0
            case .gradientV: return 0
            case .maxAbsResidual: return 0  // ≤ 4
            default: return 0
            }
        }
        XCTAssertEqual(predictor, .med,
                       "Very smooth area in extended tree should select MED")
        XCTAssertEqual(context, 0)
    }

    func testTraverse_ExtendedTree_SlightlyNoisySmooth_SelectsMED() {
        let tree = MATree.buildExtended()
        let (predictor, context) = tree.traverse { property in
            switch property {
            case .gradientH: return 5
            case .gradientV: return 5
            case .maxAbsResidual: return 10  // > 4
            default: return 0
            }
        }
        XCTAssertEqual(predictor, .med,
                       "Slightly noisy smooth area should still select MED")
        XCTAssertEqual(context, 1)
    }

    func testTraverse_ExtendedTree_HighTexture_SelectsZero() {
        let tree = MATree.buildExtended()
        let (predictor, context) = tree.traverse { property in
            switch property {
            case .gradientH: return 100
            case .gradientV: return 100
            case .maxAbsResidual: return 200  // > 64
            default: return 0
            }
        }
        XCTAssertEqual(predictor, .zero,
                       "High texture should select zero predictor")
        XCTAssertEqual(context, 7)
    }

    func testTraverse_ThresholdBoundary_LeftInclusive() {
        let tree = MATree.buildDefault()
        // Test that threshold 16 is inclusive (≤ 16 goes left)
        let (predictor, _) = tree.traverse { property in
            switch property {
            case .gradientH: return 16    // exactly at threshold
            case .gradientV: return 16    // exactly at threshold
            default: return 0
            }
        }
        XCTAssertEqual(predictor, .med,
                       "gradH == 16 and gradV == 16 should go left (smooth area)")
    }

    func testTraverse_ThresholdBoundary_RightExclusive() {
        let tree = MATree.buildDefault()
        let (predictor, _) = tree.traverse { property in
            switch property {
            case .gradientH: return 17    // just above threshold
            case .gradientV: return 0
            default: return 0
            }
        }
        XCTAssertEqual(predictor, .north,
                       "gradH == 17 should go right (horizontal edge)")
    }

    // MARK: - Property Evaluation Tests

    func testEvaluateProperty_ChannelIndex() {
        let data: [UInt16] = [100]
        let residuals: [Int32] = [0]
        let value = MATree.evaluateProperty(
            .channelIndex, data: data, residuals: residuals,
            x: 0, y: 0, width: 1, height: 1, channel: 2
        )
        XCTAssertEqual(value, 2)
    }

    func testEvaluateProperty_GradientH_SmoothArea() {
        // 3x3 uniform image
        let data: [UInt16] = [50, 50, 50, 50, 50, 50, 50, 50, 50]
        let residuals = [Int32](repeating: 0, count: 9)
        let value = MATree.evaluateProperty(
            .gradientH, data: data, residuals: residuals,
            x: 1, y: 1, width: 3, height: 3, channel: 0
        )
        XCTAssertEqual(value, 0, "Uniform image should have zero horizontal gradient")
    }

    func testEvaluateProperty_GradientH_HorizontalEdge() {
        // 3x3 with horizontal gradient
        let data: [UInt16] = [10, 50, 90,
                              10, 50, 90,
                              10, 50, 90]
        let residuals = [Int32](repeating: 0, count: 9)
        let value = MATree.evaluateProperty(
            .gradientH, data: data, residuals: residuals,
            x: 2, y: 1, width: 3, height: 3, channel: 0
        )
        // W = data[1*3+1] = 50, NW = data[0*3+1] = 50
        // gradH = abs(50 - 50) = 0
        XCTAssertEqual(value, 0,
                       "Same W and NW values produce zero horizontal gradient")
        
        // Test at (1,1) where NW=10 and W=10 → also 0
        let value2 = MATree.evaluateProperty(
            .gradientH, data: data, residuals: residuals,
            x: 1, y: 1, width: 3, height: 3, channel: 0
        )
        // W = data[1*3+0] = 10, NW = data[0*3+0] = 10
        // gradH = abs(10 - 10) = 0
        XCTAssertEqual(value2, 0)
    }
    
    func testEvaluateProperty_GradientH_DiagonalGradient() {
        // Image with values that create non-zero W-NW gradient
        let data: [UInt16] = [10, 30,
                              50, 70]
        let residuals = [Int32](repeating: 0, count: 4)
        let value = MATree.evaluateProperty(
            .gradientH, data: data, residuals: residuals,
            x: 1, y: 1, width: 2, height: 2, channel: 0
        )
        // W=50, NW=10, gradH = abs(50 - 10) = 40
        XCTAssertEqual(value, 40)
    }

    func testEvaluateProperty_GradientV_VerticalEdge() {
        // 3x3 with vertical gradient
        let data: [UInt16] = [10, 10, 10,
                              50, 50, 50,
                              90, 90, 90]
        let residuals = [Int32](repeating: 0, count: 9)
        let value = MATree.evaluateProperty(
            .gradientV, data: data, residuals: residuals,
            x: 1, y: 2, width: 3, height: 3, channel: 0
        )
        // N=50, NW=50, gradV = abs(50 - 50) = 0
        XCTAssertEqual(value, 0)
    }

    func testEvaluateProperty_NorthValue() {
        let data: [UInt16] = [100, 200, 300, 400]
        let residuals = [Int32](repeating: 0, count: 4)
        let value = MATree.evaluateProperty(
            .northValue, data: data, residuals: residuals,
            x: 0, y: 1, width: 2, height: 2, channel: 0
        )
        XCTAssertEqual(value, 100, "North of (0,1) should be (0,0) = 100")
    }

    func testEvaluateProperty_WestValue() {
        let data: [UInt16] = [100, 200, 300, 400]
        let residuals = [Int32](repeating: 0, count: 4)
        let value = MATree.evaluateProperty(
            .westValue, data: data, residuals: residuals,
            x: 1, y: 0, width: 2, height: 2, channel: 0
        )
        XCTAssertEqual(value, 100, "West of (1,0) should be (0,0) = 100")
    }

    func testEvaluateProperty_NorthWestValue() {
        let data: [UInt16] = [100, 200, 300, 400]
        let residuals = [Int32](repeating: 0, count: 4)
        let value = MATree.evaluateProperty(
            .northWestValue, data: data, residuals: residuals,
            x: 1, y: 1, width: 2, height: 2, channel: 0
        )
        XCTAssertEqual(value, 100, "NW of (1,1) should be (0,0) = 100")
    }

    func testEvaluateProperty_WestMinusNW() {
        let data: [UInt16] = [10, 30, 20, 50]
        let residuals = [Int32](repeating: 0, count: 4)
        let value = MATree.evaluateProperty(
            .westMinusNW, data: data, residuals: residuals,
            x: 1, y: 1, width: 2, height: 2, channel: 0
        )
        // W=20, NW=10, W-NW=10
        XCTAssertEqual(value, 10)
    }

    func testEvaluateProperty_NorthMinusNW() {
        let data: [UInt16] = [10, 30, 20, 50]
        let residuals = [Int32](repeating: 0, count: 4)
        let value = MATree.evaluateProperty(
            .northMinusNW, data: data, residuals: residuals,
            x: 1, y: 1, width: 2, height: 2, channel: 0
        )
        // N=30, NW=10, N-NW=20
        XCTAssertEqual(value, 20)
    }

    func testEvaluateProperty_NorthMinusNE_InteriorPixel() {
        let data: [UInt16] = [10, 20, 30,
                              40, 50, 60,
                              70, 80, 90]
        let residuals = [Int32](repeating: 0, count: 9)
        let value = MATree.evaluateProperty(
            .northMinusNE, data: data, residuals: residuals,
            x: 1, y: 1, width: 3, height: 3, channel: 0
        )
        // N=20, NE=30 → N-NE = -10
        XCTAssertEqual(value, -10)
    }

    func testEvaluateProperty_NorthMinusNE_RightEdge() {
        let data: [UInt16] = [10, 20,
                              30, 40]
        let residuals = [Int32](repeating: 0, count: 4)
        let value = MATree.evaluateProperty(
            .northMinusNE, data: data, residuals: residuals,
            x: 1, y: 1, width: 2, height: 2, channel: 0
        )
        // x=width-1, NE unavailable → NE defaults to N=20, N-NE=0
        XCTAssertEqual(value, 0,
                       "NE should default to N at right edge")
    }

    func testEvaluateProperty_MaxAbsResidual_AllZero() {
        let data: [UInt16] = [0, 0, 0, 0]
        let residuals: [Int32] = [0, 0, 0, 0]
        let value = MATree.evaluateProperty(
            .maxAbsResidual, data: data, residuals: residuals,
            x: 1, y: 1, width: 2, height: 2, channel: 0
        )
        XCTAssertEqual(value, 0)
    }

    func testEvaluateProperty_MaxAbsResidual_WithResiduals() {
        let data: [UInt16] = [0, 0, 0, 0, 0, 0]
        let residuals: [Int32] = [-5, 10, 0, -20, 0, 0]
        // At (1,1) with width=3:
        // rN = residuals[(0)*3+1] = 10
        // rW = residuals[(1)*3+0] = -20
        // rNW = residuals[(0)*3+0] = -5
        // max(abs(10), abs(-20), abs(-5)) = 20
        let value = MATree.evaluateProperty(
            .maxAbsResidual, data: data, residuals: residuals,
            x: 1, y: 1, width: 3, height: 2, channel: 0
        )
        XCTAssertEqual(value, 20)
    }

    // MARK: - Boundary Handling Tests

    func testEvaluateProperty_FirstPixel_GradientH_IsZero() {
        // 32768 is the midpoint of the 16-bit range, used as the unsigned
        // representation of signed-zero after the Reversible Colour Transform
        // (RCT) offsets chroma channels by +32768.
        let data: [UInt16] = [32768]
        let residuals: [Int32] = [0]
        let value = MATree.evaluateProperty(
            .gradientH, data: data, residuals: residuals,
            x: 0, y: 0, width: 1, height: 1, channel: 0
        )
        XCTAssertEqual(value, 0,
                       "First pixel gradient should be 0 (no neighbours)")
    }

    func testEvaluateProperty_FirstRow_GradientH_UsesWestFallback() {
        // In the first row, NW falls back to W, so gradH = abs(W-W) = 0
        let data: [UInt16] = [32768, 32800]
        let residuals: [Int32] = [0, 0]
        let value = MATree.evaluateProperty(
            .gradientH, data: data, residuals: residuals,
            x: 1, y: 0, width: 2, height: 1, channel: 0
        )
        // W=32768, NW falls back to W=32768, gradH=abs(32768-32768)=0
        XCTAssertEqual(value, 0,
                       "First row gradientH should use W as NW fallback")
    }

    func testEvaluateProperty_FirstColumn_GradientV_UsesNorthFallback() {
        // In the first column, NW falls back to N, so gradV = abs(N-N) = 0
        let data: [UInt16] = [32768,
                              32800]
        let residuals: [Int32] = [0, 0]
        let value = MATree.evaluateProperty(
            .gradientV, data: data, residuals: residuals,
            x: 0, y: 1, width: 1, height: 2, channel: 0
        )
        // N=32768, NW falls back to N=32768, gradV=abs(32768-32768)=0
        XCTAssertEqual(value, 0,
                       "First column gradientV should use N as NW fallback")
    }

    func testEvaluateProperty_FirstRow_NorthFallsBackToWest() {
        // y=0, x>0: N unavailable → N falls back to W
        let data: [UInt16] = [100, 200]
        let residuals: [Int32] = [0, 0]
        let n = MATree.evaluateProperty(
            .northValue, data: data, residuals: residuals,
            x: 1, y: 0, width: 2, height: 1, channel: 0
        )
        XCTAssertEqual(n, 100,
                       "N should fall back to W when y=0")
    }

    func testEvaluateProperty_FirstColumn_WestFallsBackToNorth() {
        // x=0, y>0: W unavailable → W falls back to N
        let data: [UInt16] = [100,
                              200]
        let residuals: [Int32] = [0, 0]
        let w = MATree.evaluateProperty(
            .westValue, data: data, residuals: residuals,
            x: 0, y: 1, width: 1, height: 2, channel: 0
        )
        XCTAssertEqual(w, 100,
                       "W should fall back to N when x=0")
    }

    // MARK: - Predictor Application Tests

    func testApplyPredictor_Zero_AlwaysReturnsZero() {
        let data: [UInt16] = [100, 200, 300, 400]
        let predicted = MATree.applyPredictor(
            .zero, data: data, x: 1, y: 1, width: 2, height: 2
        )
        XCTAssertEqual(predicted, 0)
    }

    func testApplyPredictor_West_ReturnsWestNeighbour() {
        let data: [UInt16] = [10, 20,
                              30, 40]
        let predicted = MATree.applyPredictor(
            .west, data: data, x: 1, y: 1, width: 2, height: 2
        )
        XCTAssertEqual(predicted, 30)
    }

    func testApplyPredictor_North_ReturnsNorthNeighbour() {
        let data: [UInt16] = [10, 20,
                              30, 40]
        let predicted = MATree.applyPredictor(
            .north, data: data, x: 1, y: 1, width: 2, height: 2
        )
        XCTAssertEqual(predicted, 20)
    }

    func testApplyPredictor_AverageWN_ReturnsFlooredAverage() {
        let data: [UInt16] = [10, 20,
                              30, 40]
        let predicted = MATree.applyPredictor(
            .averageWN, data: data, x: 1, y: 1, width: 2, height: 2
        )
        // W=30, N=20 → (30+20)/2 = 25
        XCTAssertEqual(predicted, 25)
    }

    func testApplyPredictor_MED_LinearGradient() {
        let data: [UInt16] = [10, 20,
                              30, 0]
        let predicted = MATree.applyPredictor(
            .med, data: data, x: 1, y: 1, width: 2, height: 2
        )
        // N=20, W=30, NW=10 → 20+30-10 = 40
        XCTAssertEqual(predicted, 40)
    }

    func testApplyPredictor_MED_ClampsNegative() {
        let data: [UInt16] = [100, 10,
                              10,  0]
        let predicted = MATree.applyPredictor(
            .med, data: data, x: 1, y: 1, width: 2, height: 2
        )
        // N=10, W=10, NW=100 → 10+10-100 = -80, clamped to 0
        XCTAssertEqual(predicted, 0)
    }

    func testApplyPredictor_MED_ClampsToMax() {
        let data: [UInt16] = [0, 60000,
                              60000, 0]
        let predicted = MATree.applyPredictor(
            .med, data: data, x: 1, y: 1, width: 2, height: 2
        )
        // N=60000, W=60000, NW=0 → 120000, clamped to 65535
        XCTAssertEqual(predicted, 65535)
    }

    func testApplyPredictor_SelectGradient_ChoosesWest_WhenVerticalGradientSmaller() {
        // N=100, W=50, NW=90
        // gradH = abs(W-NW) = abs(50-90) = 40
        // gradV = abs(N-NW) = abs(100-90) = 10
        // gradV < gradH → returns W = 50
        let data: [UInt16] = [90, 100,
                              50,  0]
        let predicted = MATree.applyPredictor(
            .selectGradient, data: data, x: 1, y: 1, width: 2, height: 2
        )
        XCTAssertEqual(predicted, 50,
                       "Should select W when vertical gradient is smaller")
    }

    func testApplyPredictor_SelectGradient_ChoosesNorth_WhenHorizontalGradientSmaller() {
        // N=100, W=50, NW=40
        // gradH = abs(W-NW) = abs(50-40) = 10
        // gradV = abs(N-NW) = abs(100-40) = 60
        // gradV >= gradH → returns N = 100
        let data: [UInt16] = [40, 100,
                              50,  0]
        let predicted = MATree.applyPredictor(
            .selectGradient, data: data, x: 1, y: 1, width: 2, height: 2
        )
        XCTAssertEqual(predicted, 100,
                       "Should select N when horizontal gradient is smaller")
    }

    func testApplyPredictor_AverageWNW() {
        let data: [UInt16] = [10, 20,
                              30, 0]
        let predicted = MATree.applyPredictor(
            .averageWNW, data: data, x: 1, y: 1, width: 2, height: 2
        )
        // W=30, NW=10 → (30+10)/2 = 20
        XCTAssertEqual(predicted, 20)
    }

    func testApplyPredictor_AverageNNW() {
        let data: [UInt16] = [10, 20,
                              30, 0]
        let predicted = MATree.applyPredictor(
            .averageNNW, data: data, x: 1, y: 1, width: 2, height: 2
        )
        // N=20, NW=10 → (20+10)/2 = 15
        XCTAssertEqual(predicted, 15)
    }

    func testApplyPredictor_FirstPixel_AllReturnZero() {
        let data: [UInt16] = [42]
        for predictor in MAPredictor.allCases {
            let predicted = MATree.applyPredictor(
                predictor, data: data, x: 0, y: 0, width: 1, height: 1
            )
            XCTAssertEqual(predicted, 0,
                           "\(predictor) should return 0 for first pixel")
        }
    }

    // MARK: - Encoder MA Tree Integration Tests

    func testEncoder_HighEffort_UsesExtendedTree() {
        let encoder = makeEncoder(effort: .squirrel)
        XCTAssertEqual(encoder.maTree.contextCount, 8,
                       "Squirrel effort should use extended tree (8 contexts)")
    }

    func testEncoder_LowEffort_UsesDefaultTree() {
        let encoder = makeEncoder(effort: .falcon)
        XCTAssertEqual(encoder.maTree.contextCount, 4,
                       "Falcon effort should use default tree (4 contexts)")
    }

    func testEncoder_KittenEffort_UsesExtendedTree() {
        let encoder = makeEncoder(effort: .kitten)
        XCTAssertEqual(encoder.maTree.contextCount, 8,
                       "Kitten effort should use extended tree")
    }

    func testEncoder_CheetahEffort_UsesDefaultTree() {
        let encoder = makeEncoder(effort: .cheetah)
        XCTAssertEqual(encoder.maTree.contextCount, 4,
                       "Cheetah effort should use default tree")
    }

    // MARK: - MA Prediction Integration Tests

    func testApplyMAPrediction_UniformData_AllZeroResiduals() {
        let encoder = makeEncoder()
        let data = [UInt16](repeating: 128, count: 16)
        let residuals = encoder.applyMAPrediction(data: data, width: 4, height: 4, channel: 0)

        // First pixel residual is 128 (predicted 0), rest should converge
        XCTAssertEqual(residuals[0], 128,
                       "First pixel: actual=128, predicted=0, residual=128")
        // After the first row/column establish context, uniform data should
        // produce 0 residuals for interior pixels
        for y in 1..<4 {
            for x in 1..<4 {
                XCTAssertEqual(residuals[y * 4 + x], 0,
                               "Uniform interior pixel at (\(x),\(y)) should have zero residual")
            }
        }
    }

    func testApplyMAPrediction_LinearGradient_SmallResiduals() {
        let encoder = makeEncoder()
        let width = 8
        let height = 8
        var data = [UInt16](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                data[y * width + x] = UInt16(x * 4 + y * 4)
            }
        }

        let residuals = encoder.applyMAPrediction(data: data, width: width, height: height, channel: 0)

        // Interior pixels should have very small residuals (MED is optimal)
        var maxResidual: Int32 = 0
        for y in 2..<height {
            for x in 2..<width {
                maxResidual = max(maxResidual, abs(residuals[y * width + x]))
            }
        }
        XCTAssertLessThanOrEqual(maxResidual, 1,
                                  "Linear gradient interior should have near-zero residuals with MED")
    }

    func testApplyMAPrediction_HorizontalEdge_UsesAppropriatePredictor() {
        let encoder = makeEncoder(effort: .falcon) // Default tree
        let width = 4
        let height = 4
        // Image with horizontal edge: top half = 0, bottom half = 200
        var data = [UInt16](repeating: 0, count: width * height)
        for y in 2..<4 {
            for x in 0..<width {
                data[y * width + x] = 200
            }
        }

        let residuals = encoder.applyMAPrediction(data: data, width: width, height: height, channel: 0)

        // The encoder should produce non-empty residuals at the edge
        XCTAssertGreaterThan(abs(residuals[2 * width + 0]), 0,
                              "Edge pixels should have non-zero residuals")
        // But uniform regions should have zero residuals
        XCTAssertEqual(residuals[3 * width + 1], 0,
                       "Interior of bottom half should have zero residual")
    }

    func testApplyMAPrediction_ProducesSameOutputAsMED_ForSmoothGradient() {
        // For a perfectly smooth gradient, the MA tree should select MED
        // and produce identical results to the original predictPixel
        let encoder = makeEncoder()
        let width = 8
        let height = 8
        var data = [UInt16](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                data[y * width + x] = UInt16(x * 8 + y * 8)
            }
        }

        let maResiduals = encoder.applyMAPrediction(data: data, width: width, height: height, channel: 0)

        // Compare with MED predictions
        for y in 0..<height {
            for x in 0..<width {
                let actual = Int32(data[y * width + x])
                let medPredicted = encoder.predictPixel(data: data, x: x, y: y, width: width, height: height)
                let medResidual = actual - medPredicted
                XCTAssertEqual(maResiduals[y * width + x], medResidual,
                               "MA residual at (\(x),\(y)) should match MED for smooth gradient")
            }
        }
    }

    // MARK: - Full Pipeline Tests

    func testEncode_WithMATree_LosslessProducesOutput() throws {
        let encoder = JXLEncoder(options: .lossless)
        var frame = ImageFrame(width: 16, height: 16, channels: 3)
        for y in 0..<16 {
            for x in 0..<16 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 16))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 16))
                frame.setPixel(x: x, y: y, channel: 2, value: UInt16((x + y) * 8))
            }
        }
        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0)
        XCTAssertGreaterThan(result.stats.compressionRatio, 1.0,
                              "MA tree-based lossless encoding should achieve compression")
    }

    func testEncode_WithMATree_UniformImage_CompressesWell() throws {
        let encoder = JXLEncoder(options: .lossless)
        let frame = ImageFrame(width: 32, height: 32, channels: 3)
        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.stats.compressionRatio, 1.0,
                              "Uniform image should compress well with MA tree")
    }

    func testEncode_LowEffort_DefaultTree_ProducesOutput() throws {
        var options = EncodingOptions.lossless
        options.effort = .falcon
        let encoder = JXLEncoder(options: options)
        var frame = ImageFrame(width: 8, height: 8, channels: 3)
        for y in 0..<8 {
            for x in 0..<8 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 32))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 32))
                frame.setPixel(x: x, y: y, channel: 2, value: UInt16((x + y) * 16))
            }
        }
        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0,
                              "Low effort with default tree should produce output")
    }

    func testEncode_SingleChannel_WithMATree_ProducesOutput() throws {
        let encoder = JXLEncoder(options: .lossless)
        var frame = ImageFrame(width: 8, height: 8, channels: 1)
        for y in 0..<8 {
            for x in 0..<8 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 32))
            }
        }
        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 0)
    }

    // MARK: - Edge Case Tests

    func testApplyPredictor_FirstRow_MED_EqualsWest() {
        // First row: N=0, NW=0, so MED = 0+W-0 = W
        let data: [UInt16] = [10, 20, 30]
        let predicted = MATree.applyPredictor(
            .med, data: data, x: 1, y: 0, width: 3, height: 1
        )
        XCTAssertEqual(predicted, 10,
                       "MED on first row should equal West (N=0, NW=0)")
    }

    func testApplyPredictor_FirstColumn_MED_EqualsNorth() {
        let data: [UInt16] = [10, 20, 30]
        let predicted = MATree.applyPredictor(
            .med, data: data, x: 0, y: 1, width: 1, height: 3
        )
        XCTAssertEqual(predicted, 10,
                       "MED on first column should equal North (W=0, NW=0)")
    }

    func testApplyPredictor_AverageWN_OddSum() {
        // Test integer division: (5 + 4) / 2 = 4 (floor division)
        let data: [UInt16] = [0, 4,
                              5, 0]
        let predicted = MATree.applyPredictor(
            .averageWN, data: data, x: 1, y: 1, width: 2, height: 2
        )
        XCTAssertEqual(predicted, 4,
                       "averageWN should use floor division for odd sums")
    }

    func testApplyMAPrediction_1x1Image() {
        let encoder = makeEncoder()
        let data: [UInt16] = [42]
        let residuals = encoder.applyMAPrediction(data: data, width: 1, height: 1, channel: 0)
        XCTAssertEqual(residuals[0], 42,
                       "1×1 image: actual=42, predicted=0, residual=42")
    }

    func testApplyMAPrediction_1xN_Column() {
        let encoder = makeEncoder()
        let data: [UInt16] = [10, 20, 30]
        let residuals = encoder.applyMAPrediction(data: data, width: 1, height: 3, channel: 0)
        XCTAssertEqual(residuals[0], 10, "First pixel residual should be 10")
        XCTAssertEqual(residuals[1], 10, "Second pixel: actual=20, predicted=10 (N)")
        XCTAssertEqual(residuals[2], 10, "Third pixel: actual=30, predicted=20 (N)")
    }
}
