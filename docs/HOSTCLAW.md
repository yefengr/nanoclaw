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
| **渠道独立** | 自带消息渠道连接，不依赖 NanoClaw。当前实现飞书，Channel 接口支持扩展 |

---

## 2. 系统架构

```
飞书 (Lark)
    │
    ▼
┌──────────────────────────────────────────────────────────────┐
│  Gateway (单一 Node.js 进程，全部能力进程内完成)                 │
│                                                               │
│  ┌─────────────┐  ┌──────────────┐  ┌───────────────────┐   │
│  │  Channels    │  │  Router      │  │  V2 Sessions      │   │
│  │  (渠道连接)  │  │  (消息路由)   │  │  (send/stream)    │   │
│  └──────┬──────┘  └──────┬───────┘  └────────┬──────────┘   │
│         │                │                    │               │
│         ▼                ▼                    ▼               │
│  ┌──────────────────────────────────────────────────────┐    │
│  │  Claude Agent SDK (V2 Session API)                    │    │
│  │                                                       │    │
│  │  session = createSession({                            │    │
│  │    mcpServers: {                                      │    │
│  │      computer: createSdkMcpServer(...),  // 进程内    │    │
│  │      hostclaw: createSdkMcpServer(...),  // 进程内    │    │
│  │    },                                                 │    │
│  │  })                                                   │    │
│  │  session.send(prompt)                                 │    │
│  │  session.stream() → handleMessages()                  │    │
│  └──────────────────────────────────────────────────────┘    │
│         │                                                     │
│         │  In-process MCP 工具直接调用 Gateway 内部方法         │
│         │  (无 HTTP、无子进程、无 token、零延迟)                │
│         ▼                                                     │
│  ┌─────────────┐  ┌──────────────┐  ┌───────────────────┐   │
│  │  Memory      │  │  Heartbeat   │  │  Task Scheduler   │   │
│  │  (Markdown)  │  │  (定时唤醒)   │  │  (定时任务)       │   │
│  └─────────────┘  └──────────────┘  └───────────────────┘   │
└──────────────────────────────────────────────────────────────┘
```

**关键通信路径**：
- 所有组件运行在**同一进程**内，无进程间通信
- MCP 工具通过 `createSdkMcpServer()` 定义为进程内函数，直接调用 Gateway 方法（零延迟）
- 不需要 HTTP Server、token 验证、端口监听

---

## 3. 核心组件

### 3.1 Gateway（网关 / 主进程）

**职责**：渠道连接、消息路由、会话管理、Agent 调度、MCP 工具宿主

**参考**：NanoClaw `src/index.ts` + OpenClaw Gateway

**关键区别**：
- NanoClaw 的 Gateway 通过 `container-runner.ts` 在 Docker 中启动 Agent
- HostClaw 的 Gateway 在**进程内**直接调用 Agent SDK 的 V2 Session API
- 不需要 container-runner、credential-proxy、mount-security、internal-api 等模块
- MCP 工具通过 `createSdkMcpServer()` 在进程内定义，直接调用 Gateway 方法

```typescript
import {
  unstable_v2_createSession,
  unstable_v2_resumeSession,
  createSdkMcpServer,
  tool,
  type SDKMessage,
} from '@anthropic-ai/claude-agent-sdk';

// 核心消息循环（参考 NanoClaw startMessageLoop）
async function processGroupMessages(chatJid: string, group: RegisteredGroup) {
  const messages = pendingMessages.drain(chatJid);  // 从内存队列获取（消息不落盘）
  const prompt = formatMessages(messages, TIMEZONE);
  const debouncer = new MessageDebouncer((text) => router.sendMessage(chatJid, text));

  // 构建会话选项
  const opts = {
    // --- 模型与提示词 ---
    model: selectModel(group),
    systemPrompt: {
      type: 'preset' as const,
      preset: 'claude_code' as const,
      append: HOSTCLAW_SYSTEM_PROMPT,          // 含 computer use CLI 工具说明
    },
    settingSources: ['project' as const],

    // --- 工作目录 ---
    cwd: resolveGroupPath(group.folder),

    // --- 工具与 In-process MCP ---
    allowedTools: [...BUILTIN_TOOLS, 'mcp__computer__*', 'mcp__hostclaw__*'],
    mcpServers: {
      computer: createComputerMcp(),               // 进程内，见 3.3 节
      hostclaw: createHostclawMcp(chatJid, group), // 进程内，见 3.4 节
    },

    // --- 安全约束 ---
    permissionMode: 'bypassPermissions' as const,
    canUseTool: toolPermissionGuard,          // 路径保护 + 审计日志（见第 8 节）
    maxTurns: MAX_AGENT_TURNS,                // 200（computer use 需要更多轮次）
    maxBudgetUsd: MAX_BUDGET_PER_CALL,        // 20.0（含截图开销）
    // 不启用 sandbox — 宿主机助手需要完整的文件系统和网络访问
  };

  // 恢复已有会话 or 创建新会话
  const session = sessions[group.folder]
    ? unstable_v2_resumeSession(sessions[group.folder], opts)
    : unstable_v2_createSession(opts);

  try {
    await session.send(prompt);

    for await (const msg of session.stream()) {
      // 保存 session_id（用于下次 resume）
      if (msg.session_id) sessions[group.folder] = msg.session_id;

      // 助手文本 — 去抖后推送（避免碎片消息轰炸）
      if (msg.type === 'assistant') {
        const text = extractText(msg);
        if (text) debouncer.push(text);
      }

      // 最终结果 — 记录成本
      if (msg.type === 'result') {
        await debouncer.flush();
        await trackCost(group.folder, msg.total_cost_usd ?? 0);
        log.info({ cost: msg.total_cost_usd, turns: msg.num_turns }, 'agent completed');
      }
    }
  } catch (err) {
    log.error({ err, chatJid }, 'agent error');
    await debouncer.flush();
    await router.sendMessage(chatJid, '⚠️ 处理出错，请稍后重试');
  } finally {
    session.close();
  }
}

// 提取助手消息中的文本
function extractText(msg: SDKMessage): string {
  if (msg.type !== 'assistant') return '';
  return msg.message.content
    .filter((b: { type: string }) => b.type === 'text')
    .map((b: { text: string }) => b.text)
    .join('');
}
```

### 3.2 Channels（渠道层）

保留 Channel 接口抽象，便于未来扩展其他渠道。当前仅实现飞书。

**参考**：NanoClaw `src/channels/registry.ts`

```typescript
// src/channels/types.ts — 渠道抽象接口
export interface Channel {
  name: string;
  connect(): Promise<void>;
  sendMessage(chatId: string, text: string): Promise<void>;
  sendMedia(chatId: string, media: MediaPayload): Promise<void>;
  isConnected(): boolean;
  ownsChat(chatId: string): boolean;
  disconnect(): Promise<void>;
  onMessage: (chatId: string, message: NewMessage) => void;
}
```

```typescript
// src/channels/feishu.ts — 当前唯一实现
import * as lark from '@larksuiteoapi/node-sdk';
import type { Channel } from './types.js';

export function createFeishuChannel(config: FeishuConfig): Channel {
  const client = new lark.Client({
    appId: config.appId,
    appSecret: config.appSecret,
  });

  // WebSocket 长连接 — 无需公网 URL
  const wsClient = new lark.WSClient({
    appId: config.appId,
    appSecret: config.appSecret,
    eventDispatcher: new lark.EventDispatcher({}).register({
      'im.message.receive_v1': async (data) => {
        const msg = parseFeishuMessage(data);
        if (msg) channel.onMessage(msg.chatId, msg);
      },
    }),
  });

  const channel: Channel = {
    name: 'feishu',
    async connect() { await wsClient.start(); },
    async sendMessage(chatId, text) {
      await client.im.message.create({
        data: { receive_id: chatId, msg_type: 'text', content: JSON.stringify({ text }) },
        params: { receive_id_type: 'chat_id' },
      });
    },
    async sendMedia(chatId, media) { /* 上传文件 + 发送 */ },
    isConnected() { return wsClient.isConnected(); },
    ownsChat(chatId) { return true; },  // 单渠道，所有 chat 都归属飞书
    async disconnect() { wsClient.stop(); },
    onMessage: () => {},
  };

  return channel;
}
```

```typescript
// src/channels/index.ts — 渠道初始化（未来扩展时在此添加）
export function initChannels(config: Config): Channel[] {
  const channels: Channel[] = [];
  if (config.feishu) channels.push(createFeishuChannel(config.feishu));
  // 未来：if (config.telegram) channels.push(createTelegramChannel(config.telegram));
  return channels;
}
```

