defmodule Forja.TestRepo.Migrations.SetupForja do
  use Ecto.Migration

  def up, do: Forja.Migration.up()
  def down, do: Forja.Migration.down()
end
