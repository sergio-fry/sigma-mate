# frozen_string_literal: true

require "spec_helper"
require "net/http"
require "socket"
require "json"

# e2e-тесты сервиса bin/serve: сервис поднимается подпроцессом с фейковым
# pi на PATH (заглушка spec/fake_pi.rb, JSONL RPC-протокол). Настоящий pi и
# внешняя сеть не нужны: HTTP ходит по loopback (127.0.0.1).
RSpec.describe "bin/serve" do
  HOST = "127.0.0.1"
  ROOT = File.expand_path("..", __dir__)
  SERVE = File.expand_path("../bin/serve", __dir__)

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
    server = TCPServer.new(HOST, 0)
    server.addr[1]
  ensure
    server.close
  end

  # Поднимает bin/serve подпроцессом и ждёт готовности слушать сокет.
  # Адрес/порт задаются флагами argv или переменными SM_HOST/SM_PORT.
  # @param fake_pi [String] тело заглушки pi (по умолчанию - spec/fake_pi.rb)
  # @param env [Hash] дополнительное окружение (например SM_FAKE_FIRST_DELAY)
  def start_service(argv: [], env: {}, fake_pi: nil)
    install_fake_pi(fake_pi)
    port_idx = argv.index("--port")
    @port = port_idx ? Integer(argv[port_idx + 1]) : free_port
    @log_path = File.join(@dir, "serve.log")
    @log = File.open(@log_path, "w")
    full_env = { "PATH" => path_with(@dir) }.merge(env)
    unless port_idx
      full_env["SM_HOST"] = HOST
      full_env["SM_PORT"] = @port.to_s
    end
    @pid = spawn(full_env, RbConfig.ruby, SERVE, *argv,
                 chdir: ROOT, out: @log, err: @log)
    wait_ready
  end

  def wait_ready(timeout: 15)
    deadline = Time.now + timeout
    loop do
      begin
        TCPSocket.open(HOST, @port).close
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

  # Остановить сервис: TERM, при зависании - KILL.
  def stop_service
    pid = @pid
    @pid = nil
    return unless pid

    begin
      Process.kill("TERM", pid)
    rescue Errno::ESRCH
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
  end

  # POST с JSON-телом. @return [Array<Integer, Hash>]
  def post(path, body, port: nil)
    Net::HTTP.start(HOST, port || @port, open_timeout: 5, read_timeout: 20) do |http|
      req = Net::HTTP::Post.new(path, "Content-Type" => "application/json")
      req.body = body.is_a?(String) ? body : JSON.generate(body)
      resp = http.request(req)
      [resp.code.to_i, JSON.parse(resp.body)]
    end
  end

  def get(path)
    Net::HTTP.start(HOST, @port, open_timeout: 5, read_timeout: 10) do |http|
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
    start_service(argv: ["--host", HOST, "--port", port.to_s])

    expect(log_text).to include("http://#{HOST}:#{port}")

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
end
