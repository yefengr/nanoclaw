# HostClaw — 宿主机 AI 助手架构设计文档

## Context

NanoClaw 通过容器隔离保障安全，但也因此无法操作宿主机的屏幕和 GUI 软件。本项目（暂名 HostClaw）是一个**完全独立**的个人 AI 助手，受 OpenClaw 架构启发，基于 Claude Agent SDK，运行在宿主机上，支持 computer use（截图 + GUI 操控）以及 Claude Code 的全部能力。

---

## 1. 核心设计原则

| 原则 | 说明 |
|------|------|
| **宿主机原生** | 不使用容器，直接在宿主机进程内运行 Agent SDK，天然支持 computer use |
| **Agent SDK 驱动** | 复用 Claude Agent SDK 的全部能力（Bash、文件、Web、Skills、子智能体等），不造轮子 |
| **OpenClaw 式架构** | 借鉴 Gateway / Brain / Memory / Skills / Heartbeat 五层设计 |
| **NanoClaw 式实现** | 代码模式参考 NanoClaw 的 agent-runner（query() 调用、MCP 注入、会话管理） |
| **渠道独立** | 自带消息渠道连接（WhatsApp、飞书等），不依赖 NanoClaw |

---

## 2. 系统架构

```
WhatsApp / 飞书 / Telegram / WebChat
    │
    ▼
┌──────────────────────────────────────────────────────────────┐
│  Gateway (常驻 Node.js 进程)                                  │
│                                                               │
│  ┌─────────────┐  ┌──────────────┐  ┌───────────────────┐   │
│  │  Channels    │  │  Router      │  │  Session Manager  │   │
│  │  (渠道连接)  │  │  (消息路由)   │  │  (会话/游标管理)   │   │
│  └──────┬──────┘  └──────┬───────┘  └────────┬──────────┘   │
│         │                │                    │               │
│         ▼                ▼                    ▼               │
│  ┌──────────────────────────────────────────────────────┐    │
│  │  Agent Runner (宿主机内直接调用 Agent SDK)             │    │
│  │                                                       │    │
│  │  Claude Agent SDK: query({                            │    │
│  │    prompt: AsyncIterable<Message>,                    │    │
│  │    options: {                                         │    │
│  │      allowedTools: [Bash, Read, Write, Edit, ...],    │    │
│  │      mcpServers: {                                    │    │
│  │        computer: { ... },  // 截图/鼠标/键盘          │    │
│  │      },                                               │    │
│  │      permissionMode: 'bypassPermissions',             │    │
│  │    }                                                  │    │
│  │  })                                                   │    │
│  └────────────────────────┬─────────────────────────────┘    │
│                           │ HTTP localhost:17080              │
│                           ▼                                   │
│  ┌──────────────────────────────────────────────────────┐    │
│  │  Internal API (HTTP, 仅 127.0.0.1)                    │    │
│  │  POST /send-message    ← MCP 子进程调用               │    │
│  │  POST /send-media      ← 发送媒体                     │    │
│  │  POST /schedule-task   ← 创建定时任务                  │    │
│  │  GET  /list-tasks      ← 查询任务                     │    │
│  │  POST /task/:id/pause|resume|cancel|update            │    │
│  │  POST /register-group  ← 注册新群组                    │    │
│  └──────────────────────────────────────────────────────┘    │
│                                                               │
│  ┌─────────────┐  ┌──────────────┐  ┌───────────────────┐   │
│  │  Memory      │  │  Heartbeat   │  │  Task Scheduler   │   │
│  │  (Markdown)  │  │  (定时唤醒)   │  │  (定时任务)       │   │
│  └─────────────┘  └──────────────┘  └───────────────────┘   │
└──────────────────────────────────────────────────────────────┘
```

**关键通信路径**：
- Agent SDK 启动 MCP 子进程（computer-use、hostclaw）通过 stdio 与 SDK 通信
- MCP 子进程需要操作 Gateway 功能时（发消息、管任务），通过 HTTP 调用 Internal API
- Internal API 仅监听 127.0.0.1:17080，通过 token 验证，延迟 ~1ms

