defmodule Forja.ValidationError do
  @moduledoc """
  Struct representing a payload validation failure.

  Returned by `Forja.emit/3` and `Forja.emit_multi/4` when a schema module
  rejects the payload. Wraps validation errors in a Forja-owned type so
  callers never need to depend on the underlying validation library.

  ## Fields

    * `:type` - The event type (string or schema module) that failed validation
    * `:errors` - List of normalized error maps with `:field`, `:code`, and `:message`
    * `:message` - Human-readable summary

  ## Example

      case Forja.emit(:app, MyEvent, payload: %{bad: true}) do
        {:ok, event} -> event
        {:error, %Forja.ValidationError{errors: errors}} ->
          Enum.map(errors, & &1.message)
      end
  """

  defexception [:type, :errors, :message]

  @type error :: %{field: atom() | nil, code: atom(), message: String.t()}

  @type t :: %__MODULE__{
          type: String.t() | module(),
          errors: [error()],
          message: String.t()
        }

  @doc """
  Builds a `%Forja.ValidationError{}` from a type and a list of raw validation errors.
  """
  @spec new(String.t() | module(), list()) :: t()
  def new(type, raw_errors) when is_list(raw_errors) do
    normalized = Enum.map(raw_errors, &normalize_error/1)

    type_label =
      if is_atom(type) and function_exported?(type, :event_type, 0),
        do: type.event_type(),
        else: to_string(type)

    %__MODULE__{
      type: type,
      errors: normalized,
      message: "Validation failed for #{type_label}: #{summarize(normalized)}"
    }
  end

  defp normalize_error(%{code: code, message: message, path: path}) do
    field =
      case path do
        [f | _] when is_atom(f) -> f
        _ -> nil
      end

    %{field: field, code: code, message: message}
  end

  defp normalize_error(other) do
    %{field: nil, code: :unknown, message: inspect(other)}
  end

  defp summarize([]), do: "no details"

  defp summarize(errors) do
    errors
    |> Enum.map(fn
      %{field: nil, message: msg} -> msg
      %{field: field, message: msg} -> "#{field} #{msg}"
    end)
    |> Enum.join(", ")
  end
end
