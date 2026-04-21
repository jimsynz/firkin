defmodule FirkinTest do
  use ExUnit.Case
  doctest Firkin

  test "greets the world" do
    assert Firkin.hello() == :world
  end
end
