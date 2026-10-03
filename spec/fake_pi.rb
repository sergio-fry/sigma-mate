# frozen_string_literal: true

# Фейковый pi для автотестов: говорит на том же JSONL-протоколе RPC,
# что и настоящий `pi --mode rpc`, но без сети и модели.
# Эмулирует ответ ассистента на любой prompt.
#
# Управление через окружение:
#   SM_FAKE_FIRST_DELAY - задержка первого prompt в секундах (по умолчанию 0);
#     во время задержки входящий notify "abort" прерывает прогон: эмулируется
#     ошибка ассистента с reason "aborted" и agent_settled. Последующие
#     prompt-ы отвечают без задержки.
#
# Потоки: reader читает stdin (в т.ч. abort во время чужой задержки - поэтому
# задержка живёт в worker-потоке), worker обрабатывает prompt-ы по очереди.

require "json"

WRITE = Mutex.new
STATE = Mutex.new
FIRST_DELAY = (ENV["SM_FAKE_FIRST_DELAY"] || "0").to_f

def emit(record)
  WRITE.synchronize do
    $stdout.puts(JSON.generate(record))
    $stdout.flush
  end
end

def respond(input, data = {})
  emit("id" => input["id"], "type" => "response", "command" => input["type"],
       "success" => true, "data" => data)
end

aborted = false
prompts_seen = 0
last_answer = nil
prompts = Queue.new

# Обработка одного prompt-а: задержка (прерываемая abort), затем либо ошибка
# с reason "aborted" + agent_settled, либо полный ответ ассистента.
worker = Thread.new do
  loop do
    input = prompts.pop # nil, когда очередь закрыта и пуста
    break if input.nil?

    question = input["message"]
    first = STATE.synchronize { prompts_seen += 1 } == 1
    STATE.synchronize { aborted = false } # abort действует только на текущий прогон

    deadline = Time.now + (first ? FIRST_DELAY : 0)
    until Time.now >= deadline
      break if STATE.synchronize { aborted }

      sleep 0.02
    end

    if STATE.synchronize { aborted }
      emit("type" => "message_update",
           "assistantMessageEvent" => { "type" => "error", "reason" => "aborted",
                                       "error" => "Aborted" })
      emit("type" => "agent_end", "messages" => [], "willRetry" => false)
      emit("type" => "agent_settled")
      next
    end

    answer = "Ответ: #{question}"
    STATE.synchronize { last_answer = answer }
    emit("type" => "message_start", "message" =>
      { "role" => "assistant", "content" => [], "stopReason" => "pending" })
    answer.each_char do |ch|
      emit("type" => "message_update", "usage" => {}, "assistantMessageEvent" =>
        { "type" => "text_delta", "contentIndex" => 0, "delta" => ch })
    end
    emit("type" => "message_end", "message" =>
      { "role" => "assistant", "content" => answer, "stopReason" => "stop" })
    emit("type" => "agent_end", "messages" => [], "willRetry" => false)
    emit("type" => "agent_settled")
  end
end

reader = Thread.new do
  loop do
    line = $stdin.gets
    break if line.nil?

    begin
      input = JSON.parse(line)
    rescue JSON::ParserError
      next
    end

    # notify "abort" - без id: прерывает текущий (задержанный) прогон.
    if input["type"] == "abort" && input["id"].nil?
      STATE.synchronize { aborted = true }
      next
    end

    next unless input["id"]

    if input["type"] == "get_last_assistant_text"
      respond(input, "text" => STATE.synchronize { last_answer })
      next
    end

    if input["type"] == "prompt"
      respond(input, "disposition" => "started")
      prompts << input
      next
    end

    respond(input, "disposition" => "started")
  end
end

reader.join
prompts.close
worker.join
