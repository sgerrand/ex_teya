defmodule Teya.SSETest do
  use ExUnit.Case, async: true

  alias Teya.SSE

  describe "take_error_body/2" do
    test "appends a chunk that fits in the budget" do
      assert SSE.take_error_body("one ", "two") == "one two"
    end

    test "treats a missing body as empty" do
      assert SSE.take_error_body(nil, "first") == "first"
    end

    test "cuts a single chunk larger than the budget" do
      limit = SSE.max_error_body_bytes()
      chunk = String.duplicate("x", limit * 4)

      assert byte_size(SSE.take_error_body("", chunk)) == limit
    end

    test "cuts a chunk to what is left of the budget" do
      limit = SSE.max_error_body_bytes()
      body = String.duplicate("a", limit - 10)

      assert byte_size(SSE.take_error_body(body, String.duplicate("b", 500))) == limit
    end

    test "takes nothing more once the budget is used up" do
      body = String.duplicate("a", SSE.max_error_body_bytes())

      assert SSE.take_error_body(body, "more") == body
    end
  end
end
