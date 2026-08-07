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

    # Solo los hijos que TIENEN que arrancar van al Supervisor.start_link
    # inicial: si cualquier hijo de esa lista falla al arrancar, el supervisor
    # termina TODO lo que ya habia levantado (:one_for_one gobierna reinicios
    # post-arranque, no el arranque en si) y start/2 propaga el error. Con
    # start_permanent: true en prod eso tumba la VM entera.
    #
    # El HTTPS es best-effort: se agrega DESPUES con Supervisor.start_child,
    # una vez que el supervisor ya esta corriendo con HTTP adentro. Si falla
    # (certificado corrupto, puerto ocupado, lo que sea) el HTTP ya esta en
    # pie y no se cae por eso — la TV nunca se entera.
    case Supervisor.start_link(base_children(), strategy: :one_for_one, name: Videorepo.Supervisor) do
      {:ok, pid} = ok ->
        add_https_child(pid)
        ok

      error ->
        error
    end
  end

  @doc """
  Arbol de supervision completo. Publica para poder probar la composicion sin
  arrancar la aplicacion: el HTTPS es condicional y esa decision hay que poder
  verificarla. No es la lista que usa `start/2` para el `Supervisor.start_link`
  inicial (ver `base_children/0`) — el HTTPS se agrega despues, aparte.
  """
  def children do
    base_children() ++ optional_https_children()
  end

  # Hijos que TIENEN que arrancar para que la aplicacion levante. Si alguno
  # falla, no hay HTTP y la falla de arranque es correcta: no hay forma de
  # servir nada.
  defp base_children do
    port = Application.get_env(:videorepo, :port, 4000)
    dir = Application.get_env(:videorepo, :video_dir, "/data/videos")

    Logger.info("videorepo escuchando en :#{port} — storage: #{dir}")

    [Videorepo.Jobs, http_child(port)]
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

  # Usado solo por children/0 para poder verificar la composicion completa en
  # tests sin arrancar nada. El camino real de arranque usa https_spec/0 +
  # Supervisor.start_child (ver add_https_child/1).
  defp optional_https_children do
    case https_spec() do
      {:ok, spec} -> [spec]
      :disabled -> []
    end
  end

  defp add_https_child(supervisor) do
    case https_spec() do
      {:ok, spec} ->
        case Supervisor.start_child(supervisor, spec) do
          {:ok, _pid} ->
            :ok

          {:ok, _pid, _info} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "no se pudo levantar HTTPS (#{inspect(reason)}): sigo solo con HTTP, la TV no se entera"
            )

            :ok
        end

      :disabled ->
        :ok
    end
  end

  defp https_spec do
    case Videorepo.TLS.options() do
      {:ok, tls_opts} ->
        tls_port = Application.get_env(:videorepo, :tls_port, 4443)
        Logger.info("videorepo TLS escuchando en :#{tls_port} (WebXR necesita https)")

        spec =
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

        {:ok, spec}

      :disabled ->
        Logger.warning("sin certificado en TLS_DIR: arranco solo HTTP (la TV sigue funcionando)")
        :disabled
    end
  end
end
