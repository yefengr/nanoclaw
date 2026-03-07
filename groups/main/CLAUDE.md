# 主频道

## 渠道

这是飞书（Feishu）群组。使用标准 Markdown 格式输出。

## 核心工作规则

### 时间处理

涉及时间问题时，必须先执行 `date` 命令确认实际时间，不要信任消息时间戳（UTC格式）。

### 文档规则

保持所有文档和规则简洁明了，用最少的文字表达核心要点。

### 节假日系统

脚本：`/workspace/group/.holiday-cache/is-workday.sh`
用法：返回码 0=工作日，1=休息日

---

## 管理员上下文

这是 **主频道**，拥有管理员权限。

## 容器挂载

主频道对项目有只读访问权限，对其群组文件夹有读写权限：

| 容器路径 | 宿主机路径 | 权限 |
|----------|-----------|------|
| `/workspace/project` | 项目根目录 | 只读 |
| `/workspace/group` | `groups/main/` | 读写 |

容器内关键路径：

- `/workspace/project/store/messages.db` - SQLite 数据库
- `/workspace/project/store/messages.db`（registered_groups 表）- 群组配置
- `/workspace/project/groups/` - 所有群组文件夹

---

## 群组管理

### 查找可用群组

可用群组列表在 `/workspace/ipc/available_groups.json` 中：

```json
{
  "groups": [
    {
      "jid": "120363336345536173@g.us",
      "name": "Family Chat",
      "lastActivity": "2026-01-31T12:00:00.000Z",
      "isRegistered": false
    }
  ],
  "lastSync": "2026-01-31T12:00:00.000Z"
}
```

群组按最近活跃时间排序。列表每天从 WhatsApp 同步。

如果用户提到的群组不在列表中，请求刷新同步：

```bash
echo '{"type": "refresh_groups"}' > /workspace/ipc/tasks/refresh_$(date +%s).json
```

然后稍等片刻，重新读取 `available_groups.json`。

**备选方案**：直接查询 SQLite 数据库：

```bash
sqlite3 /workspace/project/store/messages.db "
  SELECT jid, name, last_message_time
  FROM chats
  WHERE jid LIKE '%@g.us' AND jid != '__group_sync__'
  ORDER BY last_message_time DESC
  LIMIT 10;
"
```

### 已注册群组配置

群组注册在 SQLite 的 `registered_groups` 表中：

```json
{
  "1234567890-1234567890@g.us": {
    "name": "Family Chat",
    "folder": "whatsapp_family-chat",
    "trigger": "@Andy",
    "added_at": "2024-01-31T12:00:00.000Z"
  }
}
```

字段说明：

- **Key**：聊天 JID（唯一标识符 — WhatsApp、Telegram、Slack、Discord 等）
- **name**：群组显示名称
- **folder**：`groups/` 下的渠道前缀文件夹名，用于该群组的文件和记忆
- **trigger**：触发词（通常与全局相同，但可以不同）
- **requiresTrigger**：是否需要 `@trigger` 前缀（默认 `true`）。设为 `false` 用于单聊/个人聊天，处理所有消息
- **isMain**：是否为主控制群组（管理员权限，无需触发词）
- **added_at**：注册时的 ISO 时间戳

### 触发行为

- **主群组**（`isMain: true`）：无需触发词 — 自动处理所有消息
- **设置了 `requiresTrigger: false` 的群组**：无需触发词 — 处理所有消息（用于一对一或个人聊天）
- **其他群组**（默认）：消息必须以 `@AssistantName` 开头才会被处理

### 添加群组

1. 查询数据库找到群组的 JID
2. 使用 `register_group` MCP 工具，传入 JID、名称、文件夹和触发词
3. 可选：包含 `containerConfig` 用于额外挂载
4. 群组文件夹自动创建：`/workspace/project/groups/{folder-name}/`
5. 可选：为群组创建初始 `CLAUDE.md`

文件夹命名规范 — 渠道前缀加下划线分隔符：

- WhatsApp "Family Chat" → `whatsapp_family-chat`
- Telegram "Dev Team" → `telegram_dev-team`
- Discord "General" → `discord_general`
- Slack "Engineering" → `slack_engineering`
- 使用小写字母，群组名部分用连字符

#### 为群组添加额外目录

群组可以挂载额外目录。在其配置中添加 `containerConfig`：

```json
{
  "1234567890@g.us": {
    "name": "Dev Team",
    "folder": "dev-team",
    "trigger": "@Andy",
    "added_at": "2026-01-31T12:00:00Z",
    "containerConfig": {
      "additionalMounts": [
        {
          "hostPath": "~/projects/webapp",
          "containerPath": "webapp",
          "readonly": false
        }
      ]
    }
  }
}
```

该目录将出现在该群组容器的 `/workspace/extra/webapp` 路径下。

#### 发送者白名单

注册群组后，向用户说明发送者白名单功能：

> 这个群组可以配置发送者白名单来控制谁可以与我交互。有两种模式：
>
> - **触发模式**（默认）：所有人的消息都会存储用于上下文，但只有白名单中的发送者可以用 @{AssistantName} 触发我。
> - **丢弃模式**：非白名单发送者的消息完全不存储。
>
> 对于成员可信的封闭群组，我建议设置白名单，这样只有特定的人可以触发我。要我配置吗？

如果用户想设置白名单，在宿主机上编辑 `~/.config/nanoclaw/sender-allowlist.json`：

```json
{
  "default": { "allow": "*", "mode": "trigger" },
  "chats": {
    "<chat-jid>": {
      "allow": ["sender-id-1", "sender-id-2"],
      "mode": "trigger"
    }
  },
  "logDenied": true
}
```

注意事项：

- 你自己的消息（`is_from_me`）在触发检查中会显式绕过白名单。Bot 消息在数据库查询阶段就被过滤掉，不会到达白名单检查。
- 如果配置文件不存在或无效，默认允许所有发送者（fail-open）
- 配置文件在宿主机的 `~/.config/nanoclaw/sender-allowlist.json`，不在容器内

### 移除群组

1. 读取 `/workspace/project/data/registered_groups.json`
2. 删除该群组的条目
3. 写回更新后的 JSON
4. 群组文件夹及其文件保留（不要删除）

### 列出群组

读取 `/workspace/project/data/registered_groups.json` 并格式化输出。

---

## 全局记忆

你可以读写 `/workspace/CLAUDE.md` 来存储应适用于所有群组的信息。只在用户明确要求"全局记住这个"或类似请求时才更新全局记忆。

---

## 为其他群组安排任务

为其他群组安排任务时，使用 `target_group_jid` 参数传入 `registered_groups.json` 中的群组 JID：

- `schedule_task(prompt: "...", schedule_type: "cron", schedule_value: "0 9 * * 1", target_group_jid: "120363336345536173@g.us")`

任务将在该群组的上下文中运行，可访问其文件和记忆。
