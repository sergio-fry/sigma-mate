# frozen_string_literal: true

require "spec_helper"
require "pi_agent"
require "sigma_mate/coordinator"

# Фейковая pi-сессия для unit-тестов Coordinator: без подпроцессов, сети
# и сокетов. Поддерживает прерывание: abort во время задержки меняет
# сценарий на "ошибка ассистента с reason aborted + agent_settled".
# Задержка действует только на первый prompt (как SM_FAKE_FIRST_DELAY
# у spec/fake_pi.rb).
class FakeSession
  def initialize(delay: 0, fail_on_prompt: nil)
    @delay = delay
    @fail_on_prompt = fail_on_prompt
    @aborted = false
    @count = 0
    @last_prompt = nil
    @m = Mutex.new
  end

  attr_reader :last_prompt

  def abort
    @m.synchronize { @aborted = true }
    self
  end

  def prompt(message)
    raise @fail_on_prompt if @fail_on_prompt

    @m.synchronize { @aborted = false } # abort действует только на текущий прогон
    first = @m.synchronize { @count += 1 } == 1
    deadline = Time.now + (first ? @delay : 0)
    until Time.now >= deadline
      break if @m.synchronize { @aborted }

      sleep 0.02
    end

    if @m.synchronize { @aborted }
      yield PiAgent::Event.new("type" => "message_update",
                               "assistantMessageEvent" =>
                                 { "type" => "error", "reason" => "aborted",
                                   "error" => "Aborted" })
    else
      @m.synchronize { @last_prompt = message }
    end
    yield PiAgent::Event.new("type" => "agent_settled")
    self
  end

  def last_assistant_text
    @last_prompt ? "Ответ: #{@last_prompt}" : nil
  end

  def close; end
end

RSpec.describe SigmaMate::Coordinator do
  let(:session) { FakeSession.new }
  let(:factory) { -> { session } }

  def wait_busy(coordinator, timeout: 5)
    deadline = Time.now + timeout
    sleep 0.02 until coordinator.busy? || Time.now >= deadline
    expect(coordinator.busy?).to be(true)
  end

  it "выполняет запрос и возвращает ответ агента" do
    coordinator = described_class.new(session_factory: factory).start

    result = coordinator.ask("Как дела?")

    expect(result.ok?).to be(true)
    expect(result.answer).to eq("Ответ: Как дела?")
    expect(result.detail).to be_nil
  end

  it "обрабатывает запросы строго по одному, сессия поднимается один раз" do
    session = FakeSession.new(delay: 0.05)
    coordinator = described_class.new(session_factory: -> { session }).start

    first = coordinator.ask("Первый")
    second = coordinator.ask("Второй")

    expect(first.ok?).to be(true)
    expect(second.ok?).to be(true)
    expect(session.last_prompt).to eq("Второй")
  end

  it "новый запрос прерывает текущий прогон и идёт сам" do
    session = FakeSession.new(delay: 10)
    coordinator = described_class.new(session_factory: -> { session }).start

    thread = Thread.new { coordinator.ask("Медленный") }
    wait_busy(coordinator)

    newcomer = coordinator.ask("Быстрый")

    expect(newcomer.ok?).to be(true)
    expect(newcomer.answer).to eq("Ответ: Быстрый")
    interrupted = thread.value
    expect(interrupted).to be_a(SigmaMate::RunResult)
    expect(interrupted.ok?).to be(false)
    expect(interrupted.interrupted?).to be(true)
    expect(interrupted.detail).to include("прерван")
  end

  it "прерванный клиент получает ответ сразу, не дожидаясь задержки" do
    session = FakeSession.new(delay: 10)
    coordinator = described_class.new(session_factory: -> { session }).start

    thread = Thread.new { coordinator.ask("Медленный") }
    wait_busy(coordinator)
    started = Time.now
    newcomer = coordinator.ask("Быстрый")
    elapsed = Time.now - started

    expect(newcomer.ok?).to be(true)
    # Медленный прогон (задержка 10с) завершается прерыванием быстро.
    expect(thread.value.interrupted?).to be(true)
    expect(elapsed).to be < 5
  end

  it "возвращает ошибку и остаётся живым, если сессия умирает" do
    session = FakeSession.new(
      fail_on_prompt: PiAgent::TransportClosedError.new("process terminated by signal 9")
    )
    coordinator = described_class.new(session_factory: -> { session }).start

    first = coordinator.ask("Вопрос")
    second = coordinator.ask("Ещё вопрос")

    expect(first.error?).to be(true)
    expect(first.detail).to include("process terminated")
    expect(second.error?).to be(true)
    expect(coordinator.busy?).to be(false)
    expect(coordinator.alive?).to be(false)
  end

  it "возвращает ошибку на каждый запрос, если pi не поднялся при старте" do
    coordinator = described_class.new(
      session_factory: -> { raise PiAgent::BinaryNotFoundError, "Could not find the `pi` binary" }
    ).start

    result = coordinator.ask("Вопрос")

    expect(result.error?).to be(true)
    expect(result.detail).to include("pi")
  end
end
