# frozen_string_literal: true

require_relative "protocol"

module SigmaMate
  # Протокол на стороне агента (doc-3, реализация SGM-6): входящее
  # сообщение из inbox-очереди агента разбирается как request-конверт
  # sigma/1, задача выполняется в pi-сессии агента - через тот же
  # Coordinator, что и HTTP /ask, - и ответ публикуется событием в канал
  # агента sigma.agent.<идентификатор>.events с correlation_id исходного
  # запроса: отправитель подписан на этот канал и узнаёт свой ответ по
  # корреляции. Транспортный reply NATS протоколом не используется и
  # игнорируется. Один вход с HTTP: одна сессия и одно правило вытеснения
  # (новая задача прерывает текущую, прерванный отправитель получает
  # interrupted).
  #
  # Каждое сообщение обрабатывается в собственном потоке: поток читателя
  # шины не блокируется (иначе во время долгой задачи агент не принял бы
  # вытесняющее сообщение), а Coordinator сам следит за единственным
  # активным прогоном. Отправитель никогда не остаётся с тишиной: на любое
  # принятое сообщение в events уходит либо reply, либо error-конверт.
  class AgentProtocol
    # @param agent_id [String] идентификатор агента; он же - поле from
    #   в ответах и токен темы очереди
    # @param coordinator [Coordinator] общий с HTTP вход в сессию
    # @param publisher [#publish(subject, payload)] шина для публикации
    #   ответов (BusListener)
    # @param io [IO] журнал (stdout сервиса)
    def initialize(agent_id:, coordinator:, publisher:, io: $stdout)
      @agent_id = agent_id
      @coordinator = coordinator
      @publisher = publisher
      @io = io
      @mutex = Mutex.new
      @workers = []
    end

    attr_reader :agent_id

    # Точка входа слушателя шины (вызывается в потоке читателя):
    # сразу отдать сообщение в собственный поток и вернуться. Завершившиеся
    # потоки не копятся: при каждом новом сообщении список чистится.
    def call(msg)
      thread = Thread.new(msg) { |m| process(m) }
      thread.report_on_exception = false
      @mutex.synchronize do
        @workers.delete_if { |t| !t.alive? } # чистим завершившиеся
        @workers << thread
      end
      nil
    end

    # Дождаться рабочих потоков (остановка сервиса). Потоки в
    # coordinator.ask получают interrupted от Coordinator#close и
    # пытаются опубликовать ответ; если шина уже остановлена, публикация
    # честно пишется в журнал как несостоявшаяся.
    def shutdown(timeout: 5)
      deadline = Time.now + timeout
      loop do
        threads = @mutex.synchronize do
          @workers.delete_if { |t| !t.alive? } # чистим завершившиеся
          @workers.dup
        end
        return if threads.empty?
        return if Time.now >= deadline

        threads.each { |t| t.join([deadline - Time.now, 0.05].max) }
      end
      nil
    end

    private

    # Полный цикл одного сообщения: разбор, обработка, ответ.
    # Любая ошибка превращается в ответ отправителю, а не в тишину.
    def process(msg)
      data = msg.data.to_s.dup.force_encoding(Encoding::UTF_8).scrub

      begin
        request = Protocol.parse_request(data)
      rescue Protocol::Rejected => e
        answer_with(Protocol.error(agent_id: @agent_id, code: e.code,
                                   detail: e.detail, id: e.id, from: e.from))
        return
      end

      log_protocol("задача принята (id=#{request.id}, from=#{request.from})")
      result = @coordinator.ask(request.task)
      reply = Protocol.reply(request, agent_id: @agent_id, status: result.status,
                                           answer: result.answer, detail: result.detail,
                                           code: result.error? ? "unavailable" : nil)
      answer_with(reply)
    rescue StandardError => e
      # Не должно случаться, но тишина хуже ошибки: отправителю - internal.
      answer_with(Protocol.error(agent_id: @agent_id, code: "internal",
                                 detail: "внутренняя ошибка обработки: #{e.message}"))
    end

    # Опубликовать ответ событием в канал агента и показать результат
    # в журнале. Ответ слышат все подписчики sigma.agent.<id>.events;
    # адресат узнаёт свой по correlation_id (doc-3 «Корреляция»).
    def answer_with(payload)
      subject = Protocol.events_subject(@agent_id)
      if @publisher.publish(subject, payload)
        log_protocol("ответ опубликован в #{subject}: #{payload}")
      else
        log_protocol("ответ НЕ опубликован в #{subject} " \
                     "(шина недоступна): #{payload}")
      end
      nil
    end

    def log_protocol(text)
      @io.puts "[протокол] #{text}"
      @io.flush if @io.respond_to?(:flush)
    rescue StandardError
      # Журнал не должен ронять обработку.
    end
  end
end
