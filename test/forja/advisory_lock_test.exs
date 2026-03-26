defmodule Forja.AdvisoryLockTest do
  use Forja.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Forja.AdvisoryLock

  describe "with_lock/3" do
    test "executes function when lock is available" do
      result = AdvisoryLock.with_lock(Repo, "event-123", fn -> :processed end)

      assert {:ok, :processed} = result
    end

    test "returns skipped when lock is held by another transaction" do
      lock_key = "concurrent-event-456"
      lock_id = AdvisoryLock.generate_lock_id(lock_key)
      test_pid = self()

      task =
        Task.async(fn ->
          # Explicitly checkout a separate connection for the task
          # to avoid conflicts with the test process's shared connection
          Sandbox.checkout(Repo)
          Sandbox.mode(Repo, {:shared, self()})

          Repo.transaction(fn ->
            Repo.query!("SELECT pg_advisory_xact_lock($1)", [lock_id])
            send(test_pid, :lock_acquired)

            receive do
              :release -> :ok
            after
              5_000 -> :timeout
            end
          end)
        end)

      assert_receive :lock_acquired, 5_000

      result = AdvisoryLock.with_lock(Repo, lock_key, fn -> :should_not_run end)
      assert {:skipped, :locked} = result

      send(task.pid, :release)
      Task.await(task)
    end

    test "returns error when function raises" do
      result =
        AdvisoryLock.with_lock(Repo, "error-event", fn ->
          raise "boom"
        end)

      assert {:error, _} = result
    end
  end

  describe "generate_lock_id/1" do
    test "returns consistent integer for same key" do
      id1 = AdvisoryLock.generate_lock_id("event-123")
      id2 = AdvisoryLock.generate_lock_id("event-123")

      assert id1 == id2
      assert is_integer(id1)
    end

    test "returns different integers for different keys" do
      id1 = AdvisoryLock.generate_lock_id("event-123")
      id2 = AdvisoryLock.generate_lock_id("event-456")

      assert id1 != id2
    end
  end
end
