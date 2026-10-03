# frozen_string_literal: true

require "spec_helper"
require "net/http"
require "socket"
require "json"
require "securerandom"
require_relative "fake_nats"

# e2e-тесты сервиса bin/serve: сервис поднимается подпроцессом с фейковым
# pi на PATH (заглушка spec/fake_pi.rb, JSONL RPC-протокол). Настоящий pi и
# внешняя сеть не нужны: HTTP ходит по loopback (127.0.0.1), шина - фейковый
# NATS-сервер (spec/fake_nats.rb) в процессе теста.
# Фикстуры - let-хелперы и методы группы, не константы: константы
# describe-блоков разных спек-файлов делят одну область видимости
# и перетирают друг друга при загрузке.
RSpec.describe "bin/serve" do
  let(:host) { "127.0.0.1" }
  let(:root) { File.expand_path("..", __dir__) }
  let(:serve_bin) { File.expand_path("../bin/serve", __dir__) }

  around do |example|
    Dir.mktmpdir("sigma-mate-serve-spec") do |dir|
      @dir = dir
      @pid = nil
      @log = nil
      begin
        example.run
      ensure
        stop_service
        @log&.close
      end
    end
  end

  def path_with(dir)
    "#{dir}#{File::PATH_SEPARATOR}#{ENV['PATH']}"
  end

  # Заглушка `pi`: вызывает fake_pi.rb, игнорируя аргументы pi.
  # (гем ищет pi по имени на PATH, абсолютный путь в PI_BIN не работает)
  def install_fake_pi(body = nil)
    path = File.join(@dir, "pi")
    body ||= <<~SH
      #!/bin/sh
      exec #{RbConfig.ruby} #{File.expand_path("fake_pi.rb", __dir__).inspect} "$@"
    SH
    File.write(path, body)
    FileUtils.chmod(0o755, path)
    path
  end

  def free_port
    server = TCPServer.new(host, 0)
    server.addr[1]
  ensure
    server.close
  end

  # Поднимает bin/serve подпроцессом и ждёт готовности слушать сокет.
  # Адрес/порт задаются флагами argv или переменными SM_HOST/SM_PORT.
  # @param fake_pi [String] тело заглушки pi (по умолчанию - spec/fake_pi.rb)
  # @param env [Hash] дополнительное окружение (например SM_FAKE_FIRST_DELAY)
  # @param bus [Boolean, String] поднять фейковую NATS-шину и включить
  #   подписку сервиса; true - идентификатор по умолчанию, строка - свой
  def start_service(argv: [], env: {}, fake_pi: nil, bus: false)
    install_fake_pi(fake_pi)
    @agent_id = nil
    @nats = nil
    @sender = nil
    if bus
      @nats = FakeNatsServer.new.start
      @agent_id = bus == true ? agent_id : bus
      argv += ["--agent-id", @agent_id, "--nats-url", "nats://127.0.0.1:#{@nats.port}"]
    end
    port_idx = argv.index("--port")
    @port = port_idx ? Integer(argv[port_idx + 1]) : free_port
    @log_path = File.join(@dir, "serve.log")
    @log = File.open(@log_path, "w")
    full_env = { "PATH" => path_with(@dir) }.merge(env)
    unless port_idx
      full_env["SM_HOST"] = host
      full_env["SM_PORT"] = @port.to_s
    end
    @pid = spawn(full_env, RbConfig.ruby, serve_bin, *argv,
                 chdir: root, out: @log, err: @log)
    wait_ready
  end

  def wait_ready(timeout: 15)
    deadline = Time.now + timeout
    loop do
      begin
        TCPSocket.open(host, @port).close
        return
      rescue Errno::ECONNREFUSED, Errno::ECONNRESET
        exited, = Process.wait(@pid, Process::WNOHANG)
        raise "сервис упал при старте, лог: #{log_text}" if exited
        raise "сервис не поднялся за #{timeout}s, лог: #{log_text}" if Time.now >= deadline

        sleep 0.05
      end
    end
  end

  def log_text
    return "" unless @log_path

    File.read(@log_path)
  rescue StandardError
    ""
  end

  # Остановить сервис: TERM, при зависании - KILL. Фейковая шина
  # останавливается после сервиса.
  def stop_service
    pid = @pid
    @pid = nil
    return unless pid

    begin
      Process.kill("TERM", pid)
    rescue Errno::ESRCH
      teardown_bus
      return
    end
    deadline = Time.now + 10
    while Process.kill(0, pid)
      break if Time.now >= deadline

      sleep 0.05
    end
    begin
      Process.kill("KILL", pid)
    rescue Errno::ESRCH
      nil
    end
    Process.wait(pid)
  rescue Errno::ECHILD
    nil
  ensure
    teardown_bus
  end

  def teardown_bus
    @sender&.close
    @sender = nil
    @nats&.stop
    @nats = nil
  end

  # POST с JSON-телом. @return [Array<Integer, Hash>]
  def post(path, body, port: nil)
    Net::HTTP.start(host, port || @port, open_timeout: 5, read_timeout: 20) do |http|
      req = Net::HTTP::Post.new(path, "Content-Type" => "application/json")
      req.body = body.is_a?(String) ? body : JSON.generate(body)
      resp = http.request(req)
      [resp.code.to_i, JSON.parse(resp.body)]
    end
  end

  def get(path)
    Net::HTTP.start(host, @port, open_timeout: 5, read_timeout: 10) do |http|
      resp = http.request(Net::HTTP::Get.new(path))
      [resp.code.to_i, resp.body]
    end
  end

  it "отвечает ответом агента на POST /ask" do
    start_service

    status, body = post("/ask", { prompt: "Как дела?" })

    expect(status).to eq(200)
    expect(body["status"]).to eq("ok")
    expect(body["answer"]).to eq("Ответ: Как дела?")
  end

  it "печатает адрес и порт при старте; адрес задаётся флагами" do
    port = free_port
    start_service(argv: ["--host", host, "--port", port.to_s])

    expect(log_text).to include("http://#{host}:#{port}")

    status, body = post("/ask", { prompt: "Вопрос" }, port: port)
    expect(status).to eq(200)
    expect(body["status"]).to eq("ok")
  end

  it "новый запрос прерывает текущий прогон: прерванный - interrupted, новый - ответ" do
    # Первый prompt у заглушки задержан на 5с, abort прерывает задержку.
    start_service(env: { "SM_FAKE_FIRST_DELAY" => "5" })

    thread = Thread.new { post("/ask", { prompt: "Медленный" }) }
    sleep 0.5 # первый запрос уже в прогоне

    started = Time.now
    new_status, new_body = post("/ask", { prompt: "Быстрый" })

    expect(new_status).to eq(200)
    expect(new_body["status"]).to eq("ok")
    expect(new_body["answer"]).to eq("Ответ: Быстрый")

    expect(thread.join(10)).not_to be_nil
    old_status, old_body = thread.value
    expect(old_status).to eq(200)
    expect(old_body["status"]).to eq("interrupted")
    expect(old_body).to have_key("detail")
    # Прерванный клиент не ждёт конца задержки (5с).
    expect(Time.now - started).to be < 4
  end

  it "обслуживает запросы последовательно: каждый получает свой ответ" do
    start_service

    first = post("/ask", { prompt: "Первый" })
    second = post("/ask", { prompt: "Второй" })

    expect(first[0]).to eq(200)
    expect(first[1]["answer"]).to eq("Ответ: Первый")
    expect(second[0]).to eq(200)
    expect(second[1]["answer"]).to eq("Ответ: Второй")
  end

  it "отвечает внятной ошибкой и остаётся живым, когда pi умирает" do
    start_service(fake_pi: "#!/bin/sh\nsleep 0.2\nexit 9\n")

    first_status, first_body = post("/ask", { prompt: "Вопрос" })
    second_status, second_body = post("/ask", { prompt: "Ещё вопрос" })

    expect(first_status).to eq(503)
    expect(first_body["status"]).to eq("error")
    expect(first_body["detail"]).to be_a(String)
    expect(first_body["detail"]).not_to be_empty
    # Сервис остался жив: отвечает и дальше, процесс на месте.
    expect(second_status).to eq(503)
    expect(second_body["status"]).to eq("error")
    expect(Process.kill(0, @pid)).to eq(1)
  end

  it "отклоняет некорректные запросы" do
    start_service

    status, body = post("/ask", { prompt: "   " })
    expect(status).to eq(400)
    expect(body["status"]).to eq("error")

    status, body = post("/ask", "не-json")
    expect(status).to eq(400)
    expect(body["status"]).to eq("error")

    status, = get("/")
    expect(status).to eq(404)
  end

  # --- шина: протокол sigma/1 (SGM-6) ---

  let(:agent_id) { "33333333-3333-3333-3333-333333333333" }
  let(:sender_id) { "44444444-4444-4444-4444-444444444444" }
  let(:agent_inbox) { "sigma.agent.#{agent_id}.inbox" }
  let(:agent_events) { "sigma.agent.#{agent_id}.events" }

  # Отправитель (SGM-7): подписан на events-канал агента, свой ответ
  # узнаёт по correlation_id (doc-3 «Корреляция»).
  def sender
    @sender ||= @nats.client.subscribe(agent_events)
  end

  # Ждать, пока сервис поднимет подписку на свой inbox.
  def wait_agent_subscribed
    expect(@nats.wait_subscribed(agent_inbox, timeout: 15)).to be(true)
  end

  # Конверт request от отправителя.
  def sigma_request(task:, id: SecureRandom.uuid, from: sender_id)
    JSON.generate(
      "proto" => "sigma/1", "type" => "request", "id" => id,
      "correlation_id" => nil, "from" => from, "to" => agent_id,
      "ts" => Time.now.utc.iso8601, "body" => { "task" => task }
    )
  end

  def publish_request(task:, id: SecureRandom.uuid)
    sender # подписка на events поднята до публикации
    @nats.publish(agent_inbox, sigma_request(task: task, id: id))
    id
  end

  it "задача из шины обрабатывается в сессии, ответ приходит в events с корреляцией" do
    start_service(bus: true)
    wait_agent_subscribed

    id = publish_request(task: "прогони тесты")
    msg = sender.next_message(timeout: 15)

    expect(msg).not_to be_nil
    expect(msg.subject).to eq(agent_events)
    json = JSON.parse(msg.payload)
    expect(json["proto"]).to eq("sigma/1")
    expect(json["type"]).to eq("reply")
    expect(json["correlation_id"]).to eq(id)
    expect(json["from"]).to eq(agent_id)
    expect(json["to"]).to eq(sender_id)
    expect(json["body"]).to eq({ "status" => "ok", "answer" => "Ответ: прогони тесты" })
    expect(log_text).to include("[протокол] задача принята (id=#{id}")
    expect(log_text).to include("[протокол] ответ опубликован в #{agent_events}")
  end

  it "битый конверт: отправитель получает error bad_request, задача не начиналась" do
    start_service(bus: true)
    wait_agent_subscribed

    sender
    @nats.publish(agent_inbox, "не json")
    msg = sender.next_message(timeout: 15)

    expect(msg).not_to be_nil
    json = JSON.parse(msg.payload)
    expect(json["type"]).to eq("error")
    expect(json["body"]["code"]).to eq("bad_request")
    expect(json["correlation_id"]).to be_nil
    # задачи не было - и ответа агента в журнале тоже
    expect(log_text).not_to include("задача принята")
  end

  it "pi умер: отправитель получает reply с ошибкой unavailable, сервис жив" do
    start_service(bus: true, fake_pi: "#!/bin/sh\nsleep 0.2\nexit 9\n")
    wait_agent_subscribed

    publish_request(task: "задача без сессии")
    msg = sender.next_message(timeout: 15)

    expect(msg).not_to be_nil
    json = JSON.parse(msg.payload)
    expect(json["type"]).to eq("reply")
    expect(json["body"]["status"]).to eq("error")
    expect(json["body"]["code"]).to eq("unavailable")
    expect(json["body"]["detail"]).to be_a(String)
    # сервис жив и HTTP продолжает отвечать ошибкой
    status, body = post("/ask", { prompt: "Вопрос" })
    expect(status).to eq(503)
    expect(body["status"]).to eq("error")
  end

  it "занятый агент: новая задача из шины прерывает текущую, обе получают ответ" do
    start_service(bus: true, env: { "SM_FAKE_FIRST_DELAY" => "5" })
    wait_agent_subscribed

    slow_id = publish_request(task: "Медленная")
    sleep 0.5 # первая задача уже в прогоне
    fast_id = publish_request(task: "Быстрая")

    replies = {}
    2.times do
      msg = sender.next_message(timeout: 20)
      expect(msg).not_to be_nil
      json = JSON.parse(msg.payload)
      replies[json["correlation_id"]] = json["body"]
    end

    expect(replies[slow_id]["status"]).to eq("interrupted")
    expect(replies[slow_id]["detail"]).to be_a(String)
    expect(replies[fast_id]["status"]).to eq("ok")
    expect(replies[fast_id]["answer"]).to eq("Ответ: Быстрая")
  end

  it "одна сессия на оба входа: HTTP-запрос прерывает задачу из шины" do
    start_service(bus: true, env: { "SM_FAKE_FIRST_DELAY" => "5" })
    wait_agent_subscribed

    bus_id = publish_request(task: "Задача из шины")
    sleep 0.5 # задача из шины уже в прогоне

    status, body = post("/ask", { prompt: "Вопрос из HTTP" })

    expect(status).to eq(200)
    expect(body["status"]).to eq("ok")
    expect(body["answer"]).to eq("Ответ: Вопрос из HTTP")

    msg = sender.next_message(timeout: 20)
    expect(msg).not_to be_nil
    json = JSON.parse(msg.payload)
    expect(json["correlation_id"]).to eq(bus_id)
    expect(json["body"]["status"]).to eq("interrupted")
  end

  it "задача из шины видна в HTTP-API так же: после шины HTTP работает с той же сессией" do
    start_service(bus: true)
    wait_agent_subscribed

    publish_request(task: "из шины")
    msg = sender.next_message(timeout: 15)
    expect(JSON.parse(msg.payload)["body"]["answer"]).to eq("Ответ: из шины")

    # та же сессия продолжает обслуживать HTTP: последний ответ сессии - от
    # задачи из шины, новый HTTP-запрос идёт тем же Coordinator-ом
    status, body = post("/ask", { prompt: "из http" })
    expect(status).to eq(200)
    expect(body["status"]).to eq("ok")
    expect(body["answer"]).to eq("Ответ: из http")
  end

  it "недопустимый идентификатор: подписка не поднимается, HTTP работает" do
    start_service(argv: ["--agent-id", "bad.id", "--nats-url", "nats://127.0.0.1:1"])

    expect(log_text).to include("недопустимый идентификатор агента")
    expect(log_text).not_to include("[шина]")

    status, body = post("/ask", { prompt: "Вопрос" })
    expect(status).to eq(200)
    expect(body["status"]).to eq("ok")
  end
end
