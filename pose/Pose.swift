//
//  Pose.swift
//
//  Created by Dmitry Rybakov on 2019-03-20.
//  Copyright © 2019 Dmitry Rybakov. All rights reserved.
//

import UIKit
import CoreML
import Vision
import CoreMLHelpers
import SwiftyBeaver

public struct JointPoint: Hashable {
    let x: Int
    let y: Int
    var hash: Int {
        return x + y * 2000
    }
}

public struct JointConnectionWithScore {
    let connection: PoseMPI15.JointConnection
    let score: Float32
    let count: Int
    let offsetJoint1: Int
    let offsetJoint2: Int
    let joint1: JointPoint
    let joint2: JointPoint
}

struct Pose {
    static var colors: [UIColor] {
        
        let colorLiterals = [0xFF0055, 0xFF0000, 0xFF5500,
                             0xFFAA00, 0xFFFF00, 0xAAFF00,
                             0x55FF00, 0x2BFF00, 0x00FF00,
                             0x00FF55, 0x00FFAA, 0x00FFFF,
                             0x00AAFF, 0x0055FF, 0xAA00FF,
                             0xFF00FF, 0xFF00AA, 0xFF0055]
        return colorLiterals.map { UIColor(hex: $0) }
    }
}

enum BodyJoint: String, CaseIterable {
    case head, neck,
    rShoulder, rElbow, rWrist,
    lShoulder, lElbow, lWrist,
    rHip, rKnee, rAnkle,
    lHip, lKnee, lAnkle,
    chest, background
    
    static var array: [BodyJoint] { return self.allCases }
    
    var color: UIColor {
        return Pose.colors[index()]
    }
    
    func index() -> Int {
        return BodyJoint.array.firstIndex(of: self)!
    }
}

public struct PoseMPI15 {
    var joints = BodyJoint.array
    var jointConnections = JointConnection.array
    
    enum JointConnection: String, CaseIterable {
        case headNeck,
        neckRShoulder, rShoulderRElbow, rElbowRWrist,
        neckLShoulder, lShoulderLElbow, lElbowLWrist,
        neckChest,
        chestRHip, rHipRKnee, rKneeRAnkle,
        chestLHip, lHipLKnee, lKneeLAnkle
        
        static var array: [JointConnection] { return self.allCases }
        
        var joints: (BodyJoint, BodyJoint) {
            switch self {
            case .headNeck:
                return (.head, .neck)
            case .neckRShoulder:
                return (.neck, .rShoulder)
            case .rShoulderRElbow:
                return (.rShoulder, .rElbow)
            case .rElbowRWrist:
                return (.rElbow, .rWrist)
            case .neckLShoulder:
                return (.neck, .lShoulder)
            case .lShoulderLElbow:
                return (.lShoulder, .lElbow)
            case .lElbowLWrist:
                return (.lElbow, .lWrist)
            case .neckChest:
                return (.neck, .chest)
            case .chestRHip:
                return (.chest, .rHip)
            case .rHipRKnee:
                return (.rHip, .rKnee)
            case .rKneeRAnkle:
                return (.rKnee, .rAnkle)
            case .chestLHip:
                return (.chest, .lHip)
            case .lHipLKnee:
                return (.lHip, .lKnee)
            case .lKneeLAnkle:
                return (.lKnee, .lAnkle)
            }
        }
        
        var pafIndices: (x: Int, y: Int) {
            switch self {
            case .headNeck:
                return (x: 0, y: 1)
            case .neckRShoulder:
                return (x: 2, y: 3)
            case .rShoulderRElbow:
                return (x: 4, y: 5)
            case .rElbowRWrist:
                return (x: 6, y: 7)
            case .neckLShoulder:
                return (x: 8, y: 9)
            case .lShoulderLElbow:
                return (x: 10, y: 11)
            case .lElbowLWrist:
                return (x: 12, y: 13)
            case .neckChest:
                return (x: 14, y: 15)
            case .chestRHip:
                return (x: 16, y: 17)
            case .rHipRKnee:
                return (x: 18, y: 19)
            case .rKneeRAnkle:
                return (x: 20, y: 21)
            case .chestLHip:
                return (x: 22, y: 23)
            case .lHipLKnee:
                return (x: 24, y: 25)
            case .lKneeLAnkle:
                return (x: 26, y: 27)
            }
        }
        
