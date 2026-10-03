# frozen_string_literal: true

require "spec_helper"

RSpec.describe "bin/ask" do
  around do |example|
    Dir.mktmpdir("sigma-mate-spec") do |dir|
      @dir = dir
      example.run
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

  it "принимает вопрос, печатает ответ агента и завершается с кодом 0" do
    install_fake_pi
    status, stdout, = AskRunner.run("Как дела?", env: { "PATH" => path_with(@dir) })

    expect(status.exitstatus).to eq(0)
    expect(stdout).to eq("Ответ: Как дела?\n")
  end

  it "печатает понятную ошибку и не нулевой код, когда pi недоступен" do
    FileUtils.mkdir(File.join(@dir, "empty"))
    status, stdout, stderr = AskRunner.run("Вопрос",
                                           env: { "PATH" => File.join(@dir, "empty") })

    expect(status.exitstatus).to eq(1)
    expect(stdout).to be_empty
    expect(stderr).to include("Ошибка").and include("не найден pi")
  end

  it "требует непустой вопрос и подсказывает использование" do
    install_fake_pi
    status, stdout, stderr = AskRunner.run("", env: { "PATH" => path_with(@dir) })

    expect(status.exitstatus).to eq(2)
    expect(stdout).to be_empty
    expect(stderr).to include("Использование")
  end

  it "падает с понятной ошибкой, когда сессия pi умирает" do
    install_fake_pi("#!/bin/sh\nexit 9\n")
    status, stdout, stderr = AskRunner.run("Вопрос", env: { "PATH" => path_with(@dir) })

    expect(status.exitstatus).to eq(1)
    expect(stdout).to be_empty
    # Гонка между EPIPE и уведомлением о смерти транспорта — любое из
    # сообщений понимаемо, оба пути дают код 1 и пустой stdout.
    expect(stderr).to start_with("Ошибка")
    expect(stderr).to(match(/сессия|Broken pipe/))
  end
end