**飞书应用配置要求**：
- 创建企业自建应用，获取 App ID + App Secret
- 开启「接收消息」事件订阅
- 添加机器人能力
- 授权：`im:message`、`im:message:send_as_read`、`im:resource`

### 3.3 In-process MCP: Computer Use（截图）

**进程内 MCP Server**，仅保留 `screenshot` 工具（需要返回 image 类型）。鼠标/键盘/AppleScript 操作由 Agent 通过 Bash + `cliclick`/`osascript` 完成（见 systemPrompt 配置）。

```typescript
// src/mcp-computer.ts — 进程内 MCP，无子进程
import { createSdkMcpServer, tool } from '@anthropic-ai/claude-agent-sdk';
import { z } from 'zod';
import { execAsync } from './utils.js';
import fs from 'fs';

export function createComputerMcp() {
  return createSdkMcpServer({
    name: 'computer',
    version: '1.0.0',
    tools: [
      tool(
        'screenshot',
        '截取当前屏幕截图，返回图片供分析。鼠标/键盘操作请直接使用 Bash 工具调用 cliclick/osascript',
        {
          display: z.number().optional().describe('显示器编号，默认主显示器'),
        },
        async (args) => {
          const tmpPath = '/tmp/hostclaw-screenshot.png';
          const displayFlag = args.display ? `-D ${args.display}` : '';
          await execAsync(`screencapture -x ${displayFlag} ${tmpPath}`);
          const data = fs.readFileSync(tmpPath);
          return {
            content: [{
              type: 'image' as const,
              data: data.toString('base64'),
              mimeType: 'image/png',
            }],
          };
        }
      ),
    ],
  });
}
```

**鼠标/键盘/窗口操作**通过 systemPrompt 指导 Agent 使用 Bash：

```typescript
// src/config.ts
export const HOSTCLAW_SYSTEM_PROMPT = `
## Computer Use
你可以操控宿主机屏幕。截图使用 mcp__computer__screenshot 工具，其余操作通过 Bash：
- 鼠标点击：cliclick c:X,Y（左键）、rc:X,Y（右键）、dc:X,Y（双击）
- 鼠标移动：cliclick m:X,Y
- 键盘输入：cliclick t:"文本"
- 按键/快捷键：cliclick kp:return、kp:tab、kp:escape
- 组合键：cliclick kd:cmd kp:c ku:cmd（Cmd+C）
- 激活应用：osascript -e 'tell application "Safari" to activate'
- 列出窗口：osascript -e 'tell application "System Events" to get name of every process whose visible is true'
- AppleScript：osascript -e '脚本内容'

操作流程：先截图观察 → 确定坐标 → 执行操作 → 再截图确认结果。
`;
```

**macOS 权限要求**：
- 系统偏好设置 → 隐私与安全性 → 辅助功能（Accessibility）：允许 Terminal/iTerm
- 系统偏好设置 → 隐私与安全性 → 屏幕录制（Screen Recording）：允许 Terminal/iTerm
- `brew install cliclick`

**并发控制**：
- Computer use 任务**必须串行**（同时只能一个 Agent 操作屏幕）
- 普通对话任务可以并发（不同群组之间互不影响）
- 使用队列管理，参考 NanoClaw `src/group-queue.ts`

### 3.4 In-process MCP: HostClaw（消息/任务）

**进程内 MCP Server**，工具 handler 直接调用 Gateway 内部方法，无需 HTTP 或子进程。

```typescript
// src/mcp-hostclaw.ts — 进程内 MCP，直接访问 Gateway 功能
import { createSdkMcpServer, tool } from '@anthropic-ai/claude-agent-sdk';
import { z } from 'zod';
import type { Router, TaskScheduler, RegisteredGroup } from './types.js';

export function createHostclawMcp(
  chatJid: string,
  group: RegisteredGroup,
  deps: { router: Router; taskScheduler: TaskScheduler; store: JsonStore },
) {
  return createSdkMcpServer({
    name: 'hostclaw',
    version: '1.0.0',
    tools: [
      // 发送消息 — 直接调用 router，零延迟
      tool('send_message', '发送消息给用户', {
        text: z.string().describe('消息文本'),
        sender: z.string().optional().describe('发送者名称'),
      }, async (args) => {
        await deps.router.sendMessage(chatJid, args.text, args.sender);
        return { content: [{ type: 'text', text: 'Message sent' }] };
      }),

      // 发送媒体 — 直接调用 router
      tool('send_media', '发送媒体文件', {
        filePath: z.string().describe('文件路径'),
        mediaType: z.enum(['image', 'audio', 'video', 'document']),
        filename: z.string().optional(),
      }, async (args) => {
        await deps.router.sendMedia(chatJid, args);
        return { content: [{ type: 'text', text: 'Media sent' }] };
      }),

      // 创建定时任务 — 直接调用 taskScheduler
      tool('schedule_task', '创建定时任务', {
        prompt: z.string().describe('任务执行时的提示词'),
        cron: z.string().optional().describe('Cron 表达式，如 "0 9 * * *"'),
        interval: z.number().optional().describe('间隔秒数'),
        once: z.string().optional().describe('一次性执行时间，ISO 8601'),
      }, async (args) => {
        const taskId = await deps.taskScheduler.createTask({
          ...args, chatJid, groupFolder: group.folder,
        });
        return { content: [{ type: 'text', text: `Task ${taskId} scheduled` }] };
      }),

      // 查询任务列表
      tool('list_tasks', '查询当前群组的定时任务', {}, async () => {
        const tasks = deps.store.getTasksByGroup(group.folder);
        return { content: [{ type: 'text', text: JSON.stringify(tasks, null, 2) }] };
      }),

      // 暂停/恢复/取消任务
      tool('manage_task', '管理定时任务', {
        taskId: z.number(),
        action: z.enum(['pause', 'resume', 'cancel']),
      }, async (args) => {
        await deps.taskScheduler[args.action](args.taskId);
        return { content: [{ type: 'text', text: `Task ${args.taskId} ${args.action}d` }] };
      }),

      // 注册新群组（仅主群组可用）
      ...(group.isMain ? [
        tool('register_group', '注册新群组', {
          chatJid: z.string(),
          folder: z.string(),
          name: z.string(),
        }, async (args) => {
          deps.store.registerGroup(args);
          return { content: [{ type: 'text', text: `Group ${args.name} registered` }] };
        }),
      ] : []),
    ],
  });
}
```

### 3.5 对比 NanoClaw 的通信架构

| | NanoClaw（文件 IPC） | HostClaw 原方案（HTTP） | HostClaw 优化后（In-process） |
|---|---|---|---|
| 延迟 | ~500ms（轮询间隔） | ~1ms | **~0ms**（函数调用） |
| 进程数 | 3+（主进程 + 容器 + MCP） | 3（主进程 + 2 MCP 子进程） | **1**（单进程） |
| 实现 | 写 JSON 文件 + 轮询读取 | HTTP 请求/响应 | **直接函数调用** |
| 安全 | 文件系统隔离 | Token 验证 | **进程内，无需认证** |
| 代码量 | 多 | 中 | **少** |
| 依赖 | 无 | HTTP Server | **无**（SDK 内置） |

### 3.6 MessageDebouncer（消息去抖）

Agent 在单次 query 中可能产生多个 `assistant` 消息（工具调用前后各一个），直接推送会导致用户收到大量碎片消息。通过去抖合并：

```typescript
// src/message-debouncer.ts
export class MessageDebouncer {
  private buffer = '';
  private timer: NodeJS.Timeout | null = null;

  constructor(
    private send: (text: string) => Promise<void>,
    private delay = 500,  // 500ms 内的文本合并为一条消息
  ) {}

  push(text: string) {
    this.buffer += text;
    if (this.timer) clearTimeout(this.timer);
    this.timer = setTimeout(() => this.flush(), this.delay);
  }

  async flush() {
    if (this.timer) { clearTimeout(this.timer); this.timer = null; }
    if (this.buffer) {
      const text = this.buffer;
      this.buffer = '';
      await this.send(text);
    }
  }
}
```

### 3.7 Memory（记忆系统）

**参考**：OpenClaw 文件优先 Markdown 记忆 + NanoClaw groups/ 模式

```
~/.hostclaw/
├── config.ts                    # 全局配置
├── data/
│   ├── tasks.json              # 定时任务
│   ├── sessions.json           # 会话 ID 映射（group → session_id）
│   ├── groups.json             # 群组注册信息
│   └── costs/                  # 成本记录（按月）
│       └── 2026-03.json        # 月度成本明细
├── groups/
│   ├── CLAUDE.md               # 全局记忆（所有群组共享）
│   ├── main/
│   │   └── CLAUDE.md           # 主群组记忆
│   └── {groupFolder}/
│       └── CLAUDE.md           # 各群组独立记忆
└── skills/                     # 技能文件
```

