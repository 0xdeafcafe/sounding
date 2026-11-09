import Foundation

var failures = 0
func check(_ condition: Bool, _ label: String) {
    print("\(condition ? "PASS" : "FAIL")  \(label)")
    if !condition { failures += 1 }
}

func selfTest() {
    check(AutoMixNetFeatures.vector(AutoMixNetObservation(moveType: "blend", blendBars: 16)).count == AutoMixNetFeatures.count, "feature vector matches \(AutoMixNetFeatures.count) names")
    check(AutoMixNetFeatures.moveGroup("loopMix") == "loop" && AutoMixNetFeatures.moveGroup("cutOnTheOne") == "cut" && AutoMixNetFeatures.moveGroup("longBlend") == "blend", "move groups")
    check(abs(areaUnderCurve([0.9, 0.8, 0.2, 0.1], [true, true, false, false]) - 1) < 1e-9 && abs(areaUnderCurve([0.1, 0.9], [true, false])) < 1e-9, "AUC extremes")
    check(abs(areaUnderCurve([0.5, 0.5], [true, false]) - 0.5) < 1e-9, "AUC ties count half")
    check(AutoMixNetExperiment.adjustment(good: 1) == AutoMixNetExperiment.maximumAdjustment && AutoMixNetExperiment.adjustment(good: 0) == -AutoMixNetExperiment.maximumAdjustment && AutoMixNetExperiment.adjustment(good: 0.5) == 0, "planner term is clamped to ±0.03")

    var xor: [Example] = []
    var rng = SeededRandom(seed: 1)
    for _ in 0..<200 {
        let a = rng.uniform() * 2 - 1, b = rng.uniform() * 2 - 1
        xor.append(Example(x: [a, b], good: (a > 0) != (b > 0) ? 1 : 0, rating: (a > 0) != (b > 0) ? 5 : 1))
    }
    var mlpConfig = TrainConfig(hidden: [16, 8], dropout: 0, learningRate: 0.01, l2: 0, epochs: 400, validationFraction: 0)
    let (net, _) = fit(xor, config: mlpConfig)
    let accuracy = Double(xor.filter { (net.predict($0.x).good > 0.5) == ($0.good > 0.5) }.count) / Double(xor.count)
    check(accuracy > 0.9, String(format: "backprop learns XOR (%.2f)", accuracy))
    mlpConfig.hidden = []
    let (linear, _) = fit(xor, config: mlpConfig)
    let linearAccuracy = Double(xor.filter { (linear.predict($0.x).good > 0.5) == ($0.good > 0.5) }.count) / Double(xor.count)
    check(linearAccuracy < 0.7, String(format: "logistic regression cannot learn XOR (%.2f)", linearAccuracy))
    let separable = xor.map { Example(x: $0.x, good: $0.x[0] + 0.5 * $0.x[1] > 0 ? 1 : 0, rating: nil) }
    let (logistic, _) = fit(separable, config: mlpConfig)
    let sepAccuracy = Double(separable.filter { (logistic.predict($0.x).good > 0.5) == ($0.good > 0.5) }.count) / Double(separable.count)
    check(sepAccuracy > 0.95, String(format: "logistic regression fits a separable set (%.2f)", sepAccuracy))
    let ratingError = xor.map { abs(net.predict($0.x).rating - ($0.rating ?? 0)) }.reduce(0, +) / Double(xor.count)
    check(ratingError < 1, String(format: "rating head regresses 1-5 (MAE %.2f)", ratingError))

    let a = fit(xor, config: TrainConfig(hidden: [8], epochs: 50, seed: 3)).model.predict([0.3, -0.2]).good
    let b = fit(xor, config: TrainConfig(hidden: [8], epochs: 50, seed: 3)).model.predict([0.3, -0.2]).good
    check(a == b, "training is deterministic for a seed")

    let names = AutoMixNetFeatures.names
    var rows: [[Float]] = []
    var r2 = SeededRandom(seed: 5)
    for _ in 0..<40 { rows.append((0..<names.count).map { _ in Float(r2.gaussian()) }) }
    let standard = Standardiser(rows)
    let probe = rows[3]
    let lab = MLP(inputs: names.count, hidden: [8, 4], rng: &r2)
    let exported = lab.export(featureNames: names, mean: standard.mean, scale: standard.scale)
    let data = try! JSONEncoder().encode(exported)
    let decoded = try! JSONDecoder().decode(AutoMixNetModel.self, from: data)
    let app = decoded.predict(probe)!
    let labP = lab.predict(standard.apply(probe))
    check(abs(app.good - labP.good) < 1e-5 && abs(app.rating - labP.rating) < 1e-4, "exported JSON predicts the same as the lab net (\(data.count) bytes)")
    let start = Date()
    for _ in 0..<10_000 { _ = decoded.predict(probe) }
    let micros = Date().timeIntervalSince(start) / 10_000 * 1e6
    check(micros < 100, String(format: "inference costs %.1f µs per plan", micros))

    let rating = AutoMixRating(date: Date(timeIntervalSince1970: 1_800_000_000), liked: false, features: AutoMixTransitionFeatures(moveType: "loopMix", blendBars: 16, energyDelta: 2, bpmDistancePercent: 1.2, keyDistance: 3, outgoingSection: "outro", incomingSection: "intro", vocalOverlapSeconds: 4))
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("automix-nn-ratings-\(ProcessInfo.processInfo.processIdentifier).json")
    try! JSONEncoder().encode([rating]).write(to: url)
    let loaded = try! AutoMixNetRatings.load(from: url)
    try? FileManager.default.removeItem(at: url)
    let v = AutoMixNetFeatures.vector(loaded[0].observation)
    let index = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($1, $0) })
    check(loaded.count == 1 && !loaded[0].good && v[index["keyDistance"]!] == 3 && v[index["move.loop"]!] == 1 && v[index["exit.outro"]!] == 1 && v[index["lowBefore"]!].isNaN, "AutoMixFeedback ratings load as samples; missing render features stay missing")

    let estimated = AutoMixNetFeatures.estimatedBands(
        outgoingBars: Array(repeating: [4, 3, 1], count: 64), exitBar: 32,
        incomingBars: Array(repeating: [4, 3, 1], count: 64), entryBar: 8, blendBars: 16, bassSwapFraction: 0.5
    )!
    let doubled = AutoMixNetFeatures.estimatedBands(
        outgoingBars: Array(repeating: [4, 3, 1], count: 64), exitBar: 32,
        incomingBars: Array(repeating: [4, 3, 1], count: 64), entryBar: 8, blendBars: 16, bassSwapFraction: 0, bassSwapBars: 16
    )!
    check(estimated.lowOverlap < doubled.lowOverlap, String(format: "estimated double bass: swap %.2f vs no swap %.2f", estimated.lowOverlap, doubled.lowOverlap))
}

