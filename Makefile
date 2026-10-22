# .env 是唯一配置来源：模型、端点、密钥都从这里读
-include .env
export

PI_VERSION        ?= 0.85.1
COMPOSE           := docker compose
DEEPSEEK_PROVIDER ?= deepseek-anthropic
DEEPSEEK_MODEL    ?= deepseek-v4-flash
DEEPSEEK_BASE_URL ?= https://api.deepseek.com/anthropic

.PHONY: up down ps build config shell-a shell-b exec-a exec-b seed-auth reset check

build:
	$(COMPOSE) build

up: build
	$(COMPOSE) up -d
	$(MAKE) config
	@$(COMPOSE) ps

down:
	$(COMPOSE) down

# 只清容器和网络，保留 pi-agent-home / pi-agent-workspace 两个卷
reset:
	$(COMPOSE) down -v
	docker volume rm -f pi-agent-home pi-agent-workspace

ps:
	$(COMPOSE) ps

# 把 config/models.json 灌进共享卷（按 .env 覆写 provider / baseUrl / model），
# 并把默认模型写进 settings.json。两个容器挂同一个卷，写一次两边都生效。
config:
	@$(COMPOSE) ps --status running --services | grep -qx pi-a || { echo "pi-a 未运行，先 make up"; exit 1; }
	@tmp=$$(mktemp) && \
	  jq --arg p "$(DEEPSEEK_PROVIDER)" --arg m "$(DEEPSEEK_MODEL)" --arg b "$(DEEPSEEK_BASE_URL)" \
	     '.providers[$$p].baseUrl = $$b | .providers[$$p].models[0].id = $$m | .providers[$$p].models[0].name = $$m' \
	     config/models.json > $$tmp && \
	  docker cp $$tmp pi-a:/root/.pi/agent/models.json && \
	  rm -f $$tmp
	@docker exec pi-a sh -lc 'set -e; f=/root/.pi/agent/settings.json; \
	  [ -f $$f ] || echo "{}" > $$f; \
	  jq --arg p "$(DEEPSEEK_PROVIDER)" --arg m "$(DEEPSEEK_MODEL)" \
	     ".defaultProvider = \$$p | .defaultModel = \$$m" $$f > $$f.tmp; \
	  mv $$f.tmp $$f; \
	  echo "defaultProvider=$$(jq -r .defaultProvider $$f)  defaultModel=$$(jq -r .defaultModel $$f)"'

# 进入交互式 pi TUI
shell-a:
	docker exec -it pi-a pi

shell-b:
	docker exec -it pi-b pi

# 在容器里跑一次性命令，例如 make exec-a CMD='pi -p "列出当前目录"'
exec-a:
	docker exec -it pi-a sh -lc '$(CMD)'

exec-b:
	docker exec -it pi-b sh -lc '$(CMD)'

# 把宿主 ~/.pi/agent 里的凭据灌进共享卷，省去容器内重新登录
seed-auth:
	docker run --rm \
	  -v pi-agent-home:/target \
	  -v "$(HOME)/.pi/agent:/src:ro" \
	  node:24-bookworm-slim \
	  sh -c 'for f in auth.json models.json provider-keys.json; do \
	           if [ -f /src/$$f ]; then cp /src/$$f /target/$$f; echo "copied $$f"; fi; \
	         done'

# 验证两个容器确实共用同一份上下文存储
check:
	@echo "== 容器 =="
	@$(COMPOSE) ps --format 'table {{.Name}}\t{{.Status}}\t{{.Image}}'
	@echo "== 卷挂载 =="
	@for c in pi-a pi-b; do \
	  printf '%s: ' $$c; \
	  docker inspect $$c --format '{{range .Mounts}}{{.Name}}->{{.Destination}} {{end}}'; \
	done
	@echo "== 配置（从 pi-b 读）=="
	@docker exec pi-b sh -lc 'jq -r ".defaultProvider + \" / \" + .defaultModel" /root/.pi/agent/settings.json'
	@docker exec pi-b sh -lc 'jq -r ".providers | to_entries[] | \"\(.key) \(.value.baseUrl) \(.value.models[0].id)\"" /root/.pi/agent/models.json'
	@echo "== 写入/读取测试 =="
	@docker exec pi-a sh -lc 'echo "written-by-pi-a $$(date -Is)" > /root/.pi/agent/.shared-probe'
	@docker exec pi-b sh -lc 'echo "pi-b 读到: $$(cat /root/.pi/agent/.shared-probe)"'
	@docker exec pi-a sh -lc 'rm -f /root/.pi/agent/.shared-probe'
