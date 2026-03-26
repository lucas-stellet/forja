defmodule Forja.EventConsumer do
  @moduledoc """
  Native GenStage ConsumerSupervisor that spawns one Task per event.

  Each event received from `Forja.EventProducer` is processed in an isolated
  transient Task. If the Task fails, the supervisor handles the restart in
  isolation without affecting other events.

  The `max_demand` controls the maximum processing concurrency.
  """

  use ConsumerSupervisor

  @doc """
  Starts the EventConsumer.

  ## Options

    * `:name` - Forja instance name (required)
    * `:producer` - Registered name of the producer (required)
    * `:max_demand` - Maximum concurrency (default: `4`)
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    ConsumerSupervisor.start_link(__MODULE__, opts, name: consumer_name(name))
  end

  @doc """
  Returns the registered name of the consumer supervisor for a Forja instance.
  """
  @spec consumer_name(atom()) :: atom()
  def consumer_name(name) do
    Module.concat([Forja, Consumer, name])
  end

  @impl ConsumerSupervisor
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    producer = Keyword.fetch!(opts, :producer)
    max_demand = Keyword.get(opts, :max_demand, 4)

    children = [
      %{
        id: Forja.EventWorker,
        start: {Forja.EventWorker, :start_link, [name]},
        restart: :transient
      }
    ]

    consumer_opts = [
      strategy: :one_for_one,
      subscribe_to: [{producer, max_demand: max_demand, min_demand: 0}]
    ]

    ConsumerSupervisor.init(children, consumer_opts)
  end
end
