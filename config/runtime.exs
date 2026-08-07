import Config

config :videorepo,
  port: String.to_integer(System.get_env("PORT") || "4000"),
  tls_port: String.to_integer(System.get_env("TLS_PORT") || "4443"),
  tls_dir: System.get_env("TLS_DIR") || "/data/videos/.certs",
  video_dir: System.get_env("VIDEO_DIR") || "/data/videos"
