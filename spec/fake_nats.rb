# frozen_string_literal: true

require "socket"

# Минимальный TCP-сервер, говорящий на текстовом NATS-протоколе -
# ровно столько, сколько нужно клиенту nats-pure для подключения,
# подписки и приёма сообщений: INFO при подключении, PONG на PING,
# разбор CONNECT/SUB/PUB, доставка MSG подписчикам. Позволяет
# тестировать слушателя шины и bin/serve без живой ноды NATS.
#
# Опубликовать сообщение можно методом #publish: он подключается
# сторонним клиентом и говорит PUB, как это делает nats CLI.
# Для приёма сообщений агента (ответы в его events-канал, doc-3) есть
# вложенный класс Client: подписка на тему и чтение MSG тем же
# текстовым протоколом.
class FakeNatsServer
  INFO = 'INFO {"server_id":"FAKE","server_name":"fake","version":"2.10.0",' \
         '"proto":1,"go":"fake","host":"127.0.0.1","max_payload":1048576}'

  # Простой клиент текстового NATS-протокола для тестов: подписка на тему
  # и чтение доставленных сообщений. Так тест играет роль отправителя
  # (SGM-7), который ждёт ответ в свой inbox.
  class Client
    Message = Struct.new(:subject, :reply, :payload, keyword_init: true)

    def initialize(host:, port:)
      @sock = TCPSocket.new(host, port)
      @sock.gets("\r\n") # INFO от сервера
      @sid = 0
      send_line('CONNECT {"verbose":false,"pedantic":false}')
      ping
    end

    def subscribe(subject)
      @sid += 1
      send_line("SUB #{subject} #{@sid}")
      ping
      self
    end

    # Опубликовать сообщение с reply-темой (как отправитель запроса).
    def publish(subject, payload, reply: nil)
      head = reply ? "PUB #{subject} #{reply} #{payload.bytesize}" \
                   : "PUB #{subject} #{payload.bytesize}"
      @sock.write("#{head}\r\n#{payload}\r\n")
      nil
    end

    # Дождаться следующего сообщения (по любой из подписок) или вернуть
    # nil по таймауту.
    def next_message(timeout: 10)
      return nil unless IO.select([@sock], nil, nil, timeout)

      line = @sock.gets("\r\n")
      return nil if line.nil?

      parts = line.strip.split(" ")
      # MSG <subject> <sid> [reply] <size>
      unless parts[0] == "MSG" && parts.size >= 4
        return parts[0] == "PING" ? next_message(timeout: timeout) : nil
      end

      reply = parts.size == 5 ? parts[3] : nil
      size = parts[-1].to_i
      payload = @sock.read(size + 2).to_s.byteslice(0, size)
               .dup.force_encoding(Encoding::UTF_8).scrub # конверт - UTF-8 (doc-3)
      Message.new(subject: parts[1], reply: reply, payload: payload)
    end

    def close
      @sock.close
    rescue StandardError
      nil
    end

    private

    def ping
      send_line("PING")
      return unless IO.select([@sock], nil, nil, 5)

      @sock.gets("\r\n") # PONG
    end

    def send_line(line)
      @sock.write("#{line}\r\n")
    end
  end

  # Клиент, подключённый к этому серверу (тест-отправитель).
  def client
    Client.new(host: @host, port: @port)
  end

  def initialize(host: "127.0.0.1", port: 0)
    @host = host
    @port = port
    @server = nil
    @clients = []    # [{ sock:, subs: {sid => subject} }]
    @subscribed = [] # subjects всех живых подписок
    @mutex = Mutex.new
    @accept_thread = nil
    @stopped = false
  end

  attr_reader :host, :port

  # Поднять сервер; port 0 - выбрать свободный.
  def start
    @server = TCPServer.new(@host, @port)
    @port = @server.addr[1]
    @accept_thread = Thread.new { accept_loop }
    self
  end

  # Остановить сервер: закрыть слушатель и все клиентские соединения.
  # Для сценария обрыва связи поднятие нового FakeNatsServer на тот же
  # порт эмулирует перезапуск ноды: клиент обязан переподключиться сам.
  def stop
    @stopped = true
    @server&.close
    socks = @mutex.synchronize do
      swap = @clients.map { |c| c[:sock] }
      @clients.clear
      @subscribed.clear
      swap
    end
    socks.each { |sock| begin; sock.close; rescue StandardError; nil; end }
    @accept_thread&.join(5)
    nil
  end

  # Есть ли сейчас подписка на subject.
  def subscribed?(subject)
    @mutex.synchronize { @subscribed.include?(subject) }
  end

  # Ждать появления подписки на subject (клиент должен успеть подключиться
  # и подписаться). @return [true, false] - дождались или вышло время.
  def wait_subscribed(subject, timeout: 10)
    deadline = Time.now + timeout
    until subscribed?(subject)
      return false if Time.now >= deadline

      sleep 0.05
    end
    true
  end

  # Опубликовать сообщение сторонним клиентом (как nats pub): подключиться
  # и отправить PUB с payload; сервер доставит MSG подписчикам.
  def publish(subject, payload, reply: nil)
    sock = TCPSocket.new(@host, @port)
    head = reply ? "PUB #{subject} #{reply} #{payload.bytesize}" \
                  : "PUB #{subject} #{payload.bytesize}"
    sock.write("#{head}\r\n#{payload}\r\n")
    sock.close
    nil
  end

  private

  def accept_loop
    loop do
      sock = @server.accept
      client = { sock: sock, subs: {} }
      @mutex.synchronize { @clients << client }
      Thread.new(client) { |c| serve_client(c) }
    end
  rescue IOError, Errno::EBADF
    # Сервер остановлен - выходим.
  end

  def serve_client(client)
    sock = client[:sock]
    subs = client[:subs]
    sock.write("#{INFO}\r\n")
    loop do
      line = sock.gets("\r\n")
      break if line.nil? || @stopped

      case line
      when /\ACONNECT\s/i
        next
      when /\APING/i
        sock.write("PONG\r\n")
      when /\ASUB\s+(\S+)(?:\s+(\S+))?\s+(\d+)\s*\z/
        subject = Regexp.last_match(1)
        sid = Regexp.last_match(3)
        subs[sid] = subject
        @mutex.synchronize { @subscribed << subject unless @subscribed.include?(subject) }
      when /\APUB\s+(\S+)(?:\s+(\S+))?\s+(\d+)\s*\z/
        subject = Regexp.last_match(1)
        reply = Regexp.last_match(2)
        size = Regexp.last_match(3).to_i
        payload = sock.read(size + 2).to_s.byteslice(0, size)
        deliver(subject, reply, payload)
      end
    end
  rescue EOFError, Errno::ECONNRESET, Errno::EPIPE, IOError
    # Клиент ушёл - выходим.
  ensure
    @mutex.synchronize do
      @clients.delete(client)
      @subscribed.replace(@clients.flat_map { |c| c[:subs].values }.uniq)
    end
    begin
      sock.close
    rescue StandardError
      nil
    end
  end

  # Доставить MSG всем подписчикам subject (точное совпадение).
  def deliver(subject, reply, payload)
    @mutex.synchronize do
      @clients.each do |client|
        client[:subs].each do |sid, sub_subject|
          next unless sub_subject == subject

          head = if reply
                   "MSG #{subject} #{sid} #{reply} #{payload.bytesize}"
                 else
                   "MSG #{subject} #{sid} #{payload.bytesize}"
                 end
          begin
            client[:sock].write("#{head}\r\n#{payload}\r\n")
          rescue StandardError
            nil
          end
        end
      end
    end
  end
end
