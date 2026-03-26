defmodule Forja.AdvisoryLock do
  @moduledoc """
  Wrapper for PostgreSQL's `pg_try_advisory_xact_lock`.

  Advisory locks are used to guarantee exactly-once processing:
  only one path (GenStage or Oban) processes a given event at a time.
  The lock is transaction-scoped -- automatically released on commit/rollback.

  The `with_lock/3` function attempts to acquire the lock and executes the
  provided function only if the lock is obtained. If the lock is already held
  by another transaction, returns `{:skipped, :locked}` immediately (non-blocking).
  """

  @doc """
  Executes `fun` inside a transaction with an advisory lock.

  The `lock_key` is converted to a 64-bit integer via `:erlang.phash2/2`.

  ## Return values

    * `{:ok, result}` - Lock acquired, function executed successfully
    * `{:skipped, :locked}` - Lock was already held by another transaction
    * `{:error, reason}` - Error in the transaction or in the function
  """
  @spec with_lock(module(), term(), (-> term())) ::
          {:ok, term()} | {:skipped, :locked} | {:error, term()}
  def with_lock(repo, lock_key, fun) when is_function(fun, 0) do
    lock_id = generate_lock_id(lock_key)

    result =
      repo.transaction(fn ->
        case acquire_lock(repo, lock_id) do
          true ->
            try do
              {:ok, fun.()}
            rescue
              reason -> {:error, reason}
            end

          false ->
            repo.rollback(:locked)
        end
      end)

    case result do
      {:ok, {:ok, value}} -> {:ok, value}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, :locked} -> {:skipped, :locked}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Generates a non-negative integer lock ID from an arbitrary term suitable
  for use as a PostgreSQL `bigint` advisory lock key.

  Uses `:erlang.phash2/2` with a range of `2^32` (4_294_967_296), producing
  a 32-bit unsigned integer. This fits within the positive range of a signed
  64-bit `bigint` accepted by `pg_try_advisory_xact_lock` and provides a
  larger, more uniform hash space than a 31-bit range.

  Note: `:erlang.phash2/2` does not guarantee collision-freedom. For a UUID-based
  event_id the collision probability at this range is negligible in practice
  (`1 / 2^32` per pair). The `processed_at` check and Oban unique constraints
  act as additional safeguards.
  """
  @spec generate_lock_id(term()) :: non_neg_integer()
  def generate_lock_id(key) do
    :erlang.phash2(key, 4_294_967_296)
  end

  defp acquire_lock(repo, lock_id) do
    %{rows: [[result]]} =
      repo.query!("SELECT pg_try_advisory_xact_lock($1)", [lock_id])

    result
  end
end
