defmodule Videorepo.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    port = Application.get_env(:videorepo, :port, 4000)
    dir = Application.get_env(:videorepo, :video_dir, "/data/videos")

    File.mkdir_p!(dir)
    # Carpeta temporal para las subidas EN EL MISMO filesystem que el storage,
    # asi mover el archivo subido es instantaneo (rename) y no una copia.
    tmp = System.get_env("TMPDIR")
    if tmp, do: File.mkdir_p!(tmp)

    Logger.info("videorepo escuchando en :#{port} — storage: #{dir}")

    children = [
      {Bandit, plug: Videorepo.Router, scheme: :http, port: port}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Videorepo.Supervisor)
  end
end
