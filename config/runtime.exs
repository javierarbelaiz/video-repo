import Config

config :videorepo,
  port: String.to_integer(System.get_env("PORT") || "4000"),
  video_dir: System.get_env("VIDEO_DIR") || "/data/videos"
