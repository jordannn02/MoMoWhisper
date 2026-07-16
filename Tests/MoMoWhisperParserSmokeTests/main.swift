import Foundation
import MoMoWhisperSummaryCore

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

func expectTruncatedResponse() {
    let responseJSON = """
    {
      "choices": [
        {
          "finish_reason": "length",
          "message": {
            "content": "{\\"topics\\":[{\\"topic\\":\\"採購明細表\\""
          }
        }
      ],
      "usage": {
        "prompt_cache_hit_tokens": 120,
        "prompt_cache_miss_tokens": 30
      }
    }
    """

    do {
        _ = try DeepSeekMeetingResponseParser.parseState(from: Data(responseJSON.utf8))
        fputs("FAIL: expected truncatedResponse\n", stderr)
        exit(1)
    } catch DeepSeekMeetingError.truncatedResponse {
    } catch {
        fputs("FAIL: expected truncatedResponse, got \(error)\n", stderr)
        exit(1)
    }
}

func expectCacheDiagnostics() throws {
    let responseJSON = """
    {
      "choices": [
        {
          "finish_reason": "stop",
          "message": {
            "content": "{\\"topics\\":[]}"
          }
        }
      ],
      "usage": {
        "prompt_cache_hit_tokens": 90,
        "prompt_cache_miss_tokens": 10
      }
    }
    """

    let diagnostics = try DeepSeekMeetingResponseParser.diagnostics(from: Data(responseJSON.utf8))

    expect(diagnostics.promptCacheHitTokens == 90, "cache hit tokens")
    expect(diagnostics.promptCacheMissTokens == 10, "cache miss tokens")
    expect(diagnostics.cacheHitRate == 0.9, "cache hit rate")
}

func expectSchemaMismatchIsInvalidResponse() {
    let responseJSON = """
    {
      "choices": [
        {
          "finish_reason": "stop",
          "message": {
            "content": "{\\"topics\\":[{\\"topic\\":\\"採購明細表\\"}]}"
          }
        }
      ]
    }
    """

    do {
        _ = try DeepSeekMeetingResponseParser.parseState(from: Data(responseJSON.utf8))
        fputs("FAIL: expected invalidResponse\n", stderr)
        exit(1)
    } catch DeepSeekMeetingError.invalidResponse {
    } catch {
        fputs("FAIL: expected invalidResponse, got \(error)\n", stderr)
        exit(1)
    }
}

func expectDeltaOnlyResponse() throws {
    let content = #"{"delta_id":"batch-唯一值","operations":[{"op":"upsert_topic","id":"topic-release","title":"Release"},{"op":"upsert_item","id":"item-smoke","topic_id":"topic-release","kind":"action","status":"open","text":"Run a synthetic smoke test."},{"op":"resolve_item","id":"item-old"}]}"#
    let responseJSON = """
    {
      "choices": [
        {
          "finish_reason": "stop",
          "message": { "content": \(try String(data: JSONEncoder().encode(content), encoding: .utf8)!) }
        }
      ],
      "usage": {
        "prompt_tokens": 200,
        "completion_tokens": 50,
        "total_tokens": 250
      }
    }
    """

    let delta = try DeepSeekMeetingResponseParser.parseDelta(from: Data(responseJSON.utf8))
    expect(delta.id == "batch-唯一值", "wire delta id remains diagnostic payload only")
    expect(delta.operations.count == 3, "delta operation count")
    _ = try SummaryProviderDeltaValidator.validated(delta, existingTopicIDs: [])

    let outOfOrder = MeetingSummaryDelta(
        id: "synthetic-out-of-order",
        operations: [delta.operations[1], delta.operations[0]]
    )
    _ = try SummaryProviderDeltaValidator.validated(outOfOrder, existingTopicIDs: [])

    let unknownTopic = MeetingSummaryDelta(
        id: "synthetic-unknown-topic",
        operations: [.upsertItem(.init(
            id: "orphan",
            topicID: "missing-topic",
            kind: .note,
            status: .unknown,
            text: "Synthetic orphan",
            source: .ai
        ))]
    )
    do {
        _ = try SummaryProviderDeltaValidator.validated(unknownTopic, existingTopicIDs: [])
        fputs("FAIL: expected unknown-topic delta to be rejected\n", stderr)
        exit(1)
    } catch SummaryProviderDeltaValidationError.itemReferencesUnknownTopic {
    }
    let diagnostics = try DeepSeekMeetingResponseParser.diagnostics(from: Data(responseJSON.utf8))
    expect(diagnostics.promptTokens == 200, "prompt token count")
    expect(diagnostics.completionTokens == 50, "completion token count")
    expect(diagnostics.totalTokens == 250, "total token count")
}

