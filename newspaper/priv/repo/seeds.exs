alias Newspaper.Intake.{InputFeed, IntakeGroup, RawItem}
alias Newspaper.Publishing.GeneratedFeed
alias Newspaper.Repo

import Ecto.Query

freshrss_categories = [
  %{
    name: "Cars",
    feeds: [
      %{name: "The Autopian", outlet: "The Autopian", url: "https://www.theautopian.com/feed/"},
      %{name: "The Drive", outlet: "The Drive", url: "https://www.thedrive.com/feed"}
    ]
  },
  %{
    name: "F1",
    feeds: [
      %{
        name: "Formula 1 news - Autosport",
        outlet: "Autosport",
        url: "https://www.autosport.com/rss/f1/news/"
      },
      %{name: "Formula 1 | RACER", outlet: "RACER", url: "https://racer.com/category/f1/feed"}
    ]
  },
  %{
    name: "IMSA",
    feeds: [
      %{
        name: "IMSA, WSC, MPC, Ferrari Challege and MX-5 Cup Articles | RACER",
        outlet: "RACER",
        url: "https://racer.com/category/imsa/feed"
      },
      %{
        name: "IMSA SportsCar news - Autosport",
        outlet: "Autosport",
        url: "https://www.autosport.com/rss/imsa/news/"
      },
      %{
        name: "Motorsport.com - IMSA - Stories",
        outlet: "Motorsport.com",
        url: "https://www.motorsport.com/rss/imsa/news/"
      }
    ]
  },
  %{
    name: "Indy Lights",
    feeds: [
      %{
        name: "Indy NXT Articles | RACER",
        outlet: "RACER",
        url: "https://racer.com/category/indy-nxt/feed"
      },
      %{
        name: "Motorsport.com - Indy Lights - Stories",
        outlet: "Motorsport.com",
        url: "https://www.motorsport.com/rss/indylights/news/"
      }
    ]
  },
  %{
    name: "Indycar",
    feeds: [
      %{
        name: "IndyCar news - Autosport",
        outlet: "Autosport",
        url: "https://www.autosport.com/rss/indycar/news/"
      },
      %{name: "IndyCar | RACER", outlet: "RACER", url: "https://racer.com/category/indycar/feed"},
      %{
        name: "IndyCar - The Race",
        outlet: "The Race",
        url: "https://the-race.com/category/indycar/feed/"
      }
    ]
  },
  %{
    name: "Music",
    feeds: [
      %{
        name: "Pitchfork Album Reviews",
        outlet: "Pitchfork",
        url: "https://pitchfork.com/feed/feed-album-reviews/rss"
      },
      %{name: "RSS: News", outlet: "Pitchfork", url: "https://pitchfork.com/feed/feed-news/rss"}
    ]
  },
  %{
    name: "Nascar",
    feeds: [
      %{
        name: "Motorsport.com - NASCAR - Stories",
        outlet: "Motorsport.com",
        url: "https://www.motorsport.com/rss/category/nascar/news/"
      },
      %{
        name: "NASCAR news - Autosport",
        outlet: "Autosport",
        url: "https://www.autosport.com/rss/nascar/news/"
      },
      %{name: "NASCAR | RACER", outlet: "RACER", url: "https://racer.com/category/nascar/feed"}
    ]
  },
  %{
    name: "Other Racing",
    feeds: [
      %{
        name: "British Touring Car Championship news - Autosport",
        outlet: "Autosport",
        url: "https://www.autosport.com/rss/btcc/news/"
      },
      %{
        name: "Formula E news - Autosport",
        outlet: "Autosport",
        url: "https://www.autosport.com/rss/formula-e/news/"
      },
      %{
        name: "Motorsport.com - Formula E - Stories",
        outlet: "Motorsport.com",
        url: "https://www.motorsport.com/rss/formula-e/news/"
      },
      %{
        name: "Motorsport.com - Supercars - Stories",
        outlet: "Motorsport.com",
        url: "https://www.motorsport.com/rss/v8supercars/news/"
      },
      %{
        name: "Supercars news - Autosport",
        outlet: "Autosport",
        url: "https://www.autosport.com/rss/supercars/news/"
      },
      %{
        name: "World Touring Car Cup news - Autosport",
        outlet: "Autosport",
        url: "https://www.autosport.com/rss/wtcr/news/"
      }
    ]
  },
  %{
    name: "Tech",
    feeds: [
      %{
        name: "Ars Technica",
        outlet: "Ars Technica",
        url: "https://feeds.arstechnica.com/arstechnica/index"
      },
      %{
        name: "MacRumors: Mac News and Rumors - Front Page",
        outlet: "MacRumors",
        url: "http://feeds.macrumors.com/MacRumors-Front"
      },
      %{name: "The Verge", outlet: "The Verge", url: "https://www.theverge.com/rss/index.xml"}
    ]
  }
]

