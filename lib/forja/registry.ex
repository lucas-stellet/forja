defmodule Forja.Registry do
  @moduledoc """
  Handler registry by event type.

  Builds a dispatch table at boot from the configured handler modules
  and stores it in `:persistent_term` for O(1) lookup without message passing.

  The dispatch table is a map `%{event_type => [handler_module]}`.
  Handlers that return `:all` in `event_types/0` are stored separately
  and included in all lookups.
  """

  @type dispatch_table :: %{String.t() => [module()]}

  @doc """
  Builds the dispatch table from a list of handler modules.

  Each handler is queried via `handler.event_types()`. Handlers that
  return `:all` are separated and included in all `handlers_for/2` lookups.

  Returns `{typed_table, catch_all_handlers}`.
  """
  @spec build([module()]) :: {dispatch_table(), [module()]}
  def build(handlers) when is_list(handlers) do
    {catch_all, typed} = Enum.split_with(handlers, fn h -> h.event_types() == :all end)

    table =
      Enum.reduce(typed, %{}, fn handler, acc ->
        Enum.reduce(handler.event_types(), acc, fn type, inner ->
          Map.update(inner, type, [handler], &(&1 ++ [handler]))
        end)
      end)

    {table, catch_all}
  end

  @doc """
  Stores the dispatch table in `:persistent_term` for the `name` instance.
  """
  @spec store(atom(), dispatch_table(), [module()]) :: :ok
  def store(name, table, catch_all) do
    :persistent_term.put({__MODULE__, name, :table}, table)
    :persistent_term.put({__MODULE__, name, :catch_all}, catch_all)
  end

  @doc """
  Returns the handlers registered for an event type in the `name` instance.

  Combines type-specific handlers with `:all` handlers.
  """
  @spec handlers_for(atom(), String.t()) :: [module()]
  def handlers_for(name, event_type) when is_atom(name) and is_binary(event_type) do
    table = :persistent_term.get({__MODULE__, name, :table}, %{})
    catch_all = :persistent_term.get({__MODULE__, name, :catch_all}, [])

    Map.get(table, event_type, []) ++ catch_all
  end
end
