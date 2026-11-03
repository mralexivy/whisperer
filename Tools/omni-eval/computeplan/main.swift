// computeplan <model.mlmodelc> [cpuOnly|cpuAndGPU|cpuAndNE|all]
// Prints how Core ML's compute plan assigns each operation of the model's main function to a device, weighted by Core ML's
// own cost estimate. This is the PLANNED placement; the runtime can still deviate, so it is evidence, not a power trace.
import CoreML
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: computeplan <model.mlmodelc> [units]"); exit(2) }
let cfg = MLModelConfiguration()
switch args.count > 2 ? args[2] : "all" {
case "cpuOnly": cfg.computeUnits = .cpuOnly
case "cpuAndGPU": cfg.computeUnits = .cpuAndGPU
case "cpuAndNE": cfg.computeUnits = .cpuAndNeuralEngine
default: cfg.computeUnits = .all
}
let plan = try await MLComputePlan.load(contentsOf: URL(fileURLWithPath: args[1]), configuration: cfg)
guard case .program(let program) = plan.modelStructure, let main = program.functions["main"] else {
    print("not an ML program (or no main function)"); exit(1)
}
var count: [String: Int] = [:], weight: [String: Double] = [:], unsupportedNE: [String: Int] = [:]
func name(_ d: MLComputeDevice) -> String {
    switch d { case .cpu: return "CPU"; case .gpu: return "GPU"; case .neuralEngine: return "ANE"; @unknown default: return "other" }
}
for op in main.block.operations {
    if op.operatorName == "const" { continue }
    guard let usage = plan.deviceUsage(for: op) else { continue }
    let dev = name(usage.preferred)
    count[dev, default: 0] += 1
    weight[dev, default: 0] += plan.estimatedCost(of: op)?.weight ?? 0
    if !usage.supported.contains(where: { name($0) == "ANE" }) { unsupportedNE[op.operatorName, default: 0] += 1 }
}
let totalW = weight.values.reduce(0, +), totalC = count.values.reduce(0, +)
print("ops (excluding const): \(totalC)")
for dev in count.keys.sorted() {
    print(String(format: "  %@: %d ops (%.1f%%), cost weight %.1f%%", dev, count[dev]!, 100 * Double(count[dev]!) / Double(totalC), totalW > 0 ? 100 * weight[dev, default: 0] / totalW : 0))
}
if !unsupportedNE.isEmpty { print("  ops with no ANE support: " + unsupportedNE.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key)×\($0.value)" }.joined(separator: ", ")) }
