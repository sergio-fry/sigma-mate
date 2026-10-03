# frozen_string_literal: true

# Общие константы sigma-mate и фабрика pi-сессии агента developer.
# Модель и провайдер не переопределяются: берётся текущая глобальная
# конфигурация pi на машине.

require "pi_agent"

module SigmaMate
  AGENT_NAME = "developer"
  AGENT_FILE = File.expand_path("../agents/#{AGENT_NAME}.md", __dir__)
  PROJECT_ROOT = File.expand_path("..", __dir__)

  DEFAULT_HOST = "127.0.0.1"
  DEFAULT_PORT = 4567

  module_function

  # Фабрика pi-сессии агента developer: pi --mode rpc с системным промптом
  # сотрудника, рабочий каталог - корень проекта.
  def default_session_factory
    lambda do
      PiAgent.session(
        args: ["--mode", "rpc", "--append-system-prompt", AGENT_FILE],
        cwd: PROJECT_ROOT
      )
    end
  end
end
