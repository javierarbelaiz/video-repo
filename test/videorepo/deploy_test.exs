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
end
