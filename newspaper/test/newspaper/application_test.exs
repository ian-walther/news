defmodule Newspaper.ApplicationTest do
  use ExUnit.Case, async: true

  test "release includes inets for RSS date parsing" do
    assert :inets in Application.spec(:newspaper, :applications)
  end
end
