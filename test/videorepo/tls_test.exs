defmodule Videorepo.TLSTest do
  use ExUnit.Case, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "videorepo_tls_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    original = Application.get_env(:videorepo, :tls_dir)
    Application.put_env(:videorepo, :tls_dir, dir)

    on_exit(fn ->
      File.rm_rf(dir)
      if original, do: Application.put_env(:videorepo, :tls_dir, original)
    end)

    {:ok, dir: dir}
  end

  test "sin ningun archivo devuelve :disabled" do
    assert Videorepo.TLS.options() == :disabled
  end

  test "con solo el certificado devuelve :disabled", %{dir: dir} do
    File.write!(Path.join(dir, "cert.pem"), "x")
    assert Videorepo.TLS.options() == :disabled
  end

  test "con solo la clave devuelve :disabled", %{dir: dir} do
    File.write!(Path.join(dir, "key.pem"), "x")
    assert Videorepo.TLS.options() == :disabled
  end

  test "con ambos archivos devuelve las rutas", %{dir: dir} do
    File.write!(Path.join(dir, "cert.pem"), "x")
    File.write!(Path.join(dir, "key.pem"), "x")

    assert {:ok, opts} = Videorepo.TLS.options()
    assert opts[:certfile] == Path.join(dir, "cert.pem")
    assert opts[:keyfile] == Path.join(dir, "key.pem")
  end

  test "un directorio no cuenta como certificado", %{dir: dir} do
    File.mkdir_p!(Path.join(dir, "cert.pem"))
    File.write!(Path.join(dir, "key.pem"), "x")
    assert Videorepo.TLS.options() == :disabled
  end
end
