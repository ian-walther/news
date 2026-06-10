defmodule Newspaper.Events do
  @moduledoc false

  @topic "newspaper:data"

  def subscribe do
    Phoenix.PubSub.subscribe(Newspaper.PubSub, @topic)
  end

  def broadcast_data_changed(event) do
    Phoenix.PubSub.broadcast(Newspaper.PubSub, @topic, {:newspaper_data_changed, event})
  end
end
