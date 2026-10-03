# frozen_string_literal: true

require "spec_helper"
require "stringio"
require_relative "fake_nats"
require_relative "../lib/sigma_mate/bus"

# Unit-тесты слушателя шины BusListener против фейкового NATS-сервера
# (spec/fake_nats.rb): живая нода и сеть не нужны, протокол честный.
RSpec.describe SigmaMate::BusListener do
  AGENT_ID = "dev-42"

  around do |example|
    @nats = FakeNatsServer.new.start
    @log = StringIO.new(+"")
    begin
      example.run
    ensure
      @bus&.stop
      @nats&.stop
    end
  end

  def start_bus(agent_id: AGENT_ID, url: nil)
    @bus = described_class.new(
      url: url || "nats://127.0.0.1:#{@nats.port}",
      agent_id: agent_id,
      io: @log
    ).start
  end

  def log_text
    @log.string
  end

  # Ждать появления текста в журнале слушателя.
  def wait_log(fragment, timeout: 10)
    deadline = Time.now + timeout
    until log_text.include?(fragment)
      return false if Time.now >= deadline

      sleep 0.05
    end
    true
  end

  it "подключается и показывает входящее сообщение в журнале" do
    start_bus
    expect(@nats.wait_subscribed(AGENT_ID)).to be(true)
    expect(wait_log("подписка на очередь #{AGENT_ID} поднята")).to be(true)

    payload = "привет, агент, это шина"
    @nats.publish(AGENT_ID, payload)

    expect(wait_log(payload)).to be(true)
    expect(log_text).to include(
      "#{AGENT_ID} <- входящее сообщение (#{payload.bytesize} байт): #{payload}"
    )
  end

  it "показывает reply-адрес сообщения, когда он есть" do
    start_bus
    expect(@nats.wait_subscribed(AGENT_ID)).to be(true)

    @nats.publish(AGENT_ID, "вопрос", reply: "_INBOX.abc123")

    expect(wait_log("вопрос")).to be(true)
    expect(log_text).to include("reply=_INBOX.abc123")
  end

  it "показывает сообщение полностью, не только начало" do
    start_bus
    expect(@nats.wait_subscribed(AGENT_ID)).to be(true)

    long = "строка-сообщения " * 100
    @nats.publish(AGENT_ID, long)

    expect(wait_log(long)).to be(true)
  end

  it "переживает остановку ноды и поднимает подписку после её возврата" do
    start_bus
    expect(@nats.wait_subscribed(AGENT_ID)).to be(true)
    @nats.publish(AGENT_ID, "до обрыва")
    expect(wait_log("до обрыва")).to be(true)

    @nats.stop
    port = @nats.port
    expect(wait_log("соединение с шиной потеряно", timeout: 15)).to be(true)

    # Нода поднята заново на тот же порт: слушатель обязан сам
    # переподключиться и продолжить приём.
    @nats = FakeNatsServer.new(port: port).start
    expect(@nats.wait_subscribed(AGENT_ID, timeout: 15)).to be(true)
    expect(wait_log("подписка на очередь #{AGENT_ID} поднята", timeout: 15)).to be(true)

    @nats.publish(AGENT_ID, "после восстановления")
    expect(wait_log("после восстановления")).to be(true)
  end

  it "шину на старте нет: слушатель жив и поднимает подписку, когда шина появится" do
    port = @nats.port
    @nats.stop

    start_bus(url: "nats://127.0.0.1:#{port}")
    expect(wait_log("шина недоступна", timeout: 10)).to be(true)
    expect(@bus.connected?).to be(false)

    @nats = FakeNatsServer.new(port: port).start
    expect(@nats.wait_subscribed(AGENT_ID, timeout: 15)).to be(true)
    expect(wait_log("подписка на очередь #{AGENT_ID} поднята", timeout: 15)).to be(true)

    @nats.publish(AGENT_ID, "шина вернулась")
    expect(wait_log("шина вернулась")).to be(true)
  end

  it "поднимается, даже когда шина недоступна: #connected? остаётся честным" do
    start_bus(url: "nats://127.0.0.1:1") # ничего не слушает
    expect(wait_log("шина недоступна", timeout: 10)).to be(true)
    expect(@bus.connected?).to be(false)
    # Слушатель жив и продолжает попытки - его поток на месте.
    expect(@bus.instance_variable_get(:@thread)).to be_alive
  end
end
