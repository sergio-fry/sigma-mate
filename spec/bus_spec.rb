# frozen_string_literal: true

require "spec_helper"
require "stringio"
require_relative "fake_nats"
require_relative "../lib/sigma_mate/bus"

# Unit-тесты слушателя шины BusListener против фейкового NATS-сервера
# (spec/fake_nats.rb): живая нода и сеть не нужны, протокол честный.
# Фикстуры - let-хелперы и методы группы, не константы: константы
# describe-блоков разных спек-файлов делят одну область видимости
# и перетирают друг друга при загрузке.
RSpec.describe SigmaMate::BusListener do
  let(:agent_id) { "dev-42" }
  let(:inbox_subject) { SigmaMate::Protocol.inbox_subject(agent_id) }

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

  # agent_id по умолчанию - фикстура группы (let выше); явное значение
  # - для специальных сценариев.
  def start_bus(agent_id: nil, url: nil, handler: nil)
    @bus = described_class.new(
      url: url || "nats://127.0.0.1:#{@nats.port}",
      agent_id: agent_id || self.agent_id,
      io: @log,
      handler: handler
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

  it "подписывается на inbox-тему протокола sigma.agent.<id>.inbox и показывает входящее" do
    start_bus
    expect(@nats.wait_subscribed(inbox_subject)).to be(true)
    expect(@bus.subject).to eq(inbox_subject)
    expect(wait_log("подписка на очередь #{inbox_subject} поднята")).to be(true)

    payload = "привет, агент, это шина"
    @nats.publish(inbox_subject, payload)

    expect(wait_log(payload)).to be(true)
    expect(log_text).to include(
      "#{inbox_subject} <- входящее сообщение (#{payload.bytesize} байт): #{payload}"
    )
  end

  it "показывает сообщение полностью, не только начало" do
    start_bus
    expect(@nats.wait_subscribed(inbox_subject)).to be(true)

    long = "строка-сообщения " * 100
    @nats.publish(inbox_subject, long)

    expect(wait_log(long)).to be(true)
  end

  it "отдаёт каждое входящее сообщение handler-у" do
    received = Queue.new
    start_bus(handler: ->(msg) { received << msg })

    expect(@nats.wait_subscribed(inbox_subject)).to be(true)
    @nats.publish(inbox_subject, "для обработчика")

    msg = Timeout.timeout(10) { received.pop }
    expect(msg.subject).to eq(inbox_subject)
    expect(msg.data.to_s.dup.force_encoding(Encoding::UTF_8)).to eq("для обработчика")
  end

  it "публикует сообщение текущим клиентом: подписчик его получает" do
    start_bus
    expect(@nats.wait_subscribed(inbox_subject)).to be(true)

    # Ответ агента - событие в его events-канал: слушает любой подписчик
    # (doc-3 «Отображение на NATS").
    events = SigmaMate::Protocol.events_subject("sender-1")
    receiver = @nats.client.subscribe(events)

    expect(@bus.publish(events, "ответ отправителю")).to be(true)

    msg = receiver.next_message
    expect(msg).not_to be_nil
    expect(msg.subject).to eq(events)
    expect(msg.payload).to eq("ответ отправителю")
  ensure
    receiver&.close
  end

  it "publish без соединения честно возвращает false и пишет в журнал" do
    start_bus(url: "nats://127.0.0.1:1") # ничего не слушает
    expect(wait_log("шина недоступна", timeout: 10)).to be(true)

    expect(@bus.publish(inbox_subject, "некуда")).to be(false)
    expect(log_text).to include("не удалось опубликовать")
  end

  it "переживает остановку ноды и поднимает подписку после её возврата" do
    start_bus
    expect(@nats.wait_subscribed(inbox_subject)).to be(true)
    @nats.publish(inbox_subject, "до обрыва")
    expect(wait_log("до обрыва")).to be(true)

    @nats.stop
    port = @nats.port
    expect(wait_log("соединение с шиной потеряно", timeout: 15)).to be(true)

    # Нода поднята заново на тот же порт: слушатель обязан сам
    # переподключиться и продолжить приём.
    @nats = FakeNatsServer.new(port: port).start
    expect(@nats.wait_subscribed(inbox_subject, timeout: 15)).to be(true)
    expect(wait_log("подписка на очередь #{inbox_subject} поднята", timeout: 15)).to be(true)

    @nats.publish(inbox_subject, "после восстановления")
    expect(wait_log("после восстановления")).to be(true)
  end

  it "шину на старте нет: слушатель жив и поднимает подписку, когда шина появится" do
    port = @nats.port
    @nats.stop

    start_bus(url: "nats://127.0.0.1:#{port}")
    expect(wait_log("шина недоступна", timeout: 10)).to be(true)
    expect(@bus.connected?).to be(false)

    @nats = FakeNatsServer.new(port: port).start
    expect(@nats.wait_subscribed(inbox_subject, timeout: 15)).to be(true)
    expect(wait_log("подписка на очередь #{inbox_subject} поднята", timeout: 15)).to be(true)

    @nats.publish(inbox_subject, "шина вернулась")
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