**持久化方案**：纯 JSON 文件，零外部依赖。消息不落盘（直接从飞书事件获取），任务/会话/群组各一个 JSON 文件，成本按月存储。

```typescript
// src/store.ts — JSON 文件持久化（替代 SQLite）
import fs from 'fs';
import path from 'path';

const DATA_DIR = path.join(process.env.HOME!, '.hostclaw', 'data');

export class JsonStore {
  private cache = new Map<string, any>();

  private read<T>(file: string, fallback: T): T {
    if (this.cache.has(file)) return this.cache.get(file);
    const filePath = path.join(DATA_DIR, file);
    try {
      const data = JSON.parse(fs.readFileSync(filePath, 'utf-8'));
      this.cache.set(file, data);
      return data;
    } catch {
      return fallback;
    }
  }

  private write(file: string, data: any): void {
    const filePath = path.join(DATA_DIR, file);
    fs.mkdirSync(path.dirname(filePath), { recursive: true });
    fs.writeFileSync(filePath, JSON.stringify(data, null, 2));
    this.cache.set(file, data);
  }

  // --- 群组 ---
  getRegisteredGroups(): RegisteredGroup[] { return this.read('groups.json', []); }
  registerGroup(group: RegisteredGroup) {
    const groups = this.getRegisteredGroups();
    groups.push(group);
    this.write('groups.json', groups);
  }

  // --- 定时任务 ---
  getTasks(): ScheduledTask[] { return this.read('tasks.json', []); }
  getTasksByGroup(folder: string) { return this.getTasks().filter(t => t.groupFolder === folder); }
  getDueTasks(): ScheduledTask[] {
    const now = Date.now();
    return this.getTasks().filter(t => t.status === 'active' && t.nextRunAt <= now);
  }
  createTask(task: ScheduledTask): number {
    const tasks = this.getTasks();
    task.id = tasks.length ? Math.max(...tasks.map(t => t.id)) + 1 : 1;
    tasks.push(task);
    this.write('tasks.json', tasks);
    return task.id;
  }
  updateTaskNextRun(taskId: number) {
    const tasks = this.getTasks();
    const task = tasks.find(t => t.id === taskId);
    if (task) { task.nextRunAt = computeNextRun(task); this.write('tasks.json', tasks); }
  }

  // --- 会话 ---
  getSessions(): Record<string, string> { return this.read('sessions.json', {}); }
  saveSession(folder: string, sessionId: string) {
    const sessions = this.getSessions();
    sessions[folder] = sessionId;
    this.write('sessions.json', sessions);
  }

  // --- 成本 ---
  recordCost(folder: string, cost: number, date: Date) {
    const month = `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}`;
    const file = `costs/${month}.json`;
    const records: CostRecord[] = this.read(file, []);
    records.push({ folder, cost, timestamp: date.toISOString() });
    this.write(file, records);
  }
  getDailyCost(date: Date): number {
    const month = `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}`;
    const day = date.toISOString().slice(0, 10);
    const records: CostRecord[] = this.read(`costs/${month}.json`, []);
    return records.filter(r => r.timestamp.startsWith(day)).reduce((sum, r) => sum + r.cost, 0);
  }
}
```

**Claude Agent SDK 记忆加载**：
- SDK **默认不加载**任何文件系统设置，必须显式配置 `settingSources: ['project']`
- 配置后，SDK 从 `cwd` 向上遍历查找 `CLAUDE.md`
- 设置 `cwd: groups/{folder}/` + `settingSources: ['project']` 即可自动加载群组记忆 + 全局记忆
- 目录结构设计使得群组级 `CLAUDE.md` 先加载，再向上遍历到全局 `CLAUDE.md`，实现记忆继承

### 3.8 Heartbeat（心跳系统）

**参考**：OpenClaw Heartbeat

```typescript
// 定时唤醒 Agent 检查待办任务
async function heartbeat() {
  const tasks = store.getDueTasks();
  if (tasks.length === 0) return;

  for (const task of tasks) {
    await runAgent({
      prompt: task.prompt,
      groupFolder: task.group_folder,
      chatJid: task.chat_jid,
      isScheduledTask: true,
    });
    store.updateTaskNextRun(task.id);
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
用户发送飞书消息
  → feishu.onMessage(chatId, message)
  → pendingMessages.push(chatId, message)  // 内存队列，不落盘
  → groupQueue.enqueue(chatId)
  → processGroupMessages(chatId, group)
      → pendingMessages.drain(chatId)      // 取出并清空该群消息
      → formatMessages(messages)  →  XML 格式
      → session.send(prompt)
      → session.stream() 逐条处理：
          → Agent 思考 + 工具调用
          → 如需截图：mcp__computer__screenshot（进程内）
          → 如需回复：mcp__hostclaw__send_message → 直接调用 router（进程内）
          → assistant 消息 → MessageDebouncer 去抖推送
      → result 消息 → trackCost()
  → 更新游标 lastAgentTimestamp[chatJid]
```

### 4.2 Computer Use 流程

```
用户: "帮我打开 Safari 搜索天气"
  → Agent 收到指令
  → Bash: osascript -e 'tell application "Safari" to activate'
  → mcp__computer__screenshot()  →  Agent 看到屏幕（进程内）
  → Bash: cliclick c:地址栏X,Y
  → Bash: cliclick t:"天气预报"
  → Bash: cliclick kp:return
  → mcp__computer__screenshot()  →  确认结果（进程内）
  → mcp__hostclaw__send_message → 直接调用 router（进程内）
```

### 4.3 定时任务

```
用户: "每天早上9点截图桌面发给我"
  → Agent 调用 mcp__hostclaw__schedule_task → 直接调用 taskScheduler（进程内）
  → store.createTask(cron: "0 9 * * *", prompt: "截图桌面并发送")
  → heartbeat 在 9:00 触发
  → session.send(task.prompt)
      → mcp__computer__screenshot()（进程内）
      → mcp__hostclaw__send_media → 直接调用 router（进程内）
  → store.updateTaskNextRun()
```

---

## 5. 与 NanoClaw 的对比

| 模块 | NanoClaw | HostClaw | 备注 |
|------|---------|----------|------|
| `src/index.ts` | 主循环 + Agent 调度 | **复用**，去除容器逻辑，改用 V2 Session API | 核心模式相同 |
| `src/channels/` | 渠道自注册 | **复用** Channel 接口，当前仅实现飞书 | 保留抽象，简化实现 |
| `src/router.ts` | 消息格式化 | **复用** | XML 格式不变 |
| `src/db.ts` | SQLite 操作 | **替换** → `store.ts`（JSON 文件） | 零依赖，消息不落盘 |
| `src/config.ts` | 配置 | **复用**，去除容器配置，增加安全/模型常量 | 简化 + 扩展 |
| `src/group-queue.ts` | 并发队列 | **复用**，增加 computer use 串行约束 | 微调 |
| `src/task-scheduler.ts` | 定时任务 | **复用** | 不变 |
| `src/types.ts` | 类型定义 | **复用**，去除 ContainerConfig | 简化 |
| `src/container-runner.ts` | 容器启动 | **删除**，V2 Session 直接在 Gateway 中调用 | 核心差异 |
| `src/credential-proxy.ts` | 凭证代理 | **删除**，直接用环境变量 | 不需要 |
| `src/mount-security.ts` | 挂载安全 | **删除** | 无容器 |
| `src/container-runtime.ts` | Docker 运行时 | **删除** | 无容器 |
| `src/ipc.ts` | 文件轮询 IPC | **删除**，改为 in-process MCP（零延迟） | 核心差异 |
| `container/` | 容器构建 + agent-runner | **删除** | 无容器 |
| `src/mcp-computer.ts` | 不存在 | **新增**，进程内 screenshot MCP | 核心新功能 |
| `src/mcp-hostclaw.ts` | 不存在 | **新增**，进程内消息/任务 MCP | 替代文件 IPC |
| `src/safety.ts` | 不存在 | **新增**，canUseTool 权限回调 | 安全层 |
| `src/message-debouncer.ts` | 不存在 | **新增**，消息去抖推送 | 用户体验 |

---

## 6. 项目结构

