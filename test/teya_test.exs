defmodule TeyaTest do
  use ExUnit.Case
  doctest Teya

  test "greets the world" do
    assert Teya.hello() == :world
  end
end
