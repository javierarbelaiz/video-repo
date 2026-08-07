defmodule Videorepo.TLS do
  @moduledoc """
  Unica fuente de verdad sobre si el listener HTTPS puede levantarse.

  WebXR exige contexto seguro, asi que el reproductor 360 necesita HTTPS. Pero
  la TV Noblex reproduce por HTTP plano: si falta el certificado la aplicacion
  tiene que arrancar igual, sin HTTPS, en vez de caerse entera.
  """

  @spec options() :: {:ok, keyword()} | :disabled
  def options do
    dir = Application.get_env(:videorepo, :tls_dir, "/data/videos/.certs")
    cert = Path.join(dir, "cert.pem")
    key = Path.join(dir, "key.pem")

    if File.regular?(cert) and File.regular?(key) do
      {:ok, [certfile: cert, keyfile: key]}
    else
      :disabled
    end
  end
end