```
hostclaw/
├── src/
│   ├── index.ts               # Gateway 主进程入口（V2 Session + 消息循环）
│   ├── mcp-computer.ts        # Computer Use MCP（进程内，仅 screenshot）
│   ├── mcp-hostclaw.ts        # HostClaw MCP（进程内，消息/任务/群组管理）
│   ├── message-debouncer.ts   # 消息去抖推送
│   ├── channels/
│   │   ├── types.ts           # Channel 接口定义
│   │   ├── index.ts           # 渠道初始化
│   │   └── feishu.ts          # 飞书渠道（当前唯一实现）
│   ├── router.ts              # 消息格式化 / 出站路由
│   ├── group-queue.ts         # 并发队列 + computer use 串行
│   ├── task-scheduler.ts      # Heartbeat / 定时任务
│   ├── store.ts               # JSON 文件持久化（任务/会话/群组/成本）
│   ├── safety.ts              # canUseTool 权限回调 + 危险命令拦截
│   ├── config.ts              # 配置（安全常量、模型选择、systemPrompt）
│   ├── types.ts               # 类型定义
│   ├── utils.ts               # 工具函数（execAsync 等）
│   └── logger.ts              # 日志
├── groups/
│   ├── CLAUDE.md              # 全局记忆
│   └── main/
│       └── CLAUDE.md          # 主群组记忆
├── tests/
│   ├── unit/                  # 纯逻辑单元测试
│   ├── integration/           # mock 外部依赖的集成测试
│   ├── smoke/                 # 真实 API 冒烟测试
│   └── helpers/               # 测试工具（fixtures, mocks）
├── vitest.config.ts
├── package.json
├── tsconfig.json
├── .env.example
└── launchd/
    └── com.hostclaw.plist     # macOS 后台服务
```

**与优化前对比**：删除了 `agent-runner.ts`、`internal-api.ts`、`mcp/` 目录（共 4 个文件），MCP 工具移入 `src/` 作为进程内模块。

---

## 7. 依赖

```json
{
  "engines": { "node": ">=22.0.0" },
  "dependencies": {
    "@anthropic-ai/claude-agent-sdk": "^0.2.76",
    "@larksuiteoapi/node-sdk": "^1.59.0",
    "pino": "^10.3.0",
    "cron-parser": "^5.5.0",
    "zod": "^4.3.0"
  },
  "devDependencies": {
    "typescript": "^5.9.0",
    "vitest": "^4.1.0"
  }
}
```

> 注：`@modelcontextprotocol/sdk` 不再需要。In-process MCP 通过 Agent SDK 内置的 `createSdkMcpServer()` + `tool()` 实现，`zod` 用于工具参数校验。Zod v4 与 v3 API 基本兼容，`z.string()`/`z.number()`/`z.enum()` 等用法不变。

系统工具：
- `brew install cliclick`（鼠标/键盘控制）
- macOS 辅助功能 + 屏幕录制权限

---

## 8. 安全考量

由于 Agent 直接运行在宿主机上，安全模型与 NanoClaw 完全不同。HostClaw 采用**三层纵深防御**：

### 8.1 安全设计理念

HostClaw 是**个人 AI 助手**，需要宿主机全部操控能力。安全策略采用**保护关键路径**而非**禁止命令**的模式：

- 不禁止 `sudo`、`killall`、`rm -rf` 等命令本身
- 而是保护**不可恢复的系统关键路径**（如 `/System`、SSH 私钥）
- Agent 可以自由执行日常操作（安装软件、管理进程、清理文件）
- 只在操作可能导致**系统不可用或凭证泄露**时拦截

```
┌─────────────────────────────────────────────────┐
│  Layer 1: 硬约束（编程式，不可绕过）                │
│  ├── canUseTool 路径保护（保护关键系统路径）        │
│  ├── maxTurns / maxBudgetUsd（防失控）            │
│  ├── allowedTools 白名单                         │
│  └── 审计日志（所有工具调用可追溯）                 │
├─────────────────────────────────────────────────┤
│  Layer 2: 结构约束（架构级）                       │
│  ├── MCP 工具参数校验（mcp-hostclaw.ts 内的 zod）  │
│  ├── 进程内 MCP（无网络暴露，无需认证）              │
│  └── 群组 cwd 隔离（不同会话不共享文件系统）         │
├─────────────────────────────────────────────────┤
│  Layer 3: 软约束（提示词级，可作为行为指南）          │
│  ├── systemPrompt 中的行为规范                    │
│  └── CLAUDE.md 中的操作准则                       │
└─────────────────────────────────────────────────┘
```

### 8.2 canUseTool 权限回调（Layer 1 核心）

采用**白名单路径保护**策略：不禁止命令本身，而是拦截对关键路径的破坏性操作。

```typescript
// src/safety.ts
import type { ToolPermissionContext } from '@anthropic-ai/claude-agent-sdk';

// ========== 受保护的系统路径 ==========
// 对这些路径的写入/删除操作会被拦截
const PROTECTED_PATHS = [
  '/System/',              // macOS 系统文件
  '/Library/System/',      // 系统库
  '/usr/bin/',             // 系统二进制
  '/usr/sbin/',            // 系统管理工具
  '/sbin/',                // 启动必需工具
  '/private/var/db/',      // 系统数据库
];

// 敏感文件（精确匹配或前缀）
const SENSITIVE_FILES = [
  '/.ssh/id_',             // SSH 私钥（id_rsa, id_ed25519 等）
  '/.ssh/authorized_keys', // SSH 授权
  '/Keychain/',            // macOS 钥匙串
];

// ========== 真正不可恢复的破坏性命令 ==========
const DESTRUCTIVE_PATTERNS = [
  /\brm\s+-rf\s+\/\s*$/,              // rm -rf / （根目录，裸奔）
  /\brm\s+-rf\s+\/System\b/,          // rm -rf /System
  /\brm\s+-rf\s+\/Library\s*$/,       // rm -rf /Library（整个）
  /\brm\s+-rf\s+~\s*$/,               // rm -rf ~（整个 home）
  /\bmkfs\b/,                         // 格式化磁盘
  /\bdd\s+of=\/dev\//,                // 写入磁盘设备
  /\bnewfs\b/,                        // 创建文件系统
];

export async function toolPermissionGuard(
  toolName: string,
  input: Record<string, unknown>,
  context: ToolPermissionContext,
) {
  // --- Bash: 仅拦截真正破坏性的命令 ---
  if (toolName === 'Bash') {
    const cmd = String(input.command ?? '');
    for (const pattern of DESTRUCTIVE_PATTERNS) {
      if (pattern.test(cmd)) {
        return { allowed: false, message: `破坏性命令已阻止: ${cmd.slice(0, 80)}` };
      }
    }
  }

  // --- Write/Edit: 保护关键系统路径和敏感文件 ---
  if (toolName === 'Write' || toolName === 'Edit') {
    const filePath = String(input.file_path ?? '');
    for (const p of PROTECTED_PATHS) {
      if (filePath.startsWith(p)) {
        return { allowed: false, message: `系统路径受保护: ${filePath}` };
      }
    }
    for (const s of SENSITIVE_FILES) {
      if (filePath.includes(s)) {
        return { allowed: false, message: `敏感文件受保护: ${filePath}` };
      }
    }
  }

  // --- 审计日志：所有工具调用可追溯 ---
  log.info({ tool: toolName, input }, 'tool invocation');

  return { allowed: true };
}
```

**设计要点**：

| 操作 | 是否允许 | 理由 |
|------|---------|------|
| `sudo brew install ffmpeg` | ✅ 允许 | 日常软件安装 |
| `killall Finder` | ✅ 允许 | 应用管理 |
| `rm -rf /Users/me/project/node_modules` | ✅ 允许 | 正常清理 |
| `git push --force-with-lease` | ✅ 允许 | 安全的强制推送 |
| 创建/编辑 `.env` 文件 | ✅ 允许 | 项目配置 |
| 编辑 `~/.ssh/config` | ✅ 允许 | SSH 连接配置 |
| `rm -rf /` | ❌ 拦截 | 系统毁灭 |
| `rm -rf ~` | ❌ 拦截 | 删除整个 home |
| `mkfs /dev/disk2` | ❌ 拦截 | 格式化磁盘 |
| `dd of=/dev/disk0` | ❌ 拦截 | 覆写系统盘 |
| 写入 `/System/` | ❌ 拦截 | 系统完整性 |
| 覆写 `~/.ssh/id_rsa` | ❌ 拦截 | 凭证不可恢复 |

### 8.3 运行时限制（Layer 1）

```typescript
export const MAX_AGENT_TURNS = 200;       // 单次调用最大轮次（computer use 需要更多）
export const MAX_BUDGET_PER_CALL = 20.0;  // 单次调用成本上限（美元，含截图开销）
```

超出限制时 SDK 自动终止 Agent 并返回 result，不会静默失败。

**参数选择理由**：
- **200 turns**：复杂 GUI 操作每步消耗 2-3 turns（截图+分析+操作），200 turns 支持 ~60-80 步操作
- **$20 上限**：Opus + 多次截图（base64 ~1MB/张进入上下文）成本较高，$20 足够大多数复杂任务

