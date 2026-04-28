defmodule TeyaTest do
  use ExUnit.Case

  test "module is defined" do
    assert Code.ensure_loaded?(Teya)
  end
end
