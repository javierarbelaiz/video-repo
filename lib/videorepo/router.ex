defmodule Videorepo.Router do
  @moduledoc """
  Repo de videos: subida por web, importacion desde YouTube (descarga + transcode
  a H.264/AAC) y serving HTTP con Range (reproduccion resumible para la TV).
  """
  use Plug.Router
  require Logger

  plug Plug.Logger

  # `only` es obligatorio: sin el, Plug.Static intentaria resolver /videos/... contra
  # priv/static y taparia la ruta que sirve los archivos con Range.
  plug Plug.Static,
    at: "/",
    from: {:videorepo, "priv/static"},
    only: ["index.html", "vr"],
    gzip: false

  plug :match

  # read_length chico = lecturas frecuentes (evita cortes en subidas lentas por WiFi);
  # read_timeout amplio para archivos grandes.
  plug Plug.Parsers,
    parsers: [:multipart, :urlencoded],
    length: 50_000_000_000,
    read_length: 256_000,
    read_timeout: 120_000

  plug :dispatch

  defp dir, do: Application.get_env(:videorepo, :video_dir, "/data/videos")

  defp send_page(conn, rel) do
    conn
    |> put_resp_content_type("text/html")
    |> send_file(200, Path.join([:code.priv_dir(:videorepo), "static", rel]))
  end

  # ---------- rutas ----------

  get "/health", do: send_resp(conn, 200, "ok")

  get "/", do: send_page(conn, "index.html")

  get "/camara", do: send_page(conn, "camera.html")

  get "/camara/imagen" do
    conn = put_resp_header(conn, "cache-control", "no-store")
    case System.cmd("curl", ["-fs", "--max-time", "4", "http://192.168.1.251:8191/snapshot"]) do
      {jpeg, 0} -> conn |> put_resp_content_type("image/jpeg") |> send_resp(200, jpeg)
      _ -> send_resp(conn, 503, "Cámara sin señal")
    end
  end

  get "/vr", do: send_page(conn, "vr/index.html")

  get "/api/videos" do
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(list_videos()))
  end

  get "/api/jobs" do
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(Videorepo.Jobs.all()))
  end

  # Importar desde YouTube: descarga + transcode a H.264/AAC en background
  post "/youtube" do
    url = conn.params["url"]

    if is_binary(url) and String.contains?(url, "http") do
      id = Videorepo.Converter.start(String.trim(url), dir())
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(%{ok: true, id: id}))
    else
      send_resp(conn, 400, "url invalida")
    end
  end

  post "/upload" do
    case conn.params["file"] do
      %Plug.Upload{path: tmp, filename: name} ->
        safe = safe_name(name)
        dest = Path.join(dir(), safe)
        File.mkdir_p!(dir())
        case File.rename(tmp, dest) do
          :ok -> :ok
          _ -> File.cp!(tmp, dest)
        end
        Logger.info("subido: #{safe} (#{File.stat!(dest).size} bytes)")
        conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(%{ok: true, name: safe}))

      _ ->
        send_resp(conn, 400, "falta el campo 'file'")
    end
  end

  delete "/videos/:name" do
    with path when is_binary(path) <- safe_path(name), true <- File.exists?(path) do
      File.rm(path)
      send_resp(conn, 204, "")
    else
      _ -> send_resp(conn, 404, "no existe")
    end
  end

  get "/videos/:name", do: serve_file(conn, name)

  match _, do: send_resp(conn, 404, "not found")

  # ---------- serving con Range ----------

  defp serve_file(conn, name) do
    with path when is_binary(path) <- safe_path(name),
         {:ok, %File.Stat{size: size}} <- File.stat(path) do
      conn =
        conn
        |> put_resp_header("accept-ranges", "bytes")
        |> put_resp_content_type(content_type(name))

      case get_req_header(conn, "range") do
        ["bytes=" <> spec] ->
          {offset, len} = parse_range(spec, size)

          conn
          |> put_resp_header("content-range", "bytes #{offset}-#{offset + len - 1}/#{size}")
          |> send_file(206, path, offset, len)

        _ ->
          send_file(conn, 200, path)
      end
    else
      _ -> send_resp(conn, 404, "no existe")
    end
  end

  defp parse_range(spec, size) do
    case String.split(spec, "-") do
      [s, ""] -> start = String.to_integer(s); {start, size - start}
      ["", e] -> n = String.to_integer(e); {max(size - n, 0), min(n, size)}
      [s, e] -> start = String.to_integer(s); finish = min(String.to_integer(e), size - 1); {start, finish - start + 1}
      _ -> {0, size}
    end
  end

  # ---------- storage ----------

  defp list_videos do
    d = dir()

    case File.ls(d) do
      {:ok, files} ->
        files
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.map(fn f ->
          {:ok, st} = File.stat(Path.join(d, f), time: :posix)
          %{name: f, size: st.size, mtime: st.mtime}
        end)
        |> Enum.sort_by(& &1.mtime, :desc)

      _ ->
        []
    end
  end

  defp safe_name(name), do: name |> Path.basename() |> String.replace(~r/[^\w.\- ]/u, "_")

  defp safe_path(name) do
    base = Path.basename(name)
    if base in ["", ".", ".."], do: nil, else: Path.join(dir(), base)
  end

  defp content_type(name) do
    case name |> Path.extname() |> String.downcase() do
      ".mp4" -> "video/mp4"
      ".m4v" -> "video/mp4"
      ".mov" -> "video/quicktime"
      ".mkv" -> "video/x-matroska"
      ".webm" -> "video/webm"
      ".avi" -> "video/x-msvideo"
      ".ts" -> "video/mp2t"
      _ -> "application/octet-stream"
    end
  end
end