### 8.4 不使用 Sandbox

HostClaw 定位为宿主机全能力助手，**不启用** SDK 的 Bash sandbox：

```typescript
// sandbox 不启用 — Agent 需要完整的文件系统和网络访问
// 安全由 canUseTool 路径保护 + 审计日志保障
```

如果启用 sandbox，会限制：
- 写入 `cwd` 之外的路径（影响跨项目操作、截图保存）
- 网络访问（影响 curl/wget/API 调用）
- 访问 `/Applications/`（影响应用管理）

这些限制与 HostClaw 的宿主机操控定位直接冲突。

### 8.5 风险矩阵

| 风险 | Layer 1 硬约束 | Layer 2 结构约束 | Layer 3 软约束 |
|------|---------------|-----------------|---------------|
| 系统路径破坏 | `canUseTool` 路径白名单保护 | — | — |
| 凭证泄露/覆写 | `canUseTool` 敏感文件保护 | — | — |
| 磁盘格式化/覆写 | `canUseTool` 破坏性命令拦截 | — | — |
| Agent 无限循环 | `maxTurns: 200` 限制 | — | — |
| 成本失控 | `maxBudgetUsd: 20` 限制 | — | — |
| MCP 工具滥用 | — | 进程内调用 + zod 校验 | — |
| Computer use 误操作 | 审计日志 | — | CLAUDE.md 操作规范 |
| 跨群组数据泄露 | — | 独立 cwd + 独立会话 | — |

**核心原则**：个人助手信任度高，保护**不可恢复**的系统关键路径，放开日常操作能力。所有工具调用均有审计日志可追溯。

---

## 9. 错误处理与韧性

宿主机长时间运行的服务必须应对各种故障场景。

### 9.1 Agent SDK 调用失败

```typescript
// 带指数退避的重试封装
async function runAgentWithRetry(input: AgentInput, maxRetries = 3): Promise<AgentOutput> {
  for (let attempt = 0; attempt < maxRetries; attempt++) {
    try {
      return await runAgent(input);
    } catch (err: any) {
      const isRetryable = err.status === 429        // 限流
        || err.status === 529                        // API 过载
        || err.code === 'ECONNRESET';                // 网络断开

      if (!isRetryable || attempt === maxRetries - 1) {
        log.error({ err, attempt }, 'agent failed permanently');
        await sendToUser(input.chatJid, '⚠️ 服务暂时不可用，请稍后重试');
        throw err;
      }

      const delay = Math.min(1000 * 2 ** attempt, 30_000);
      log.warn({ err, attempt, delay }, 'agent retrying');
      await sleep(delay);
    }
  }
  throw new Error('unreachable');
}
```

### 9.2 MCP 工具执行失败

MCP 工具现在运行在主进程内（非子进程），错误处理更直接：
- 工具 handler 抛出异常 → SDK 自动将错误返回给 Agent
- Agent 可以选择重试或跳过该工具
- 不涉及进程崩溃和重启

建议在工具 handler 中做好错误包装：

```typescript
// src/mcp-computer.ts — 工具内部捕获并返回有意义的错误
tool('screenshot', '...', {}, async (args) => {
  try {
    // ...截图逻辑
  } catch (err) {
    return {
      content: [{ type: 'text', text: `截图失败: ${err.message}` }],
      isError: true,
    };
  }
});
```

### 9.3 渠道断线重连

基于 Channel 接口的通用健康检查，适用于任何渠道实现：

```typescript
// 渠道健康检查 + 自动重连
async function channelHealthCheck(channels: Channel[]) {
  for (const ch of channels) {
    if (!ch.isConnected()) {
      log.warn({ channel: ch.name }, 'channel disconnected, reconnecting');
      try {
        await ch.connect();
      } catch (err) {
        log.error({ err, channel: ch.name }, 'reconnect failed');
      }
    }
  }
}

setInterval(() => channelHealthCheck(channels), 30_000);  // 每 30 秒检查
```

> 注：飞书 Lark SDK 的 WSClient 内置了自动重连机制，此处为兜底检查。

### 9.4 会话恢复

Agent SDK 会话通过 `session_id` 持久化到 `sessions.json`。进程重启后可恢复：

```typescript
// 启动时从 JSON 文件恢复会话映射
function restoreSessions() {
  const saved = store.getSessions();  // { folder: sessionId }
  for (const [folder, sessionId] of Object.entries(saved)) {
    sessions[folder] = sessionId;
    log.info({ group: folder, sessionId }, 'session restored');
  }
}
```

### 9.5 成本监控

```typescript
// 记录每次调用成本，支持日/月维度统计
function trackCost(groupFolder: string, cost: number) {
  store.recordCost(groupFolder, cost, new Date());

  // 日成本预警
  const dailyCost = store.getDailyCost(new Date());
  if (dailyCost > DAILY_COST_ALERT_THRESHOLD) {
    log.warn({ dailyCost }, 'daily cost threshold exceeded');
    await sendToMainGroup(`⚠️ 今日 API 成本已达 $${dailyCost.toFixed(2)}`);
  }
}
```

---

## 10. 模型选择策略

不同任务类型适合不同模型，兼顾能力和成本：

```typescript
// src/config.ts
export const DEFAULT_MODEL = 'claude-sonnet-4-5';

export function selectModel(group: RegisteredGroup, taskType?: string): string {
  // Computer use 任务需要强视觉理解
  if (taskType === 'computer_use') return 'claude-sonnet-4-5';
  // 复杂推理 / 代码生成
  if (taskType === 'complex') return 'claude-opus-4-6';
  // 群组自定义模型
  if (group.model) return group.model;
  // 默认
  return DEFAULT_MODEL;
}
```

| 任务类型 | 推荐模型 | 理由 |
|---------|---------|------|
| 日常对话 | claude-sonnet-4-5 | 性价比最优 |
| Computer use | claude-sonnet-4-5 | 视觉理解 + 工具使用平衡 |
| 复杂代码 / 推理 | claude-opus-4-6 | 最强推理能力 |
| 简单查询 / 通知 | claude-haiku-4-5 | 低成本快速响应 |

---

## 11. 实施计划

### Phase 1: 骨架（CLI → Agent → 终端输出）
1. 初始化项目（package.json、tsconfig、目录结构）
2. 实现 `config.ts`（`MAX_AGENT_TURNS`、`MAX_BUDGET_PER_CALL`、`DEFAULT_MODEL`、`HOSTCLAW_SYSTEM_PROMPT`）
3. 实现 `types.ts`、`logger.ts`、`utils.ts`
4. 实现 `safety.ts`（`toolPermissionGuard` 路径保护 + 审计日志）
5. 实现 `store.ts`（JSON 文件持久化 — 任务/会话/群组/成本 CRUD）
6. 实现 `mcp-hostclaw.ts`（进程内 MCP，send_message 暂输出到终端）
7. 实现 `src/index.ts` 最小版（V2 Session API，CLI 输入 → Agent → 终端输出）
8. **验证**：终端输入一个问题，Agent 回答；验证 `canUseTool` 拦截 `rm -rf /` 但允许 `rm -rf ./node_modules`

### Phase 2: Computer Use
1. 安装 `cliclick`，配置 macOS 权限
2. 实现 `mcp-computer.ts`（进程内 MCP，仅 screenshot 工具）
3. 验证 systemPrompt 中的 cliclick/osascript 指引是否足够
4. **验证**：终端指令 "截图当前屏幕" → Agent 截图并描述内容

### Phase 3: 渠道接入（飞书）
1. 实现 `channels/types.ts`（Channel 接口定义）
2. 创建飞书企业自建应用，配置事件订阅和机器人能力
3. 实现 `channels/feishu.ts`（WebSocket 长连接 + 消息收发）
4. 实现 `channels/index.ts`（渠道初始化）
5. 实现 `router.ts`（消息格式化 + 出站路由，基于 Channel 接口）
6. 实现 `message-debouncer.ts`（消息去抖推送）
7. 实现 `group-queue.ts`（并发控制 + computer use 串行）
8. 完善 `src/index.ts`（消息循环）
9. 完善 `mcp-hostclaw.ts`（send_message 改为通过 router → channel 发送）
10. **验证**：从飞书发消息 → Agent 回复

### Phase 4: 任务调度 + 心跳
1. 实现 `task-scheduler.ts`
2. 完善 `mcp-hostclaw.ts`（schedule_task、list_tasks、manage_task）
3. **验证**：创建定时任务 → 按时执行

### Phase 5: 产品化
1. launchd 后台服务配置
2. V2 Session 持久化（resume 跨重启）
3. 全局记忆 + 群组记忆（`settingSources: ['project']` 验证）
4. 成本监控与预警
5. 错误重试（`runAgentWithRetry`）
6. 补充 Smoke Test + 覆盖率报告（见第 12 节测试方案）

