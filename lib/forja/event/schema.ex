defmodule Forja.Event.Schema do
  @moduledoc """
  Macro module that provides a DSL for defining typed, validated event schemas
  using Zoi.

  Use this module in event definition modules to get compile-time validated
  payload schemas with automatic parsing and upcasting support.

  ## Example

      defmodule MyApp.Events.OrderCreated do
        use Forja.Event.Schema,
          event_type: "order:created",
          schema_version: 2,
          queue: :payments,
          forja: :my_app,
          source: "checkout"

        payload do
          field :user_id, Zoi.string()
          field :amount_cents, Zoi.integer() |> Zoi.positive()
          field :currency, Zoi.string() |> Zoi.default("USD"), required: false
        end

        def upcast(1, payload) do
          %{"user_id" => payload["customer_id"], "amount_cents" => payload["total"]}
        end

        def idempotency_key(payload) do
          "order_created:\#{payload["user_id"]}"
        end
      end

  When `:forja` is provided, the module also generates `emit/1,2` and
  `emit_multi/1,2` convenience functions:

      # Instead of Forja.emit(:my_app, MyApp.Events.OrderCreated, payload: ..., source: ...)
      MyApp.Events.OrderCreated.emit(%{user_id: "u123", amount_cents: 500})

      # With overrides
      MyApp.Events.OrderCreated.emit(%{user_id: "u123", amount_cents: 500},
        source: "manual_payment"
      )

      # In an Ecto.Multi
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:order, changeset)
      |> MyApp.Events.OrderCreated.emit_multi(
        payload_fn: fn %{order: o} -> %{user_id: o.user_id, amount_cents: o.total} end
      )
      |> Forja.transaction(:my_app)

  ## Options

    * `:event_type` - String identifier for this event type (required)
    * `:schema_version` - Positive integer for payload versioning (default: `1`)
    * `:queue` - Atom for Oban queue routing, prefixed with `forja_` internally (default: `nil`)
    * `:forja` - Atom for the Forja instance name; enables `emit/1,2` and `emit_multi/1,2` (default: `nil`)
    * `:source` - Default source string for events emitted via `emit/1,2` (default: `nil`)

  ## Generated functions

  - `__forja_event_schema__/0` - Returns `true`, marker for runtime detection
  - `event_type/0` - Returns the configured event type string
  - `schema_version/0` - Returns the schema version (default: 1)
  - `queue/0` - Returns the configured queue name or `nil`
  - `parse_payload/1` - Validates input against the Zoi schema
  - `upcast/2` - Upcasts an old payload version to the current version (overridable)
  - `idempotency_key/1` - Returns an idempotency key from payload (overridable, default: `nil`)

  When `:forja` is provided, also generates:

  - `emit/1,2` - Emits the event via `Forja.emit/3` with schema defaults
  - `emit_multi/1,2` - Adds event emission to an `Ecto.Multi` via `Forja.emit_multi/4`

  ## Compile-time validations

  - Raises `CompileError` if `:event_type` was not provided
  - Raises `CompileError` if no fields were defined in `payload do ... end`
  - Raises `CompileError` if Zoi is not loaded
  """

  @doc false
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @forja_opts opts
      @forja_fields []
      @forja_payload_used false

      import Forja.Event.Schema, only: [payload: 1, field: 2, field: 3]

      @before_compile Forja.Event.Schema
    end
  end

  @doc """
  Defines a scoped payload block where fields are declared.

  Inside the block, use `field/3` to define each payload field.

  ## Example

      payload do
        field :user_id, Zoi.string(), required: true
        field :amount, Zoi.integer()
      end
  """
  defmacro payload(do: block) do
    quote do
      @forja_payload_used true
      import Forja.Event.Schema, only: [field: 3, field: 2]
      unquote(block)
    end
  end

  @doc """
  Defines a payload field with a Zoi type and optional configuration.

  ## Arguments

  - `name` - The field name (atom)
  - `zoi_type` - A Zoi type expression (e.g., `Zoi.string()`, `Zoi.integer() |> Zoi.positive()`)
  - `opts` - Optional keyword list. Fields are required by default. Use `required: false` to make a field optional.

  ## Example

      field :user_id, Zoi.string()
      field :amount, Zoi.integer() |> Zoi.positive()
      field :currency, Zoi.string() |> Zoi.default("USD"), required: false
  """
  defmacro field(name, zoi_type, opts \\ []) do
    escaped_type = Macro.escape(zoi_type)

    quote do
      @forja_fields [{unquote(name), unquote(escaped_type), unquote(opts)} | @forja_fields]
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    unless Code.ensure_loaded?(Zoi) do
      raise CompileError,
        description:
          "Zoi is required for Forja.Event.Schema. Add {:zoi, \"~> 0.17\"} to your deps."
    end

    opts = Module.get_attribute(env.module, :forja_opts)
    fields = Module.get_attribute(env.module, :forja_fields) |> Enum.reverse()
    payload_used = Module.get_attribute(env.module, :forja_payload_used)

    event_type = Keyword.get(opts, :event_type)
    version = Keyword.get(opts, :schema_version, 1)
    queue_value = Keyword.get(opts, :queue)
    forja_instance = Keyword.get(opts, :forja)
    forja_source = Keyword.get(opts, :source)

    unless event_type do
      raise CompileError,
        description:
          "#{inspect(env.module)} must provide :event_type option to `use Forja.Event.Schema`"
    end

    unless is_binary(event_type) do
      raise CompileError,
        description:
          "#{inspect(env.module)} :event_type must be a string, got: #{inspect(event_type)}"
    end

    unless is_integer(version) and version > 0 do
      raise CompileError,
        description:
          "#{inspect(env.module)} :schema_version must be a positive integer, got: #{inspect(version)}"
    end

    if payload_used and fields == [] do
      raise CompileError,
        description:
          "#{inspect(env.module)} must define at least one field inside `payload do ... end`"
    end

    schema_pairs =
      Enum.map(fields, fn {name, type_ast, opts} ->
        required = Keyword.get(opts, :required, true)

        if required do
          {name, type_ast}
        else
          {name, quote(do: Zoi.optional(unquote(type_ast)))}
        end
      end)

    schema_map_ast = {:%{}, [], schema_pairs}

    quote do
      @payload_schema Zoi.map(unquote(schema_map_ast))

      @doc """
      Returns `true`, marking this module as a Forja event schema.
      """
      def __forja_event_schema__, do: true

      @doc """
      Returns the event type string for this schema.
      """
      def event_type, do: unquote(event_type)

      @doc """
      Returns the schema version for this event schema.
      """
      def schema_version, do: unquote(version)

      @doc """
      Returns the configured queue name for this event schema.
      """
      def queue, do: unquote(queue_value)

      @doc """
      Parses and validates the given payload against this event's Zoi schema.

      Returns `{:ok, validated_map}` on success or `{:error, errors}` on failure.
      """
      def parse_payload(input) when is_map(input) do
        Zoi.parse(@payload_schema, input)
      end

      @doc """
      Upcasts a payload from an old schema version to the current version.

      The default implementation is a no-op (returns the payload unchanged).
      Override this function to handle schema migrations.
      """
      def upcast(_from_version, payload), do: payload

      @doc """
      Returns an idempotency key derived from the payload.

      The default implementation returns `nil` (no idempotency).
      Override this function to derive a key from the validated payload.

      The payload passed to this function is already string-keyed.

      ## Example

          def idempotency_key(payload) do
            "order_created:\#{payload["order_id"]}"
          end
      """
      def idempotency_key(_payload), do: nil

      defoverridable upcast: 2, idempotency_key: 1

      unquote(Forja.Event.Schema.__generate_emit_functions__(forja_instance, forja_source))
    end
  end

  @doc false
  def __generate_emit_functions__(nil, _source), do: nil

  def __generate_emit_functions__(forja_instance, forja_source) do
    quote do
      @doc """
      Emits this event via `Forja.emit/3` with the configured instance defaults.

      The `payload` is validated against the Zoi schema. Options like `:source`,
      `:idempotency_key`, `:correlation_id`, and `:causation_id` can be overridden.
      """
      def emit(payload, opts \\ []) do
        merged_opts =
          unquote(__MODULE__).__merge_opts__(
            payload,
            opts,
            unquote(forja_source),
            &idempotency_key/1
          )

        Forja.emit(unquote(forja_instance), __MODULE__, merged_opts)
      end

      @doc """
      Adds event emission steps to an existing `Ecto.Multi`.

      Like `emit/1,2`, uses the configured Forja instance and source defaults.
      """
      def emit_multi(multi, opts \\ []) do
        merged_opts =
          unquote(__MODULE__).__merge_multi_opts__(
            opts,
            unquote(forja_source),
            &idempotency_key/1
          )

        Forja.emit_multi(multi, unquote(forja_instance), __MODULE__, merged_opts)
      end
    end
  end

  @doc false
  def __merge_opts__(payload, opts, default_source, idempotency_key_fn) do
    string_keyed = Map.new(payload, fn {k, v} -> {to_string(k), v} end)

    opts
    |> Keyword.put_new(:payload, payload)
    |> Keyword.put_new_lazy(:source, fn -> default_source end)
    |> Keyword.put_new_lazy(:idempotency_key, fn -> idempotency_key_fn.(string_keyed) end)
  end

  @doc false
  def __merge_multi_opts__(opts, default_source, idempotency_key_fn) do
    has_payload_fn = Keyword.has_key?(opts, :payload_fn)

    opts
    |> Keyword.put_new_lazy(:source, fn -> default_source end)
    |> then(fn opts ->
      if has_payload_fn do
        opts
      else
        payload = Keyword.get(opts, :payload, %{})
        string_keyed = Map.new(payload, fn {k, v} -> {to_string(k), v} end)
        Keyword.put_new_lazy(opts, :idempotency_key, fn -> idempotency_key_fn.(string_keyed) end)
      end
    end)
  end
end
