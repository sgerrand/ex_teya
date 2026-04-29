defmodule Teya.SSETest do
  use ExUnit.Case, async: true

  alias Teya.SSE

  describe "parse/1" do
    test "returns empty events and full buffer when no complete event" do
      input = "event: full\ndata: {}"
      assert {[], ^input} = SSE.parse(input)
    end

    test "parses a single complete event with LF endings" do
      input = "event: full\ndata: {\"status\":\"NEW\"}\n\n"
      assert {[event], ""} = SSE.parse(input)
      assert event["event"] == "full"
      assert event["data"] == "{\"status\":\"NEW\"}"
    end

    test "parses a single complete event with CRLF endings" do
      input = "event: full\r\ndata: {\"status\":\"NEW\"}\r\n\r\n"
      assert {[event], ""} = SSE.parse(input)
      assert event["event"] == "full"
      assert event["data"] == "{\"status\":\"NEW\"}"
    end

    test "parses multiple consecutive events" do
      input =
        "event: full\ndata: {\"status\":\"NEW\"}\n\n" <>
          "event: diff\ndata: {\"status\":\"IN_PROGRESS\"}\n\n"

      assert {[first, second], ""} = SSE.parse(input)
      assert first["event"] == "full"
      assert first["data"] == "{\"status\":\"NEW\"}"
      assert second["event"] == "diff"
      assert second["data"] == "{\"status\":\"IN_PROGRESS\"}"
    end

    test "returns remaining bytes from an incomplete trailing event" do
      input = "data: first\n\ndata: partial"
      assert {[event], "data: partial"} = SSE.parse(input)
      assert event["data"] == "first"
    end

    test "joins multi-line data fields with newlines" do
      input = "data: line1\ndata: line2\ndata: line3\n\n"
      assert {[event], ""} = SSE.parse(input)
      assert event["data"] == "line1\nline2\nline3"
    end

    test "includes id field when present" do
      input = "id: abc-123\ndata: {}\n\n"
      assert {[event], ""} = SSE.parse(input)
      assert event["id"] == "abc-123"
    end

    test "includes retry field as integer when present" do
      input = "retry: 3000\ndata: {}\n\n"
      assert {[event], ""} = SSE.parse(input)
      assert event["retry"] == 3000
    end

    test "ignores invalid retry values" do
      input = "retry: not-a-number\ndata: {}\n\n"
      assert {[event], ""} = SSE.parse(input)
      refute Map.has_key?(event, "retry")
    end

    test "discards comment-only frames (SSE keepalives)" do
      input = ": keepalive\n\ndata: actual\n\n"
      assert {[event], ""} = SSE.parse(input)
      assert event["data"] == "actual"
    end

    test "discards frames with no data field" do
      input = "event: keepalive\n\ndata: payload\n\n"
      assert {[event], ""} = SSE.parse(input)
      assert event["data"] == "payload"
      refute Map.has_key?(event, "event")
    end

    test "handles data: with no space after colon" do
      input = "data:{\"key\":\"val\"}\n\n"
      assert {[event], ""} = SSE.parse(input)
      assert event["data"] == "{\"key\":\"val\"}"
    end

    test "handles empty buffer" do
      assert {[], ""} = SSE.parse("")
    end

    test "handles buffer of only whitespace/newlines" do
      assert {[], "\n"} = SSE.parse("\n")
    end

    test "data values may contain colons" do
      input = "data: http://example.com/path\n\n"
      assert {[event], ""} = SSE.parse(input)
      assert event["data"] == "http://example.com/path"
    end

    test "accumulates events correctly across simulated chunks" do
      chunk1 = "event: full\ndata: {\"st"
      chunk2 = "atus\":\"NEW\"}\n\n"

      {events1, rest1} = SSE.parse(chunk1)
      assert events1 == []

      {events2, rest2} = SSE.parse(rest1 <> chunk2)
      assert rest2 == ""
      assert length(events2) == 1
      assert hd(events2)["data"] == "{\"status\":\"NEW\"}"
    end
  end
end
