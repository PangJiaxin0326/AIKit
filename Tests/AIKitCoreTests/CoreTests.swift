import Foundation
import Testing
@testable import AIKitCore
import AIKitTestSupport

@Suite struct JSONValueTests {
    @Test func roundTrip() throws {
        let value: JSONValue = .object([
            "name": .string("navigate"),
            "count": .number(3),
            "flag": .bool(true),
            "nested": .array([.string("a"), .null]),
        ])
        let data = try value.data()
        let decoded = try JSONValue(data: data)
        #expect(decoded == value)
    }

    @Test func allStringsRecursive() {
        let value: JSONValue = .object([
            "a": .string("x"),
            "b": .array([.string("y"), .number(1)]),
        ])
        #expect(Set(value.allStrings) == ["x", "y"])
    }
}

@Suite struct MockProviderTests {
    @Test func nonStreamingRoundTrip() async throws {
        let provider = MockProvider(finalText: "hello world")
        let client = LLMClient(provider: provider)
        let response = try await client.complete(
            LLMRequest(model: "test", messages: [.init(role: .user, text: "hi")])
        )
        #expect(response.text == "hello world")
        #expect(response.stopReason == .endTurn)
    }

    @Test func streamingRoundTrip() async throws {
        let provider = MockProvider(responses: [
            LLMResponse(
                content: [
                    .text("partial "),
                    .toolUse(id: "t1", name: "navigate", input: .object(["to": .string("home")])),
                ],
                stopReason: .toolUse
            )
        ])
        let client = LLMClient(provider: provider)
        var chunks: [LLMResponseChunk] = []
        for try await chunk in client.stream(LLMRequest(model: "test")) {
            chunks.append(chunk)
        }
        #expect(chunks.contains(.textDelta("partial ")))
        #expect(chunks.contains(.toolUseStart(id: "t1", name: "navigate")))
        #expect(chunks.contains(.stop(.toolUse)))
    }

    @Test func exhaustionThrows() async {
        let provider = MockProvider(finalText: "once")
        let client = LLMClient(provider: provider)
        _ = try? await client.complete(LLMRequest(model: "test"))
        await #expect(throws: LLMError.self) {
            try await client.complete(LLMRequest(model: "test"))
        }
    }
}

@Suite(.serialized) struct HTTPProviderTests {
    @Test func decodesMessagesResponse() async throws {
        let body = """
        {
          "content": [
            {"type": "text", "text": "Hi there"},
            {"type": "tool_use", "id": "tu_1", "name": "navigate", "input": {"to": "settings"}}
          ],
          "stop_reason": "tool_use",
          "usage": {"input_tokens": 12, "output_tokens": 7}
        }
        """.data(using: .utf8)!
        URLProtocolStub.setStub(.init(body: body))
        let provider = AnthropicProvider(
            apiKey: "test-key",
            session: URLProtocolStub.makeSession()
        )
        let response = try await provider.complete(
            LLMRequest(model: "claude-opus-4-7", messages: [.init(role: .user, text: "hi")])
        )
        #expect(response.text == "Hi there")
        #expect(response.stopReason == .toolUse)
        #expect(response.usage.inputTokens == 12)
        #expect(response.toolUses.first?.name == "navigate")
    }

    @Test func httpErrorSurfaces() async {
        URLProtocolStub.setStub(.init(statusCode: 500, body: Data("boom".utf8)))
        let provider = AnthropicProvider(
            apiKey: "test-key",
            session: URLProtocolStub.makeSession()
        )
        await #expect(throws: LLMError.self) {
            try await provider.complete(LLMRequest(model: "claude-opus-4-7"))
        }
    }

    @Test func missingKeyThrows() async {
        let provider = AnthropicProvider(apiKey: "", session: URLProtocolStub.makeSession())
        await #expect(throws: LLMError.self) {
            try await provider.complete(LLMRequest(model: "claude-opus-4-7"))
        }
    }

    @Test func decodesChatCompletion() async throws {
        let body = """
        {
          "choices": [{
            "message": {
              "content": "done",
              "tool_calls": [{
                "id": "call_1",
                "type": "function",
                "function": {"name": "setSetting", "arguments": "{\\"key\\":\\"theme\\"}"}
              }]
            },
            "finish_reason": "tool_calls"
          }],
          "usage": {"prompt_tokens": 5, "completion_tokens": 9}
        }
        """.data(using: .utf8)!
        URLProtocolStub.setStub(.init(body: body))
        let provider = OpenAIProvider(
            apiKey: "test-key",
            session: URLProtocolStub.makeSession()
        )
        let response = try await provider.complete(
            LLMRequest(model: "gpt-4o", messages: [.init(role: .user, text: "hi")])
        )
        #expect(response.text == "done")
        #expect(response.stopReason == .toolUse)
        #expect(response.toolUses.first?.name == "setSetting")
        #expect(response.toolUses.first?.input.objectValue?["key"]?.stringValue == "theme")
    }
}
