import Foundation

/// OpenAI Responses API with strict structured output; transport and privacy gates
/// are shared with the other decision providers.
enum OpenAIClassification {
    static func body(content: String, model: String, rules: DecisionClassificationRules) throws -> Data {
        let choices = try rules.validated().choices
        let (text, truncated) = JevSystemOneRequest.truncated(content)
        var state = ["clipboard_content": text]
        if truncated { state["clipboard_content_note"] = "Only the beginning of a longer clipboard item is included." }
        let input = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
        let criteria = choices.map { ["id": $0.id, "description": $0.description] }
        let descriptions = try JSONSerialization.data(withJSONObject: criteria, options: [.sortedKeys])
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["choice": ["type": "string", "enum": choices.map(\.id)]],
            "required": ["choice"],
            "additionalProperties": false
        ]
        let request: [String: Any] = [
            "model": model,
            "store": false,
            "max_output_tokens": 4096,
            "instructions": JevSystemOneRequest.instructions
                + "\nReturn the chosen id as choice. Available classifiers, ordered specific to general:\n"
                + String(decoding: descriptions, as: UTF8.self),
            "input": [["role": "user", "content": String(decoding: input, as: UTF8.self)]],
            "text": ["format": ["type": "json_schema", "name": "clipboard_classification", "strict": true, "schema": schema]]
        ]
        return try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
    }

    static func decode(_ data: Data, latency: TimeInterval, attempts: Int, rules: DecisionClassificationRules) throws -> JevClassification {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw JevAPIError.invalidResponse("could not decode the OpenAI Responses API response.")
        }
        guard response.status == "completed", !response.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              response.error == nil else {
            throw JevAPIError.invalidResponse("OpenAI did not complete the classification. The local classification was retained.")
        }
        let messages = response.output.filter { $0.type == "message" }
        let parts = messages.flatMap { $0.content ?? [] }
        guard !parts.contains(where: { $0.type == "refusal" }) else {
            throw JevAPIError.invalidResponse("OpenAI declined to classify this text.")
        }
        let texts = parts.filter { $0.type == "output_text" }.compactMap(\.text)
        guard messages.count == 1, messages[0].role == "assistant", messages[0].status == "completed",
              texts.count == 1, let text = texts.first,
              let choice = try? JSONDecoder().decode(Choice.self, from: Data(text.utf8)),
              let category = try rules.validated().choices.first(where: { $0.id == choice.choice })?.category,
              response.usage?.input_tokens.map({ $0 >= 0 }) != false,
              response.usage?.output_tokens.map({ $0 >= 0 }) != false else {
            throw JevAPIError.invalidResponse("OpenAI returned no single supported classifier choice.")
        }
        // Do not invent a calibrated confidence or probabilities for generative output.
        return JevClassification(category: category, rawChoice: choice.choice, modelVersion: response.model,
                                 latency: latency, attempts: attempts, inputTokens: response.usage?.input_tokens,
                                 outputTokens: response.usage?.output_tokens)
    }

    private struct Choice: Decodable {
        let choice: String
    }

    private struct Response: Decodable {
        struct Output: Decodable {
            struct Content: Decodable {
                let type: String
                let text: String?
            }
            let type: String
            let role: String?
            let status: String?
            let content: [Content]?
        }
        struct Usage: Decodable {
            let input_tokens: Int?
            let output_tokens: Int?
        }
        struct Failure: Decodable {}
        let status: String
        let model: String
        let output: [Output]
        let usage: Usage?
        let error: Failure?
    }
}