all_feeds = Enum.flat_map(freshrss_categories, & &1.feeds)

feeds_by_url =
  all_feeds
  |> Enum.uniq_by(& &1.url)
  |> Map.new(fn feed ->
    input_feed =
      case Repo.get_by(InputFeed, url: feed.url) do
        nil ->
          %InputFeed{}

        input_feed ->
          input_feed
      end
      |> InputFeed.changeset(%{
        intake_group_id: nil,
        name: feed.name,
        url: feed.url,
        outlet_name: feed.outlet,
        enabled: true,
        default_metadata: %{"seed_source" => "freshrss_opml"}
      })
      |> Repo.insert_or_update!()

    {feed.url, input_feed}
  end)

seeded_input_feed_ids =
  feeds_by_url
  |> Map.values()
  |> Enum.map(& &1.id)

Repo.update_all(
  from(raw_item in RawItem,
    where: raw_item.input_feed_id in ^seeded_input_feed_ids
  ),
  set: [intake_group_id: nil]
)

Repo.query!(
  """
  UPDATE articles
  SET intake_group_id = NULL,
      dedupe_scope = 'feed:' || raw_items.input_feed_id::text
  FROM raw_items
  WHERE articles.representative_raw_item_id = raw_items.id
    AND raw_items.input_feed_id = ANY($1)
  """,
  [seeded_input_feed_ids]
)

Enum.each(freshrss_categories, fn category ->
  input_feed_ids =
    category.feeds
    |> Enum.map(&Map.fetch!(feeds_by_url, &1.url).id)

  feed =
    case Repo.one(from feed in GeneratedFeed, where: feed.title == ^category.name, limit: 1) do
      nil -> %GeneratedFeed{}
      feed -> Repo.preload(feed, [:intake_groups, :input_feeds])
    end

  feed
  |> GeneratedFeed.changeset(%{
    guid:
      "feed_freshrss_#{category.name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_") |> String.trim("_")}",
    title: category.name,
    description: "Seeded from the FreshRSS #{category.name} category.",
    item_limit: 500,
    enabled: true,
    link_to_hosted_article: false,
    title_source: "original",
    body_source: "original_feed",
    policy_config: %{"seed_source" => "freshrss_opml"}
  })
  |> Ecto.Changeset.put_assoc(
    :input_feeds,
    Repo.all(from input_feed in InputFeed, where: input_feed.id in ^input_feed_ids)
  )
  |> Ecto.Changeset.put_assoc(:intake_groups, [])
  |> Repo.insert_or_update!()
end)

seeded_group_names =
  all_feeds
  |> Enum.map(& &1.outlet)
  |> Enum.uniq()

seeded_group_ids =
  Repo.all(
    from group in IntakeGroup,
      where:
        group.name in ^seeded_group_names and group.notes == "Seeded from FreshRSS OPML export.",
      select: group.id
  )

groups_still_in_use =
  Repo.all(
    from group in IntakeGroup,
      as: :group,
      where:
        group.id in ^seeded_group_ids and
          (exists(from feed in InputFeed, where: feed.intake_group_id == parent_as(:group).id) or
             exists(
               from raw_item in RawItem, where: raw_item.intake_group_id == parent_as(:group).id
             )),
      select: group.id
  )

deletable_group_ids = seeded_group_ids -- groups_still_in_use

Repo.delete_all(
  from group in IntakeGroup,
    where: group.id in ^deletable_group_ids
)

IO.puts(
  "Seeded #{map_size(feeds_by_url)} ungrouped input feeds and #{length(freshrss_categories)} output feeds."
)
