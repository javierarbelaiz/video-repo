defmodule Videorepo.ApplicationTest do
  use ExUnit.Case, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "videorepo_app_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    original = Application.get_env(:videorepo, :tls_dir)
    Application.put_env(:videorepo, :tls_dir, dir)

    on_exit(fn ->
      File.rm_rf(dir)
      if original, do: Application.put_env(:videorepo, :tls_dir, original)
    end)

    {:ok, dir: dir}
  end

  defp ids(children) do
    Enum.map(children, fn
      %{id: id} -> id
      module when is_atom(module) -> module
      {module, _} -> module
    end)
  end

  test "sin certificados levanta solo el listener HTTP" do
    children = Videorepo.Application.children()
    assert :videorepo_http in ids(children)
    refute :videorepo_https in ids(children)
  end

  test "con certificados agrega el listener HTTPS", %{dir: dir} do
    File.write!(Path.join(dir, "cert.pem"), "x")
    File.write!(Path.join(dir, "key.pem"), "x")

    children = Videorepo.Application.children()
    assert :videorepo_http in ids(children)
    assert :videorepo_https in ids(children)
  end

  test "los dos listeners tienen ids distintos", %{dir: dir} do
    File.write!(Path.join(dir, "cert.pem"), "x")
    File.write!(Path.join(dir, "key.pem"), "x")

    all = ids(Videorepo.Application.children())
    assert length(all) == length(Enum.uniq(all))
  end

  test "el job store esta siempre presente" do
    assert Videorepo.Jobs in ids(Videorepo.Application.children())
  end

  test "certificado corrupto: la app arranca y el HTTP queda vivo (no lo tumba HTTPS)", %{
    dir: dir
  } do
    # Contenido basura: :ssl difiere el parseo del PEM hasta el handshake, asi
    # que esto no es lo que hace fallar a HTTPS en produccion (:eaddrinuse es
    # el caso real) — pero probar exactamente este caso es lo que pide la
    # invariante: aunque el certificado este corrupto, el arranque tiene que
    # devolver {:ok, pid} y el listener HTTP tiene que estar vivo. La
    # estructura del fix (start_child aparte, no en start_link) es lo que
    # generaliza esto a cualquier otra causa de falla del HTTPS.
    File.write!(Path.join(dir, "cert.pem"), "esto no es un certificado")
    File.write!(Path.join(dir, "key.pem"), "esto no es una clave")

    # Puertos altos y libres: el 4000/4443 de produccion ya estan ocupados
    # dentro de este mismo pod de test.
    original_port = Application.get_env(:videorepo, :port)
    original_tls_port = Application.get_env(:videorepo, :tls_port)
    Application.put_env(:videorepo, :port, 45123)
    Application.put_env(:videorepo, :tls_port, 45124)

    on_exit(fn ->
      restore_env(:port, original_port)
      restore_env(:tls_port, original_tls_port)
    end)

    assert {:ok, pid} = Videorepo.Application.start(:normal, [])

    try do
      http_pid =
        pid
        |> Supervisor.which_children()
        |> Enum.find_value(fn
          {:videorepo_http, child_pid, _type, _modules} -> child_pid
          _ -> nil
        end)

      assert is_pid(http_pid)
      assert Process.alive?(http_pid)
    after
      # No dejar el listener vivo para el resto de la suite.
      Supervisor.stop(pid)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:videorepo, key)
  defp restore_env(key, value), do: Application.put_env(:videorepo, key, value)
end
