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

    on_exit(fn ->
      File.rm_rf(dir)
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

    test "reconoce el muro de bot" do
      assert Converter.stale_failure?("ERROR: Sign in to confirm you're not a bot")
    end

    test "un video que no existe NO es binario viejo" do
      refute Converter.stale_failure?("ERROR: [youtube] abc: Video unavailable")
    end

    test "un corte de red NO es binario viejo" do
      refute Converter.stale_failure?("ERROR: unable to download: <urlopen error timed out>")
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

    test "si el reintento tambien falla, el error dice que ya se actualizo", %{dir: dir, tmp: tmp} do
      fake_ytdlp(dir, """
      case "$1" in
        --update) exit 0 ;;
      esac
      echo "ERROR: unable to download video data: HTTP Error 403: Forbidden"
      exit 1
      """)

      assert_raise RuntimeError, ~r/aun con yt-dlp actualizado/, fn ->
        Converter.download("https://youtu.be/x", tmp)
      end
    end

    test "un error que no es de obsolescencia no gatilla update", %{dir: dir, tmp: tmp} do
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

      assert Path.join(dir, "calls") |> File.read!() |> String.split("\n", trim: true) |> length() == 1
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
end
