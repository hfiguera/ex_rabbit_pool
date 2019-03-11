defmodule ExRabbitPool.Worker.RabbitConnectionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ExRabbitPool.FakeRabbitMQ
  alias ExRabbitPool.Worker.RabbitConnection, as: ConnWorker
  alias ExRabbitPool.Worker.MonitorEts

  setup do
    rabbitmq_config = [
      channels: 5,
      port: String.to_integer(System.get_env("EX_RABBIT_POOL_PORT") || "5672"),
      queue: "test.queue",
      adapter: FakeRabbitMQ
    ]

    {:ok, config: rabbitmq_config}
  end

  test "creates a pool of channels based on config", %{config: config} do
    pid = start_supervised!({ConnWorker, config})
    %{channels: channels, connection: connection} = ConnWorker.state(pid)
    refute is_nil(connection)
    assert length(channels) == 5
  end

  test "creates a pool of channels by default", %{config: config} do
    pid = start_supervised!({ConnWorker, Keyword.delete(config, :channels)})
    %{channels: channels} = ConnWorker.state(pid)
    assert length(channels) == 10
  end

  test "return :out_of_channels when all channels are holded by clients", %{config: config} do
    new_config = Keyword.update!(config, :channels, fn _ -> 1 end)
    pid = start_supervised!({ConnWorker, new_config})
    start_supervised!({MonitorEts, []})
    assert {:ok, channel} = ConnWorker.checkout_channel(pid)
    assert {:error, :out_of_channels} = ConnWorker.checkout_channel(pid)
    %{channels: channels} = ConnWorker.state(pid)
    assert Enum.empty?(channels)
    monitors = MonitorEts.get_monitors()
    assert length(monitors) == 1
    assert :ok = ConnWorker.checkin_channel(pid, channel)
  end

  test "creates a monitor when getting a channel and deletes the monitor when putting it back", %{
    config: config
  } do
    pid = start_supervised!({ConnWorker, config})
    start_supervised!({MonitorEts, []})
    assert {:ok, channel} = ConnWorker.checkout_channel(pid)
    monitors = MonitorEts.get_monitors()
    assert length(monitors) == 1
    assert :ok = ConnWorker.checkin_channel(pid, channel)
    Process.sleep(2000)
    monitors = MonitorEts.get_monitors()
    assert Enum.empty?(monitors)
  end

  test "channel is returned to the pool when a client holding it crashes", %{config: config} do
    pid = start_supervised!({ConnWorker, config})
    start_supervised!({MonitorEts, []})

    client_pid =
      spawn(fn ->
        assert {:ok, channel} = ConnWorker.checkout_channel(pid)
      end)

    ref = Process.monitor(client_pid)
    assert_receive {:DOWN, ^ref, :process, ^client_pid, :normal}
    %{channels: channels} = ConnWorker.state(pid)
    monitors = MonitorEts.get_monitors()
    assert Enum.empty?(monitors)
    assert length(channels) == 5
  end

  test "returns error when disconnected", %{config: config} do
    new_config = Keyword.update!(config, :queue, fn _ -> "error.queue" end)

    capture_log(fn ->
      pid = start_supervised!({ConnWorker, new_config})
      assert {:error, :disconnected} = ConnWorker.get_connection(pid)
      assert {:error, :disconnected} = ConnWorker.checkout_channel(pid)
    end) =~ "[Rabbit] error reason: :invalid"
  end
end
