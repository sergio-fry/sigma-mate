# frozen_string_literal: true

require "spec_helper"
require "json"
require_relative "../lib/sigma_mate/protocol"

# Конверт sigma/1 (doc-3): разбор request и сборка reply/error.
RSpec.describe SigmaMate::Protocol do
  def request_json(**overrides)
    {
      "proto" => "sigma/1", "type" => "request",
      "id" => "req-1", "correlation_id" => nil,
      "from" => "11111111-1111-1111-1111-111111111111",
      "to" => "22222222-2222-2222-2222-222222222222",
      "ts" => "2026-10-03T10:00:00Z",
      "body" => { "task" => "прогони тесты" }
    }.merge(overrides)
  end

  describe ".parse_request" do
    it "разбирает корректный конверт и достаёт задачу" do
      env = described_class.parse_request(JSON.generate(request_json))

      expect(env).to be_a(SigmaMate::Protocol::Envelope)
      expect(env.id).to eq("req-1")
      expect(env.from).to eq("11111111-1111-1111-1111-111111111111")
      expect(env.to).to eq("22222222-2222-2222-2222-222222222222")
      expect(env.task).to eq("прогони тесты")
    end

    it "игнорирует неизвестные поля" do
      json = JSON.generate(request_json.merge("extra" => {"x" => 1}))
      expect { described_class.parse_request(json) }.not_to raise_error
    end

    it "отвергает битый JSON как bad_request" do
      expect { described_class.parse_request("не json") }
        .to raise_error(SigmaMate::Protocol::Rejected) do |e|
          expect(e.code).to eq("bad_request")
          expect(e.id).to be_nil
          expect(e.detail).to include("JSON")
        end
    end

    it "отвергает чужую версию proto с корреляцией, если id/from понятны" do
      json = JSON.generate(request_json("proto" => "sigma/9"))
      expect { described_class.parse_request(json) }
        .to raise_error(SigmaMate::Protocol::Rejected) do |e|
          expect(e.code).to eq("bad_request")
          expect(e.id).to eq("req-1")
          expect(e.from).to eq("11111111-1111-1111-1111-111111111111")
        end
    end

    it "отвергает не-request тип: в очередь агента нельзя слать reply" do
      json = JSON.generate(request_json("type" => "reply"))
      expect { described_class.parse_request(json) }
        .to raise_error(SigmaMate::Protocol::Rejected) do |e|
          expect(e.code).to eq("bad_request")
          expect(e.detail).to include("request")
        end
    end

    it "отвергает конверт без обязательных полей" do
      [%w[id from to], %w[from], %w[to]].each do |remove|
        fields = request_json
        remove.each { |f| fields.delete(f) }
        expect { described_class.parse_request(JSON.generate(fields)) }
          .to raise_error(SigmaMate::Protocol::Rejected) do |e|
            expect(e.code).to eq("bad_request")
            expect(e.detail).to include(remove.first)
          end
      end
    end

    it "отвергает тело без непустой task" do
      [{ "task" => "" }, { "task" => "   " }, { "другое" => 1 }, "не хэш"]
        .each do |body|
          expect { described_class.parse_request(JSON.generate(request_json("body" => body))) }
            .to raise_error(SigmaMate::Protocol::Rejected) do |e|
              expect(e.code).to eq("bad_request")
              expect(e.detail).to include("task")
            end
        end
    end
  end

  describe ".reply" do
    let(:request) { described_class.parse_request(JSON.generate(request_json)) }

    it "ok: статус, ответ и корреляция с исходным сообщением" do
      json = JSON.parse(described_class.reply(
                          request, agent_id: "agent-9", status: :ok, answer: "готово"
                        ))

      expect(json["proto"]).to eq("sigma/1")
      expect(json["type"]).to eq("reply")
      expect(json["id"]).to be_a(String)
      expect(json["id"]).not_to be_empty
      expect(json["correlation_id"]).to eq("req-1")
      expect(json["from"]).to eq("agent-9")
      expect(json["to"]).to eq("11111111-1111-1111-1111-111111111111")
      expect(json["ts"]).to match(/\A\d{4}-\d{2}-\d{2}T/)
      expect(json["body"]).to eq({ "status" => "ok", "answer" => "готово" })
    end

    it "interrupted: причина вытеснения" do
      json = JSON.parse(described_class.reply(
                          request, agent_id: "agent-9", status: :interrupted,
                                  detail: "вытеснен новым сообщением"
                        ))
      expect(json["body"]).to eq(
        "status" => "interrupted", "detail" => "вытеснен новым сообщением"
      )
    end

    it "error: код и описание" do
      json = JSON.parse(described_class.reply(
                          request, agent_id: "agent-9", status: :error,
                                  code: "unavailable", detail: "сессия недоступна"
                        ))
      expect(json["body"]).to eq(
        "status" => "error", "code" => "unavailable", "detail" => "сессия недоступна"
      )
    end

    it "каждому ответу - свежий id" do
      first = JSON.parse(described_class.reply(request, agent_id: "a", status: :ok, answer: "1"))
      second = JSON.parse(described_class.reply(request, agent_id: "a", status: :ok, answer: "2"))
      expect(first["id"]).not_to eq(second["id"])
    end
  end

  describe ".error" do
    it "собирает error-конверт с корреляцией, когда отправитель известен" do
      json = JSON.parse(described_class.error(
                          agent_id: "agent-9", code: "bad_request", detail: "битый JSON",
                          id: "req-7", from: "sender-7"
                        ))

      expect(json["type"]).to eq("error")
      expect(json["correlation_id"]).to eq("req-7")
      expect(json["from"]).to eq("agent-9")
      expect(json["to"]).to eq("sender-7")
      expect(json["body"]).to eq("code" => "bad_request", "detail" => "битый JSON")
    end

    it "без корреляции, когда конверт не разобран даже частично" do
      json = JSON.parse(described_class.error(
                          agent_id: "agent-9", code: "internal", detail: "сбой"
                        ))
      expect(json["correlation_id"]).to be_nil
      expect(json["to"]).to be_nil
    end
  end

  describe "темы и идентификаторы" do
    it "темы собираются в неймспейсе sigma из идентификатора дословно" do
      expect(described_class.inbox_subject("abc"))
        .to eq("sigma.agent.abc.inbox")
      expect(described_class.events_subject("abc"))
        .to eq("sigma.agent.abc.events")
    end

    it "идентификатор не может содержать точки, пробелы и * и >" do
      valid = ["developer", "11111111-1111-1111-1111-111111111111"]
      valid.each { |id| expect(described_class.valid_agent_id?(id)).to be(true) }

      invalid = ["a.b", "a b", "a\tb", "a*b", "a>b", "", "   ", nil, 42]
      invalid.each { |id| expect(described_class.valid_agent_id?(id)).to be(false) }
    end
  end
end