---

## 3. 核心组件

### 3.1 Gateway（网关 / 主进程）

**职责**：渠道连接、消息路由、会话管理、Agent 调度

**参考**：NanoClaw `src/index.ts` + OpenClaw Gateway

**关键区别**：
- NanoClaw 的 Gateway 通过 `container-runner.ts` 在 Docker 中启动 Agent
- HostClaw 的 Gateway 在**进程内**直接调用 Agent SDK 的 `query()`
- 不需要 container-runner、credential-proxy、mount-security 等容器相关模块

```typescript
// 核心消息循环（参考 NanoClaw startMessageLoop）
async function processGroupMessages(chatJid: string, group: RegisteredGroup) {
  const messages = await db.getMessagesSince(chatJid, lastAgentTimestamp[chatJid]);
  const prompt = formatMessages(messages, TIMEZONE);

  // 直接调用 Agent SDK，无需容器
  for await (const message of query({
    prompt: messageStream,  // AsyncIterable，支持多轮注入
    options: {
      cwd: resolveGroupPath(group.folder),
      resume: sessions[group.folder],
      allowedTools: [...BUILTIN_TOOLS, 'mcp__computer__*', 'mcp__hostclaw__*'],
      mcpServers: {
        computer: computerUseMcpConfig(),
        hostclaw: hostclawMcpConfig(chatJid, group),
      },
      permissionMode: 'bypassPermissions',
      allowDangerouslySkipPermissions: true,
    }
  })) {
    handleAgentMessage(message, chatJid, group);
  }
}
```

### 3.2 Channels（渠道层）

**参考**：NanoClaw `src/channels/registry.ts` 的自注册模式

```typescript
interface Channel {
  name: string;
  connect(): Promise<void>;
  sendMessage(jid: string, text: string): Promise<void>;
  sendMedia?(jid: string, media: MediaPayload): Promise<void>;
  isConnected(): boolean;
  ownsJid(jid: string): boolean;
  disconnect(): Promise<void>;
}

// 工厂模式自注册
type ChannelFactory = (opts: ChannelOpts) => Channel | null;
registerChannel('whatsapp', createWhatsAppChannel);
registerChannel('feishu', createFeishuChannel);
```

可复用 NanoClaw 的渠道实现（WhatsApp/Baileys、飞书/Lark SDK），仅去除容器相关逻辑。

### 3.3 Agent Runner（智能体运行器）

**参考**：NanoClaw `container/agent-runner/src/index.ts`

**核心差异**：NanoClaw 的 agent-runner 运行在容器内，HostClaw 的 agent-runner 运行在主进程中。

```typescript
import { query } from '@anthropic-ai/claude-agent-sdk';

async function runAgent(input: AgentInput): Promise<AgentOutput> {
  const stream = new MessageStream();
  stream.push(input.prompt);

  let sessionId = input.sessionId;
  let result: string | null = null;

  for await (const msg of query({
    prompt: stream,
    options: {
      cwd: input.workingDir,
      resume: sessionId,
      allowedTools: [
        // Claude Code 内置工具
        'Bash', 'Read', 'Write', 'Edit', 'Glob', 'Grep',
        'WebSearch', 'WebFetch',
        'Agent',              // 子智能体
        'NotebookEdit',
        // MCP 工具
        'mcp__computer__*',   // computer use
        'mcp__hostclaw__*',   // 消息发送 / 任务管理
      ],
      mcpServers: {
        computer: {
          command: 'node',
          args: ['./mcp/computer-use.js'],
        },
        hostclaw: {
          command: 'node',
          args: ['./mcp/hostclaw.js'],
          env: {
            HOSTCLAW_API_URL: 'http://127.0.0.1:17080',
            HOSTCLAW_API_TOKEN: currentToken,
            CHAT_JID: input.chatJid,
            GROUP_FOLDER: input.groupFolder,
            IS_MAIN: input.isMain ? '1' : '0',
          },
        },
      },
      permissionMode: 'bypassPermissions',
      allowDangerouslySkipPermissions: true,
    }
  })) {
    if (msg.type === 'system' && msg.subtype === 'init') {
      sessionId = msg.session_id;
    }
    if (msg.type === 'result') {
      result = msg.result;
      // 实时回调：将结果发送给用户
      await sendToUser(input.chatJid, result);
    }
  }

  return { sessionId, result };
}
```

