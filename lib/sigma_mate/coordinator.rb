# frozen_string_literal: true

require_relative "../sigma_mate"

module SigmaMate
  # Результат прогона агента над промптом.
  # status:
  #   :ok          - ответ получен, answer несёт текст
  #   :interrupted - прогон прерван новым запросом, answer nil
  #   :error       - pi-сессия недоступна или упала, detail описывает причину
  RunResult = Struct.new(:status, :answer, :detail, keyword_init: true) do
    def ok?          = status == :ok
    def interrupted? = status == :interrupted
    def error?       = status == :error
  end

  # Оркестратор одной pi-сессии: запросы обрабатываются строго по одному.
  # Новый запрос во время активного прогона прерывает его (session.abort):
  # прерванный клиент сразу получает RunResult :interrupted, после чего
  # выполняется новый промпт.
  class Coordinator
    # Один прогон агента над промптом. Доступен из нескольких потоков
    # (поток-исполнитель и поток-прерыватель), состояние под собственным
    # мьютексом.
    class Run
      def initialize(prompt)
        @prompt = prompt
        @result = nil
        @interrupted = false
        @abort_sent = false
        @m = Mutex.new
      end

      attr_reader :prompt

      # Пометить прогон прерванным (вызывается потоком нового запроса).
      def mark_interrupted
        @m.synchronize { @interrupted = true }
      end

      def interrupted?
        @m.synchronize { @interrupted }
      end

      # Отправить abort в pi-сессию (не более одного раза).
      # Вызывается вне мьютекса Coordinator, чтобы запись в транспорт
      # не блокировала остальные запросы.
      def abort_via(session)
        send_now = @m.synchronize do
          next false if @abort_sent

          @abort_sent = true
        end
        session&.abort if send_now
      rescue StandardError
        # Не удалось прервать - прогон завершится сам по своему сценарию.
      end

      def finish(result)
        @m.synchronize { @result = result }
      end

      def result
        @m.synchronize { @result }
      end
    end

    # @param session_factory [#call] вызывается один раз при #start;
    #   должна вернуть pi-сессию (PiAgent::Session или совместимый объект).
    def initialize(session_factory:)
      @session_factory = session_factory
      @mutex = Mutex.new
      @cond = ConditionVariable.new
      @active_run = nil
      @session = nil
      @session_error = nil
      @closed = false
    end

    # Поднимает pi-сессию. Если pi не запустился, ошибка запоминается и
    # сервис продолжает жить: #ask возвращает :error на каждый запрос.
    def start
      @mutex.synchronize do
        return self if @closed || @session

        begin
          @session = @session_factory.call
        rescue StandardError => e
          @session_error = e.message
        end
      end
      self
    end

    # Выполнить промпт. Блокирует поток до завершения прогона (или его
    # прерывания новым запросом). Всегда возвращает RunResult, исключения
    # наружу не выходят.
    def ask(prompt)
      run = acquire_run(prompt)
      return run if run.is_a?(RunResult) # сессии нет - сразу ошибка

      execute_run(run)
      run.result
    end

    # Идёт ли сейчас прогон.
    def busy?
      @mutex.synchronize { !@active_run.nil? }
    end

    # Жива ли pi-сессия.
    def alive?
      @mutex.synchronize { !@session.nil? }
    end

    # Причина, по которой сессия недоступна (nil, если сессия жива).
    def session_error
      @mutex.synchronize { @session_error }
    end

    # Остановить оркестратор и закрыть сессию. Идемпотентен.
    def close
      session = @mutex.synchronize do
        @closed = true
        @active_run&.mark_interrupted
        @cond.broadcast
        swap = @session
        @session = nil
        swap
      end
      begin
        session&.abort
        session&.close
      rescue StandardError
        # Сессия могла уже умереть - не важно, закрываем молча.
      end
      nil
    end

    private

    # Занять слот единственного прогона. Если активный прогон есть -
    # пометить его прерванным, отправить abort вне мьютекса и дождаться
    # его завершения. Возвращает Run (слот занят) или RunResult (:error,
    # если сессии нет или оркестратор закрыт).
    def acquire_run(prompt)
      loop do
        target = @mutex.synchronize do
          if @closed || @session.nil?
            next RunResult.new(status: :error, detail: unavailable_detail)
          end
          next @active_run if @active_run

          run = Run.new(prompt)
          @active_run = run
          return run
        end

        return target if target.is_a?(RunResult)

        target.mark_interrupted
        target.abort_via(current_session_for_abort)
        @mutex.synchronize do
          @cond.wait(@mutex) while @active_run.equal?(target)
        end
      end
    end

    # Выполнить прогон: слить поток событий сессии до agent_settled,
    # собрать ответ и зафиксировать результат. Выполняется в потоке
    # запроса (вне мьютекса Coordinator).
    def execute_run(run)
      session = @mutex.synchronize { @session }
      answer = +""
      aborted = false
      begin
        session.prompt(run.prompt) do |event|
          answer << event.delta if event.type == :message_update && event.delta
          aborted = true if event.error? && event.error_reason == "aborted"
        end

        if run.interrupted? || aborted
          run.finish(RunResult.new(status: :interrupted,
                                   detail: "Прогон прерван новым запросом"))
        else
          run.finish(RunResult.new(status: :ok,
                                   answer: final_answer(session, answer)))
        end
      rescue PiAgent::Error => e
        mark_session_dead("сессия pi-агента прервалась: #{e.message}")
        run.finish(RunResult.new(status: :error, detail: e.message))
      ensure
        release_run(run)
      end
    end

    # Ответ агента: текст последнего сообщения ассистента, а при недоступности
    # - накопленные текстовые дельты.
    def final_answer(session, collected)
      session.last_assistant_text || (collected.strip.empty? ? nil : collected)
    rescue PiAgent::Error
      collected.strip.empty? ? nil : collected
    end

    def release_run(run)
      @mutex.synchronize do
        @active_run = nil if @active_run.equal?(run)
      end
      @cond.broadcast
    end

    def mark_session_dead(detail)
      @mutex.synchronize do
        @session = nil
        @session_error = detail
      end
    end

    def current_session_for_abort
      @mutex.synchronize { @session }
    end

    def unavailable_detail
      return "Сервис остановлен" if @closed

      "pi-сессия недоступна: #{@session_error || 'сессия не поднята'}"
    end
  end
end
