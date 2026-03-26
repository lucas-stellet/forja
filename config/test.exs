import Config
config :forja, Forja.TestRepo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "forja_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2,
  queue_target: 5000,
  queue_interval: 10_000

config :logger, level: :warning
config :forja, Oban, testing: :manual
