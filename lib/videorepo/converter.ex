defmodule Videorepo.Converter do
  @moduledoc """
  Capa de conversion: descarga un video de YouTube con yt-dlp y lo transcodifica
  a H.264 (High) + AAC en MP4 con faststart -> el formato que la TV decodifica siempre.
  Corre en background y reporta estado via Videorepo.Jobs.
  """
  require Logger

  def tools_dir, do: System.get_env("TOOLS_DIR") || "/data/videos/.tools"
  defp ytdlp, do: Path.join(tools_dir(), "yt-dlp")
  defp ffmpeg, do: Path.join(tools_dir(), "ffmpeg")

  # Dos familias de fallo que se curan distinto, y confundirlas cuesta caro.
  #
  # STALE: yt-dlp quedo viejo. YouTube rota sus defensas cada pocas semanas y un
  # binario congelado negocia formatos que el CDN despues rechaza (el 403). Se
  # cura actualizando el binario.
  @stale_markers [
    "HTTP Error 403",
    "Requested format is not available",
    "nsig extraction failed",
    "Failed to extract any player response"
  ]

  # BLOQUEO: el binario esta perfecto, es YouTube negandose a servir a ESTE
  # cliente desde esta IP. Actualizar no cambia nada (medido el 2026-09-20: el
  # muro seguia ahi con yt-dlp recien bajado); lo que sirve es pedir el video
  # por otro player client.
  @blocked_markers [
    "Sign in to confirm",
    "PO Token",
    "HTTP Error 429",
    "The page needs to be reloaded"
  ]

  # Player clients en orden de preferencia. El default resuelve la mayoria de
  # los videos; los otros son la salida cuando YouTube levanta el muro contra el
  # cliente web, que exige un PO Token que no tenemos (conseguirlo implicaria
  # meter cookies de una cuenta real en el pod).
  #
  # Orden medido contra el muro el 2026-09-20 (video Qoc1zSZoTog):
  # web_embedded devolvio 399+251 (1080p), mweb solo el formato 18 (360p), y
  # tv/tv_simply/visionos/android_vr/ios no pasaron. Por eso mweb va ultimo: es
  # el bote salvavidas, no una opcion buena.
  @clients [
    {"default", []},
    {"web_embedded", ["--extractor-args", "youtube:player_client=web_embedded"]},
    {"mweb", ["--extractor-args", "youtube:player_client=mweb"]}
  ]

  @doc "Arranca un trabajo de conversion; devuelve el id."
  def start(url, video_dir) do
    id = :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)

    Videorepo.Jobs.put(id, %{
      id: id,
      url: url,
      title: url,
      status: "en cola",
      error: nil,
      started: System.system_time(:second)
    })

    Task.start(fn -> run(id, url, video_dir) end)
    id
  end

  defp run(id, url, dir) do
    tmp = Path.join(System.tmp_dir!(), "yt_" <> id)
    File.mkdir_p!(tmp)

    try do
      unless File.regular?(ytdlp()) and File.regular?(ffmpeg()) do
        raise "faltan las herramientas (yt-dlp/ffmpeg) — todavia se estan bajando en el pod"
      end

      set(id, status: "descargando de YouTube")
      title = get_title(url)
      set(id, title: title)

      src = download(url, tmp)

      set(id, status: "convirtiendo a H.264/AAC")
      # transcodifica a un archivo OCULTO (.part_) y al terminar lo renombra: asi la
      # lista nunca muestra un .mp4 a medio convertir (sin moov atom = no reproducible).
      final = Path.join(dir, safe(title) <> ".mp4")
      part = Path.join(dir, ".part_" <> id <> ".mp4")
      transcode(src, part)
      File.rename!(part, final)

      set(id, status: "listo")
      Logger.info("youtube: convertido \"#{title}\" -> #{Path.basename(final)} (#{File.stat!(final).size} bytes)")
    rescue
      e ->
        msg = Exception.message(e)
        set(id, status: "error", error: msg)
        Logger.error("youtube job #{id} fallo: #{msg}")
    after
      File.rm_rf(tmp)
    end
  end

  # Recorre los mismos clientes que la descarga: si el default esta bloqueado el
  # titulo sale vacio y el job se mostraba como "youtube_1789911995" aunque la
  # descarga despues funcionara por otra puerta. Best-effort: el nombre generico
  # es un final aceptable, no vale abortar por el.
  defp get_title(url) do
    Enum.find_value(@clients, fallback_title(), fn {_name, args} ->
      case System.cmd(
             ytdlp(),
             ["--no-playlist", "--no-warnings", "--print", "%(title)s"] ++ args ++ [url],
             stderr_to_stdout: true
           ) do
        {out, 0} ->
          out |> String.split("\n", trim: true) |> List.first() |> to_string() |> String.trim() |> presence()

        _ ->
          nil
      end
    end)
  end

  defp presence(""), do: nil
  defp presence(title), do: title

  defp fallback_title, do: "youtube_" <> Integer.to_string(System.system_time(:second))

  @doc """
  Distingue "el binario quedo viejo" de "este video no se puede bajar".

  Solo el primer caso se cura actualizando yt-dlp. Reintentar un video privado
  o un corte de red seria puro ruido, y peor: escondería la causa real.
  """
  def stale_failure?(log), do: Enum.any?(@stale_markers, &String.contains?(log, &1))

  @doc """
  Reconoce que YouTube nos cerro la puerta a este player client.

  Separado de `stale_failure?/1` a proposito: el sintoma se parece (la descarga
  no arranca) pero la cura es la opuesta — aca no hay nada que actualizar, hay
  que golpear otra puerta.
  """
  def blocked_failure?(log), do: Enum.any?(@blocked_markers, &String.contains?(log, &1))

  @doc """
  Descarga el video en `tmp` y devuelve la ruta del archivo bajado.

  Publica para poder probar los reintentos sin red. Son dos, y hay que poder
  verificarlos de punta a punta porque los dos nacieron de fallas reales: el
  binario congelado en el PVC (403) y el muro anti-bot de YouTube.
  """
  def download(url, tmp), do: attempt(url, tmp, @clients, false, "sin intentos")

  defp attempt(_url, _tmp, [], _updated?, last) do
    raise "ningun player client (#{Enum.map_join(@clients, ", ", &elem(&1, 0))}) pudo bajar el video. " <>
            "Ultimo error: #{last}. Suele pasar cuando la IP quedo marcada; si persiste, la unica " <>
            "salida es pasarle cookies de una sesion de YouTube a yt-dlp (--cookies)."
  end

  defp attempt(url, tmp, [{name, args} | resto], updated?, last) do
    case run_ytdlp(url, tmp, args) do
      {_log, 0} ->
        if name != "default", do: Logger.info("descarga resuelta con el player client #{name}")
        downloaded!(tmp)

      {log, _} ->
        cond do
          stale_failure?(log) and not updated? ->
            Logger.warning("yt-dlp parece viejo (#{tail(log)}) — actualizo y reintento")
            update_ytdlp()
            attempt(url, tmp, [{name, args} | resto], true, tail(log))

          blocked_failure?(log) or stale_failure?(log) ->
            Logger.warning("player client #{name} rechazado (#{tail(log)}) — pruebo el siguiente")
            pause()
            attempt(url, tmp, resto, updated?, tail(log))

          true ->
            # Video privado, borrado, con geobloqueo: cambiar de cliente no lo
            # arregla y reintentar solo escondería el motivo real.
            raise("yt-dlp fallo: " <> tail(log))
        end
    end
  end

  defp run_ytdlp(url, tmp, extra) do
    System.cmd(
      ytdlp(),
      ["-f", "bv*[height<=1080]+ba/b[height<=1080]/b", "--no-playlist",
       "--merge-output-format", "mkv", "-o", Path.join(tmp, "src.%(ext)s")] ++ extra ++ [url],
      stderr_to_stdout: true
    )
  end

  # Probar clientes en rafaga se gana un 429 de YouTube (visto al medir), que
  # despues parece un bloqueo y contamina el diagnostico del intento siguiente.
  defp pause, do: Process.sleep(Application.get_env(:videorepo, :retry_pause_ms, 2_000))

  # Best-effort: si la actualizacion falla igual reintentamos, porque el 403
  # tambien puede haber sido pasajero. Abortar aca solo perderia ese intento.
  defp update_ytdlp do
    case System.cmd(ytdlp(), ["--update"], stderr_to_stdout: true) do
      {out, 0} -> Logger.info("yt-dlp actualizado: #{tail(out)}")
      {out, _} -> Logger.warning("no se pudo actualizar yt-dlp: #{tail(out)}")
    end
  end

  defp downloaded!(tmp) do
    tmp
    |> File.ls!()
    |> Enum.map(&Path.join(tmp, &1))
    |> Enum.find(&(Path.basename(&1) |> String.starts_with?("src.")))
    |> case do
      nil -> raise "no se encontro el archivo descargado"
      f -> f
    end
  end

  defp transcode(src, out) do
    {log, code} =
      System.cmd(
        ffmpeg(),
        ["-y", "-i", src,
         # cap a 1080p (evita transcodes 4K eternos en el nodo)
         "-vf", "scale=w=min(1920\\,iw):h=-2:flags=lanczos",
         "-c:v", "libx264", "-preset", "veryfast", "-profile:v", "high", "-level", "4.1",
         "-pix_fmt", "yuv420p",
         "-c:a", "aac", "-b:a", "192k",
         "-movflags", "+faststart",
         out],
        stderr_to_stdout: true
      )

    if code != 0 do
      File.rm(out)
      raise("ffmpeg fallo: " <> tail(log))
    end
  end

  defp safe(name),
    do: name |> String.replace(~r/[^\w.\- ]/u, "_") |> String.trim() |> String.slice(0, 120)

  defp tail(s), do: s |> String.trim() |> String.split("\n") |> Enum.take(-4) |> Enum.join(" | ")

  defp set(id, kw), do: Videorepo.Jobs.update(id, fn j -> Enum.into(kw, j) end)
end