**并发控制**：
- 与 NanoClaw 不同，无容器隔离，需要注意：
  - Computer use 任务**必须串行**（同时只能一个 Agent 操作屏幕）
  - 普通对话任务可以并发（不同群组之间互不影响）
  - 使用队列管理，参考 NanoClaw `src/group-queue.ts`

### 3.4 MCP Server: Computer Use

**新增组件**，实现宿主机截图和 GUI 操控。

```typescript
// mcp/computer-use.ts
import { McpServer } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { exec } from 'child_process';

const server = new McpServer({ name: 'computer', version: '1.0.0' });

// 截图 — 返回 base64 图片供 Claude 分析
server.tool('screenshot', {
  description: '截取当前屏幕截图',
}, async () => {
  const tmpPath = '/tmp/hostclaw-screenshot.png';
  await execAsync(`screencapture -x ${tmpPath}`);
  const data = fs.readFileSync(tmpPath);
  return {
    content: [{
      type: 'image',
      data: data.toString('base64'),
      mimeType: 'image/png',
    }],
  };
});

// 鼠标点击
server.tool('click', {
  x: z.number().describe('X 坐标'),
  y: z.number().describe('Y 坐标'),
  button: z.enum(['left', 'right', 'double']).default('left'),
}, async ({ x, y, button }) => {
  const cmd = button === 'double' ? `dc:${x},${y}` :
              button === 'right' ? `rc:${x},${y}` : `c:${x},${y}`;
  await execAsync(`cliclick ${cmd}`);
  return { content: [{ type: 'text', text: `Clicked ${button} at (${x}, ${y})` }] };
});

// 键盘输入
server.tool('type', {
  text: z.string().describe('要输入的文本'),
}, async ({ text }) => {
  await execAsync(`cliclick t:"${escapeShell(text)}"`);
  return { content: [{ type: 'text', text: `Typed: ${text}` }] };
});

// 按键（快捷键）
server.tool('key', {
  key: z.string().describe('按键名称，如 return, tab, escape, cmd+c'),
}, async ({ key }) => {
  await execAsync(`cliclick kp:${key}`);
  return { content: [{ type: 'text', text: `Pressed: ${key}` }] };
});

// 列出窗口
server.tool('list_windows', {}, async () => {
  const result = await execAsync(`osascript -e '
    tell application "System Events"
      set windowList to {}
      repeat with proc in (every process whose visible is true)
        set end of windowList to name of proc
      end repeat
      return windowList
    end tell
  '`);
  return { content: [{ type: 'text', text: result }] };
});

// 激活应用
server.tool('activate_app', {
  name: z.string().describe('应用名称，如 Safari, Finder'),
}, async ({ name }) => {
  await execAsync(`osascript -e 'tell application "${name}" to activate'`);
  return { content: [{ type: 'text', text: `Activated: ${name}` }] };
});

// 执行 AppleScript
server.tool('run_applescript', {
  script: z.string().describe('AppleScript 脚本'),
}, async ({ script }) => {
  const result = await execAsync(`osascript -e '${escapeShell(script)}'`);
  return { content: [{ type: 'text', text: result }] };
});
```

**macOS 权限要求**：
- 系统偏好设置 → 隐私与安全性 → 辅助功能（Accessibility）：允许 Terminal/iTerm
- 系统偏好设置 → 隐私与安全性 → 屏幕录制（Screen Recording）：允许 Terminal/iTerm
- `brew install cliclick`

### 3.5 Internal API + MCP Client

NanoClaw 中 MCP 子进程通过文件轮询与主进程通信（~500ms 延迟）。HostClaw 改为 **localhost HTTP**，MCP 子进程直接调用主进程的 HTTP 端点（~1ms）。

#### 3.5.1 Internal API（主进程内，HTTP Server）

```typescript
// src/internal-api.ts
// 仅监听 127.0.0.1:17080，token 验证
import { createServer } from 'http';

