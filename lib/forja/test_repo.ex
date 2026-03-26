defmodule Forja.TestRepo do
  @moduledoc false
  use Ecto.Repo,
    otp_app: :forja,
    adapter: Ecto.Adapters.Postgres,
    migrations_path: "priv/repo/migrations"
end
