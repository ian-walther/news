defmodule Newspaper.Publishing.GeneratedFeedTest do
  use Newspaper.DataCase

  alias Newspaper.Publishing

  test "hosted article digests default to hidden" do
    assert {:ok, feed} = Publishing.create_generated_feed(%{"title" => "Cars"})

    refute feed.show_digest_in_hosted_article
  end
end
