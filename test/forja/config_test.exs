defmodule Forja.ConfigTest do
  use ExUnit.Case, async: true

  alias Forja.Config

  # Fake modules for testing
  defmodule Repo do
    defmacro __using__(_), do: :ok
  end

  defmodule PubSub do
    defmacro __using__(_), do: :ok
  end

  defmodule FakeHandler do
    defmacro __using__(_), do: :ok
  end

  defmodule FakeDeadLetter do
    defmacro __using__(_), do: :ok
  end

  describe "new/1" do
    test "creates config with required fields" do
      config = Config.new(name: :test_app, repo: Repo, pubsub: PubSub)

      assert config.name == :test_app
      assert config.repo == Repo
      assert config.pubsub == PubSub
    end

    test "applies default values" do
      config = Config.new(name: :test_app, repo: Repo, pubsub: PubSub)

      assert config.oban_name == Oban
      assert config.default_queue == :events
      assert config.event_topic_prefix == "forja"
      assert config.handlers == []
      assert config.dead_letter == nil
      assert config.reconciliation[:enabled] == true
      assert config.reconciliation[:interval_minutes] == 60
      assert config.reconciliation[:threshold_minutes] == 15
      assert config.reconciliation[:max_retries] == 3
    end

    test "allows overriding defaults" do
      config =
        Config.new(
          name: :test_app,
          repo: Repo,
          pubsub: PubSub,
          oban_name: Oban,
          default_queue: :custom,
          event_topic_prefix: "billing",
          handlers: [FakeHandler],
          dead_letter: FakeDeadLetter,
          reconciliation: [
            enabled: false,
            interval_minutes: 30,
            threshold_minutes: 10,
            max_retries: 5
          ]
        )

      assert config.oban_name == Oban
      assert config.default_queue == :custom
      assert config.event_topic_prefix == "billing"
      assert config.handlers == [FakeHandler]
      assert config.dead_letter == FakeDeadLetter
      assert config.reconciliation[:enabled] == false
      assert config.reconciliation[:max_retries] == 5
    end

    test "default_queue defaults to :events" do
      config = Config.new(name: :test, repo: Repo, pubsub: PubSub)
      assert config.default_queue == :events
    end

    test "default_queue can be overridden" do
      config = Config.new(name: :test, repo: Repo, pubsub: PubSub, default_queue: :custom)
      assert config.default_queue == :custom
    end

    test "raises on missing required field :name" do
      assert_raise ArgumentError, ~r/Missing required config key :name/, fn ->
        Config.new(repo: Repo, pubsub: PubSub)
      end
    end

    test "raises on missing required field :repo" do
      assert_raise ArgumentError, ~r/Missing required config key :repo/, fn ->
        Config.new(name: :test_app, pubsub: PubSub)
      end
    end

    test "raises on missing required field :pubsub" do
      assert_raise ArgumentError, ~r/Missing required config key :pubsub/, fn ->
        Config.new(name: :test_app, repo: Repo)
      end
    end
  end

  describe "store/1 and get/1" do
    test "stores and retrieves config by name" do
      config = Config.new(name: :store_test, repo: Repo, pubsub: PubSub)
      Config.store(config)

      retrieved = Config.get(:store_test)
      assert retrieved == config
    end

    test "raises when config not found" do
      assert_raise ArgumentError, ~r/Forja instance :nonexistent not found/, fn ->
        Config.get(:nonexistent)
      end
    end
  end
end