---

## 12. 测试方案

### 12.1 测试分层

```
┌─────────────────────────────────────────────────────────────┐
│  Layer 3: Smoke Test（真实 API，CI 按需触发）                  │
│  验证 Agent SDK 端到端可用性，每次发版前手动/定时运行            │
├─────────────────────────────────────────────────────────────┤
│  Layer 2: Integration Test（mock 外部依赖）                   │
│  MCP 工具 + Gateway 消息循环 + 渠道消息解析                    │
├─────────────────────────────────────────────────────────────┤
│  Layer 1: Unit Test（纯逻辑，零 mock 或极少 mock）             │
│  store / safety / debouncer / router / scheduler / queue     │
└─────────────────────────────────────────────────────────────┘
```

### 12.2 测试目录结构

```
hostclaw/
├── src/
│   └── ...
├── tests/
│   ├── unit/
│   │   ├── store.test.ts
│   │   ├── safety.test.ts
│   │   ├── message-debouncer.test.ts
│   │   ├── router.test.ts
│   │   ├── task-scheduler.test.ts
│   │   └── group-queue.test.ts
│   ├── integration/
│   │   ├── mcp-hostclaw.test.ts
│   │   ├── mcp-computer.test.ts
│   │   ├── feishu-channel.test.ts
│   │   └── gateway.test.ts
│   ├── smoke/
│   │   └── agent-sdk.test.ts
│   └── helpers/
│       ├── fixtures.ts          # 测试数据工厂
│       ├── mock-channel.ts      # Channel 接口 mock
│       └── mock-agent-sdk.ts    # Agent SDK mock
├── vitest.config.ts
```

### 12.3 Vitest 配置

```typescript
// vitest.config.ts
import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    include: ['tests/**/*.test.ts'],
    coverage: {
      provider: 'v8',
      include: ['src/**/*.ts'],
      exclude: ['src/index.ts'],     // Gateway 入口由集成测试覆盖
      thresholds: { lines: 80, branches: 75, functions: 80 },
    },
    // 按层分组，支持单独运行
    typecheck: { enabled: true },
  },
});
```

```json
// package.json scripts
{
  "scripts": {
    "test": "vitest run",
    "test:unit": "vitest run tests/unit/",
    "test:integration": "vitest run tests/integration/",
    "test:smoke": "vitest run tests/smoke/",
    "test:watch": "vitest watch tests/unit/",
    "test:coverage": "vitest run --coverage"
  }
}
```

### 12.4 Unit Test（Layer 1）

#### 12.4.1 store.test.ts — JSON 持久化

```typescript
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import fs from 'fs';
import path from 'path';
import os from 'os';
import { JsonStore } from '../src/store.js';

describe('JsonStore', () => {
  let store: JsonStore;
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'hostclaw-test-'));
    store = new JsonStore(tmpDir);  // 注入数据目录，不污染真实数据
  });

  afterEach(() => { fs.rmSync(tmpDir, { recursive: true }); });

  describe('groups', () => {
    it('初始为空数组', () => {
      expect(store.getRegisteredGroups()).toEqual([]);
    });

    it('注册后可读取', () => {
      store.registerGroup({ chatJid: 'chat1', folder: 'proj', name: 'Project' });
      const groups = store.getRegisteredGroups();
      expect(groups).toHaveLength(1);
      expect(groups[0].folder).toBe('proj');
    });

    it('持久化到文件', () => {
      store.registerGroup({ chatJid: 'chat1', folder: 'proj', name: 'Project' });
      // 新实例读取同一目录
      const store2 = new JsonStore(tmpDir);
      expect(store2.getRegisteredGroups()).toHaveLength(1);
    });
  });

  describe('tasks', () => {
    it('创建任务返回自增 ID', () => {
      const id1 = store.createTask({ prompt: 'task1', groupFolder: 'main' });
      const id2 = store.createTask({ prompt: 'task2', groupFolder: 'main' });
      expect(id2).toBe(id1 + 1);
    });

    it('按群组过滤任务', () => {
      store.createTask({ prompt: 'a', groupFolder: 'main' });
      store.createTask({ prompt: 'b', groupFolder: 'other' });
      expect(store.getTasksByGroup('main')).toHaveLength(1);
    });

    it('getDueTasks 仅返回到期的活跃任务', () => {
      store.createTask({ prompt: 'due', groupFolder: 'main', status: 'active', nextRunAt: Date.now() - 1000 });
      store.createTask({ prompt: 'future', groupFolder: 'main', status: 'active', nextRunAt: Date.now() + 60000 });
      store.createTask({ prompt: 'paused', groupFolder: 'main', status: 'paused', nextRunAt: Date.now() - 1000 });
      expect(store.getDueTasks()).toHaveLength(1);
      expect(store.getDueTasks()[0].prompt).toBe('due');
    });
  });

  describe('sessions', () => {
    it('保存和读取会话映射', () => {
      store.saveSession('main', 'sess-abc');
      store.saveSession('proj', 'sess-xyz');
      expect(store.getSessions()).toEqual({ main: 'sess-abc', proj: 'sess-xyz' });
    });

    it('覆盖已有会话', () => {
      store.saveSession('main', 'old');
      store.saveSession('main', 'new');
      expect(store.getSessions().main).toBe('new');
    });
  });

  describe('costs', () => {
    it('记录并按日聚合成本', () => {
      const today = new Date('2026-03-14T10:00:00Z');
      store.recordCost('main', 1.5, today);
      store.recordCost('proj', 0.8, today);
      expect(store.getDailyCost(today)).toBeCloseTo(2.3);
    });

    it('不同日期互不干扰', () => {
      store.recordCost('main', 1.0, new Date('2026-03-14T10:00:00Z'));
      store.recordCost('main', 2.0, new Date('2026-03-15T10:00:00Z'));
      expect(store.getDailyCost(new Date('2026-03-14T10:00:00Z'))).toBeCloseTo(1.0);
    });

    it('按月存储到独立文件', () => {
      store.recordCost('main', 1.0, new Date('2026-03-14'));
      store.recordCost('main', 2.0, new Date('2026-04-01'));
      expect(fs.existsSync(path.join(tmpDir, 'costs', '2026-03.json'))).toBe(true);
      expect(fs.existsSync(path.join(tmpDir, 'costs', '2026-04.json'))).toBe(true);
    });
  });
});
```

#### 12.4.2 safety.test.ts — 权限守卫

```typescript
import { describe, it, expect } from 'vitest';
import { toolPermissionGuard } from '../src/safety.js';

describe('toolPermissionGuard', () => {
  // --- 应拦截的操作 ---
  describe('拦截破坏性命令', () => {
    const blocked = [
      'rm -rf /',
      'rm -rf /System/Library',
      'rm -rf ~',
      'mkfs /dev/disk2',
      'dd of=/dev/disk0 if=/tmp/image',
      'newfs_hfs /dev/disk3',
    ];
    for (const cmd of blocked) {
      it(`阻止: ${cmd}`, async () => {
        const result = await toolPermissionGuard('Bash', { command: cmd }, {});
        expect(result.allowed).toBe(false);
      });
    }
  });

  describe('拦截敏感文件写入', () => {
    const blocked = [
      '/Users/me/.ssh/id_rsa',
      '/Users/me/.ssh/id_ed25519',
      '/Users/me/.ssh/authorized_keys',
      '/Library/Keychains/System.keychain',
    ];
    for (const filePath of blocked) {
      it(`阻止写入: ${filePath}`, async () => {
        const result = await toolPermissionGuard('Write', { file_path: filePath }, {});
        expect(result.allowed).toBe(false);
      });
    }
  });

  describe('拦截系统路径写入', () => {
    const blocked = ['/System/Library/foo', '/usr/bin/node', '/sbin/mount'];
    for (const filePath of blocked) {
      it(`阻止写入: ${filePath}`, async () => {
        const result = await toolPermissionGuard('Write', { file_path: filePath }, {});
        expect(result.allowed).toBe(false);
      });
    }
  });

  // --- 应放行的操作 ---
  describe('放行日常操作', () => {
    const allowed: Array<[string, Record<string, unknown>]> = [
      ['Bash', { command: 'sudo brew install ffmpeg' }],
      ['Bash', { command: 'killall Finder' }],
      ['Bash', { command: 'rm -rf /Users/me/project/node_modules' }],
      ['Bash', { command: 'git push --force-with-lease' }],
      ['Write', { file_path: '/Users/me/project/.env' }],
      ['Write', { file_path: '/Users/me/.ssh/config' }],
      ['Edit', { file_path: '/Users/me/project/src/index.ts' }],
      ['Read', { file_path: '/System/Library/anything' }],  // 读取不拦截
    ];
    for (const [tool, input] of allowed) {
      it(`允许: ${tool} ${JSON.stringify(input)}`, async () => {
        const result = await toolPermissionGuard(tool, input, {});
        expect(result.allowed).toBe(true);
      });
    }
  });
});
```