func expectFullStateEchoIsRejectedByDeltaParser() {
    let responseJSON = """
    {
      "choices": [
        {
          "finish_reason": "stop",
          "message": { "content": "{\\"topics\\":[]}" }
        }
      ]
    }
    """

    do {
        _ = try DeepSeekMeetingResponseParser.parseDelta(from: Data(responseJSON.utf8))
        fputs("FAIL: expected full-state echo to be rejected\n", stderr)
        exit(1)
    } catch DeepSeekMeetingError.invalidResponse {
    } catch {
        fputs("FAIL: expected invalidResponse, got \(error)\n", stderr)
        exit(1)
    }
}

func expectMissingHeadlineAndUnboundedOperationsAreRejected() {
    let missingHeadlineResponse = #"{"choices":[{"finish_reason":"stop","message":{"content":"{\"delta_id\":\"batch\",\"operations\":[{\"op\":\"set_headline\"}]}"}}]}"#
    do {
        _ = try DeepSeekMeetingResponseParser.parseDelta(from: Data(missingHeadlineResponse.utf8))
        fputs("FAIL: expected missing headline to be rejected\n", stderr)
        exit(1)
    } catch DeepSeekMeetingError.invalidResponse {
    } catch {
        fputs("FAIL: expected invalidResponse for missing headline, got \(error)\n", stderr)
        exit(1)
    }

    let topic = MeetingSummaryTopic(id: "topic", title: "Synthetic")
    let tooMany = MeetingSummaryDelta(
        id: "too-many",
        operations: [.upsertTopic(topic)] + (0..<256).map { index in
            .upsertItem(.init(
                id: "item-\(index)",
                topicID: topic.id,
                kind: .note,
                status: .unknown,
                text: "Synthetic item \(index)",
                source: .ai
            ))
        }
    )
    do {
        _ = try SummaryProviderDeltaValidator.validated(tooMany, existingTopicIDs: [])
        fputs("FAIL: expected operation cap to reject 257 operations\n", stderr)
        exit(1)
    } catch SummaryProviderDeltaValidationError.tooManyOperations {
    } catch {
        fputs("FAIL: expected tooManyOperations, got \(error)\n", stderr)
        exit(1)
    }

    let oversized = MeetingSummaryDelta(
        id: "oversized",
        operations: [
            .upsertTopic(topic),
            .upsertItem(.init(
                id: "oversized-item",
                topicID: topic.id,
                kind: .note,
                status: .unknown,
                text: String(repeating: "x", count: 4_001),
                source: .ai
            ))
        ]
    )
    do {
        _ = try SummaryProviderDeltaValidator.validated(oversized, existingTopicIDs: [])
        fputs("FAIL: expected oversized item text to be rejected\n", stderr)
        exit(1)
    } catch SummaryProviderDeltaValidationError.invalidField {
    } catch {
        fputs("FAIL: expected invalidField, got \(error)\n", stderr)
        exit(1)
    }
}

expectTruncatedResponse()
try expectCacheDiagnostics()
expectSchemaMismatchIsInvalidResponse()
try expectDeltaOnlyResponse()
expectFullStateEchoIsRejectedByDeltaParser()
expectMissingHeadlineAndUnboundedOperationsAreRejected()
print("DeepSeekMeetingResponseParser smoke tests passed")
