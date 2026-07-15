import Foundation

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

expectTruncatedResponse()
try expectCacheDiagnostics()
expectSchemaMismatchIsInvalidResponse()
print("DeepSeekMeetingResponseParser smoke tests passed")
