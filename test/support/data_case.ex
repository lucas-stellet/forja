defmodule Forja.DataCase do
  @moduledoc """
  Case template for tests that require database access.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias Forja.TestRepo, as: Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(Forja.TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end
end
