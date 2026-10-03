# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "open3"
require "rbconfig"

RSpec.configure do |config|
  config.order = :random
end

# Прогон обвязки как реального подпроцесса: bin/ask запускается с
# PI_BIN, указывающим на фейковый pi, говорящий на JSONL-протоколе RPC.
# Ни настоящего pi, ни сети не нужно.
module AskRunner
  ASK = File.expand_path("../bin/ask", __dir__)
  ROOT = File.expand_path("..", __dir__)

  module_function

  # @return [Array<status, stdout, stderr>]
  def run(question, env: {})
    opts = { chdir: ROOT }
    Open3.capture3(ENV.to_h.merge(env), RbConfig.ruby, ASK, question, **opts)
    .then { |out, err, st| [st, out, err] }
  end
end
