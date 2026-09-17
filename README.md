# Codex Quota Bar

在 macOS 菜单栏显示 Codex 剩余额度、重置倒计时和当天模型调用汇总。

Codex Quota Bar is an unofficial macOS menu bar utility for viewing remaining Codex quota and local daily model activity.

> [!IMPORTANT]
> 这是非官方社区项目，与 OpenAI 没有关联或背书。Codex 和 OpenAI 是其各自权利人的商标。

## 功能

- 菜单栏显示剩余额度和距离重置的时间，例如 `26% 2d8h`。
- 不足一天时显示到分钟，例如 `5h30m`。
- 展示额度更新时间、重置时间、重置券数量及最近到期日。
- 汇总当天使用的模型、推理等级和调用次数。
- 按任务展示对应模型、推理等级和调用次数。
- 启动时查询额度，之后每 5 分钟自动更新；也可手动刷新。
- 原生 Swift + AppKit，无 Electron、无第三方运行时依赖。

## 访问逻辑与隐私

### 实时额度

应用会查找本机已经安装的官方 `codex` 命令行程序，然后短暂启动：

```text
codex app-server --stdio
```

通过本地 JSON-RPC 调用 `account/rateLimits/read` 获取：

- 已用百分比和剩余百分比；
- 额度重置时间；
- 重置券数量和最近到期时间。

这次调用会由 Codex CLI 使用现有 ChatGPT 登录状态访问 OpenAI，因此会产生一条很小的网络请求，但不会启动模型任务，也不会消耗 Codex 对话额度。Codex Quota Bar 不读取、不复制、不保存登录 token。

查询发生在启动时、每 5 分钟以及点击“刷新”时。查询失败会继续展示上一次成功结果并标记为旧数据，不会连续重试。

### 本地模型统计

当天模型和任务汇总只读访问以下本机数据库：

```text
~/.codex/logs_2.sqlite
~/.codex/state_5.sqlite
~/.codex/thread_history_1.sqlite
```

读取通过系统自带的 `/usr/bin/sqlite3 -readonly` 完成，不修改数据库。应用不上传任务标题、模型统计或 SQLite 内容。

### 不会做的事

- 不调用模型生成内容；
- 不保存 ChatGPT/Codex 凭证；
- 不修改 `~/.codex` 数据库；
- 不包含遥测、广告或第三方分析；
- 不向 OpenAI 以外的服务发送请求。

`account/rateLimits/read` 属于 Codex app-server 协议，未来 Codex 版本可能调整该协议。如果实时查询失效，请提交 issue 并附上 Codex 版本和错误现象，不要上传凭证或数据库文件。

## 系统要求

- macOS 14 或更高版本；
- 已安装并登录 Codex/ChatGPT Desktop，或安装了兼容的 Codex CLI；
- Apple Silicon Mac。源码可在其他架构的 Mac 上自行编译。

应用会按顺序查找常见的 Codex CLI 路径，包括 ChatGPT/Codex Desktop、`~/.local/bin`、Homebrew 和 `/usr/local/bin`。

## 从源码构建

```bash
git clone https://github.com/IsaacSu95/codex-quota-bar.git
cd codex-quota-bar
./package_share.sh
```

构建产物：

```text
dist-share/CodexQuotaBar.app
dist-share/CodexQuotaBar.zip
```

## 安装

将 `CodexQuotaBar.app` 拖入系统 `/Applications` 文件夹后运行。

当前构建使用 ad-hoc 签名，没有 Apple Developer ID 公证。如果 macOS 阻止首次打开：

1. 在访达中右键应用并选择“打开”；
2. 再次确认打开；
3. 或在“系统设置 → 隐私与安全性”中允许本次启动。

源码安装到当前用户目录：

```bash
./install_to_applications.sh
```

该脚本安装到 `~/Applications/CodexQuotaBar.app`，聚焦搜索可以找到它；访达侧边栏的“应用程序”通常对应系统 `/Applications`。

## 命令行诊断

只读取本地模型和任务统计：

```bash
dist-share/CodexQuotaBar.app/Contents/MacOS/CodexMeter --once
```

执行一次实时额度查询：

```bash
dist-share/CodexQuotaBar.app/Contents/MacOS/CodexMeter --fetch-usage
```

诊断输出只包含额度、重置时间和重置券信息，不输出账号 ID 或凭证。

## AI 协作声明

本项目由 [IsaacSu95](https://github.com/IsaacSu95) 以个人名义提出需求、确定交互并进行验收，主要代码与文档通过 OpenAI Codex 协作生成和迭代。

AI 生成不代表代码天然正确或安全。项目保留了简洁实现并进行了编译、额度查询和打包验证，但使用者仍应自行审查源码，尤其是在 Codex app-server 协议或本地数据库结构发生变化后。

## License

[MIT](LICENSE)
