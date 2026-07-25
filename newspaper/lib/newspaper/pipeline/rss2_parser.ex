defmodule Newspaper.Pipeline.RSS2Parser do
  @moduledoc false

  use Fiet.RSS2.Engine,
    extras: [
      item: [
        {"content:encoded", :content_encoded},
        {"dc:creator", :dc_creator},
        {"dc:date", :dc_date},
        {"updated", :updated},
        {"atom:updated", :atom_updated}
      ]
    ]
end
