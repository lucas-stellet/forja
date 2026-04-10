defmodule Forja.Config do
  @moduledoc """
  Configuration struct for a Forja instance.

  Stores validated configuration in `:persistent_term` for O(1) reads
  without message passing. Each Forja instance is identified by a unique `name`.

  ## Fields

    * `:name` - Atom identifying the instance (required)
    * `:repo` - Ecto.Repo module (required)
    * `:pubsub` - Phoenix.PubSub module (required)
    * `:oban_name` - Oban instance name (default: `Oban`)
    * `:default_queue` - Default Oban queue used for event jobs (default: `:events`)
    * `:event_topic_prefix` - Prefix for PubSub topics (default: `"forja"`)
    * `:handlers` - List of modules implementing `Forja.Handler` (default: `[]`)
    * `:dead_letter` - Module implementing `Forja.DeadLetter` (default: `nil`, optional)
    * `:migration_check` - Whether to verify DB migration version at startup (default: `true`)
    * `:reconciliation` - Keyword list for reconciliation settings (default: see below)

  ## Reconciliation defaults

      reconciliation: [
        enabled: true,
        interval_minutes: 60,
        threshold_minutes: 15,
        max_retries: 3
      ]
  """

  @enforce_keys [:name, :repo, :pubsub]
  defstruct [
    :name,
    :repo,
    :pubsub,
    oban_name: Oban,
    default_queue: :events,
    event_topic_prefix: "forja",
    handlers: [],
    dead_letter: nil,
    migration_check: true,
    reconciliation: [
      enabled: true,
      interval_minutes: 60,
      threshold_minutes: 15,
      max_retries: 3
    ]
  ]

  @type t :: %__MODULE__{
          name: atom(),
          repo: module(),
          pubsub: module(),
          oban_name: atom(),
          default_queue: atom(),
          event_topic_prefix: String.t(),
          handlers: [module()],
          dead_letter: module() | nil,
          migration_check: boolean(),
          reconciliation: keyword()
        }

  @doc """
  Creates a new `Config` struct from a keyword list.

  Validates that the required fields (`:name`, `:repo`, `:pubsub`) are present.
  Raises `ArgumentError` if any required field is missing.

  ## Examples

      iex> Forja.Config.new(name: :my_app, repo: MyApp.Repo, pubsub: MyApp.PubSub)
      %Forja.Config{name: :my_app, repo: MyApp.Repo, pubsub: MyApp.PubSub, ...}
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    validate_required!(opts, [:name, :repo, :pubsub])
    struct!(__MODULE__, opts)
  end

  @doc """
  Stores the configuration in `:persistent_term` indexed by the `name` field.

  The key used is `{Forja.Config, name}`.
  """
  @spec store(t()) :: :ok
  def store(%__MODULE__{name: name} = config) do
    :persistent_term.put({__MODULE__, name}, config)
  end

  @doc """
  Retrieves the configuration stored in `:persistent_term` by `name`.

  Raises `ArgumentError` if the configuration is not found.
  """
  @spec get(atom()) :: t()
  def get(name) when is_atom(name) do
    case :persistent_term.get({__MODULE__, name}, :not_found) do
      :not_found ->
        raise ArgumentError,
              "Forja instance #{inspect(name)} not found. Ensure Forja is started in your supervision tree."

      config ->
        config
    end
  end

  defp validate_required!(opts, keys) do
    Enum.each(keys, fn key ->
      unless Keyword.has_key?(opts, key) do
        raise ArgumentError,
              "Missing required config key #{inspect(key)} for Forja. " <>
                "Required keys: #{inspect(keys)}"
      end
    end)
  end
end
