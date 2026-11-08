# Agent CLI 与输出路径规范

这不是 Web 前后端。应用按职责分层：SwiftUI 图形界面、独立 `pathsync` 命令入口、共享的签名 Swift 调度核心，以及 Python 同步/索引引擎。`rules`、`check-path` 使用 Python 引擎的同一排除匹配器，读取当前根规则与本机仅云端策略；`status`、`preview`、`sync` 走已有签名核心，保留同步锁、凭据、备份和冲突保护；`stop` 使用同一运行 UUID 停止协议。没有新增 HTTP 服务。

## 安装

```sh
/usr/bin/python3 '/Applications/路径同步.app/Contents/Resources/install-agent-cli.py'
```

入口安装到 `~/.local/bin/pathsync`，指向已安装应用的当前资源，应用升级后不会留在旧引擎副本。若要安装已约定的全局 Codex 输出规范，显式加 `--instructions`；会备份并保留原有 AGENTS 内容，更新独立标记区。存在生效的非空全局 `AGENTS.override.md` 时，也在该文件保留相同约定。规范模板见 [agent-instructions.md](agent-instructions.md)。其他 agent 可引用同一文档。

## 命令

```sh
pathsync version --json
pathsync rules --json
pathsync rules --pair '科研' --json
pathsync check-path "$HOME/Documents/科研/results/final.pdf" --json
pathsync check-path "$HOME/Documents/科研/results" --directory --json
pathsync status --json
pathsync preview --pair '科研' --json
pathsync sync --pair '科研' --json
pathsync stop --json
```

所有 JSON 均含 `schemaVersion: 1`。组名要求唯一，也可用 UUID；不存在或重名会报错，不会退回同步全部路径。同步方向沿用保存值；被禁用的组不能通过该 CLI 强行启动。`--config PATH` 须放在子命令前，仅供显式读取另一份本机配置，`stop` 操作全局当前任务，不接受该参数。读取当前配置不代表读取 GUI 未保存草稿。

`check-path` 返回 `classification`、`matchedRules`、`cloudOnlyPaths`、`safeForImportantOutput` 和规则来源。退出码 0 表示处于启用且允许上传的本机工作范围；3 表示排除、仅云端、符号链接或协议保留路径；4 表示未纳入同步、组未启用/配置不完整、仅下载方向或云端镜像；2 表示规则未知或错误，不能当作允许。状态和规则查询成功为 0；实际同步/预览透传核心退出码，用户停止为 130。

路径检查只确认当前配置适合承载输出，不证明服务器已收到文件。根规则缺失、无效、仅在线或读取不稳定时，不使用本地历史规则兜底。规则/路径查询不调用 Graph，不打开待检查业务文件，不下载云端占位文件；实际同步沿用现有按需下载行为。

“仅云端”是本机暂停整个子树的上传和下载，不是所有设备共同排除；每台 Mac 都必须查询自己的 CLI。配置包含私有目录名，不能把实际 `rules --json` 输出上传到公共仓库。
