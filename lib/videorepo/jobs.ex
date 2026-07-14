defmodule Videorepo.Jobs do
  @moduledoc "Estado en memoria de los trabajos de conversion (descarga + transcode)."
  use Agent

  def start_link(_), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  def put(id, data), do: Agent.update(__MODULE__, &Map.put(&1, id, data))

  def update(id, fun) do
    Agent.update(__MODULE__, fn m ->
      if Map.has_key?(m, id), do: Map.put(m, id, fun.(m[id])), else: m
    end)
  end

  def all do
    Agent.get(__MODULE__, fn m -> m |> Map.values() |> Enum.sort_by(& &1.started, :desc) end)
  end
end
