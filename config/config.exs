import Config
config :forja, ecto_repos: [Forja.TestRepo]
import_config "#{config_env()}.exs"
