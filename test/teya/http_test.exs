defmodule Teya.HTTPTest do
  use ExUnit.Case, async: false

  alias Teya.{HTTP, TestEnv}

  describe "new_request/3" do
    test "takes only options that say how a request is sent from config" do
      TestEnv.put(:sse_req_options,
        receive_timeout: 5,
        retry: false,
        url: "https://elsewhere.example",
        cache: true,
        redirect_trusted: true
      )

      req = HTTP.new_request(:sse_req_options, [url: "https://api.teya.test/x"], [])

      assert req.url == URI.parse("https://api.teya.test/x")
      assert req.options.receive_timeout == 5
      assert req.options.retry == false
      refute Map.has_key?(req.options, :cache)
      refute Map.has_key?(req.options, :redirect_trusted)
    end
  end

  describe "new_request/3 with an idempotency key in config" do
    test "drops it, from a kind that falls back to :req_options too" do
      TestEnv.delete(:auth_req_options)
      TestEnv.add(:req_options, headers: [{"idempotency-key", "from-config"}])

      for key <- [:req_options, :auth_req_options, :sse_req_options] do
        req = HTTP.new_request(key, [url: "https://api.teya.test/x"], [])
        assert Req.Request.get_header(req, "idempotency-key") == [], inspect(key)
      end
    end
  end

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
