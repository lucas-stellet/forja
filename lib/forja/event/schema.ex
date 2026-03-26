defmodule Forja.Event.Schema do
  @moduledoc """
  Macro module that provides a DSL for defining typed, validated event schemas
  using Zoi.

  Use this module in event definition modules to get compile-time validated
  payload schemas with automatic parsing and upcasting support.

  ## Example

      defmodule MyApp.Events.OrderCreated do
        use Forja.Event.Schema

        event_type "order:created"
        schema_version 2

        payload do
          field :user_id, Zoi.string()
          field :amount_cents, Zoi.integer() |> Zoi.positive()
          field :currency, Zoi.string() |> Zoi.default("USD"), required: false
        end

        def upcast(1, payload) do
          %{"user_id" => payload["customer_id"], "amount_cents" => payload["total"]}
        end
      end

  ## Generated functions

  - `__forja_event_schema__/0` - Returns `true`, marker for runtime detection
  - `event_type/0` - Returns the configured event type string
  - `schema_version/0` - Returns the schema version (default: 1)
  - `parse_payload/1` - Validates input against the Zoi schema
  - `upcast/2` - Upcasts an old payload version to the current version

  ## Compile-time validations

  - Raises `CompileError` if `event_type/1` was not called
  - Raises `CompileError` if no fields were defined in `payload do ... end`
  - Raises `CompileError` if Zoi is not loaded
  """

  @doc false
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @forja_fields []
      @forja_event_type nil
      @forja_schema_version 1
      @forja_payload_used false

      import Forja.Event.Schema

      @before_compile Forja.Event.Schema
    end
  end

  @doc """
  Sets the event type string for this event schema.

  ## Example

      event_type "order:created"
  """
  defmacro event_type(type) when is_binary(type) do
    quote do
      @forja_event_type unquote(type)
    end
  end

  @doc """
  Sets the schema version for this event schema.

  Defaults to 1 if not specified.

  ## Example

      schema_version 2
  """
  defmacro schema_version(version) when is_integer(version) and version > 0 do
    quote do
      @forja_schema_version unquote(version)
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

    fields = Module.get_attribute(env.module, :forja_fields) |> Enum.reverse()
    event_type = Module.get_attribute(env.module, :forja_event_type)
    version = Module.get_attribute(env.module, :forja_schema_version)

    unless event_type do
      raise CompileError,
        description: "#{inspect(env.module)} must call `event_type \"some:type\"`"
    end

    payload_used = Module.get_attribute(env.module, :forja_payload_used)

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

      defoverridable upcast: 2
    end
  end
end