        var color: UIColor {
            return self.joints.1.color
        }
        
        func index() -> Int {
            return JointConnection.array.firstIndex(of: self)!
        }
    }
}

struct HeatMapJointCandidate {
    let col: Int
    let row: Int
    let layerIndex: Int
    let confidence: Float32
    
    var color: UIColor {
        return Pose.colors[layerIndex % Pose.colors.count]
    }
}

open class PoseEstimation {

    let model: MLModel
    let layersCount = 44
    let backgroundLayerIndex = 15
    let pafLayerStartIndex = 16
    let modelOutputWidh = 64
    let modelOutputHeight = 64
    let modelInputSize = CGSize(width: 512, height: 512)
    let scoreThreasholdFactor = Float32(2)
    
    var saveDebugImages: Bool = false
    var timeElapsedString: String = ""
    private var coremlProcessingStart = Date()
    private var coremlProcessingFinish = Date()
    private let log = SwiftyBeaver.self
    
    public init(model: MLModel) {
        self.model = model
    }
    
    private func stride(x1: Int, y1: Int, x2: Int, y2: Int,
                processBlock: ((Int, Int, Int, Int) -> Void)) {
        var (dx, dy) = (Float(abs(x2 - x1) + 1), Float(abs(y2 - y1) + 1))
        var stepCount = dy
        if (dx >= dy) {
            stepCount = dx
        }
        dx /= stepCount
        dy /= stepCount
        if x2 < x1 {
            dx = -dx
        }
        if y2 < y1 {
            dy = -dy
        }
        var (x, y) = (Float(x1), Float(y1))
        let count = Int(stepCount.rounded())
        (0..<count).forEach { idx in
            processBlock(Int(x.rounded(.toNearestOrAwayFromZero)),
                         Int(y.rounded(.toNearestOrAwayFromZero)), idx, count)
            x += dx
            y += dy
        }
    }
    
    private func score(x1: Int, y1: Int, x2: Int, y2: Int,
               pafMatX: Array<Float32>, pafMatY: Array<Float32>,
               yStride: Int) -> (Float32, Int) {
        
        var pafXs = Array<Float32>()
        var pafYs = Array<Float32>()
        
        stride(x1: x1, y1: y1, x2: x2, y2: y2) { x, y, idx, count in
            // These offset values are used to cover larger area in PAF's to collect as many score as possible
            var dx = [-1, 0, 1]
            var dy = [0, 0, 0]
            if abs(x2 - x1) > abs(y2 - y1) {
                // If scores are collected horizontally then use Ys offsets instead of Xs
                //  When moving horizontally
                //  y - 1   y - 1      y - 1
                //  x1, y   x2, y .... xn, y
                //  y + 1   y + 1      y + 1
                //  When moving vertically
                //  x - 1   x, y1  x + 1
                //  x - 1   x, y2  x + 1
                //          ....
                //          ....
                //  x - 1   x, yn  x + 1
                swap(&dx, &dy)
            }
            var (scoreX, scoreY) = (Float(0), Float(0))
            for (dx, dy) in zip(dx, dy) {
                var offset = (y + dy) * yStride + x + dx
                // Check if it is out of array's bounds
                offset = min(max(0, offset), pafMatX.count - 1)
                // Accumulate PAFs values
                scoreX += pafMatX[offset]
                scoreY += pafMatY[offset]
            }
            pafXs.append(scoreX)
            pafYs.append(scoreY)
        }
        pafXs = pafXs.map({ abs($0) })
        pafYs = pafYs.map({ abs($0) })
        // Summ all the scores
        let localScores = zip(pafXs, pafYs).map(+)
        // The parts of the scores that crosses PAFs that belong to other connections should be penalized
        // In that way the scores that belongs to correct connection will have more chances to win later
        let localScoreMax = localScores.max() ?? Float(0.0)
        let scorePenalty = -localScoreMax
        let filteredLocalScores = localScores.map { localScoreMax / $0 > scoreThreasholdFactor ? scorePenalty: $0 }
        
        log.debug("scores: [\(localScores)]\nfiltered_scores: [\(filteredLocalScores)]")
        
        return (filteredLocalScores.reduce(0, +), filteredLocalScores.count )
    }
    
