import Foundation
import MLXLLM
import MLXLMCommon

@main
struct LLMTest {
    static func main() async {
        let modelId = "mlx-community/Qwen3.5-4B-MLX-4bit"
        let testInput = "Now we want to improve it further. Like the buttons on the HUD, we need to tell user what is the functionality they expect."
        let systemPrompt = "Fix grammar and punctuation. Return only the corrected text."

        print("=== LLM STANDALONE TEST ===")
        print("Model: \(modelId)")
        print("")

        do {
            // Load model
            print("Loading model...")
            let loadStart = CFAbsoluteTimeGetCurrent()

            let config = ModelConfiguration(id: modelId)
            let container = try await LLMModelFactory.shared.loadContainer(
                configuration: config,
                progressHandler: { progress in
                    let pct = Int(progress.fractionCompleted * 100)
                    print("  Download: \(pct)%", terminator: "\r")
                    fflush(stdout)
                }
            )

            let loadTime = CFAbsoluteTimeGetCurrent() - loadStart
            print("\nModel loaded in \(String(format: "%.2f", loadTime))s")

            // Run inference
            print("\nRunning inference...")
            print("Input: \(testInput)")
            let inferStart = CFAbsoluteTimeGetCurrent()

            let session = ChatSession(
                container,
                instructions: systemPrompt,
                generateParameters: GenerateParameters(temperature: 0.1, topP: 0.8)
            )

            let result = try await session.respond(to: testInput)
            let inferTime = CFAbsoluteTimeGetCurrent() - inferStart

            print("\nOutput: \(result)")
            print("\n=== RESULTS ===")
            print("Load time: \(String(format: "%.2f", loadTime))s")
            print("Inference time: \(String(format: "%.2f", inferTime))s")
            print("Total: \(String(format: "%.2f", loadTime + inferTime))s")

        } catch {
            print("ERROR: \(error)")
        }
    }
}
