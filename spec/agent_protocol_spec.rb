# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "json"
require_relative "../lib/sigma_mate/coordinator"
require_relative "../lib/sigma_mate/protocol"
require_relative "../lib/sigma_mate/agent_protocol"

# Протокол на стороне агента (SGM-6): входящее сообщение -> задача в
# Coordinator -> ответ событием в канал агента sigma.agent.<id>.events
# с корреляцией (doc-3 «Корреляция»). Без шины: Coordinator - заглушка
# с запрограммированным результатом, издатель - шпион, пишущий всё
# в массив.
#
# Фикстуры - let-хелперы и методы группы, не константы: константы
# describe-блоков разных спек-файлов делят одну область видимости
# и перетирают друг друга при загрузке.
RSpec.describe SigmaMate::AgentProtocol do
  let(:agent_id) { "22222222-2222-2222-2222-222222222222" }

  # Тема events-канала агента.
  def events
    SigmaMate::Protocol.events_subject(agent_id)
  end

  # Шпион-издатель: запоминает (subject, payload).
  let(:spy_publisher_class) do
    Class.new do
      attr_reader :published

      def initialize(ok: true)
        @ok = ok
        @published = []
      end

      def publish(subject, payload)
        return false unless @ok

        @published << [subject, payload]
        true
      end
    end
  end

  # Заглушка Coordinator: ask возвращает запрограммированный RunResult.
  let(:fake_coordinator_class) do
    Class.new do
      attr_reader :prompts

      def initialize(result)
        @result = result
        @prompts = []
        @m = Mutex.new
      end

      def ask(prompt)
        @m.synchronize { @prompts << prompt }
        @result
      end
    end
  end

  def run_result(status, answer: nil, detail: nil)
    SigmaMate::RunResult.new(status: status, answer: answer, detail: detail)
  end

  def request_payload(task: "задача", id: "req-1", from: "sender-1")
    JSON.generate(
      "proto" => "sigma/1", "type" => "request", "id" => id,
      "correlation_id" => nil, "from" => from, "to" => agent_id,
      "ts" => "2026-10-03T10:00:00Z", "body" => { "task" => task }
    )
  end

  def build(result: run_result(:ok, answer: "готово"), publisher_ok: true)
    @publisher = spy_publisher_class.new(ok: publisher_ok)
    @coordinator = fake_coordinator_class.new(result)
    @log = StringIO.new(+"")
    @protocol = described_class.new(
      agent_id: agent_id, coordinator: @coordinator,
      publisher: @publisher, io: @log
    )
  end

  # Отдать сообщение протоколу и дождаться его обработки.
  def process(message)
    @protocol.call(message)
    @protocol.shutdown(timeout: 10)
  end

  def published_json
    @publisher.published.map { |_, payload| JSON.parse(payload) }
  end

  # Сообщение шины (как отдаёт nats-pure в подписку). По doc-3
  # транспортной reply-темы у запросов нет, поле есть для негативного
  # теста «reply игнорируется».
  def bus_msg(payload, reply: nil)
    Struct.new(:subject, :reply, :data, keyword_init: true).new(
      subject: SigmaMate::Protocol.inbox_subject(agent_id),
      reply: reply, data: payload
    )
  end

  it "успешный прогон: задача уходит в Coordinator, ответ - событием в events" do
    build(result: run_result(:ok, answer: "тесты зелёные"))
    process(bus_msg(request_payload(task: "прогони тесты")))

    expect(@coordinator.prompts).to eq(["прогони тесты"])
    expect(@publisher.published.size).to eq(1)
    subject, payload = @publisher.published.first
    expect(subject).to eq(events)

    json = JSON.parse(payload)
    expect(json["type"]).to eq("reply")
    expect(json["correlation_id"]).to eq("req-1")
    expect(json["from"]).to eq(agent_id)
    expect(json["to"]).to eq("sender-1")
    expect(json["body"]).to eq({ "status" => "ok", "answer" => "тесты зелёные" })
    expect(@log.string).to include("ответ опубликован в #{events}")
  end

  it "транспортная reply-тема игнорируется: ответ всё равно в events агента" do
    build(result: run_result(:ok, answer: "готово"))
    process(bus_msg(request_payload, reply: "_INBOX.abc123"))

    expect(@publisher.published.size).to eq(1)
    subject, = @publisher.published.first
    expect(subject).to eq(events)
  end

  it "прерванный прогон: отправитель получает interrupted, а не тишину" do
    build(result: run_result(:interrupted, detail: "Прогон прерван новым запросом"))
    process(bus_msg(request_payload))

    expect(published_json.dig(0, "body", "status")).to eq("interrupted")
    expect(published_json.dig(0, "body", "detail")).to include("прерван")
  end

  it "мертвая сессия: reply с ошибкой unavailable" do
    build(result: run_result(:error, detail: "pi-сессия недоступна: pi не поднялся"))
    process(bus_msg(request_payload))

    expect(published_json[0]["type"]).to eq("reply")
    expect(published_json[0]["body"]["status"]).to eq("error")
    expect(published_json[0]["body"]["code"]).to eq("unavailable")
    expect(published_json[0]["body"]["detail"]).to include("недоступна")
  end

  it "битый конверт: error bad_request, задача не начиналась" do
    build
    process(bus_msg("не json"))

    expect(@coordinator.prompts).to be_empty
    expect(published_json[0]["type"]).to eq("error")
    expect(published_json[0]["body"]["code"]).to eq("bad_request")
    expect(published_json[0]["correlation_id"]).to be_nil
  end

  it "чужой proto: bad_request с корреляцией на исходное сообщение" do
    build
    process(bus_msg(request_payload.sub("sigma/1", "sigma/9")))

    expect(published_json[0]["type"]).to eq("error")
    expect(published_json[0]["body"]["code"]).to eq("bad_request")
    expect(published_json[0]["correlation_id"]).to eq("req-1")
    expect(published_json[0]["to"]).to eq("sender-1")
  end

  it "внезапный сбой обработки: error internal, отправитель не в тишине" do
    build(result: run_result(:ok))
    def @coordinator.ask(_prompt)
      raise "всё сломалось"
    end

    process(bus_msg(request_payload))

    expect(published_json[0]["type"]).to eq("error")
    expect(published_json[0]["body"]["code"]).to eq("internal")
    expect(published_json[0]["body"]["detail"]).to include("всё сломалось")
  end

  it "шина пропала к моменту ответа: неудача публикации честно в журнале" do
    build(publisher_ok: false)
    process(bus_msg(request_payload))

    expect(@publisher.published).to be_empty
    expect(@log.string).to include("ответ НЕ опубликован")
  end

  it "#shutdown ждёт завершения обработки: после него всё опубликовано" do
    build(result: run_result(:ok, answer: "ок"))
    @protocol.call(bus_msg(request_payload))
    @protocol.shutdown(timeout: 10)

    expect(@publisher.published.size).to eq(1)
  end
end