struct Dataset: Codable {
    var samples: [SyntheticPair]
}

func evaluate(rows: [[Float]], labels: [Bool], ratings: [Double?], title: String, outDirectory: URL?) -> [String] {
    var report: [String] = ["## \(title)", "", "n = \(rows.count), good = \(labels.filter { $0 }.count), bad = \(labels.filter { !$0 }.count), features = \(AutoMixNetFeatures.count)", ""]
    let k = min(5, max(2, labels.filter { !$0 }.count))
    let netConfig = TrainConfig()
    let (net, importance) = crossValidate(rows, labels, ratings, k: k, config: netConfig, permute: true)
    var logisticConfig = TrainConfig(hidden: [], dropout: 0)
    logisticConfig.learningRate = 0.01
    let (logistic, _) = crossValidate(rows, labels, ratings, k: k, config: logisticConfig, permute: false)
    let gateScores = rows.map(Gates.score)
    let gateMetrics = Metrics(scores: gateScores, labels: labels, threshold: 0.75)
    let netMetrics = Metrics(scores: net.scores, labels: labels)
    let logMetrics = Metrics(scores: logistic.scores, labels: labels)
    report.append("\(k)-fold stratified cross-validation, seed 7.")
    report.append("")
    report.append("| model | accuracy | AUC | bad recall | bad precision |")
    report.append("|---|---|---|---|---|")
    for (name, m) in [("hard-rule gates", gateMetrics), ("logistic regression", logMetrics), ("MLP 24-16", netMetrics)] {
        report.append(String(format: "| %@ | %.3f | %.3f | %.3f | %.3f |", name, m.accuracy, m.auc, m.badRecall, m.badPrecision))
    }
    report.append("")
    report.append(String(format: "Rating head MAE (1-5): MLP %.2f, logistic %.2f. Early stopping epochs per fold: %@.", ratingError(net.ratings, ratings), ratingError(logistic.ratings, ratings), net.epochs.map(String.init).joined(separator: ", ")))
    let passed = rows.indices.filter { Gates.fired(rows[$0]).isEmpty }
    let passedLabels = passed.map { labels[$0] }
    let passedBad = passedLabels.filter { !$0 }.count
    let netOnPassed = Metrics(scores: passed.map { net.scores[$0] }, labels: passedLabels)
    let logOnPassed = Metrics(scores: passed.map { logistic.scores[$0] }, labels: passedLabels)
    report.append("")
    report.append("Beyond the gates: \(passed.count) transitions pass every gate, \(passedBad) of them are bad.")
    report.append(String(format: "On those, MLP: AUC %.3f, bad recall %.3f; logistic: AUC %.3f, bad recall %.3f.", netOnPassed.auc, netOnPassed.badRecall, logOnPassed.auc, logOnPassed.badRecall))
    let combined = rows.indices.map { Gates.fired(rows[$0]).isEmpty ? net.scores[$0] : 0 }
    let combinedMetrics = Metrics(scores: combined, labels: labels)
    report.append(String(format: "Gates then MLP (gates veto, net ranks the rest): acc %.3f, AUC %.3f, bad recall %.3f.", combinedMetrics.accuracy, combinedMetrics.auc, combinedMetrics.badRecall))
    report.append("")
    report.append("Permutation importance (mean AUC drop on held-out folds, top 12):")
    report.append("")
    let ranked = importance.enumerated().sorted { $0.element > $1.element }.prefix(12)
    for (j, drop) in ranked { report.append(String(format: "- %@: %.3f", AutoMixNetFeatures.names[j], drop)) }
    report.append("")
    if let outDirectory {
        let standard = Standardiser(rows)
        let all = rows.indices.map { Example(x: standard.apply(rows[$0]), good: labels[$0] ? 1 : 0, rating: ratings[$0]) }
        let (final, epochs) = fit(all, config: netConfig)
        let model = final.export(featureNames: AutoMixNetFeatures.names, mean: standard.mean, scale: standard.scale)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let url = outDirectory.appendingPathComponent("transition-net-\(title.lowercased().replacingOccurrences(of: " ", with: "-")).json")
        try? encoder.encode(model).write(to: url)
        report.append("Final model trained on all \(rows.count) samples (\(epochs) epochs) written to `\(url.path)`.")
        report.append("")
    }
    return report
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "selftest" {
case "selftest":
    selfTest()
    print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
case "synth":
    let audio = URL(fileURLWithPath: args[2]), analysis = URL(fileURLWithPath: args[3]), output = URL(fileURLWithPath: args[4])
    let ids = ["jungle", "voodoo", "marionette", "darkknight"]
    let tracks = try ids.map { try loadTrack($0, audio: audio, analysis: analysis) }
    let samples = try makeSamples(tracks: tracks, limit: args.count > 5 ? Int(args[5]) : nil)
    try JSONEncoder().encode(Dataset(samples: samples)).write(to: output)
    print("SYNTH|\(samples.count) samples, \(samples.filter(\.good).count) good -> \(output.path)")
case "train":
    let dataset = try JSONDecoder().decode(Dataset.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
    let outDirectory = URL(fileURLWithPath: args[3])
    try FileManager.default.createDirectory(at: outDirectory, withIntermediateDirectories: true)
    var report: [String] = []
    for (title, pick) in [("Planner features", { (s: SyntheticPair) in s.estimated }), ("Rendered features", { (s: SyntheticPair) in s.measured })] {
        let rows = dataset.samples.map { AutoMixNetFeatures.vector(pick($0)) }
        report += evaluate(rows: rows, labels: dataset.samples.map(\.good), ratings: dataset.samples.map { Optional($0.rating) }, title: title, outDirectory: outDirectory)
    }
    let faults = Set(dataset.samples.compactMap(\.fault)).sorted()
    report.append("Gate firing by injected fault (planner features):")
    report.append("")
    for fault in ["good"] + faults {
        let group = dataset.samples.filter { ($0.fault ?? "good") == fault }
        let caught = group.filter { !Gates.fired(AutoMixNetFeatures.vector($0.estimated)).isEmpty }.count
        report.append("- \(fault): \(caught)/\(group.count) flagged")
    }
    let text = report.joined(separator: "\n")
    print(text)
    try text.write(to: outDirectory.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
default:
    print("usage: automix-net-lab selftest | synth <audio dir> <analysis dir> <out.json> [limit] | train <dataset.json> <out dir>")
    exit(2)
}
