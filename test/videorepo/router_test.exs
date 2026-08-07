defmodule Videorepo.RouterTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @opts Videorepo.Router.init([])

  setup do
    dir = Path.join(System.tmp_dir!(), "videorepo_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    original = Application.get_env(:videorepo, :video_dir)
    Application.put_env(:videorepo, :video_dir, dir)

    on_exit(fn ->
      File.rm_rf(dir)
      if original, do: Application.put_env(:videorepo, :video_dir, original)
    end)

    {:ok, dir: dir}
  end

  defp call(conn), do: Videorepo.Router.call(conn, @opts)

  test "GET /health responde ok" do
    conn = conn(:get, "/health") |> call()
    assert conn.status == 200
    assert conn.resp_body == "ok"
  end

  test "GET /api/videos devuelve name, size y mtime por archivo", %{dir: dir} do
    File.write!(Path.join(dir, "clip.mp4"), "0123456789")

    conn = conn(:get, "/api/videos") |> call()
    assert conn.status == 200

    assert [%{"name" => "clip.mp4", "size" => 10, "mtime" => mtime}] = Jason.decode!(conn.resp_body)
    assert is_integer(mtime)
  end

  test "GET /api/videos oculta los archivos que empiezan con punto", %{dir: dir} do
    File.write!(Path.join(dir, ".part_abc.mp4"), "x")
    File.write!(Path.join(dir, "visible.mp4"), "x")

    conn = conn(:get, "/api/videos") |> call()
    assert [%{"name" => "visible.mp4"}] = Jason.decode!(conn.resp_body)
  end

  test "GET /videos/:name sin Range devuelve 200 y anuncia accept-ranges", %{dir: dir} do
    File.write!(Path.join(dir, "clip.mp4"), "0123456789")

    conn = conn(:get, "/videos/clip.mp4") |> call()
    assert conn.status == 200
    assert get_resp_header(conn, "accept-ranges") == ["bytes"]
    assert get_resp_header(conn, "content-type") == ["video/mp4; charset=utf-8"]
  end

  test "GET /videos/:name con Range devuelve 206 y content-range", %{dir: dir} do
    File.write!(Path.join(dir, "clip.mp4"), "0123456789")

    conn =
      conn(:get, "/videos/clip.mp4")
      |> put_req_header("range", "bytes=2-5")
      |> call()

    assert conn.status == 206
    assert get_resp_header(conn, "content-range") == ["bytes 2-5/10"]
  end

  test "GET /videos/:name de un archivo inexistente devuelve 404" do
    conn = conn(:get, "/videos/no_existe.mp4") |> call()
    assert conn.status == 404
  end

  test "GET /videos/:name with encoded slashes returns 404 from video route" do
    conn = conn(:get, "/videos/..%2F..%2Fetc%2Fpasswd") |> call()
    assert conn.status == 404
    assert conn.resp_body == "no existe"
  end

  test "GET /videos/:name with .. component returns 404 from video route" do
    conn = conn(:get, "/videos/..") |> call()
    assert conn.status == 404
    assert conn.resp_body == "no existe"
  end

  test "GET / sirve la pagina de subida" do
    conn = conn(:get, "/") |> call()
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/html; charset=utf-8"]
    assert conn.resp_body =~ "Video Repo"
  end

  test "GET /vr sirve la pagina 360" do
    conn = conn(:get, "/vr") |> call()
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/html; charset=utf-8"]
    assert conn.resp_body =~ "360"
  end

  test "GET /vr/app.js lo sirve Plug.Static con su content-type" do
    conn = conn(:get, "/vr/app.js") |> call()
    assert conn.status == 200
    assert hd(get_resp_header(conn, "content-type")) =~ "javascript"
  end

  test "Plug.Static no intercepta /videos", %{dir: dir} do
    File.write!(Path.join(dir, "clip.mp4"), "0123456789")

    conn = conn(:get, "/videos/clip.mp4") |> call()
    assert conn.status == 200
    assert get_resp_header(conn, "accept-ranges") == ["bytes"]
  end
end
