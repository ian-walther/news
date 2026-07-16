defmodule Newspaper.Extraction.SimpleHtmlWorker do
  @implementation "extraction.simple_html"

  def implementation, do: @implementation

  def extract(url, opts \\ []) when is_binary(url) do
    command = Keyword.get(opts, :command, default_command())
    timeout_ms = Keyword.get(opts, :timeout_ms, 20_000)
    command_timeout_ms = Keyword.get(opts, :command_timeout_ms, timeout_ms + 5_000)
    minimum_text_length = Keyword.get(opts, :minimum_text_length, 500)

    request = %{
      schema_version: 1,
      implementation: @implementation,
      url: url,
      metadata: Keyword.get(opts, :metadata, %{}),
      options: %{
        timeout_ms: timeout_ms,
        minimum_text_length: minimum_text_length
      }
    }

    with {:ok, payload} <- Jason.encode(request),
         {:ok, output, exit_status} <- run_command(command, payload, command_timeout_ms),
         {:ok, decoded} <- Jason.decode(output),
         :ok <- ensure_worker_status(exit_status, decoded) do
      {:ok, decoded, request}
    else
      {:error, reason} ->
        {:error, worker_failure(reason), request}
    end
  end

  defp run_command(command, payload, timeout) do
    input_path =
      Path.join(
        System.tmp_dir!(),
        "newspaper-extraction-#{System.unique_integer([:positive])}.json"
      )

    File.write!(input_path, payload)

    try do
      bash = System.find_executable("bash") || raise "bash executable not found"

      port =
        Port.open(
          {:spawn_executable, bash},
          [
            :binary,
            :exit_status,
            :use_stdio,
            :hide,
            args: ["-c", "exec \"$2\" < \"$1\"", "newspaper-extract", input_path, command]
          ]
        )

      receive_output(port, timeout, [])
    after
      File.rm(input_path)
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  defp receive_output(port, timeout, output) do
    deadline = System.monotonic_time(:millisecond) + timeout
    receive_output_until(port, deadline, output)
  end

  defp receive_output_until(port, deadline, output) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        receive_output_until(port, deadline, [output, data])

      {^port, :eof} ->
        receive_output_until(port, deadline, output)

      {^port, {:exit_status, exit_status}} ->
        {:ok, IO.iodata_to_binary(output), exit_status}
    after
      remaining ->
        close_port(port)
        {:error, :timeout}
    end
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp ensure_worker_status(0, _decoded), do: :ok
  defp ensure_worker_status(_exit_status, %{"status" => "failed"}), do: :ok
  defp ensure_worker_status(exit_status, _decoded), do: {:error, {:worker_exit, exit_status}}

  defp worker_failure(:timeout) do
    %{
      "schema_version" => 1,
      "implementation" => @implementation,
      "status" => "failed",
      "failure_kind" => "timeout",
      "retryable" => true,
      "message" => "Worker exceeded its execution timeout",
      "debug_metadata" => %{}
    }
  end

  defp worker_failure(reason) do
    %{
      "schema_version" => 1,
      "implementation" => @implementation,
      "status" => "failed",
      "failure_kind" => "worker_error",
      "retryable" => false,
      "message" => inspect(reason),
      "debug_metadata" => %{}
    }
  end

  defp default_command do
    Application.fetch_env!(:newspaper, :extractors)
    |> Keyword.fetch!(:simple_html_command)
  end
end
