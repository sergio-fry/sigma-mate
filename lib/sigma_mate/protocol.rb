# frozen_string_literal: true

require "json"
require "securerandom"
require "time"

module SigmaMate
  # Конверт протокола sigma/1 (doc-3 «Протокол общения агентов по шине»).
  # Здесь живут форматы сообщений и только они: разбор входящего request,
  # сборка reply и error. Транспорт (подключение к шине, темы) и обработка
  # задачи (Coordinator) - вне этого модуля.
  #
  # Темы протокола - в неймспейсе sigma.: у агента два канала - входящие
  # sigma.agent.<идентификатор>.inbox и события наружу (ответы, телеметрия)
  # sigma.agent.<идентификатор>.events. Тема собирается из идентификатора
  # дословно, поэтому в идентификаторе запрещены точки, пробелы и
  # NATS-подстановочные символы (* и >).
  module Protocol
    PROTO = "sigma/1"
    NAMESPACE = "sigma"
    AGENT_PREFIX = "#{NAMESPACE}.agent."
    INBOX_SUFFIX = ".inbox"
    EVENTS_SUFFIX = ".events"

    # Разобранный конверт request. body - Hash с ключом "task".
    Envelope = Struct.new(:id, :from, :to, :body, keyword_init: true) do
      def task
        body["task"]
      end
    end

    # Конверт не принят к обработке (задача не начиналась): код ошибки
    # из закрытого списка (bad_request / unavailable / internal), detail -
    # человекочитаемое описание. id и from - что удалось достать из
    # входящего сообщения, чтобы ответить с корреляцией, если она есть.
    Rejected = Class.new(StandardError) do
      attr_reader :code, :detail, :id, :from

      def initialize(code:, detail:, id: nil, from: nil)
        super("#{code}: #{detail}")
        @code = code
        @detail = detail
        @id = id
        @from = from
      end
    end

    module_function

    # Тема входящих агенту: задачи и запросы. Отправитель публикует
    # сюда конверт request; агент подписан постоянно.
    def inbox_subject(agent_id)
      "#{AGENT_PREFIX}#{agent_id}#{INBOX_SUFFIX}"
    end

    # Тема событий агента: всё, что агент транслирует наружу, - ответы
    # на запросы (reply/error с correlation_id) и события телеметрии
    # (SGM-8). Публикует агент, слушает любой.
    def events_subject(agent_id)
      "#{AGENT_PREFIX}#{agent_id}#{EVENTS_SUFFIX}"
    end

    # Допустим ли идентификатор как токен темы: непустая строка без
    # точек, пробелов и подстановочных символов NATS (* и >).
    def valid_agent_id?(agent_id)
      agent_id.is_a?(String) && !agent_id.strip.empty? &&
        !agent_id.match?(/[\s.*>]/)
    end

    # Разобрать payload входящего сообщения как request-конверт sigma/1.
    # Успех - Envelope; неудача - Rejected bad_request (битый JSON, чужой
    # proto, не тот тип, нет обязательных полей). Неизвестные поля
    # игнорируются.
    def parse_request(payload)
      data = JSON.parse(payload.to_s)
      unless data.is_a?(Hash)
        raise Rejected.new(code: "bad_request",
                           detail: "конверт должен быть JSON-объектом")
      end

      # Что удалось достать из конверта для корреляции ответа: id и from,
      # если они присутствуют и осмысленны (иначе поле не попадает в ответ).
      known = %w[id from]
                .select { |f| data[f].is_a?(String) && !data[f].strip.empty? }
                .to_h { |f| [f.to_sym, data[f]] }

      if data["proto"] != PROTO
        raise Rejected.new(code: "bad_request",
                           detail: "неизвестная версия протокола " \
                                   "(proto=#{data['proto'].inspect}, ожидается #{PROTO})",
                           **known)
      end
      if data["type"] != "request"
        raise Rejected.new(code: "bad_request",
                           detail: "в очередь агента ожидается type=request, " \
                                   "получен #{data['type'].inspect}",
                           **known)
      end
      %w[id from to].each do |field|
        next if data[field].is_a?(String) && !data[field].strip.empty?

        raise Rejected.new(code: "bad_request",
                           detail: "конверт без обязательного поля " \
                                   "\"#{field}\" (непустая строка)",
                           **known)
      end
      body = data["body"]
      unless body.is_a?(Hash) &&
             body["task"].is_a?(String) && !body["task"].strip.empty?
        raise Rejected.new(code: "bad_request",
                           detail: 'тело запроса должно содержать поле "task" - ' \
                                   "непустую строку",
                           **known)
      end

      Envelope.new(id: data["id"], from: data["from"], to: data["to"], body: body)
    rescue JSON::ParserError
      raise Rejected.new(code: "bad_request",
                         detail: "payload не является корректным JSON")
    end

    # Собрать reply-конверт: работа по исходному сообщению завершена.
    # status: :ok (answer), :interrupted (detail), :error (code, detail).
    # correlation_id = id исходного request; конверт публикуется событием
    # в sigma.agent.<идентификатор>.events - тему своего канала событий,
    # не тему отправителя (doc-3 «Корреляция»).
    def reply(request, agent_id:, status:, answer: nil, detail: nil, code: nil)
      body = case status
             when :ok
               { "status" => "ok", "answer" => answer }
             when :interrupted
               { "status" => "interrupted", "detail" => detail }
             else
               { "status" => "error", "code" => code, "detail" => detail }
             end
      envelope(
        type: "reply",
        correlation_id: request.id,
        from: agent_id,
        to: request.from,
        body: body
      )
    end

    # Собрать error-конверт: сообщение не принято к обработке, задача
    # не начиналась. correlation_id/to - что известно об отправителе
    # (nil, если конверт не разобран даже частично).
    def error(agent_id:, code:, detail:, id: nil, from: nil)
      envelope(
        type: "error",
        correlation_id: id,
        from: agent_id,
        to: from,
        body: { "code" => code, "detail" => detail }
      )
    end

    private

    # Общий каркас конверта; id и ts свежие на каждый ответ.
    # (module_function не распространяется на приватные методы ниже
    # private, поэтому явный def self.)
    def self.envelope(type:, correlation_id:, from:, to:, body:)
      JSON.generate(
        "proto" => PROTO,
        "type" => type,
        "id" => SecureRandom.uuid,
        "correlation_id" => correlation_id,
        "from" => from,
        "to" => to,
        "ts" => Time.now.utc.iso8601,
        "body" => body
      )
    end
    private_class_method :envelope
  end
end