export function startInternalApi(deps: InternalApiDeps) {
  const server = createServer(async (req, res) => {
    if (!verifyToken(req)) return res.writeHead(401).end();

    if (req.method === 'POST' && req.url === '/send-message') {
      const { chatJid, text, sender } = await readBody(req);
      await deps.sendMessage(chatJid, text, sender);
      res.writeHead(200).end(JSON.stringify({ ok: true }));
    }

    if (req.method === 'POST' && req.url === '/send-media') {
      const { chatJid, filePath, mediaType, filename } = await readBody(req);
      await deps.sendMedia(chatJid, { type: mediaType, filePath, filename });
      res.writeHead(200).end(JSON.stringify({ ok: true }));
    }

    if (req.method === 'POST' && req.url === '/schedule-task') {
      const task = await readBody(req);
      const taskId = await deps.createTask(task);
      res.writeHead(200).end(JSON.stringify({ ok: true, taskId }));
    }

    if (req.method === 'GET' && req.url === '/list-tasks') {
      const tasks = await deps.listTasks(req.headers['x-group-folder']);
      res.writeHead(200).end(JSON.stringify(tasks));
    }

    // POST /task/:id/pause, /task/:id/resume, /task/:id/cancel, /task/:id/update
    // POST /register-group
  });

  server.listen(17080, '127.0.0.1');
}
```

**安全**：
- 仅 `127.0.0.1`，外部不可访问
- 每次 Agent 启动时生成随机 token，通过环境变量传给 MCP 子进程
- 请求头 `Authorization: Bearer <token>` 验证

#### 3.5.2 MCP Server: HostClaw（MCP 子进程）

```typescript
// mcp/hostclaw.ts — MCP 工具，通过 HTTP 调用主进程
const API_URL = process.env.HOSTCLAW_API_URL!;   // http://127.0.0.1:17080
const API_TOKEN = process.env.HOSTCLAW_API_TOKEN!; // 随机 token

