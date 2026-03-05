# Debian VPS 一键初始化与深度调优脚本

专为 Debian 生产环境设计的重装后基础配置脚本。采用防御性 Bash 编程 (set -Eeuo pipefail) 编写，具备高容错性、幂等性，并能根据系统内存大小智能分档调优网络并发参数。

## 🌟 核心特性

* **智能 Swap 部署**：自动检测内存大小。`<2G` 内存分配 `2G` Swap，`>=2G` 内存分配 `1G` Swap。完美兼容并修复了 Btrfs 文件系统的写时复制 (COW) 和压缩冲突陷阱。
* **自适应内核与网络调优**：告别死板参数。脚本会自动将机器划分为“小内存 / 中等 / 大内存”三档，动态计算 TCP 读写缓冲区 (`rmem/wmem`)、连接队列 (`somaxconn`) 以及系统预留物理内存 (`min_free_kbytes`)，在榨干网络吞吐量的同时严防 OOM。
* **网络加速**：全自动检测并开启 BBR 拥塞控制算法及 FQ 队列，并写入开机加载模块。
* **基础安全加固**：一键关闭 IPv6、禁用 ICMP Ping 响应、优化 TCP TIME-WAIT 状态及防御 SYN Flood 攻击。
* **极高鲁棒性**：具备虚拟化容器 (LXC/OpenVZ) 智能预警、临时文件全局 Trap 回收以及依赖项自动补全机制。

## 🚀 快速使用

以 `root` 用户登录你的 Debian 服务器，执行以下命令即可一键完成初始化：

```bash
bash <(curl -sL [https://raw.githubusercontent.com/yellowdking/vps-setup/main/systemstart.sh](https://raw.githubusercontent.com/yellowdking/vps-setup/main/systemstart.sh))
