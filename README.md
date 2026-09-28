# v2node
A v2board backend base on moddified xray-core.
一个基于修改版xray内核的V2board节点服务端。

**注意： 本项目需要搭配[修改版V2board](https://github.com/wyx2685/v2board)**

## 软件安装

### 一键安装

```
wget -N https://raw.githubusercontent.com/Tommy8mao/v2node/main/script/install.sh && bash install.sh
```

## 构建
``` bash
GOEXPERIMENT=jsonv2 go build -v -o build_assets/v2node -trimpath -ldflags "-X 'github.com/wyx2685/v2node/cmd.version=$version' -s -w -buildid="
```

### PROXY protocol 与普通 TCP 共用监听口

本地版本使用 `third_party/xray-core`。节点设置 `network_settings.acceptProxyProtocol=true` 时，同一监听口接受普通 TCP、PROXY protocol v1 和 v2；有 PROXY 头时按头部的来源地址处理，没有时保留原始连接数据。Next-V1 内层监听口也使用此行为。未开启该设置的其他监听口不受影响。

任何能连接此监听口的客户端都可以通过自带 PROXY 头伪造来源 IP。安装脚本从此仓库最新 GitHub Release 下载二进制；推送 `main` 本身不会更新已安装的节点。机器上的旧 `v2node update` 管理脚本仍可能指向上游仓库，首次升级请运行上方安装命令。发布 `v0.4.4-next-v1.6` 后，该命令才会下载包含本次改动的版本。

## Stars 增长记录

[![Stargazers over time](https://starchart.cc/wyx2685/v2node.svg?variant=adaptive)](https://starchart.cc/wyx2685/v2node)
