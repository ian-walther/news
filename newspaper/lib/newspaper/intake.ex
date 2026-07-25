defmodule Newspaper.Intake do
  import Ecto.Query

  alias Newspaper.Intake.{InputFeed, IntakeGroup, RawItem}
  alias Newspaper.Repo

  def list_intake_groups do
    IntakeGroup
    |> order_by([g], asc: g.name)
    |> preload(:input_feeds)
    |> Repo.all()
  end

  def list_enabled_intake_groups do
    IntakeGroup
    |> where([g], g.enabled == true)
    |> order_by([g], asc: g.name)
    |> Repo.all()
  end

  def get_intake_group!(id), do: Repo.get!(IntakeGroup, id) |> Repo.preload(:input_feeds)

  def create_intake_group(attrs) do
    %IntakeGroup{}
    |> IntakeGroup.changeset(attrs)
    |> Repo.insert()
    |> broadcast_on_ok(:intake_changed)
  end

  def update_intake_group(%IntakeGroup{} = group, attrs) do
    group
    |> IntakeGroup.changeset(attrs)
    |> Repo.update()
    |> broadcast_on_ok(:intake_changed)
  end

  def delete_intake_group(%IntakeGroup{} = group) do
    group
    |> Repo.delete()
    |> broadcast_on_ok(:intake_changed)
  end

  def change_intake_group(%IntakeGroup{} = group, attrs \\ %{}) do
    IntakeGroup.changeset(group, attrs)
  end

  def list_input_feeds do
    InputFeed
    |> order_by([f], asc: f.name)
    |> preload(:intake_group)
    |> Repo.all()
  end

  def list_enabled_input_feeds do
    InputFeed
    |> join(:left, [f], g in assoc(f, :intake_group))
    |> where([f, g], f.enabled == true and (is_nil(f.intake_group_id) or g.enabled == true))
    |> order_by([f], asc: f.name)
    |> preload(:intake_group)
    |> Repo.all()
  end

  def list_ungrouped_input_feeds do
    InputFeed
    |> where([f], is_nil(f.intake_group_id))
    |> order_by([f], asc: f.name)
    |> Repo.all()
  end

  def get_input_feed!(id), do: Repo.get!(InputFeed, id) |> Repo.preload(:intake_group)

  def create_input_feed(attrs) do
    %InputFeed{}
    |> InputFeed.changeset(attrs)
    |> Repo.insert()
    |> broadcast_on_ok(:intake_changed)
  end

  def update_input_feed(%InputFeed{} = feed, attrs) do
    feed
    |> InputFeed.changeset(attrs)
    |> Repo.update()
    |> broadcast_on_ok(:intake_changed)
  end

  def delete_input_feed(%InputFeed{} = feed) do
    feed
    |> Repo.delete()
    |> broadcast_on_ok(:intake_changed)
  end

  def mark_input_feed_fetched(%InputFeed{} = feed, status, attrs \\ %{}) do
    attrs =
      attrs
      |> Map.put(:last_fetch_status, status)
      |> Map.put(:last_fetched_at, DateTime.utc_now(:second))

    feed
    |> InputFeed.fetch_state_changeset(attrs)
    |> Repo.update()
    |> broadcast_on_ok(:intake_changed)
  end

  def change_input_feed(%InputFeed{} = feed, attrs \\ %{}) do
    InputFeed.changeset(feed, attrs)
  end

  def list_recent_raw_items(limit \\ 50) do
    RawItem
    |> order_by([r], desc: r.discovered_at)
    |> limit(^limit)
    |> preload([:input_feed, :intake_group])
    |> Repo.all()
  end

  def get_raw_item!(id), do: Repo.get!(RawItem, id)

  def find_raw_item(%InputFeed{id: input_feed_id}, attrs) do
    feed_guid = Map.get(attrs, :feed_guid) || Map.get(attrs, "feed_guid")
    url = Map.get(attrs, :url) || Map.get(attrs, "url")

    query =
      cond do
        present?(feed_guid) and present?(url) ->
          from r in RawItem,
            where:
              r.input_feed_id == ^input_feed_id and
                (r.feed_guid == ^feed_guid or r.url == ^url)

        present?(feed_guid) ->
          from r in RawItem,
            where: r.input_feed_id == ^input_feed_id and r.feed_guid == ^feed_guid

        present?(url) ->
          from r in RawItem,
            where: r.input_feed_id == ^input_feed_id and r.url == ^url

        true ->
          nil
      end

    if query do
      query
      |> order_by([r], asc: r.inserted_at)
      |> limit(1)
      |> Repo.one()
    end
  end

  def upsert_raw_item(%InputFeed{} = feed, attrs, opts \\ []) do
    attrs =
      attrs
      |> Map.put_new(:discovered_at, DateTime.utc_now(:second))

    case find_raw_item(feed, attrs) do
      nil ->
        changeset =
          %RawItem{
            input_feed_id: feed.id,
            intake_group_id: feed.intake_group_id
          }
          |> RawItem.changeset(attrs)

        case Repo.insert(changeset, on_conflict: :nothing) do
          {:ok, %RawItem{id: id} = raw_item} when not is_nil(id) ->
            maybe_broadcast_raw_item(raw_item, opts)

          {:ok, %RawItem{}} ->
            case find_raw_item(feed, attrs) do
              %RawItem{} = raw_item -> {:ok, raw_item}
              nil -> {:error, :raw_item_conflict_without_match}
            end

          {:error, _changeset} = error ->
            error
        end

      %RawItem{} = raw_item ->
        {:ok, raw_item}
    end
  end

  defp maybe_broadcast_raw_item(raw_item, opts) do
    if Keyword.get(opts, :broadcast, true) do
      broadcast_on_ok({:ok, raw_item}, :intake_changed)
    else
      {:ok, raw_item}
    end
  end

  defp broadcast_on_ok({:ok, value}, event) do
    Newspaper.Events.broadcast_data_changed(event)
    {:ok, value}
  end

  defp broadcast_on_ok(result, _event), do: result

  defp present?(value), do: is_binary(value) and value != ""
end
