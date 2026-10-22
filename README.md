# pi-cluster

用两个 pi agent 容器共享同一份 pi 上下文存储（`~/.pi`），验证"同一个 session 被两个 agent 同时提问"会发生什么。

OrbStack 本地起两个容器 `pi-a` / `pi-b`，挂在同一个 `pi-agent-home` 卷上，session 目录是同一份。

## 结论

**两个 agent 同时用同一个 session 提问，不会报错，最后写入者胜利。**

- 两边都能正常跑完，各自拿到完整的模型回复，没有任何锁冲突或异常退出。
- session 文件是追加写的 jsonl，两个进程各自从同一份历史出发、各自追加自己的那一轮。
- 后写入的那一轮成为文件末尾，后续 `pi -c` 恢复时看到的就是它；先写入的那一轮留在文件里，但已经不在对话主干上。
- 也就是说不会丢数据、不会崩，但会得到一份"分叉后又合并"的历史：两条并行的提问都躺在同一个文件里，谁都不是在对方的上下文之上继续的。

如果要自己控制并发（串行化、拒绝第二个写入者、或者分叉成两个独立 session），需要自定义 session manager。pi 只对 `settings.json` 做了 mkdir 锁，session 文件本身没有写锁。

## 结构

```
pi-cluster/
├── Dockerfile            # node:24 + @earendil-works/pi-coding-agent
├── docker-compose.yml    # pi-a / pi-b 两个容器
├── Makefile              # 启动、进容器、注入配置、验证
├── config/models.json    # 自定义 provider 模板，make config 按 .env 覆写后灌进卷
├── .env                  # 端点 / 密钥 / 模型（gitignore）
└── .env.example
```

两个容器都是常驻进程（`sleep infinity`），交互时用 `docker exec` 进 TUI。这样容器一直活着，`pi-a` 里开的会话在 `pi-b` 里能直接接上。

## 卷

| 卷名 | 挂载点 | 作用 |
| --- | --- | --- |
| `pi-agent-home` | `/root/.pi`（两个容器同一个） | sessions、auth、settings、extensions、npm 缓存 |
| `pi-agent-workspace` | `/workspace`（两个容器同一个） | 共享代码目录 |

`pi-agent-home` 就是"上下文存储"。pi 把会话写到 `$PI_CODING_AGENT_DIR/sessions/<cwd 编码>/`，配置和凭据在同一层。两个容器挂同一个卷、同一个 `working_dir`，所以：

- `pi-a` 里 `pi "重构 auth 模块"`，`pi-b` 里 `pi -c` 能接着这个会话继续；
- `pi-b` 里 `pi -r` 能看到 `pi-a` 产生的会话列表；
- 扩展、模型配置、登录凭据装一次两边都有。

工作区必须共享，不能省。会话目录名是按 cwd 编码的（例如 `/workspace` → `--workspace--`），cwd 不同就落在不同目录，等于没共享。

## 用法

```bash
cd pi-cluster
cp .env.example .env    # 首次：填 DEEPSEEK_API_KEY
make up                 # 构建镜像、启动 pi-a / pi-b、写入模型配置
make shell-a            # 进 pi-a 的 TUI
make shell-b            # 进 pi-b 的 TUI
make check              # 验证两个容器挂同一个卷、配置一致、能互相读文件
make exec-a CMD='pi -p "列出当前目录"'
make down               # 停容器，保留数据
make reset              # 停容器并删除两个卷
```

`.env` 是唯一配置来源，`Makefile` 直接 `include` 它，`docker compose` 也读同一份。

## 模型配置

默认接 DeepSeek 的 Anthropic 兼容端点：

| 变量 | 值 |
| --- | --- |
| `DEEPSEEK_BASE_URL` | `https://api.deepseek.com/anthropic` |
| `DEEPSEEK_API_KEY` | 你的 key |
| `DEEPSEEK_MODEL` | `deepseek-v4-flash` |
| `DEEPSEEK_PROVIDER` | `deepseek-anthropic` |

`make config` 做两件事：

1. 把 `config/models.json` 按 `.env` 覆写 provider / baseUrl / model 后写进共享卷的 `/root/.pi/agent/models.json`；
2. 用 jq 把 `defaultProvider` / `defaultModel` 合并进 `settings.json`，所以直接 `pi` 就是这个模型，不用带参数。

**baseUrl 不能带 `/v1`。** pi 走 Anthropic SDK，请求路径由 SDK 补成 `<baseUrl>/v1/messages`。写成 `https://api.deepseek.com/anthropic/v1` 会打到 `/anthropic/v1/v1/messages`，直接 404。Anthropic SDK 原生客户端要求带 `/v1`，pi 相反，这是最容易踩的一脚。

`apiKey` 用 `$DEEPSEEK_API_KEY` 引用环境变量，密钥只在 `.env` 里，不进 `models.json`。

要换成别的 Anthropic 兼容服务：改 `.env` 里的 baseUrl / model / provider 名，`make config` 重新注入即可，不用重建镜像。

## 并发写同一个 session

结论在上面：不报错，最后写入者胜利，历史分叉。要避免就按下面来：

- 串行交接：`pi-a` 那一轮跑完退出后，再在 `pi-b` 里 `pi -c`。
- 或者各自开新会话并行跑，session 文件互相独立，没有这个问题。
- `settings.json` 用 mkdir 锁（proper-lockfile）。两边同时改设置（装扩展、切模型）可能撞锁，遇到 `EEXIST ... settings.json.lock` 就等几秒，或删掉残留锁目录。
- 要真正控制并发（第二个写入者排队、拒绝、或自动分叉成新 session），只能自定义 session manager。

## 已验证

2026-10-22 在 OrbStack 上实跑过：

- `pi-a` 里 `pi -p "用 bash 工具执行 echo pi-a-ok"` → 返回 `pi-a-ok`，说明模型连通、bash 工具可用；
- `pi-b` 里 `pi -c "刚才 pi-a 执行的命令输出是什么"` → 答 `pi-a-ok`，说明会话文件确实被两个容器共用；
- `make check` 从 `pi-b` 读到的 `models.json` / `settings.json` 与 `pi-a` 写入的一致。

## 镜像版本

`PI_VERSION` 默认 `0.85.1`，与宿主 `pi --version` 对齐。会话格式跨版本不保证兼容，升级时两边一起升：

```bash
make up PI_VERSION=0.86.0
```

宿主 `~/.pi/agent` 里已有的老会话不会自动进容器卷。要迁移就在宿主和容器间拷 `sessions/` 子目录，注意 cwd 编码必须匹配（宿主的路径编码和 `/workspace` 对不上，通常直接搬过去看不到）。
