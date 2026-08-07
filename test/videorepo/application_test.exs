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
end
