# frozen_string_literal: true

# Фейковый pi для автотестов: говорит на том же JSONL-протоколе RPC,
# что и настоящий `pi --mode rpc`, но без сети и модели.
# Эмулирует ответ ассистента на любой prompt.

require "json"

def emit(record)
  $stdout.puts(JSON.generate(record))
  $stdout.flush
end

last_answer = nil

loop do
  line = $stdin.gets
  break if line.nil?

  begin
    input = JSON.parse(line)
  rescue JSON::ParserError
    next
  end

  next unless input["id"]

  if input["type"] == "get_last_assistant_text"
    emit("id" => input["id"], "type" => "response",
         "command" => "get_last_assistant_text", "success" => true,
         "data" => { "text" => last_answer })
    next
  end

  emit("id" => input["id"], "type" => "response", "command" => input["type"],
       "success" => true, "data" => { "disposition" => "started" })

  next unless input["type"] == "prompt"

  question = input["message"]
  answer = "Ответ: #{question}"
  last_answer = answer
  emit("type" => "message_start",
       "message" => { "role" => "assistant", "content" => [], "stopReason" => "pending" })
  answer.each_char do |ch|
    emit("type" => "message_update", "usage" => {}, "assistantMessageEvent" =>
      { "type" => "text_delta", "contentIndex" => 0, "delta" => ch })
  end
  emit("type" => "message_end", "message" =>
    { "role" => "assistant", "content" => answer, "stopReason" => "stop" })
  emit("type" => "agent_end", "messages" => [], "willRetry" => false)
  emit("type" => "agent_settled")
end
