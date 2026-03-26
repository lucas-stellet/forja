ExUnit.start()

{:ok, _} = Forja.TestRepo.start_link(pool: Ecto.Adapters.SQL.Sandbox)
Ecto.Adapters.SQL.Sandbox.mode(Forja.TestRepo, :manual)
