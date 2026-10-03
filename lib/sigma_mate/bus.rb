# frozen_string_literal: true

require "nats/client"
require_relative "protocol"

module SigmaMate
  # Слушатель очереди агента на шине NATS. Транспортная часть протокола
  # (doc-3): подключение по адресу из параметров запуска, подписка на тему
  # sigma.agent.<идентификатор>.inbox и журнал - каждое входящее сообщение
  # видно в выводе сервиса. Смысл сообщений обрабатывает handler
  # (AgentProtocol); без него слушатель только показывает сообщение
  # (транспорт без протокола). Handler вызывается в потоке читателя шины и
  # потому обязан не блокировать: обработка задачи уходит в собственный
  # поток на стороне handler-а.
  #
  # Обрыв связи с шиной не роняет слушатель и не мешает HTTP-API: слушатель
  # живёт в собственном потоке, а вся политика переподключения - в его
  # цикле. Клиент подключается без внутреннего авто-reconnect (reconnect:
  # false): неудачная попытка сразу становится видна в журнале, обрыв
  # закрывает клиент, и цикл поднимает подписку заново с паузой. Такой
  # слушатель останавливается чисто даже когда шина недоступна. Адрес шины
  # передаётся снаружи - из параметров запуска или конфигурации, в коде он
  # не зашит.
  class BusListener
    CONNECT_TIMEOUT = 2
    RETRY_DELAY = 2.0
    POLL_INTERVAL = 0.2

    # @param url [String] адрес шины, например "nats://127.0.0.1:4222"
    # @param agent_id [String] идентификатор агента; тема его очереди -
    #   sigma.agent.<идентификатор>.inbox (doc-3)
    # @param io [IO] куда писать журнал (stdout сервиса)
    # @param handler [#call, nil] вызывается для каждого входящего сообщения
    #   (объект NATS-клиента с subject, reply, data); nil - только журнал
    def initialize(url:, agent_id:, io: $stdout, handler: nil)
      @url = url
      @agent_id = agent_id
      @subject = Protocol.inbox_subject(agent_id)
      @handler = handler
      @io = io
      @mutex = Mutex.new
      @stop = false
      @client = nil
      @thread = nil
    end

    attr_reader :url, :agent_id, :subject

    # Обработчик протокола (AgentProtocol); выставляется после создания
    # слушателя, потому что обработчику сам слушатель нужен как издатель.
    attr_accessor :handler

    # Поднимает поток слушателя и возвращается сразу (не блокируется).
    def start
      @mutex.synchronize do
        return self if @thread

        @stop = false
        @thread = Thread.new { run_loop }
      end
      self
    end

    # Останавливает слушателя: закрывает клиент шины и ждёт поток.
    # Идемпотентен, безопасен до #start.
    def stop
      thread, client = @mutex.synchronize do
        @stop = true
        swap_t = @thread
        @thread = nil
        [swap_t, @client]
      end
      close_client(client)
      thread&.join(5)
      nil
    end

    # Подключён ли слушатель к шине прямо сейчас.
    def connected?
      client = @mutex.synchronize { @client }
      !client.nil? && client.connected?
    end

    # Опубликовать сообщение в шину текущим клиентом. Используется для
    # ответов протокола: reply публикуется событием в канал
    # sigma.agent.<идентификатор>.events. Возвращает true при успехе; false,
    # если шины сейчас нет (соединение потеряно и ещё не поднято) - в этом
    # случае сообщение теряется (core NATS - at-most-once, doc-3) и это
    # честно отмечается в журнале.
    def publish(subject, payload)
      client = @mutex.synchronize { @client }
      if client.nil? || client.closed?
        log_bus("не удалось опубликовать в #{subject}: нет соединения с шиной")
        return false
      end

      client.publish(subject, payload)
      client.flush(2) # убедиться, что ответ ушёл в шину, а не остался в очереди
      true
    rescue StandardError => e
      log_bus("не удалось опубликовать в #{subject} " \
              "(#{e.class}: #{e.message})")
      false
    end

    private

    # Цикл жизни слушателя: поднимать подписку, пока не остановлен.
    # Ошибка подключения или закрытое соединение не вылетают наружу -
    # пауза и новая попытка.
    def run_loop
      until @mutex.synchronize { @stop }
        begin
          listen_until_closed
        rescue StandardError => e
          log_bus("шина недоступна (#{e.class}: #{e.message}); " \
                   "повторная попытка через #{RETRY_DELAY} с")
          sleep_retry_delay
        end
      end
    rescue StandardError => e
      log_bus("слушатель шины остановился по ошибке: #{e.class}: #{e.message}")
    end

    # Одно соединение с шиной: подключение, подписка и ожидание, пока
    # соединение живо. Возврат - соединение закрылось или слушатель
    # остановлен (в цикле наверху подписка поднимется снова). Подключение
    # без внутреннего авто-reconnect: недоступность шины сразу даёт
    # ошибку, и её видно в журнале, а клиент всегда можно закрыть.
    def listen_until_closed
      nc = NATS::Client.new
      nc.connect(@url, reconnect: false, connect_timeout: CONNECT_TIMEOUT)
      @mutex.synchronize { @client = nc }

      nc.on_disconnect do |error|
        log_bus("соединение с шиной потеряно" \
                 "#{" (#{error.class}: #{error.message})" if error && error.message}")
      end
      nc.subscribe(@subject) { |msg| dispatch(msg) }
      log_bus("подписка на очередь #{@subject} поднята (#{@url})")

      until @mutex.synchronize { @stop } || nc.closed?
        sleep POLL_INTERVAL
      end
    ensure
      @mutex.synchronize { @client = nil if @client.equal?(nc) }
      close_client(nc)
    end

    # Входящее сообщение: честно показать его в журнале (subject, размер,
    # payload) и отдать handler-у. Handler работает в потоке читателя
    # шины и должен возвращаться быстро: пока он занят, новые сообщения
    # не принимаются.
    def dispatch(msg)
      show_message(msg)
      @handler&.call(msg)
    end

    # Журнал: показать входящее сообщение целиком - subject очереди,
    # размер и payload.
    def show_message(msg)
      data = msg.data.to_s.dup.force_encoding(Encoding::UTF_8).scrub
      log_bus("#{@subject} <- входящее сообщение " \
              "(#{data.bytesize} байт): #{data}")
    end

    # Пауза между попытками подключения, прерываемая остановкой.
    def sleep_retry_delay
      deadline = Time.now + RETRY_DELAY
      until @mutex.synchronize { @stop } || Time.now >= deadline
        sleep POLL_INTERVAL
      end
    end

    def close_client(client)
      client&.close
    rescue StandardError
      # Соединения могло уже не быть - закрываем молча.
    end

    # Все события шины одинаково важны журналу; в выводе сервиса
    # они не отличаются по важности, поэтому один метод.
    def log_bus(text)
      @io.puts "[шина] #{text}"
      @io.flush if @io.respond_to?(:flush)
    rescue StandardError
      # Журнал не должен ронять слушатель.
    end
  end
end
