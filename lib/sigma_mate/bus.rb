# frozen_string_literal: true

require "nats/client"

module SigmaMate
  # Слушатель очереди агента на шине NATS. Транспортная часть: подключение
  # по адресу из параметров запуска, подписка на subject = идентификатору
  # агента и журнал - каждое входящее сообщение целиком показывается в
  # выводе сервиса. Смысл сообщений и формат ответов задаёт протокол
  # (SGM-5), здесь сообщение важно не потерять и честно показать.
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
    # @param agent_id [String] идентификатор агента; он же - subject очереди
    # @param io [IO] куда писать журнал (stdout сервиса)
    def initialize(url:, agent_id:, io: $stdout)
      @url = url
      @agent_id = agent_id
      @io = io
      @mutex = Mutex.new
      @stop = false
      @client = nil
      @thread = nil
    end

    attr_reader :url, :agent_id

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
      nc.subscribe(@agent_id) { |msg| show_message(msg) }
      log_bus("подписка на очередь #{@agent_id} поднята (#{@url})")

      until @mutex.synchronize { @stop } || nc.closed?
        sleep POLL_INTERVAL
      end
    ensure
      @mutex.synchronize { @client = nil if @client.equal?(nc) }
      close_client(nc)
    end

    # Журнал: показать входящее сообщение целиком - subject очереди,
    # reply-адрес при наличии, размер и payload.
    def show_message(msg)
      data = msg.data.to_s.dup.force_encoding(Encoding::UTF_8).scrub
      reply = msg.reply ? ", reply=#{msg.reply}" : ""
      log_bus("#{@agent_id} <- входящее сообщение " \
              "(#{data.bytesize} байт#{reply}): #{data}")
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