#### 12.4.3 message-debouncer.test.ts — 消息去抖

```typescript
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { MessageDebouncer } from '../src/message-debouncer.js';

describe('MessageDebouncer', () => {
  beforeEach(() => { vi.useFakeTimers(); });
  afterEach(() => { vi.useRealTimers(); });

  it('500ms 内合并多条文本为一次发送', async () => {
    const send = vi.fn().mockResolvedValue(undefined);
    const debouncer = new MessageDebouncer(send, 500);

    debouncer.push('Hello ');
    debouncer.push('World');
    expect(send).not.toHaveBeenCalled();

    await vi.advanceTimersByTimeAsync(500);
    expect(send).toHaveBeenCalledOnce();
    expect(send).toHaveBeenCalledWith('Hello World');
  });

  it('flush 立即发送并清空 buffer', async () => {
    const send = vi.fn().mockResolvedValue(undefined);
    const debouncer = new MessageDebouncer(send, 500);

    debouncer.push('immediate');
    await debouncer.flush();
    expect(send).toHaveBeenCalledWith('immediate');

    // flush 后不再触发定时器发送
    await vi.advanceTimersByTimeAsync(500);
    expect(send).toHaveBeenCalledOnce();
  });

  it('空 buffer 时 flush 不触发发送', async () => {
    const send = vi.fn().mockResolvedValue(undefined);
    const debouncer = new MessageDebouncer(send, 500);
    await debouncer.flush();
    expect(send).not.toHaveBeenCalled();
  });

  it('push 重置定时器', async () => {
    const send = vi.fn().mockResolvedValue(undefined);
    const debouncer = new MessageDebouncer(send, 500);

    debouncer.push('a');
    await vi.advanceTimersByTimeAsync(400);  // 还没到 500ms
    debouncer.push('b');                      // 重置
    await vi.advanceTimersByTimeAsync(400);  // 距第二次 push 400ms
    expect(send).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(100);  // 距第二次 push 500ms
    expect(send).toHaveBeenCalledWith('ab');
  });
});
```

#### 12.4.4 group-queue.test.ts — 并发控制

```typescript
import { describe, it, expect } from 'vitest';
import { GroupQueue } from '../src/group-queue.js';

describe('GroupQueue', () => {
  it('不同群组并发执行', async () => {
    const queue = new GroupQueue();
    const order: string[] = [];

    await Promise.all([
      queue.enqueue('group-a', async () => { order.push('a-start'); await delay(50); order.push('a-end'); }),
      queue.enqueue('group-b', async () => { order.push('b-start'); await delay(10); order.push('b-end'); }),
    ]);

    // b 先完成，证明 a/b 并发
    expect(order.indexOf('b-end')).toBeLessThan(order.indexOf('a-end'));
  });

  it('同一群组串行执行', async () => {
    const queue = new GroupQueue();
    const order: string[] = [];

    const p1 = queue.enqueue('same', async () => { order.push('1-start'); await delay(50); order.push('1-end'); });
    const p2 = queue.enqueue('same', async () => { order.push('2-start'); order.push('2-end'); });
    await Promise.all([p1, p2]);

    expect(order).toEqual(['1-start', '1-end', '2-start', '2-end']);
  });

  it('computer use 全局串行', async () => {
    const queue = new GroupQueue({ computerUseSerial: true });
    const order: string[] = [];

    const p1 = queue.enqueue('group-a', async () => { order.push('a'); await delay(50); }, { computerUse: true });
    const p2 = queue.enqueue('group-b', async () => { order.push('b'); }, { computerUse: true });
    await Promise.all([p1, p2]);

    // 即使不同群组，computer use 也串行
    expect(order).toEqual(['a', 'b']);
  });
});

function delay(ms: number) { return new Promise(r => setTimeout(r, ms)); }
```

#### 12.4.5 task-scheduler.test.ts — 调度计算

```typescript
import { describe, it, expect } from 'vitest';
import { computeNextRun } from '../src/task-scheduler.js';

describe('computeNextRun', () => {
  const base = new Date('2026-03-14T08:00:00Z');

  it('cron 表达式 — 每天 9:00', () => {
    const next = computeNextRun({ type: 'cron', cron: '0 9 * * *' }, base);
    expect(next.getHours()).toBe(9);
    expect(next > base).toBe(true);
  });

  it('interval — 每 3600 秒', () => {
    const next = computeNextRun({ type: 'interval', interval: 3600 }, base);
    expect(next.getTime() - base.getTime()).toBe(3600_000);
  });

  it('once — ISO 时间', () => {
    const target = '2026-03-15T10:00:00Z';
    const next = computeNextRun({ type: 'once', once: target }, base);
    expect(next.toISOString()).toBe(target);
  });
});
```

#### 12.4.6 router.test.ts — 消息格式化

```typescript
import { describe, it, expect } from 'vitest';
import { formatMessages } from '../src/router.js';

describe('formatMessages', () => {
  it('格式化为 XML 结构', () => {
    const messages = [
      { sender: 'Alice', text: 'Hello', timestamp: 1710400000000 },
      { sender: 'Bob', text: 'Hi there', timestamp: 1710400001000 },
    ];
    const result = formatMessages(messages, 'Asia/Shanghai');
    expect(result).toContain('<message');
    expect(result).toContain('Alice');
    expect(result).toContain('Hello');
  });

  it('空消息列表返回空字符串', () => {
    expect(formatMessages([], 'UTC')).toBe('');
  });
});
```

### 12.5 Integration Test（Layer 2）

#### 12.5.1 mcp-hostclaw.test.ts — HostClaw MCP 工具

```typescript
import { describe, it, expect, vi } from 'vitest';
import { createHostclawMcp } from '../src/mcp-hostclaw.js';

describe('HostClaw MCP', () => {
  function createMocks() {
    return {
      router: {
        sendMessage: vi.fn().mockResolvedValue(undefined),
        sendMedia: vi.fn().mockResolvedValue(undefined),
      },
      taskScheduler: {
        createTask: vi.fn().mockResolvedValue(1),
        pause: vi.fn(), resume: vi.fn(), cancel: vi.fn(),
      },
      store: {
        getTasksByGroup: vi.fn().mockReturnValue([]),
        registerGroup: vi.fn(),
      },
    };
  }

  it('send_message 调用 router.sendMessage', async () => {
    const mocks = createMocks();
    const mcp = createHostclawMcp('chat-1', { folder: 'main', isMain: true }, mocks);
    await mcp.callTool('send_message', { text: 'hello' });
    expect(mocks.router.sendMessage).toHaveBeenCalledWith('chat-1', 'hello', undefined);
  });

  it('schedule_task 调用 taskScheduler.createTask', async () => {
    const mocks = createMocks();
    const mcp = createHostclawMcp('chat-1', { folder: 'main', isMain: true }, mocks);
    await mcp.callTool('schedule_task', { prompt: 'test', cron: '0 9 * * *' });
    expect(mocks.taskScheduler.createTask).toHaveBeenCalled();
  });

  it('register_group 仅主群组可用', async () => {
    const mocks = createMocks();
    const mcp = createHostclawMcp('chat-1', { folder: 'sub', isMain: false }, mocks);
    const tools = mcp.listTools();
    expect(tools.map(t => t.name)).not.toContain('register_group');
  });
});
```

#### 12.5.2 mcp-computer.test.ts — Computer Use MCP

```typescript
import { describe, it, expect, vi } from 'vitest';
import { createComputerMcp } from '../src/mcp-computer.js';

// mock execAsync 和 fs — 不需要真实截图
vi.mock('../src/utils.js', () => ({
  execAsync: vi.fn().mockResolvedValue({ stdout: '', stderr: '' }),
}));
vi.mock('fs', async (importOriginal) => {
  const original = await importOriginal<typeof import('fs')>();
  return {
    ...original,
    readFileSync: vi.fn().mockReturnValue(Buffer.from('fake-png-data')),
  };
});

describe('Computer Use MCP', () => {
  it('screenshot 返回 base64 图片', async () => {
    const mcp = createComputerMcp();
    const result = await mcp.callTool('screenshot', {});
    expect(result.content[0].type).toBe('image');
    expect(result.content[0].mimeType).toBe('image/png');
    expect(result.content[0].data).toBe(Buffer.from('fake-png-data').toString('base64'));
  });

  it('截图失败返回错误而非抛异常', async () => {
    const { execAsync } = await import('../src/utils.js');
    vi.mocked(execAsync).mockRejectedValueOnce(new Error('screencapture not found'));

    const mcp = createComputerMcp();
    const result = await mcp.callTool('screenshot', {});
    expect(result.isError).toBe(true);
    expect(result.content[0].text).toContain('截图失败');
  });
});
```

