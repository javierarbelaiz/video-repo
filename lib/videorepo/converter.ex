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

  defp get_title(url) do
    case System.cmd(ytdlp(), ["--no-playlist", "--no-warnings", "--print", "%(title)s", url],
           stderr_to_stdout: true) do
      {out, 0} -> out |> String.split("\n", trim: true) |> List.first() |> to_string() |> String.trim()
      _ -> "youtube_" <> Integer.to_string(System.system_time(:second))
    end
  end

  # Errores que NO son del video ni de la red: son yt-dlp quedandose viejo.
  # YouTube rota sus defensas cada pocas semanas y un binario congelado empieza
  # a negociar formatos que el CDN despues rechaza (el 403 clasico).
  @stale_markers [
    "HTTP Error 403",
    "Requested format is not available",
    "nsig extraction failed",
    "Sign in to confirm",
    "Failed to extract any player response"
  ]

  @doc """
  Distingue "el binario quedo viejo" de "este video no se puede bajar".

  Solo el primer caso se cura actualizando yt-dlp. Reintentar un video privado
  o un corte de red seria puro ruido, y peor: escondería la causa real.
  """
  def stale_failure?(log), do: Enum.any?(@stale_markers, &String.contains?(log, &1))

  @doc """
  Descarga el video en `tmp` y devuelve la ruta del archivo bajado.

  Publica para poder probar el reintento sin red: el binario de yt-dlp vive en
  el PVC y sobrevive a todos los reinicios del pod, asi que si nadie lo
  actualiza se queda congelado para siempre y cada descarga termina en 403. La
  unica cura es actualizarlo, y eso hay que poder verificarlo de punta a punta.
  """
  def download(url, tmp) do
    case run_ytdlp(url, tmp) do
      {_log, 0} ->
        downloaded!(tmp)

      {log, _} ->
        unless stale_failure?(log), do: raise("yt-dlp fallo: " <> tail(log))

        Logger.warning("yt-dlp parece viejo (#{tail(log)}) — actualizo y reintento")
        update_ytdlp()

        case run_ytdlp(url, tmp) do
          {_log, 0} -> downloaded!(tmp)
          {log2, _} -> raise("la descarga fallo aun con yt-dlp actualizado: " <> tail(log2))
        end
    end
  end

  defp run_ytdlp(url, tmp) do
    System.cmd(
      ytdlp(),
      ["-f", "bv*[height<=1080]+ba/b[height<=1080]/b", "--no-playlist",
       "--merge-output-format", "mkv", "-o", Path.join(tmp, "src.%(ext)s"), url],
      stderr_to_stdout: true
    )
  end

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
