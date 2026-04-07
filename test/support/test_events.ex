defmodule Forja.TestEvents.EmitTestCreated do
  use Forja.Event.Schema, event_type: "emit_test:created"

  payload do
    field(:order_id, Zoi.string(), required: false)
    field(:a, Zoi.integer(), required: false)
  end
end

defmodule Forja.TestEvents.EmitTestMulti do
  use Forja.Event.Schema, event_type: "emit_test:multi"

  payload do
    field(:ref, Zoi.string(), required: false)
    field(:static, Zoi.boolean(), required: false)
  end
end

defmodule Forja.TestEvents.TestingCreated do
  use Forja.Event.Schema, event_type: "testing:created"

  payload do
    field(:order_id, Zoi.string(), required: false)
    field(:a, Zoi.integer(), required: false)
    field(:b, Zoi.integer(), required: false)
  end
end