    public func estimate(on image: UIImage, completion: @escaping (([Int: [JointConnectionWithScore]]) -> ())) {
        
        var uiImage = image
        if image.size != modelInputSize {
            uiImage = image.resizedCenteredKeepingSpectRatio(toSize: modelInputSize)
        }
        guard let ciImage = CIImage(image: uiImage) else {
            assertionFailure("Failed to create ciImage")
            completion([:])
            return
        }
        
        do {
            let model = try VNCoreMLModel(for: self.model)
            let coremlRequest = VNCoreMLRequest(model: model) { request, error in
                
                do {
                    guard let observations = request.results as? [VNCoreMLFeatureValueObservation] else {
                        assertionFailure("Unknown results for CoreML request: \(request)")
                        return
                    }
                    let multiArray = observations.first!.featureValue.multiArrayValue
                    try withExtendedLifetime(multiArray) {
                        self.coremlProcessingFinish = Date()
                        
                        if let multiArray = try? multiArray?.reshaped(to: [self.layersCount,
                                                                           self.modelOutputWidh,
                                                                           self.modelOutputHeight]),
                            let reshapedArray = multiArray {

                            let nnOutput = UnsafeMutablePointer<Float32>(OpaquePointer(reshapedArray.dataPointer))
                            let layerStride = reshapedArray.strides[0].intValue
                            let heatMatCount = self.backgroundLayerIndex
                            
                            // Draw heatmap matrices
                            let heatMatPtr = nnOutput
                            if self.saveDebugImages {
                                try heatMatPtr.drawMatricesCombined(matricesCount: heatMatCount,
                                                                              width: self.modelOutputWidh,
                                                                              height: self.modelOutputHeight,
                                                                              colors: Pose.colors).save(tofileName: "heatMapMatrices")
                            }
                            
                            // Do a second round filtering by applying a threshold
                            let arr = Array(UnsafeBufferPointer(start: heatMatPtr, count: heatMatCount * layerStride))
                            let avg = arr.reduce(0, +) / Float32(arr.count)
                            let NMS_Threshold: Float32 = 0.1
                            var _NMS_Threshold = max(avg * 4.0, NMS_Threshold)
                            _NMS_Threshold = min(_NMS_Threshold, 0.3)
                            var candidates:[HeatMapJointCandidate] = []
                            for layerIndex in 0..<heatMatCount {
                                let layerPtr = heatMatPtr.advanced(by: layerIndex * layerStride)
                                for idx in 0..<layerStride {
                                    if layerPtr[idx] > _NMS_Threshold {
                                        let col = idx % self.modelOutputWidh
                                        let row = idx / self.modelOutputWidh
                                        candidates.append(HeatMapJointCandidate(col: col,
                                                                                row: row,
                                                                                layerIndex: layerIndex,
                                                                                confidence: layerPtr[idx]))
                                    }
                                }
                            }
                            
                            if self.saveDebugImages {
                                let backgroundLayer = nnOutput.array(idx: self.backgroundLayerIndex, stride: layerStride)
                                // Draw heatmap candidates for joints after filtering
                                // Use alpha to show candiates that are overlapping
                                try candidates.draw(width: self.modelOutputWidh,
                                                              height: self.modelOutputHeight,
                                                              radius: 3.0,
                                                              lineWidth: 2.0,
                                                              on: backgroundLayer.draw(width: self.modelOutputWidh,
                                                                                       height: self.modelOutputHeight).resized(to: uiImage.size)).save(tofileName: "allCandidates")
                            }
                            
                            var filteredCandidates: [HeatMapJointCandidate] = []
                            
                            for layerIndex in (0..<heatMatCount) {
                                let candidates = candidates.filter { $0.layerIndex == layerIndex }
                                // Non maximum suppression to get as minimum candidates as possible
                                let boxes = candidates.map { c -> BoundingBox in
                                    let windowOrigin = CGPoint(x: max(0, c.col - 2), y: max(0, c.row - 2))
                                    let windowSize = CGSize(width: 5, height: 5)
                                    return BoundingBox(classIndex: 0,
                                                       score: Float(c.confidence),
                                                       rect: CGRect(origin: windowOrigin, size: windowSize))
                                }
                                let boxIndices = nonMaxSuppression(boundingBoxes: boxes, iouThreshold: 0.3, maxBoxes: boxes.count)
                                filteredCandidates += boxIndices.map { candidates[$0] }
                            }
                            
                            if self.saveDebugImages {
                                // Draw filtered joint candidates
                                try filteredCandidates.draw(width: self.modelOutputWidh,
                                                                      height: self.modelOutputHeight,
                                                                      radius: 3.0,
                                                                      lineWidth: 6.0,
                                                                      on: UIImage.image(with: .white, size: uiImage.size)).save(tofileName: "filteredCandidates")
                            }
                            
                            let pose = PoseMPI15()
                            // Map layerIndex to joint type
                            let candidatesByJoints = Dictionary(grouping: filteredCandidates, by: { pose.joints[$0.layerIndex] })
                            
                            // Get joint connections with scores based on PAF matrices
                            var allConnectionCandidates: [JointConnectionWithScore] = []
                            var connections: [JointConnectionWithScore] = []
                            
                            try pose.jointConnections.forEach { connection in
                                
                                let (indexX, indexY) = connection.pafIndices
                                let pafMatX = nnOutput.array(idx: self.pafLayerStartIndex + indexX,
                                                             stride: layerStride)
                                let pafMatY = nnOutput.array(idx: self.pafLayerStartIndex + indexY,
                                                             stride: layerStride)
                                
                                let (joint1, joint2) = (connection.joints.0, connection.joints.1)
                                
                                if let candidate1 = candidatesByJoints[joint1],
                                    let candidate2 = candidatesByJoints[joint2] {
                                    
                                    var connectionCandidates: [JointConnectionWithScore] = []
                                    
                                    // Get non filtered joint connections
                                    candidate1.enumerated().forEach { offset1, first in
                                        candidate2.enumerated().forEach { offset2, second in
                                            
                                            let (x1, y1) = (first.col, first.row)
                                            let (x2, y2) = (second.col, second.row)
                                            
                                            let (s, c) = self.score(x1: x1, y1: y1, x2: x2, y2: y2,
                                                                    pafMatX: pafMatX, pafMatY: pafMatY,
                                                                    yStride: self.modelOutputWidh)
                                            if s > 0 {
                                                let connWithCoords = JointConnectionWithScore(connection: connection,
                                                                                              score: s,
                                                                                              count: c,
                                                                                              offsetJoint1: offset1,
                                                                                              offsetJoint2: offset2,
                                                                                              joint1: JointPoint(x: x1, y: y1),
                                                                                              joint2: JointPoint(x: x2, y: y2))
                                                connectionCandidates.append(connWithCoords)
                                            }
                                            self.log.debug("\(connection) \(s) \(c) \(x1) \(y1) \(x2) \(y2)")
                                        }
                                    }
                                    
                                    if self.saveDebugImages {
                                        let pafXImage = pafMatX.draw(width: self.modelOutputWidh, height: self.modelOutputHeight)
                                        let pafYImage = pafMatY.draw(width: self.modelOutputWidh, height: self.modelOutputHeight)
                                        
                                        let joints1 = filteredCandidates.filter({ $0.layerIndex == connection.joints.0.index()})
                                        let joints2 = filteredCandidates.filter({ $0.layerIndex == connection.joints.1.index()})
                                        let jointCandidates1 = candidates.filter({ $0.layerIndex == connection.joints.0.index()})
                                        let jointCandidates2 = candidates.filter({ $0.layerIndex == connection.joints.1.index()})
                                        
                                        let jointConns = connectionCandidates.filter({ $0.connection == connection })
                                        
                                        
                                        let (heatMapIndex1, heatMapIndex2) = (connection.joints.0.index(),
                                                                              connection.joints.1.index())
                                        let heatMap1 = nnOutput.array(idx: heatMapIndex1,
                                                                      stride: layerStride)
                                        let heatMap2 = nnOutput.array(idx: heatMapIndex2,
                                                                      stride: layerStride)
                                        var heatMap1Image = heatMap1.draw(width: self.modelOutputWidh, height: self.modelOutputHeight)
                                        var heatMap2Image = heatMap2.draw(width: self.modelOutputWidh, height: self.modelOutputHeight)
                                        
                                        heatMap1Image = joints1.draw(width: self.modelOutputWidh,
                                                                     height: self.modelOutputHeight,
                                                                     alpha: 1.0,
                                                                     radius: 5,
                                                                     lineWidth: 3,
                                                                     on: heatMap1Image.resized(to: uiImage.size))
                                        try jointCandidates1.draw(width: self.modelOutputWidh,
                                                                            height: self.modelOutputHeight,
                                                                            radius: 5,
                                                                            lineWidth: 0.5,
                                                                            on: heatMap1Image).save(tofileName: "jointCandidates1")
                                        
                                        heatMap2Image = joints2.draw(width: self.modelOutputWidh,
                                                                     height: self.modelOutputHeight,
                                                                     alpha: 1.0,
                                                                     radius: 5,
                                                                     lineWidth: 3,
                                                                     on: heatMap2Image.resized(to: uiImage.size))
                                        try jointCandidates2.draw(width: self.modelOutputWidh,
                                                                            height: self.modelOutputHeight,
                                                                            radius: 5,
                                                                            lineWidth: 0.5,
                                                                            on: heatMap2Image).save(tofileName: "jointCandidates2")
                                        
                                        try joints1.draw(width: self.modelOutputWidh,
                                                                   height: self.modelOutputHeight,
                                                                   alpha: 1.0,
                                                                   radius: 7,
                                                                   lineWidth: 3,
                                                                   on: pafXImage.resized(to: uiImage.size)).save(tofileName: "allJointsX")
                                        try joints2.draw(width: self.modelOutputWidh,
                                                                   height: self.modelOutputHeight,
                                                                   alpha: 1.0,
                                                                   radius: 7,
                                                                   lineWidth: 3,
                                                                   on: pafYImage.resized(to: uiImage.size)).save(tofileName: "allJointsY")
                                        try jointConns.draw(width: self.modelOutputWidh,
                                                                      height: self.modelOutputHeight,
                                                                      lineWidth: 3,
                                                                      on: pafXImage.resized(to: uiImage.size)).save(tofileName: "allConnectionsX")
                                        try jointConns.draw(width: self.modelOutputWidh,
                                                                      height: self.modelOutputHeight,
                                                                      lineWidth: 3,
                                                                      on: pafYImage.resized(to: uiImage.size)).save(tofileName: "allConnectionsY")
                                    }
                                    allConnectionCandidates += connectionCandidates
                                    
                                    var (usedIdx1, usedIdx2) = (Set<Int>(), Set<Int>())
                                    connectionCandidates.sorted(by: { $0.score > $1.score }).forEach { c in
                                        if usedIdx1.contains(c.offsetJoint1) || usedIdx2.contains(c.offsetJoint2) {
                                            return
                                        }
                                        connections.append(c)
                                        usedIdx1.insert(c.offsetJoint1)
                                        usedIdx2.insert(c.offsetJoint2)
                                    }
                                }
                            }
                            
                            if self.saveDebugImages {
                                // Draw connecions with score
                                let allConnectionsImage = allConnectionCandidates.draw(width: self.modelOutputWidh,
                                                                                       height: self.modelOutputHeight,
                                                                                       lineWidth: 5,
                                                                                       on: UIImage.image(with: .white, size: uiImage.size))
                                // Draw joints
                                try filteredCandidates.draw(width: self.modelOutputWidh,
                                                                      height: self.modelOutputHeight,
                                                                      radius: 5,
                                                                      lineWidth: 3,
                                                                      on: allConnectionsImage).save(tofileName: "filteredCandidatesWithConnections")
                            }
                            // Group connections by human.
                            var humanJoints: [Set<JointPoint>] = []
                            var humanConnections: [Int: [JointConnectionWithScore]] = [:]
                            connections.enumerated().forEach { connIdx, c in
                                var added = false
                                (0..<humanJoints.count).forEach { humanIdx in
                                    let conn = humanJoints[humanIdx]
                                    if (conn.contains(c.joint1) && !conn.contains(c.joint2)) ||
                                        (conn.contains(c.joint2) && !conn.contains(c.joint1)) {
                                        humanJoints[humanIdx].insert(c.joint1)
                                        humanJoints[humanIdx].insert(c.joint2)
                                        humanConnections[humanIdx]?.append(c)
                                        added = true
                                        return
                                    }
                                }
                                if !added {
                                    humanJoints.append([c.joint1, c.joint2])
                                    humanConnections[humanJoints.count - 1] = [c]
                                }
                            }
                            
                            if self.saveDebugImages {
                                // Draw human joint connection over an original image
                                var resultImage = uiImage.grayed
                                humanConnections.forEach { h in
                                    resultImage = h.value.draw(width: self.modelOutputWidh,
                                                               height: self.modelOutputHeight,
                                                               lineWidth: 3,
                                                               drawJoint: true,
                                                               alpha: 1.0,
                                                               on: resultImage)
                                }
                                try resultImage.save(tofileName: "humanPoseOverOriginal")
                            }
                            // Filter each heatmap layer by subtracting a min value
                            let pafCount = self.layersCount - heatMatCount - 1
                            for layerIndex in 0..<pafCount {
                                
                                let channelArray = nnOutput.advanced(by: (self.pafLayerStartIndex + layerIndex) * layerStride)
                                let arr = Array(UnsafeBufferPointer(start: channelArray, count: layerStride))
                                
                                let valSet = NSCountedSet(array: arr.map { ($0 * 10000).rounded() })
                                let hist = valSet.sorted(by: { (a, b) -> Bool in
                                    return valSet.count(for: a) < valSet.count(for: b)
                                })
                                if let last = hist.last as? Int {
                                    let maxHist = Float(last) / 10000
                                    for idx in 0..<layerStride {
                                        if channelArray[idx] < 0 {
                                            channelArray[idx] = abs(channelArray[idx] - maxHist)
                                        }
                                    }
                                }
                            }
                            if self.saveDebugImages {
                                let pafArray = nnOutput.advanced(by: self.pafLayerStartIndex * layerStride)
                                try pafArray.drawMatricesCombined(matricesCount: pafCount,
                                                                            width: self.modelOutputWidh,
                                                                            height: self.modelOutputHeight,
                                                                            colors: Pose.colors).save(tofileName: "PAF")
                            }
                            let timeElapsed = self.coremlProcessingFinish.timeIntervalSince(self.coremlProcessingStart)
                            let formatter: NumberFormatter = NumberFormatter()
                            formatter.numberStyle = .decimal
                            formatter.maximumFractionDigits = 2
                            self.timeElapsedString = formatter.string(from: NSNumber(value: timeElapsed)) ?? ""
                            completion(humanConnections)
                        }
                    }
                } catch {
                    self.log.error(error)
                }
            }
            // Set an image scaling mode for the Vision framework
            coremlRequest.imageCropAndScaleOption = .centerCrop
            // Even though the CoreML model has fixed input image size that is not equal to the real input image the Vision framework will scale it accordingly
            let handler = VNImageRequestHandler(ciImage: ciImage)
            DispatchQueue.global(qos: .userInteractive).async {
                do {
                    self.coremlProcessingStart = Date()
                    try handler.perform([coremlRequest])
                } catch {
                    self.log.error(error)
                }
            }
        }
        catch {
            log.error(error)
        }
    }
}