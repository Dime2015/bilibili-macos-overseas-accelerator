# bilibili macOS overseas accelerator（B站加速）

在海外用 Mac 版哔哩哔哩 App 看 4K 卡顿？这个小工具让 App 的视频流量走更快的国内 CDN 节点，**不修改 App、不装证书、不用代理软件**。

> English summary: a tiny macOS menu-bar launcher for the official bilibili Mac app (Electron). It injects a hook at startup that redirects video requests from bilibili's overseas CDN nodes (`*-mirrorcosov` / `aliov` / `hwov`, Akamai) to a faster domestic node (default `upos-sz-mirror08c.bilivideo.com`). No app modification, no MITM certificate, no proxy.

## 为什么会卡

海外用户会被分配到海外节点（腾讯云 `cosov`、阿里云 `aliov`、Akamai 等）。实测（日本，家宽约 70 Mbps）：

| 节点 | 已缓存的片段 | 未缓存的片段 |
|---|---|---|
| `upos-sz-mirrorcosov`（海外，默认） | ~40 Mbps | **0.3～1 Mbps** |
| `upos-sz-mirror08c`（国内） | ~50 Mbps | **~50 Mbps** |

海外节点没缓存的部分要回源，速度掉到不到 1 Mbps，而 H.264 4K 需要 10～12 Mbps，所以播放到一半就开始卡。国内节点在海外的速度反而稳定得多。各节点表现因地区和时段而异，菜单里可以切换。

## 用法

1. 下载源码后运行：
   ```bash
   ./build.sh
   ```
   需要 Xcode Command Line Tools（`xcode-select --install`）。构建完成后会安装到 `~/Applications/B站加速.app`。
2. 把 **B站加速** 拖进 Dock，以后**用它来打开哔哩哔哩**。
3. 哔哩哔哩运行时再点一次 B站加速，会打开设置窗口：
   - 查看状态（已转到国内节点多少次）
   - 切换节点：`08c` / `hwb` / `hw` / 暂停（切换立即生效，不用重启）
   - 重启哔哩哔哩
4. 菜单栏也有一个 ⚡ 图标，功能相同（有刘海的 MacBook 上可能被挤到看不见）。
5. 关闭哔哩哔哩时 B站加速 会自动退出。

## 工作原理

1. 用 `--inspect-brk` 启动哔哩哔哩，Electron 主进程会停在第一行代码，等待调试器连接。
2. 启动器通过 Node inspector（Chrome DevTools Protocol）注入 [`src/hook.js`](src/hook.js)，然后让 App 继续运行，再用 `process._debugEnd()` 关掉调试端口。
3. `hook.js` 包装每个 session 的 `webRequest` API：
   - `onBeforeRequest`：把海外节点的视频请求重定向到选定的国内节点。B 站的签名链接在各个 `upos` 镜像之间通用。
   - `onBeforeSendHeaders`：App 自己用这个事件给 CDN 请求加 `Referer` / `Origin`，CDN 没有 `Referer` 会返回 403。Electron 每个事件只允许一个监听器，所以这里不替换 App 的监听器，而是包装它：重定向后的请求按原 URL 交给 App 处理，并确保带上 `Referer`。
4. 设置保存在 `~/Library/Application Support/BiliCDN/config.json`，hook 会监听这个文件；统计数据写在同目录的 `stats.json`。

只有通过 B站加速 启动的哔哩哔哩才会生效。直接打开哔哩哔哩就是原样。

## 适用范围与限制

- 测试环境：哔哩哔哩 Mac 版 1.18.0（Electron 22）、Apple Silicon、macOS 27。
- 前提是 App 的 Electron fuse `EnableNodeCliInspectArguments` 处于开启状态。如果 B 站以后关掉它，注入会失败（启动器显示 ⚠️），App 本身照常运行。
- **不支持网页版**、iOS、Apple TV：只对 Mac App 有效。
- 只改 DNS 的方法行不通：国内节点会拒绝不属于自己的 SNI（TLS 握手失败）。
- 调试端口只绑定 `127.0.0.1`，使用随机端口，注入完成后立即关闭。

## 免责声明

本项目与哔哩哔哩官方无关，仅供个人学习和改善自己的观看体验。它不绕过任何会员或版权限制，只改变视频文件从哪个 CDN 节点下载。请自行承担使用风险。

## License

[MIT](LICENSE)
