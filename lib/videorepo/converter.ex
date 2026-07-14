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
      out = Path.join(dir, safe(title) <> ".mp4")
      transcode(src, out)

      set(id, status: "listo")
      Logger.info("youtube: convertido \"#{title}\" -> #{Path.basename(out)} (#{File.stat!(out).size} bytes)")
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

  defp download(url, tmp) do
    tpl = Path.join(tmp, "src.%(ext)s")

    {log, code} =
      System.cmd(
        ytdlp(),
        ["-f", "bv*[height<=1080]+ba/b[height<=1080]/b", "--no-playlist",
         "--merge-output-format", "mkv", "-o", tpl, url],
        stderr_to_stdout: true
      )

    if code != 0, do: raise("yt-dlp fallo: " <> tail(log))

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
