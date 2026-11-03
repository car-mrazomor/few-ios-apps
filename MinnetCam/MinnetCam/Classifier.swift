import Foundation

struct Prediction: Identifiable, Equatable {
    let label: String
    let confidence: Float
    var id: String { label }
}

final class Classifier {
    let labels: [String]
    let width: Int
    let height: Int
    private let net: OpaquePointer
    private var probs: [Float]

    init?(model: String = "cifar10") {
        guard let modelURL = Bundle.main.url(forResource: model, withExtension: "mnet"),
              let labelsURL = Bundle.main.url(forResource: model, withExtension: "labels"),
              let text = try? String(contentsOf: labelsURL, encoding: .utf8),
              let net = mn_load(modelURL.path) else { return nil }
        var c: Int32 = 0, h: Int32 = 0, w: Int32 = 0
        mn_input_shape(net, &c, &h, &w)
        let labels = text.split(whereSeparator: \.isNewline).map(String.init)
        guard c == 3, labels.count == Int(mn_output_size(net)) else {
            mn_free(net)
            return nil
        }
        self.net = net
        self.labels = labels
        width = Int(w)
        height = Int(h)
        probs = [Float](repeating: 0, count: labels.count)
    }

    deinit {
        mn_free(net)
    }

    func classify(_ input: [Float]) -> [Float] {
        let k = Int32(labels.count)
        input.withUnsafeBufferPointer { x in
            guard let logits = mn_forward(net, x.baseAddress, 1) else { return }
            probs.withUnsafeMutableBufferPointer { mn_softmax(logits, $0.baseAddress, 1, k) }
        }
        return probs
    }
}
