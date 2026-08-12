defmodule Firkin.GetOptsTest do
  use ExUnit.Case, async: true

  doctest Firkin.GetOpts

  describe "resolve_range/2" do
    test "returns :none without a range" do
      assert :none == Firkin.GetOpts.resolve_range(nil, 11)
    end

    test "passes through a range within the object" do
      assert {:ok, {2, 5}} == Firkin.GetOpts.resolve_range({2, 5}, 11)
    end

    test "clamps a last byte beyond the end of the object" do
      assert {:ok, {2, 10}} == Firkin.GetOpts.resolve_range({2, 99}, 11)
    end

    test "resolves an open-ended range against the end of the object" do
      assert {:ok, {6, 10}} == Firkin.GetOpts.resolve_range({6, nil}, 11)
      assert {:ok, {0, 10}} == Firkin.GetOpts.resolve_range({0, nil}, 11)
      assert {:ok, {10, 10}} == Firkin.GetOpts.resolve_range({10, nil}, 11)
    end

    test "resolves a suffix range against the end of the object" do
      assert {:ok, {6, 10}} == Firkin.GetOpts.resolve_range({nil, 5}, 11)
      assert {:ok, {0, 10}} == Firkin.GetOpts.resolve_range({nil, 11}, 11)
    end

    test "clamps a suffix longer than the object to the whole object" do
      assert {:ok, {0, 10}} == Firkin.GetOpts.resolve_range({nil, 99}, 11)
    end

    test "reports a first byte at or past the end as unsatisfiable" do
      assert :unsatisfiable == Firkin.GetOpts.resolve_range({11, nil}, 11)
      assert :unsatisfiable == Firkin.GetOpts.resolve_range({11, 20}, 11)
    end

    test "reports a zero-length suffix as unsatisfiable" do
      assert :unsatisfiable == Firkin.GetOpts.resolve_range({nil, 0}, 11)
    end

    test "reports any range over an empty object as unsatisfiable" do
      assert :unsatisfiable == Firkin.GetOpts.resolve_range({0, 0}, 0)
      assert :unsatisfiable == Firkin.GetOpts.resolve_range({0, nil}, 0)
      assert :unsatisfiable == Firkin.GetOpts.resolve_range({nil, 5}, 0)
    end
  end
end
