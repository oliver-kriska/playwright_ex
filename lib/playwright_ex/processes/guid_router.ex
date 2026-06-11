defmodule PlaywrightEx.GuidRouter do
  @moduledoc """
  Maps Playwright object guids to the `PlaywrightEx.Connection` that owns them.

  Guids are scoped to a single Playwright server process. When multiple
  `PlaywrightEx.Supervisor` instances run side by side (one node.js server each),
  a message about an object must be sent over the connection that created it.

  Each connection registers a guid here when it receives the `__create__` message
  for an object and removes it on `__dispose__`. `route/2` resolves the owning
  connection for a guid, falling back to the given default when the guid is
  unknown (e.g. the root `"Playwright"` object, or a single-connection setup
  where everything lives on the default connection anyway).

  This makes multiple connections transparent to callers: channel functions can
  be called without an explicit `:connection` option for objects that live on a
  non-default connection.
  """

  use GenServer

  @table __MODULE__

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the connection that owns `guid`, or `default` if the guid is unknown.
  """
  @spec route(PlaywrightEx.guid(), GenServer.name()) :: GenServer.name()
  def route(guid, default) do
    case :ets.lookup(@table, guid) do
      [{^guid, connection}] -> connection
      [] -> default
    end
  rescue
    # Table not available (router not started, e.g. :playwright_ex app not started)
    ArgumentError -> default
  end

  @doc false
  # Only dynamic guids (`type@hex`, random per server instance) are registered.
  # Well-known singletons ("Playwright", "localUtils", root "") exist on every
  # connection with the same guid and must resolve to the caller's connection.
  @spec put(PlaywrightEx.guid(), GenServer.name()) :: :ok
  def put(guid, connection) do
    if String.contains?(guid, "@") do
      :ets.insert(@table, {guid, connection})
      GenServer.cast(__MODULE__, {:monitor_connection, connection})
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc false
  @spec delete(PlaywrightEx.guid()) :: :ok
  def delete(guid) do
    :ets.delete(@table, guid)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
    {:ok, %{monitored: %{}}}
  end

  @impl GenServer
  def handle_cast({:monitor_connection, connection}, state) do
    if Map.has_key?(state.monitored, connection) do
      {:noreply, state}
    else
      case GenServer.whereis(connection) do
        nil ->
          {:noreply, state}

        pid ->
          ref = Process.monitor(pid)
          {:noreply, put_in(state.monitored[connection], ref)}
      end
    end
  end

  # Drop all routes of a crashed/stopped connection so stale entries don't
  # shadow the caller-provided default.
  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.monitored, fn {_connection, monitored_ref} -> monitored_ref == ref end) do
      {connection, _ref} ->
        :ets.match_delete(@table, {:_, connection})
        {:noreply, %{state | monitored: Map.delete(state.monitored, connection)}}

      nil ->
        {:noreply, state}
    end
  end
end
