defmodule Videorepo.DeployTest do
  # Invariantes del despliegue por Argo CD: sin IPs privadas ni credenciales en el repo, datos
  # protegidos contra poda/borrado y un workflow que no pueda pisar main ni filtrar su token.
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @image "ghcr.io/javierarbelaiz/videorepo"
  @keep ~r/argocd\.argoproj\.io\/sync-options: Prune=false,Delete=false/

  defp read(rel), do: File.read!(Path.join(@root, rel)) |> String.replace("\r\n", "\n")

  defp files(dirs, exts) do
    for dir <- dirs,
        path <- Path.wildcard(Path.join([@root, dir, "**", "*"])),
        File.regular?(path),
        Path.extname(path) in exts,
        do: Path.relative_to(path, @root)
  end

  defp k8s_docs do
    files(["k8s"], [".yaml"])
    |> Enum.flat_map(fn f -> read(f) |> String.split(~r/^---$/m) end)
    |> Enum.filter(&Regex.match?(~r/^kind:/m, &1))
  end

  defp doc(kind, name) do
    Enum.find(k8s_docs(), fn d ->
      Regex.match?(~r/^kind: #{kind}$/m, d) and Regex.match?(~r/^  name: #{name}$/m, d)
    end)
  end

  test "no hay IPs privadas ni de la tailnet en el código, los estáticos ni los manifiestos" do
    private = ~r/\b(192\.168\.\d+\.\d+|10\.\d+\.\d+\.\d+|172\.(1[6-9]|2\d|3[01])\.\d+\.\d+|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d+\.\d+)\b/

    for f <- files(["lib", "priv", "scripts", "k8s", "config"], [".ex", ".exs", ".html", ".js", ".py", ".yaml"]) ++ ["Dockerfile"],
        not String.contains?(f, "vendor") do
      refute Regex.match?(private, read(f)), "#{f} tiene una IP privada: va en el Secret videorepo-red"
    end
  end

  test "ningún manifiesto declara un Secret" do
    for d <- k8s_docs(), do: refute(Regex.match?(~r/^kind: Secret$/m, d))
  end

  test "el Namespace y el volumen de videos no se podan ni se borran" do
    assert doc("Namespace", "videorepo") =~ @keep
    assert doc("PersistentVolumeClaim", "videos") =~ @keep
  end

  test "la app corre desde la imagen de ghcr, sin el fuente del nodo" do
    app = doc("Deployment", "videorepo")
    assert app, "falta el Deployment videorepo"
    refute app =~ "hostPath"
    assert app =~ ~r/image: #{Regex.escape(@image)}$/m
    assert app =~ ~r/imagePullSecrets:\s*\n\s+- \{ ?name: ghcr-pull ?\}/
    assert app =~ "videorepo-red"
  end

  test "la sincronización de la cámara corre en el cluster con la URL del Secret" do
    job = doc("CronJob", "camara-sync")
    assert job, "falta el CronJob camara-sync"
    assert job =~ "concurrencyPolicy: Forbid"
    assert job =~ "videorepo-red"
    assert job =~ "claimName: videos"
    # Un deploy reinicia la app; sin reintentos el Job falla y Argo marca Degraded.
    assert job =~ "backoffLimit: 2"
  end

  describe "depurador de clips de la cámara" do
    test "corre una vez por día, sin solaparse, con el repo de restic del Secret" do
      job = doc("CronJob", "camara-depurador")
      assert job, "falta el CronJob camara-depurador"
      assert job =~ ~s(schedule: "0 5 * * *")
      assert job =~ "concurrencyPolicy: Forbid"
      assert job =~ "/app/scripts/depurar_camara.py"
      assert job =~ "camara-restic"
      for key <- ~w(RESTIC_REPOSITORY RESTIC_PASSWORD), do: assert(job =~ "key: #{key}")
      assert job =~ "claimName: videos"
      # Borra clips: el volumen tiene que estar montado con escritura.
      refute job =~ "readOnly: true"
    end

    test "depurador y sync leen la misma retención (sino sync reimporta lo depurado)" do
      cm = doc("ConfigMap", "camara-retencion")
      assert cm, "falta el ConfigMap camara-retencion"
      assert cm =~ ~s(RETENTION_DAYS: "30")
      for name <- ~w(camara-depurador camara-sync) do
        job = doc("CronJob", name)
        assert job =~ ~r/name: RETENTION_DAYS\s*\n\s*valueFrom: \{ configMapKeyRef: \{ name: camara-retencion, key: RETENTION_DAYS \} \}/,
               "#{name} no toma RETENTION_DAYS del ConfigMap"
      end
    end

    test "restic.ps1 no corta la salida de ssh con Select-Object (mata a ssh y da código -1)" do
      refute read("deploy/restic.ps1") =~ ~r/& ssh[^\n]*\|\s*Select-Object/
    end

    test "está en la kustomización" do
      assert read("k8s/kustomization.yaml") =~ ~r/^  - camara-depurador\.yaml$/m
    end

    test "la imagen trae restic 0.17.3 verificado por sha256" do
      df = read("Dockerfile")
      assert df =~ "ARG RESTIC_VERSION=0.17.3"
      assert df =~ "restic_${RESTIC_VERSION}_linux_amd64.bz2"
      assert df =~ "5097faeda6aa13167aae6e36efdba636637f8741fed89bbf015678334632d4d3"
      assert df =~ "sha256sum -c"
      assert df =~ "scripts/depurar_camara.py"
    end

    test "CI corre los tests de los scripts de Python antes de publicar" do
      wf = read(".github/workflows/deploy.yml")
      {py, _} = :binary.match(wf, "python3 -m unittest discover -s test/python")
      {push, _} = :binary.match(wf, "docker/build-push-action")
      assert py < push
    end
  end

  test "el mDNS no se declara acá: es de la Application mdns-videorepo" do
    refute doc("Deployment", "mdns-videorepo")
    refute File.exists?(Path.join(@root, "k8s/mdns.yaml"))
  end

  test "kustomize fija la etiqueta de la imagen en una sola línea" do
    k = read("k8s/kustomization.yaml")
    assert k =~ ~r/^namespace: videorepo$/m
    assert length(Regex.scan(~r/newTag: sha-[0-9a-f]{7}$/m, k)) == 1
  end

  describe "workflow de despliegue" do
    setup do: {:ok, wf: read(".github/workflows/deploy.yml")}

    test "corre los tests antes de publicar la imagen", %{wf: wf} do
      {tests, _} = :binary.match(wf, "mix test")
      {push, _} = :binary.match(wf, "docker/build-push-action")
      assert tests < push
    end

    test "los tests de CI usan carpetas del runner, no /data", %{wf: wf} do
      for var <- ~w(VIDEO_DIR TMPDIR TLS_DIR TOOLS_DIR) do
        assert wf =~ ~r/#{var}: \$\{\{ runner\.temp \}\}/, "falta #{var} en el paso de tests"
      end
    end

    test "fija las acciones por SHA", %{wf: wf} do
      uses = Regex.scan(~r/^\s*(?:- )?uses: (\S+)/m, wf, capture: :all_but_first) |> List.flatten()
      assert length(uses) >= 4
      for u <- uses, do: assert(u =~ ~r/@[0-9a-f]{40}$/, "#{u} no está fijada por SHA")
    end

    test "solo despliega desde main, sin rebase y sin dejar el token en .git/config", %{wf: wf} do
      assert wf =~ "if: github.ref == 'refs/heads/main'"
      assert wf =~ "persist-credentials: false"
      assert wf =~ ~r/paths-ignore: \[[^\]]*'k8s\/\*\*'/
      assert wf =~ "[skip ci]"
      assert wf =~ "reset --hard origin/main"
      refute wf =~ "pull --rebase"
    end

    test "el workflow viejo que publicaba :latest ya no existe" do
      refute File.exists?(Path.join(@root, ".github/workflows/docker.yml"))
    end
  end
  describe "go2rtc (cámara en vivo por WebRTC)" do
    setup do: {:ok, cfg: read("k8s/go2rtc.yaml")}

    test "la imagen está fijada por versión y digest" do
      app = doc("Deployment", "go2rtc")
      assert app, "falta el Deployment go2rtc"
      assert app =~ ~r/image: alexxit\/go2rtc:\d+\.\d+\.\d+@sha256:[0-9a-f]{64}$/m
    end

    test "las credenciales y direcciones de la cámara salen de Secrets", %{cfg: cfg} do
      assert cfg =~ "camara-rtsp"
      assert cfg =~ "videorepo-red"
      assert cfg =~ "${CAM_USER}"
      assert cfg =~ "${CAM_PASS}"
      assert cfg =~ "${CAM_HOST}"
      refute cfg =~ ~r/rtsp:\/\/[^$\s]+:[^$\s]+@/, "una URL RTSP con usuario y clave escritos"
    end

    test "la API solo expone el reproductor, no la configuración", %{cfg: cfg} do
      assert cfg =~ "allow_paths"
      refute cfg =~ "/api/config"
      assert cfg =~ "/api/webrtc"
      # Sin "/" go2rtc no sirve stream.html (probado con 1.9.15): el reproductor queda en 404.
      assert cfg =~ ~r/allow_paths:\s*
\s+- \/
/
      refute cfg =~ "/api/streams
"
    end

    test "usa el comando de la imagen (tini + go2rtc) y la config en /config/go2rtc.yaml" do
      app = doc("Deployment", "go2rtc")
      refute app =~ ~r/^\s+(args|command):/m, "args/command reemplazan el CMD y tini ejecuta '-config'"
      assert app =~ "mountPath: /config"
    end

    test "WebRTC escucha y se anuncia en la IP del nodo", %{cfg: cfg} do
      assert cfg =~ ~s(listen: "${NODE_IP}:8555")
      assert cfg =~ "- ${NODE_IP}:8555"
    end

    test "no reexpone la cámara por RTSP en la red", %{cfg: cfg} do
      assert cfg =~ ~r/rtsp:\s*\n\s+listen: ""/
    end
  end

  test "la página de la cámara usa WebRTC con go2rtc en el mismo host" do
    html = read("priv/static/camera.html")
    assert html =~ "location.hostname"
    assert html =~ ":1984/stream.html?src=entrada"
    # Solo WebRTC: con "webrtc,mse" go2rtc 1.9.15 se queda en MSE, que conecta primero.
    assert html =~ "stream.html?src=entrada&mode=webrtc'"
    # img{display:block} le ganaba al atributo hidden: la foto oculta se veía como imagen rota.
    assert html =~ "[hidden]{display:none!important}"
  end

  test "la página de la cámara tiene el pad PTZ con freno al soltar" do
    html = read("priv/static/camera.html")
    for d <- ~w(up down left right zoom_in zoom_out), do: assert(html =~ ~s(data-dir="#{d}"))
    assert html =~ "/camara/ptz/move"
    assert html =~ "/camara/ptz/stop"
    for ev <- ~w(pointerup pointerleave pointercancel), do: assert(html =~ ev)
  end

  test "la sincronización convierte los clips a H.264 antes de subirlos" do
    py = read("scripts/sync_camera.py")
    assert py =~ "libx264"
    assert py =~ "+faststart"
  end

  test "la sincronización espera a que la app esté lista y si no, saltea la corrida sin fallar" do
    py = read("scripts/sync_camera.py")
    assert py =~ "/health"
    assert py =~ "def wait_ready"
    assert py =~ "se saltea esta corrida"
  end
  test "la página elige el reproductor por protocolo" do
    html = read("priv/static/camera.html")
    assert html =~ "location.protocol==='https:'"
    assert html =~ "/go2rtc/stream.html?src=entrada&mode=mse"
    assert html =~ ":1984/stream.html?src=entrada&mode=webrtc"
    assert html =~ ~s(<link rel="manifest" href="/manifest.webmanifest">)
    # El reproductor de go2rtc fija el video en 320 px: en un celular se desbordaba con scroll horizontal.
    assert html =~ "object-fit:contain"
    assert html =~ "video-stream{flex:1 1 auto!important;min-width:0!important}"
    assert html =~ "live.onload"
  end

  test "el manifest instala la cámara como app" do
    m = read("priv/static/manifest.webmanifest") |> Jason.decode!()
    assert m["name"] == "Cámara"
    assert m["start_url"] == "/camara"
    assert m["display"] == "standalone"
    assert Enum.any?(m["icons"], &(&1["src"] == "/icon.svg" and &1["sizes"] == "any"))
  end
end
