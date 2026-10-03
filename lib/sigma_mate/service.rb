# frozen_string_literal: true

require "json"
require "webrick"
require_relative "coordinator"

module SigmaMate
  # HTTP-обвязка сервиса агента: POST /ask, тело {"prompt": "..."},
  # ответ - JSON с результатом прогона координатора. Обработка запросов
  # не параллелится на уровне агента: Coordinator держит один прогон.
  class Service
    # @param coordinator [Coordinator]
    # @param host [String] адрес, на котором слушать
    # @param port [Integer] порт; 0 - выбрать свободный (актуальный порт
    #   доступен через #port после запуска сервера)
    def initialize(coordinator:, host:, port:)
      @coordinator = coordinator
      @host = host
      @port = port
      @server = WEBrick::HTTPServer.new(
        BindAddress: host,
        Port: port,
        Logger: WEBrick::Log.new($stderr, WEBrick::Log::ERROR),
        AccessLog: []
      )
      @server.mount_proc("/") { |req, res| handle(req, res) }
    end

    # Блокирует до остановки сервера (#shutdown или сигнала).
    def start
      @server.start
    end

    # Актуальный адрес и порт (полезны при port 0).
    def host
      listener_addr(:host) || @host
    end

    def port
      listener_addr(:port) || @port
    end

    def shutdown
      @server.shutdown
    end

    private

    def listener_addr(part)
      listener = @server.listeners.first
      return nil unless listener.respond_to?(:addr)

      case part
      when :host then listener.addr[2] || listener.addr[3]
      when :port then listener.addr[1]
      end
    rescue StandardError
      nil
    end

    def handle(req, res)
      unless req.request_method == "POST" && req.path == "/ask"
        res.status = req.path == "/ask" ? 405 : 404
        respond(res, "error",
                detail: "ожидается POST /ask, получен #{req.request_method} #{req.path}")
        return
      end

      body = parse_json_body(req, res)
      return unless body

      prompt = body["prompt"]
      unless prompt.is_a?(String) && !prompt.strip.empty?
        res.status = 400
        respond(res, "error",
                detail: 'тело запроса должно содержать поле "prompt" - непустую строку')
        return
      end

      result = @coordinator.ask(prompt)
      case result.status
      when :ok
        respond(res, "ok", answer: result.answer)
      when :interrupted
        res.status = 200
        respond(res, "interrupted", detail: result.detail)
      else
        res.status = 503
        respond(res, "error", detail: result.detail)
      end
    rescue StandardError => e
      res.status = 500
      respond(res, "error", detail: "внутренняя ошибка сервиса: #{e.message}")
    end

    # Разобрать JSON-тело; при ошибке отвечает 400 и возвращает nil.
    def parse_json_body(req, res)
      JSON.parse(req.body.to_s)
    rescue JSON::ParserError
      res.status = 400
      respond(res, "error", detail: "тело запроса не является корректным JSON")
      nil
    end

    # Записать JSON-ответ: {"status": ..., "answer"?: ..., "detail"?}.
    def respond(res, status, answer: nil, detail: nil)
      payload = { "status" => status }
      # ответ только при успешном прогоне (в т.ч. null, если агент промолчал)
      payload["answer"] = answer if status == "ok" || !answer.nil?
      payload["detail"] = detail if detail
      res["Content-Type"] = "application/json; charset=utf-8"
      res.body = JSON.generate(payload)
    end
  end
end
