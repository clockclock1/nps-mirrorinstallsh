# nps-mirrorinstallsh

面向 [nps / npc](https://github.com/djylb/nps) 的镜像源一键安装脚本。

脚本不再依赖单一下载地址：每次运行都会**并行探测** GitHub、jsDelivr CDN 各节点
以及多个公共 GitHub 代理，按当前网络实测速度排序，优先用最快的镜像下载，失败
自动按顺序回退。版本号解析也有三条独立通道，`api.github.com` 被墙时仍能取到最
新 tag。

覆盖镜像：`github`、`jsdelivr`、`fastly`、`gcore`、`testingcf`、`ghproxy`、
`ghproxycom`、`ghfast`、`gitmirror`、`moeyy`。

---

## 服务端安装

### Linux

```bash
# 自动选择最快镜像安装 nps 服务端（jsDelivr CDN 节点 → GitHub 代理 → GitHub 直连）
# 默认配置路径：/etc/nps/；二进制路径：/usr/bin/
curl -fsSL https://cdn.jsdelivr.net/gh/clockclock1/nps-mirrorinstallsh@main/install.sh | sudo sh -s nps

# jsDelivr 不可用时的备用入口
curl -fsSL https://raw.githubusercontent.com/clockclock1/nps-mirrorinstallsh/main/install.sh | sudo sh -s nps
curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/clockclock1/nps-mirrorinstallsh/main/install.sh | sudo sh -s nps

sudo nps install
sudo nps start|stop|restart|uninstall

# 更新
sudo nps update
sudo nps update-force
```

> **提示：** 首次安装后请先编辑 `/etc/nps/conf/nps.conf`，确认配置无误后再执行 `nps start`。
>
> **镜像控制：** 默认自动测速。可用 `sudo NPS_MIRROR_ORDER="jsdelivr,ghproxy,github" sh -s nps`
> 固定顺序，`NPS_MIRROR_PROBE=0` 关闭测速，`NPS_MIRRORS="jsdelivr,github"` 替换候选列表，
> `NPS_NO_MIRROR=1` 仅使用 GitHub。

## 客户端安装

### Linux

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/clockclock1/nps-mirrorinstallsh@main/install.sh | sudo sh -s npc
sudo /usr/bin/npc install -launch="npc://YOUR_VKEY@203.0.113.10:8024?type=tls"
sudo npc start|stop|restart|uninstall

# 更新
sudo npc update
sudo npc update-force
```

> **提示：** `npc install` 的参数请以 NPS Web 管理端客户端页面生成的命令为准。

---

## 用法

```text
sh install.sh [模式] [版本] [安装目录]

模式       npc | nps | all           （默认 all）
版本       发布 tag，如 v0.35.6       （默认 latest）
安装目录   只解压到该目录，不改动 /usr/bin 与 /etc/nps
```

示例：

```bash
# 安装指定版本
curl -fsSL https://cdn.jsdelivr.net/gh/clockclock1/nps-mirrorinstallsh@main/install.sh | sudo sh -s nps v0.35.6

# 只下载解压，不改动系统
sh install.sh all latest /tmp/nps-pkg

# 固定镜像顺序（跳过测速）
NPS_MIRROR_ORDER="gcore,jsdelivr,github" sudo sh install.sh nps
```

### 环境变量

| 变量 | 含义 | 默认 |
| --- | --- | --- |
| `NPS_MIRROR_ORDER` | 固定镜像顺序，如 `jsdelivr,ghproxy,github`，设置后跳过测速 | 自动测速 |
| `NPS_MIRRORS` | 替换候选镜像列表 | 内置 10 个镜像 |
| `NPS_MIRROR_PROBE=0` | 关闭测速，使用内置顺序 | 开启 |
| `NPS_PROBE_TIMEOUT` | 单个镜像探测超时，秒 | `4` |
| `NPS_CONNECT_TIMEOUT` | 下载连接超时，秒 | `10` |
| `NPS_DOWNLOAD_TIMEOUT` | 单次下载总超时，秒 | `300` |
| `NPS_NO_MIRROR=1` | 仅使用 GitHub 直连 | 关闭 |
| `NPS_IPV4=1` | curl/wget 强制 IPv4 | 关闭 |
| `NPS_INSECURE=1` | 跳过 TLS 校验 | 关闭 |
| `NPS_INSTALL_MODE` / `NPS_INSTALL_VERSION` / `NPS_INSTALL_DIR` | 与位置参数等价 | — |

## 镜像选择逻辑

1. 对每个镜像并行发起一个小请求（`install.sh`，最多 64 KiB），4 秒截止。
2. 按耗时排序；探测失败的镜像不会被丢弃，而是排到最后作为兜底。
3. 用第一个下载成功的镜像获取发布包，并打印该次下载耗时。
4. 若 `/releases/latest` 解析失败，退回 jsDelivr 的 `@latest` 别名（由服务端解析）。

探测结果反映脚本实际运行所在的网络，因此国内主机通常选中 `gcore` /
`testingcf` / `ghproxy`，海外主机通常选中 `github` 或 `jsdelivr`。

## 实测

在 Debian 13（x86_64）上通过镜像链完成安装并运行，随后清理：

```text
Version: 0.35.6
Core version: 0.34.0
```

## 许可证

与上游 nps 一致，见 [LICENSE](LICENSE)。