#### 12.5.3 gateway.test.ts — Gateway 消息循环

```typescript
import { describe, it, expect, vi } from 'vitest';

// mock Agent SDK — 不实际调用 API
vi.mock('@anthropic-ai/claude-agent-sdk', () => ({
  unstable_v2_createSession: vi.fn().mockReturnValue({
    send: vi.fn(),
    stream: vi.fn().mockReturnValue((async function* () {
      yield { session_id: 'sess-123' };
      yield { type: 'assistant', message: { content: [{ type: 'text', text: 'Hello!' }] } };
      yield { type: 'result', total_cost_usd: 0.01, num_turns: 2 };
    })()),
    close: vi.fn(),
  }),
  unstable_v2_resumeSession: vi.fn(),
  createSdkMcpServer: vi.fn().mockReturnValue({}),
  tool: vi.fn(),
}));

describe('Gateway processGroupMessages', () => {
  it('创建新会话并处理 Agent 响应', async () => {
    // ... 验证消息循环正确调用 SDK 并推送回复
  });

  it('已有 session_id 时使用 resumeSession', async () => {
    // ... 验证会话恢复逻辑
  });

  it('API 错误时发送错误提示给用户', async () => {
    // ... mock stream 抛异常，验证错误消息推送
  });
});
```

#### 12.5.4 feishu-channel.test.ts — 飞书渠道

```typescript
import { describe, it, expect, vi } from 'vitest';

// mock Lark SDK
vi.mock('@larksuiteoapi/node-sdk', () => ({
  Client: vi.fn().mockReturnValue({
    im: { message: { create: vi.fn().mockResolvedValue({}) } },
  }),
  WSClient: vi.fn().mockReturnValue({
    start: vi.fn().mockResolvedValue(undefined),
    stop: vi.fn(),
    isConnected: vi.fn().mockReturnValue(true),
  }),
  EventDispatcher: vi.fn().mockReturnValue({ register: vi.fn().mockReturnThis() }),
}));

describe('Feishu Channel', () => {
  it('sendMessage 调用 Lark API 正确参数', async () => {
    const { createFeishuChannel } = await import('../src/channels/feishu.js');
    const ch = createFeishuChannel({ appId: 'test', appSecret: 'secret' });
    await ch.sendMessage('chat-123', 'Hello');
    // 验证 client.im.message.create 被正确调用
  });

  it('connect 启动 WebSocket', async () => {
    const { createFeishuChannel } = await import('../src/channels/feishu.js');
    const ch = createFeishuChannel({ appId: 'test', appSecret: 'secret' });
    await ch.connect();
    expect(ch.isConnected()).toBe(true);
  });
});
```

### 12.6 Smoke Test（Layer 3）

需要真实 API Key，仅在以下场景运行：
- 发版前手动触发
- CI 定时任务（如每日一次）
- 设置 `ANTHROPIC_API_KEY` 环境变量

```typescript
// tests/smoke/agent-sdk.test.ts
import { describe, it, expect } from 'vitest';
import { unstable_v2_createSession } from '@anthropic-ai/claude-agent-sdk';

const SKIP = !process.env.ANTHROPIC_API_KEY;

describe.skipIf(SKIP)('Agent SDK Smoke Test', () => {
  it('基本问答可用', async () => {
    const session = unstable_v2_createSession({
      model: 'claude-haiku-4-5',    // 用最便宜的模型
      maxTurns: 2,
      maxBudgetUsd: 0.05,
    });

    await session.send('回复 OK 即可，不要多说');
    let response = '';
    for await (const msg of session.stream()) {
      if (msg.type === 'assistant') {
        response += msg.message.content
          .filter(b => b.type === 'text')
          .map(b => b.text)
          .join('');
      }
    }
    session.close();
    expect(response.toLowerCase()).toContain('ok');
  }, 30_000);  // 30s 超时

  it('canUseTool 拦截生效', async () => {
    const session = unstable_v2_createSession({
      model: 'claude-haiku-4-5',
      maxTurns: 3,
      maxBudgetUsd: 0.05,
      permissionMode: 'bypassPermissions',
      canUseTool: async (tool, input) => {
        if (tool === 'Bash' && String(input.command).includes('rm -rf /'))
          return { allowed: false, message: 'blocked' };
        return { allowed: true };
      },
    });

    await session.send('请执行 rm -rf /');
    let blocked = false;
    for await (const msg of session.stream()) {
      if (msg.type === 'assistant') {
        const text = msg.message.content.map(b => b.text ?? '').join('');
        if (text.includes('blocked') || text.includes('无法') || text.includes('拒绝')) blocked = true;
      }
    }
    session.close();
    expect(blocked).toBe(true);
  }, 30_000);
});
```

### 12.7 测试覆盖率目标

| 层级 | 覆盖范围 | 目标 | 运行频率 |
|------|---------|------|---------|
| Unit | store, safety, debouncer, router, scheduler, queue | **≥ 90%** 行覆盖 | 每次提交 |
| Integration | MCP 工具, Gateway, 渠道 | **≥ 70%** 行覆盖 | 每次提交 |
| Smoke | Agent SDK 端到端 | 核心场景通过 | 发版前 / 每日 |
| **总计** | 全部 src/ | **≥ 80%** 行覆盖 | — |

### 12.8 各模块与实施阶段的测试对应

| Phase | 实现模块 | 同步编写的测试 |
|-------|---------|---------------|
| Phase 1 | config, types, utils, safety, store, mcp-hostclaw, index | `safety.test.ts`, `store.test.ts`, `mcp-hostclaw.test.ts` |
| Phase 2 | mcp-computer | `mcp-computer.test.ts` |
| Phase 3 | channels/, router, debouncer, group-queue | `feishu-channel.test.ts`, `router.test.ts`, `message-debouncer.test.ts`, `group-queue.test.ts` |
| Phase 4 | task-scheduler | `task-scheduler.test.ts` |
| Phase 5 | Gateway 完整版 | `gateway.test.ts`, `agent-sdk.test.ts`（smoke） |

> **原则**：每个 Phase 的实现和测试同步完成，不积压到 Phase 5。

### 12.9 不自动化测试的部分

以下场景依赖真实 macOS 环境，通过手动验证：

| 场景 | 验证方式 |
|------|---------|
| screencapture 截图 | Phase 2 手动：`截图当前屏幕` |
| cliclick 鼠标/键盘 | Phase 2 手动：`打开 Safari 搜索天气` |
| 飞书 WebSocket 端到端 | Phase 3 手动：从飞书发消息验证回复 |
| launchd 后台运行 | Phase 5 手动：`launchctl load` 后观察日志 |
| 进程重启会话恢复 | Phase 5 手动：kill 进程后验证 resume |

---

## 13. 关键文件参考（从 NanoClaw 复用的模式）

| NanoClaw 文件 | 复用内容 | HostClaw 对应 |
|---------------|---------|--------------|
| `src/index.ts` | 消息循环、状态管理、启动恢复 | `src/index.ts`（改用 V2 Session API） |
| `src/channels/registry.ts` | Channel 接口 + 渠道初始化 | `src/channels/`（保留接口，当前仅飞书） |
| `src/router.ts` | formatMessages()、findChannel()、stripInternalTags() | `src/router.ts`（直接复用） |
| `src/db.ts` | SQLite schema（messages、tasks、sessions、groups） | `src/store.ts`（JSON 文件，消息不落盘） |
| `src/group-queue.ts` | GroupState 状态机、enqueueMessageCheck | `src/group-queue.ts`（增加 computer use 串行） |
| `src/task-scheduler.ts` | computeNextRun()、startSchedulerLoop()、cron/interval/once | `src/task-scheduler.ts`（直接复用） |
| `src/types.ts` | Channel、RegisteredGroup、NewMessage、ScheduledTask | `src/types.ts`（去除 ContainerConfig） |
| `src/config.ts` | 配置常量模式 | `src/config.ts`（增加安全/模型/systemPrompt） |
| `container/agent-runner/src/index.ts` | query() 调用模式、会话恢复 | 已合并到 `src/index.ts`（V2 Session API） |
| `container/agent-runner/src/ipc-mcp-stdio.ts` | MCP 工具定义（send_message 等） | `src/mcp-hostclaw.ts`（进程内 MCP） |
