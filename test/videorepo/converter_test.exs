defmodule Videorepo.ConverterTest do
  use ExUnit.Case, async: false

  alias Videorepo.Converter

  # yt-dlp falso: se comporta segun los argumentos y deja rastro de cada
  # invocacion en $TOOLS_DIR/calls para poder afirmar sobre el reintento.
  # Escrito en sh porque las pruebas corren dentro del pod (Linux).
  defp fake_ytdlp(dir, body) do
    path = Path.join(dir, "yt-dlp")
    File.write!(path, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(path, 0o755)
    path
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "videorepo_conv_#{System.unique_integer([:positive])}")
    tmp = Path.join(dir, "work")
    File.mkdir_p!(tmp)
    original = System.get_env("TOOLS_DIR")
    System.put_env("TOOLS_DIR", dir)
    # Sin pausa entre intentos: en produccion existe para no comerse un 429 de
    # YouTube, pero aca solo haria lenta la suite.
    Application.put_env(:videorepo, :retry_pause_ms, 0)

    on_exit(fn ->
      File.rm_rf(dir)
      Application.delete_env(:videorepo, :retry_pause_ms)
      if original, do: System.put_env("TOOLS_DIR", original), else: System.delete_env("TOOLS_DIR")
    end)

    {:ok, dir: dir, tmp: tmp}
  end

  describe "stale_failure?/1" do
    test "reconoce el 403 del CDN como binario viejo" do
      assert Converter.stale_failure?("ERROR: unable to download video data: HTTP Error 403: Forbidden")
    end

    test "reconoce el formato que ya no existe" do
      assert Converter.stale_failure?("ERROR: Requested format is not available")
    end

    test "reconoce la firma nsig rota" do
      assert Converter.stale_failure?("WARNING: nsig extraction failed: Some formats may be missing")
    end

    # Medido el 2026-09-20: fallaba igual con yt-dlp recien actualizado. No es
    # el binario, es YouTube pidiendo un PO Token que no tenemos.
    test "el muro de bot NO es binario viejo: actualizar no lo cura" do
      refute Converter.stale_failure?("ERROR: Sign in to confirm you're not a bot")
    end

    test "un video que no existe NO es binario viejo" do
      refute Converter.stale_failure?("ERROR: [youtube] abc: Video unavailable")
    end

    test "un corte de red NO es binario viejo" do
      refute Converter.stale_failure?("ERROR: unable to download: <urlopen error timed out>")
    end
  end

  describe "blocked_failure?/1" do
    test "reconoce el muro de bot" do
      assert Converter.blocked_failure?("ERROR: Sign in to confirm you're not a bot")
    end

    test "reconoce el PO Token faltante" do
      assert Converter.blocked_failure?(
               "WARNING: Unable to fetch GVS PO Token for web client: Missing required Visitor Data"
             )
    end

    test "reconoce el rate limit" do
      assert Converter.blocked_failure?("WARNING: Unable to download webpage: HTTP Error 429: Too Many Requests")
    end

    test "un video que no existe NO es bloqueo" do
      refute Converter.blocked_failure?("ERROR: [youtube] abc: Video unavailable")
    end
  end

  describe "download/2 con binario obsoleto" do
    test "ante un 403 actualiza yt-dlp y reintenta una sola vez", %{dir: dir, tmp: tmp} do
      # 1a corrida: 403. --update deja la marca. 2a corrida: baja de verdad.
      fake_ytdlp(dir, """
      echo "$@" >> "#{dir}/calls"
      case "$1" in
        --update)
          touch "#{dir}/updated"
          echo "Updated yt-dlp to stable@2026.09.19"
          exit 0 ;;
      esac
      if [ -f "#{dir}/updated" ]; then
        touch "#{tmp}/src.mkv"
        exit 0
      fi
      echo "ERROR: unable to download video data: HTTP Error 403: Forbidden"
      exit 1
      """)

      assert Converter.download("https://youtu.be/x", tmp) == Path.join(tmp, "src.mkv")
      assert File.exists?(Path.join(dir, "updated")), "no se llamo a yt-dlp --update"

      descargas =
        Path.join(dir, "calls")
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.reject(&String.starts_with?(&1, "--update"))

      assert length(descargas) == 2, "esperaba 1 intento + 1 reintento, hubo #{length(descargas)}"
    end

    test "si el 403 sobrevive al update, prueba los otros clientes y no vuelve a actualizar",
         %{dir: dir, tmp: tmp} do
      fake_ytdlp(dir, """
      case "$1" in
        --update) echo update >> "#{dir}/updates"; exit 0 ;;
      esac
      echo "$@" >> "#{dir}/calls"
      echo "ERROR: unable to download video data: HTTP Error 403: Forbidden"
      exit 1
      """)

      # El error final tiene que decir POR QUE fallo, no solo que fallo.
      assert_raise RuntimeError, ~r/HTTP Error 403/, fn ->
        Converter.download("https://youtu.be/x", tmp)
      end

      assert Path.join(dir, "updates") |> File.read!() |> String.split("\n", trim: true) |> length() == 1,
             "actualizo yt-dlp mas de una vez"

      # default, default (post-update), web_embedded, mweb
      assert Path.join(dir, "calls") |> File.read!() |> String.split("\n", trim: true) |> length() == 4
    end

    test "un error que no es de obsolescencia no gatilla update ni otros clientes", %{dir: dir, tmp: tmp} do
      fake_ytdlp(dir, """
      echo "$@" >> "#{dir}/calls"
      case "$1" in
        --update) touch "#{dir}/updated"; exit 0 ;;
      esac
      echo "ERROR: [youtube] abc: Video unavailable"
      exit 1
      """)

      assert_raise RuntimeError, ~r/Video unavailable/, fn ->
        Converter.download("https://youtu.be/x", tmp)
      end

      refute File.exists?(Path.join(dir, "updated")),
             "actualizo yt-dlp por un error que no es de obsolescencia"

      assert Path.join(dir, "calls") |> File.read!() |> String.split("\n", trim: true) |> length() == 1,
             "insistio con otros clientes con un video que no existe"
    end

    test "en el camino feliz no toca yt-dlp --update", %{dir: dir, tmp: tmp} do
      fake_ytdlp(dir, """
      case "$1" in
        --update) touch "#{dir}/updated"; exit 0 ;;
      esac
      touch "#{tmp}/src.mkv"
      exit 0
      """)

      assert Converter.download("https://youtu.be/x", tmp) == Path.join(tmp, "src.mkv")
      refute File.exists?(Path.join(dir, "updated"))
    end
  end

  describe "download/2 contra el muro anti-bot" do
    test "si el cliente por defecto choca con el muro, pasa a web_embedded", %{dir: dir, tmp: tmp} do
      # El default pega contra el muro; web_embedded baja. Medido contra YouTube
      # el 2026-09-20 con el video Qoc1zSZoTog.
      fake_ytdlp(dir, """
      echo "$@" >> "#{dir}/calls"
      case "$1" in
        --update) touch "#{dir}/updated"; exit 0 ;;
      esac
      case "$*" in
        *player_client=web_embedded*)
          touch "#{tmp}/src.mkv"
          exit 0 ;;
      esac
      echo "ERROR: [youtube] x: Sign in to confirm you're not a bot."
      exit 1
      """)

      assert Converter.download("https://youtu.be/x", tmp) == Path.join(tmp, "src.mkv")

      refute File.exists?(Path.join(dir, "updated")),
             "gasto un update en algo que actualizar no cura"

      assert Path.join(dir, "calls") |> File.read!() =~ "player_client=web_embedded"
    end

    test "si web_embedded tambien esta bloqueado, sigue con mweb", %{dir: dir, tmp: tmp} do
      fake_ytdlp(dir, """
      echo "$@" >> "#{dir}/calls"
      case "$*" in
        *player_client=mweb*)
          touch "#{tmp}/src.mkv"
          exit 0 ;;
      esac
      echo "ERROR: [youtube] x: Sign in to confirm you're not a bot."
      exit 1
      """)

      assert Converter.download("https://youtu.be/x", tmp) == Path.join(tmp, "src.mkv")
      assert Path.join(dir, "calls") |> File.read!() |> String.split("\n", trim: true) |> length() == 3
    end

    test "agotados todos los clientes, el error explica que falta (cookies)", %{dir: dir, tmp: tmp} do
      fake_ytdlp(dir, """
      echo "$@" >> "#{dir}/calls"
      echo "ERROR: [youtube] x: Sign in to confirm you're not a bot."
      exit 1
      """)

      assert_raise RuntimeError, ~r/cookies/i, fn ->
        Converter.download("https://youtu.be/x", tmp)
      end

      # No insiste eternamente: un intento por cliente y se rinde con un mensaje util.
      assert Path.join(dir, "calls") |> File.read!() |> String.split("\n", trim: true) |> length() == 3
    end
  end
end
