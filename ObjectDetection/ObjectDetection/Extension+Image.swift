//
//  Extension+Image.swift
//  ObjectDetection
//
//  Created by Dong Han Lin on 2021/10/11.
//  Copyright © 2021 MachineThink. All rights reserved.
//

import Foundation
import Vision
import UIKit

// - MARK: image operation
extension UIImage {
    func addBoundingBox(prediction: VNRecognizedObjectObservation) -> UIImage {
        let width = self.size.width
        let height = self.size.height
        let scale = CGAffineTransform.identity.scaledBy(x: width, y: height)
        let transform = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -height)
        let rect = prediction.boundingBox.applying(scale).applying(transform)

        UIGraphicsBeginImageContext(self.size)
        let imageRect = CGRect(x: 0, y: 0, width: self.size.width, height: self.size.height)
        self.draw(in: imageRect)

        let context = UIGraphicsGetCurrentContext()

        context?.setStrokeColor(UIColor.red.cgColor)
        context?.setLineWidth(5)
        context?.stroke(rect)

        let result = UIGraphicsGetImageFromCurrentImageContext() ?? self
        UIGraphicsEndImageContext()
        return result
    }
    func addBorder(width: CGFloat, color: UIColor) -> UIImage {
        UIGraphicsBeginImageContext(self.size)
        let imageRect = CGRect(x: 0, y: 0, width: self.size.width, height: self.size.height)
        self.draw(in: imageRect)

        let context = UIGraphicsGetCurrentContext()
        let borderRect = imageRect.insetBy(dx: width / 2, dy: width / 2)

        context?.setStrokeColor(color.cgColor)
        context?.setLineWidth(width)
        context?.stroke(borderRect)

        let borderedImage = UIGraphicsGetImageFromCurrentImageContext() ?? self
        UIGraphicsEndImageContext()
        return borderedImage
    }
}
