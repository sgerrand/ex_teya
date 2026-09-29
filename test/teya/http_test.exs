defmodule Teya.HTTPTest do
  use ExUnit.Case, async: false

  alias Teya.{HTTP, TestEnv}

  describe "options/1" do
    test "uses the options set for that kind of request" do
      TestEnv.put(:sse_req_options, retry: false)

      assert HTTP.options(:sse_req_options) == [retry: false]
    end

    test "falls back to :req_options when none are set for that kind" do
      TestEnv.delete(:sse_req_options)

      assert HTTP.options(:sse_req_options) == Application.fetch_env!(:teya, :req_options)
    end
  end
end
