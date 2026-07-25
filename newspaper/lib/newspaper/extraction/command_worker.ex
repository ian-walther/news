defmodule Newspaper.Extraction.CommandWorker do
  def extract(implementation, command, url, opts \\ [])
      when is_binary(implementation) and (is_binary(command) or is_list(command)) and
             is_binary(url) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 20_000)
    command_timeout_ms = Keyword.get(opts, :command_timeout_ms, timeout_ms + 5_000)
    minimum_text_length = Keyword.get(opts, :minimum_text_length, 500)

    request = %{
      schema_version: 1,
      implementation: implementation,
      url: url,
      metadata: Keyword.get(opts, :metadata, %{}),
      options: %{
        timeout_ms: timeout_ms,
        minimum_text_length: minimum_text_length
      }
    }

    with {:ok, argv} <- normalize_command(command),
         {:ok, payload} <- Jason.encode(request),
         {:ok, output, exit_status} <- run_command(argv, payload, command_timeout_ms),
         {:ok, decoded} <- Jason.decode(output),
         :ok <- ensure_worker_status(exit_status, decoded) do
      {:ok, decoded, request}
    else
      {:error, reason} ->
        {:error, worker_failure(implementation, reason), request}
    end
  end

  defp run_command(argv, payload, timeout) do
    input_path =
      Path.join(
        System.tmp_dir!(),
        "newspaper-extraction-#{System.unique_integer([:positive])}.json"
      )

    pid_path = input_path <> ".pid"
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
            args: [
              "-c",
              """
              input_path="$1"
              pid_path="$2"
              shift 2
              set -m
              "$@" < "$input_path" &
              worker_pid=$!
              printf '%s' "$worker_pid" > "$pid_path"
              set +m
              cleanup() { kill -TERM -- "-$worker_pid" 2>/dev/null || true; }
              trap cleanup EXIT TERM INT
              wait "$worker_pid"
              status=$?
              trap - EXIT TERM INT
              exit "$status"
              """,
              "newspaper-extract",
              input_path,
              pid_path | argv
            ]
          ]
        )

      receive_output(port, timeout, [], pid_path)
    after
      File.rm(input_path)
      File.rm(pid_path)
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  defp normalize_command(command) when is_binary(command) and command != "", do: {:ok, [command]}

  defp normalize_command([executable | _args] = argv) when is_binary(executable) do
    if Enum.all?(argv, &is_binary/1), do: {:ok, argv}, else: {:error, :invalid_command}
  end

  defp normalize_command(_command), do: {:error, :invalid_command}

  defp receive_output(port, timeout, output, pid_path) do
    deadline = System.monotonic_time(:millisecond) + timeout
    receive_output_until(port, deadline, output, pid_path)
  end

  defp receive_output_until(port, deadline, output, pid_path) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        receive_output_until(port, deadline, [output, data], pid_path)

      {^port, :eof} ->
        receive_output_until(port, deadline, output, pid_path)

      {^port, {:exit_status, exit_status}} ->
        {:ok, IO.iodata_to_binary(output), exit_status}
    after
      remaining ->
        terminate_worker(port, pid_path)
        {:error, :timeout}
    end
  end

  defp terminate_worker(port, pid_path) do
    with {:ok, pid_text} <- File.read(pid_path),
         {pid, ""} <- pid_text |> String.trim() |> Integer.parse() do
      _ = System.cmd("kill", ["-TERM", "-#{pid}"], stderr_to_stdout: true)
      _ = System.cmd("kill", ["-KILL", "-#{pid}"], stderr_to_stdout: true)
    end

    close_port(port)
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp ensure_worker_status(0, _decoded), do: :ok
  defp ensure_worker_status(_exit_status, %{"status" => "failed"}), do: :ok
  defp ensure_worker_status(exit_status, _decoded), do: {:error, {:worker_exit, exit_status}}

  defp worker_failure(implementation, :timeout) do
    %{
      "schema_version" => 1,
      "implementation" => implementation,
      "status" => "failed",
      "failure_kind" => "timeout",
      "retryable" => true,
      "message" => "Worker exceeded its execution timeout",
      "debug_metadata" => %{}
    }
  end

  defp worker_failure(implementation, reason) do
    %{
      "schema_version" => 1,
      "implementation" => implementation,
      "status" => "failed",
      "failure_kind" => "worker_error",
      "retryable" => false,
      "message" => inspect(reason),
      "debug_metadata" => %{}
    }
  end
end
