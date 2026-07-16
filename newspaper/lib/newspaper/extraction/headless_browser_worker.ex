defmodule Newspaper.Extraction.HeadlessBrowserWorker do
  alias Newspaper.Extraction.CommandWorker

  @implementation "extraction.headless_browser"

  def implementation, do: @implementation

  def extract(url, opts \\ []) when is_binary(url) do
    command = Keyword.get_lazy(opts, :command, &default_command/0)
    CommandWorker.extract(@implementation, command, url, opts)
  end

  defp default_command do
    Application.fetch_env!(:newspaper, :extractors)
    |> Keyword.fetch!(:headless_browser_command)
  end
end
