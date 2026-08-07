defmodule Videorepo.Application do
  @moduledoc false
  use Application
  require Logger

  @read_timeout 300_000

  @impl true
  def start(_type, _args) do
    dir = Application.get_env(:videorepo, :video_dir, "/data/videos")
    File.mkdir_p!(dir)

    # Carpeta temporal para las subidas EN EL MISMO filesystem que el storage,
    # asi mover el archivo subido es instantaneo (rename) y no una copia.
    tmp = System.get_env("TMPDIR")
    if tmp, do: File.mkdir_p!(tmp)

    Supervisor.start_link(children(), strategy: :one_for_one, name: Videorepo.Supervisor)
  end

  @doc """
  Arbol de supervision. Publica para poder probar la composicion sin arrancar
  la aplicacion: el HTTPS es condicional y esa decision hay que poder verificarla.
  """
  def children do
    port = Application.get_env(:videorepo, :port, 4000)
    dir = Application.get_env(:videorepo, :video_dir, "/data/videos")

    Logger.info("videorepo escuchando en :#{port} — storage: #{dir}")

    [Videorepo.Jobs, http_child(port)] ++ https_child()
  end

  defp http_child(port) do
    Supervisor.child_spec(
      {Bandit,
       plug: Videorepo.Router,
       scheme: :http,
       port: port,
       # read_timeout amplio: subidas grandes por WiFi no se cortan por inactividad
       thousand_island_options: [read_timeout: @read_timeout]},
      id: :videorepo_http
    )
  end

  defp https_child do
    case Videorepo.TLS.options() do
      {:ok, tls_opts} ->
        tls_port = Application.get_env(:videorepo, :tls_port, 4443)
        Logger.info("videorepo TLS escuchando en :#{tls_port} (WebXR necesita https)")

        [
          Supervisor.child_spec(
            {Bandit,
             plug: Videorepo.Router,
             scheme: :https,
             port: tls_port,
             thousand_island_options: [
               read_timeout: @read_timeout,
               transport_options: tls_opts
             ]},
            id: :videorepo_https
          )
        ]

      :disabled ->
        Logger.warning("sin certificado en TLS_DIR: arranco solo HTTP (la TV sigue funcionando)")
        []
    end
  end
end
