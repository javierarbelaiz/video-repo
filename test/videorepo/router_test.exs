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
  test "GET /camara/imagen sin CAMERA_URL responde 503 sin salir a la red" do
    original = System.get_env("CAMERA_URL")
    System.delete_env("CAMERA_URL")
    on_exit(fn -> if original, do: System.put_env("CAMERA_URL", original) end)

    conn = conn(:get, "/camara/imagen") |> call()
    assert conn.status == 503
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "GET /camara sirve la página de la cámara" do
    conn = conn(:get, "/camara") |> call()
    assert conn.status == 200
    assert conn.resp_body =~ "Cámara"
  end
  describe "control de la cámara (PTZ)" do
    defmodule FakeRecorder do
      use Plug.Router
      plug :match
      plug Plug.Parsers, parsers: [:json], json_decoder: Jason
      plug :dispatch

      post "/ptz/move" do
        send(Application.get_env(:videorepo, :fake_recorder_pid), {:move, conn.body_params})
        send_resp(conn, 200, ~s({"direction":"#{conn.body_params["direction"]}"}))
      end

      post "/ptz/stop" do
        send(Application.get_env(:videorepo, :fake_recorder_pid), :stop)
        send_resp(conn, 200, ~s({"stopped":true}))
      end
    end

    setup do
      original = System.get_env("CAMERA_URL")
      on_exit(fn -> if original, do: System.put_env("CAMERA_URL", original), else: System.delete_env("CAMERA_URL") end)
      :ok
    end

    defp form(path, body) do
      conn(:post, path, body)
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> call()
    end

    defp start_fake_recorder do
      Application.put_env(:videorepo, :fake_recorder_pid, self())
      {:ok, pid} = Bandit.start_link(plug: FakeRecorder, port: 0, ip: {127, 0, 0, 1}, startup_log: false)
      {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
      System.put_env("CAMERA_URL", "http://127.0.0.1:#{port}")
      pid
    end

    test "sin CAMERA_URL el movimiento y el stop responden 503" do
      System.delete_env("CAMERA_URL")
      assert form("/camara/ptz/move", "direction=right").status == 503
      assert form("/camara/ptz/stop", "").status == 503
    end

    test "una dirección desconocida se rechaza sin llamar al grabador" do
      System.put_env("CAMERA_URL", "http://127.0.0.1:9")
      conn = form("/camara/ptz/move", "direction=diagonal")
      assert conn.status == 400
    end

    test "reenvía al grabador solo dirección, velocidad y duración válidas" do
      start_fake_recorder()
      conn = form("/camara/ptz/move", "direction=left&speed=9&seconds=60&extra=hola")
      assert conn.status == 200
      assert_receive {:move, body}, 5_000
      assert body == %{"direction" => "left", "speed" => 1.0, "seconds" => 2.0}
    end

    test "el stop se reenvía al grabador" do
      start_fake_recorder()
      assert form("/camara/ptz/stop", "").status == 200
      assert_receive :stop, 5_000
    end
  end
  test "sirve el manifest y el ícono de la app de la cámara" do
    conn = conn(:get, "/manifest.webmanifest") |> call()
    assert conn.status == 200
    assert hd(get_resp_header(conn, "content-type")) =~ ~r/^application\/manifest\+json/
    icon = conn(:get, "/icon.svg") |> call()
    assert icon.status == 200
    assert hd(get_resp_header(icon, "content-type")) =~ ~r/^image\/svg\+xml/
  end
end