async function callApi(path: string, body?: object) {
  const res = await fetch(`${API_URL}${path}`, {
    method: body ? 'POST' : 'GET',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${API_TOKEN}`,
      'X-Group-Folder': process.env.GROUP_FOLDER!,
      'X-Is-Main': process.env.IS_MAIN!,
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  return res.json();
}

// send_message — 发送消息给用户
server.tool('send_message', {
  text: z.string(),
  sender: z.string().optional(),
}, async ({ text, sender }) => {
  await callApi('/send-message', { chatJid, text, sender });
  return { content: [{ type: 'text', text: 'Message sent' }] };
});

// send_media — 发送媒体文件
server.tool('send_media', { ... }, async (args) => {
  await callApi('/send-media', { chatJid, ...args });
  return { content: [{ type: 'text', text: 'Media sent' }] };
});

// schedule_task — 创建定时任务
server.tool('schedule_task', { ... }, async (args) => {
  const result = await callApi('/schedule-task', args);
  return { content: [{ type: 'text', text: `Task ${result.taskId} scheduled` }] };
});

// list_tasks, pause_task, resume_task, cancel_task, update_task
// register_group（仅主群组）
```

#### 3.5.3 Agent Runner 中的 MCP 配置

```typescript
// agent-runner.ts 中传给 Agent SDK
mcpServers: {
  computer: {
    command: 'node',
    args: ['./mcp/computer-use.js'],
  },
  hostclaw: {
    command: 'node',
    args: ['./mcp/hostclaw.js'],
    env: {
      HOSTCLAW_API_URL: 'http://127.0.0.1:17080',
      HOSTCLAW_API_TOKEN: currentToken,     // 每次启动随机生成
      CHAT_JID: input.chatJid,
      GROUP_FOLDER: input.groupFolder,
      IS_MAIN: input.isMain ? '1' : '0',
    },
  },
},
```

#### 3.5.4 对比 NanoClaw 的文件 IPC

| | NanoClaw（文件 IPC） | HostClaw（HTTP） |
|---|---|---|
| 延迟 | ~500ms（轮询间隔） | ~1ms |
| 实现 | 写 JSON 文件 + 轮询读取 | HTTP 请求/响应 |
| 可靠性 | 原子文件写入 | HTTP 事务 |
| 同步性 | 异步（fire-and-forget） | **同步**（等待响应，MCP 可拿到结果） |
| 安全 | 文件系统隔离 | Token 验证 |
| 代码量 | 多（写文件 + 轮询 + 解析） | 少（标准 HTTP） |

### 3.6 Memory（记忆系统）

**参考**：OpenClaw 文件优先 Markdown 记忆 + NanoClaw groups/ 模式

```
~/.hostclaw/
├── config.ts                    # 全局配置
├── data/
│   ├── hostclaw.db             # SQLite（消息、任务、会话）
│   └── sessions/               # Agent SDK 会话数据
│       └── {groupFolder}/
│           └── .claude/        # Claude 会话文件
├── groups/
│   ├── CLAUDE.md               # 全局记忆（所有群组共享）
│   ├── main/
│   │   └── CLAUDE.md           # 主群组记忆
│   └── {groupFolder}/
│       └── CLAUDE.md           # 各群组独立记忆
└── skills/                     # 技能文件
```

**Claude Agent SDK 自动发现**：
- SDK 从 `cwd` 向上遍历查找 `CLAUDE.md`
- 设置 `cwd: groups/{folder}/` 即可自动加载群组记忆 + 全局记忆

### 3.7 Heartbeat（心跳系统）

**参考**：OpenClaw Heartbeat

```typescript
// 定时唤醒 Agent 检查待办任务
async function heartbeat() {
  const tasks = await db.getDueTasks();
  if (tasks.length === 0) return;

  for (const task of tasks) {
    await runAgent({
      prompt: task.prompt,
      groupFolder: task.group_folder,
      chatJid: task.chat_jid,
      isScheduledTask: true,
    });
    await db.updateTaskNextRun(task.id);
  }
}

// 每 60 秒检查一次
setInterval(heartbeat, 60_000);
```

参考 NanoClaw `src/task-scheduler.ts`，支持 cron / interval / once 三种调度模式。

---

## 4. 数据流

### 4.1 用户消息 → Agent 响应

```
用户发送 WhatsApp 消息
  → Channel.onMessage(chatJid, message)
  → db.storeMessage(message)
  → messageLoop 检测到新消息
  → groupQueue.enqueue(chatJid)
  → processGroupMessages(chatJid, group)
      → db.getMessagesSince(chatJid, cursor)
      → formatMessages(messages)  →  XML 格式
      → Agent SDK query({ prompt, mcpServers: {computer, hostclaw} })
          → Agent 思考 + 工具调用
          → 如需截图：mcp__computer__screenshot（stdio）
          → 如需回复：mcp__hostclaw__send_message → HTTP → Internal API → Channel
      → result 消息
  → 更新游标 lastAgentTimestamp[chatJid]
```

### 4.2 Computer Use 流程

```
用户: "帮我打开 Safari 搜索天气"
  → Agent 收到指令
  → mcp__computer__activate_app("Safari")
  → mcp__computer__screenshot()  →  Agent 看到屏幕
  → mcp__computer__click(地址栏坐标)
  → mcp__computer__type("天气预报")
  → mcp__computer__key("return")
  → mcp__computer__screenshot()  →  确认结果
  → mcp__hostclaw__send_message → HTTP → Internal API → Channel.sendMessage
  → mcp__hostclaw__send_media  → HTTP → Internal API → Channel.sendMedia
```

### 4.3 定时任务

```
用户: "每天早上9点截图桌面发给我"
  → Agent 调用 mcp__hostclaw__schedule_task → HTTP → Internal API
  → db.createTask(cron: "0 9 * * *", prompt: "截图桌面并发送")
  → heartbeat 在 9:00 触发
  → runAgent(task.prompt)
      → mcp__computer__screenshot()
      → mcp__hostclaw__send_media(截图)
  → db.updateTaskNextRun()
```

---

## 5. 与 NanoClaw 的对比

| 模块 | NanoClaw | HostClaw | 备注 |
|------|---------|----------|------|
| `src/index.ts` | 主循环 + Agent 调度 | **复用**，去除容器相关逻辑 | 核心模式相同 |
| `src/channels/` | 渠道自注册 | **复用** | 接口完全一致 |
| `src/router.ts` | 消息格式化 | **复用** | XML 格式不变 |
| `src/db.ts` | SQLite 操作 | **复用** | Schema 基本一致 |
| `src/config.ts` | 配置 | **复用**，去除容器配置 | 简化 |
| `src/group-queue.ts` | 并发队列 | **复用**，增加 computer use 串行约束 | 微调 |
| `src/task-scheduler.ts` | 定时任务 | **复用** | 不变 |
| `src/types.ts` | 类型定义 | **复用**，去除 ContainerConfig | 简化 |
| `src/container-runner.ts` | 容器启动 | **替换**为进程内 Agent SDK 调用 | 核心差异 |
| `src/credential-proxy.ts` | 凭证代理 | **删除**，直接用环境变量 | 不需要 |
| `src/mount-security.ts` | 挂载安全 | **删除** | 无容器 |
| `src/container-runtime.ts` | Docker 运行时 | **删除** | 无容器 |
| `src/ipc.ts` | 文件轮询 IPC | **替换**为 `internal-api.ts`（HTTP） | 延迟从 500ms 降至 1ms |
| `container/` | 容器构建 + agent-runner | **删除**，agent-runner 逻辑移入主进程 | 核心差异 |
| `mcp/computer-use.ts` | 不存在 | **新增** | 核心新功能 |
| `src/internal-api.ts` | 不存在 | **新增**，HTTP API 供 MCP 子进程调用 | 替代文件 IPC |

---

## 6. 项目结构

```
hostclaw/
├── src/
│   ├── index.ts               # Gateway 主进程入口
│   ├── agent-runner.ts        # Agent SDK 封装（参考 NanoClaw agent-runner）
│   ├── internal-api.ts        # HTTP API（MCP 子进程 → 主进程通信）
│   ├── channels/
│   │   ├── registry.ts        # 渠道自注册（复用 NanoClaw）
│   │   ├── index.ts           # 渠道 barrel
│   │   ├── whatsapp.ts        # WhatsApp 渠道
│   │   └── feishu.ts          # 飞书渠道
│   ├── router.ts              # 消息格式化 / 出站路由
│   ├── group-queue.ts         # 并发队列 + computer use 串行
│   ├── task-scheduler.ts      # Heartbeat / 定时任务
│   ├── db.ts                  # SQLite
│   ├── config.ts              # 配置
│   ├── types.ts               # 类型定义
│   └── logger.ts              # 日志
├── mcp/
│   ├── computer-use.ts        # Computer Use MCP Server（截图/鼠标/键盘）
│   └── hostclaw.ts            # HostClaw MCP Server（通过 HTTP 调 Internal API）
├── groups/
│   ├── CLAUDE.md              # 全局记忆
│   └── main/
│       └── CLAUDE.md          # 主群组记忆
├── package.json
├── tsconfig.json
├── .env.example
└── launchd/
    └── com.hostclaw.plist     # macOS 后台服务
```

---

## 7. 依赖

```json
{
  "dependencies": {
    "@anthropic-ai/claude-agent-sdk": "latest",
    "@modelcontextprotocol/sdk": "latest",
    "better-sqlite3": "^11.0.0",
    "pino": "^9.0.0",
    "cron-parser": "^5.0.0"
  },
  "devDependencies": {
    "typescript": "^5.7.0",
    "vitest": "^4.0.0"
  }
}
```

渠道依赖按需添加：
- WhatsApp: `baileys`, `@hapi/boom`
- 飞书: `@larksuiteoapi/node-sdk`
- Telegram: `grammy`

系统工具：
- `brew install cliclick`（鼠标/键盘控制）
- macOS 辅助功能 + 屏幕录制权限

---

## 8. 安全考量

由于 Agent 直接运行在宿主机上，安全模型与 NanoClaw 完全不同：

| 风险 | 缓解措施 |
|------|---------|
| Agent 可执行任意宿主机命令 | 限制 `allowedTools`；CLAUDE.md 中设定行为边界 |
| API 密钥暴露 | `.env` 文件权限 600；不提交到 git |
| 消息渠道认证 | 仅监听 localhost；渠道使用标准 auth |
| Computer use 误操作 | CLAUDE.md 中设定操作规范；关键操作前要求确认 |
| 多用户场景 | 群组隔离（不同 cwd + 独立会话） |

**核心权衡**：放弃容器隔离换取宿主机全部能力。安全依赖于：
1. Agent SDK 的 `allowedTools` 白名单
2. CLAUDE.md 中的行为规范（软约束）
3. MCP 工具内的参数校验（硬约束）

---

## 9. 实施计划

### Phase 1: 骨架（可运行的最小系统）
1. 初始化项目（package.json、tsconfig、目录结构）
2. 实现 `config.ts`、`types.ts`、`logger.ts`
3. 实现 `db.ts`（SQLite schema + 基本 CRUD）
4. 实现 `internal-api.ts`（HTTP Server，send_message 端点）
5. 实现 `mcp/hostclaw.ts`（MCP 工具，通过 HTTP 调 Internal API）
6. 实现 `agent-runner.ts`（Agent SDK query() 封装 + MCP 注入）
7. 实现 `src/index.ts` 最小版（CLI 输入 → Agent → 终端输出）
8. **验证**：终端输入一个问题，Agent 回答

### Phase 2: Computer Use
1. 实现 `mcp/computer-use.ts`（screenshot、click、type、key）
2. 注册到 agent-runner 的 mcpServers
3. **验证**：终端指令 "截图当前屏幕" → 返回截图描述

### Phase 3: 渠道接入
1. 实现 `channels/registry.ts`（自注册模式）
2. 移植一个渠道（WhatsApp 或飞书）
3. 实现 `router.ts`（消息格式化 + 出站路由）
4. 实现 `group-queue.ts`（并发控制）
5. 完善 `src/index.ts`（消息循环 + 渠道路由）
6. **验证**：从消息渠道发消息 → Agent 回复

### Phase 4: 任务调度 + 心跳
1. 实现 `task-scheduler.ts`
2. 完善 `mcp/hostclaw.ts`（schedule_task 等任务工具）
3. **验证**：创建定时任务 → 按时执行

### Phase 5: 产品化
1. launchd 后台服务配置
2. 会话管理（resume / 多轮对话）
3. 全局记忆 + 群组记忆
4. 测试

---

## 10. 关键文件参考（从 NanoClaw 复用的模式）

| NanoClaw 文件 | 复用内容 |
|---------------|---------|
| `src/index.ts` | 消息循环、状态管理、启动恢复 |
| `src/channels/registry.ts` | Channel 接口 + ChannelFactory 自注册 |
| `src/router.ts` | formatMessages()、findChannel()、stripInternalTags() |
| `src/db.ts` | SQLite schema（messages、scheduled_tasks、sessions、registered_groups） |
| `src/group-queue.ts` | GroupState 状态机、enqueueMessageCheck、并发控制 |
| `src/task-scheduler.ts` | computeNextRun()、startSchedulerLoop()、cron/interval/once |
| `src/types.ts` | Channel、RegisteredGroup、NewMessage、ScheduledTask、MediaPayload |
| `src/config.ts` | 配置常量模式 |
| `container/agent-runner/src/index.ts` | query() 调用模式、MessageStream、会话恢复、消息类型处理 |
| `container/agent-runner/src/ipc-mcp-stdio.ts` | MCP 工具定义（send_message 等），改为 HTTP 调用 |
