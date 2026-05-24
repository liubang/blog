---
title: "DataNode 内部机制 — 本地存储、心跳与块报告"
description: "深入 MiniDFS DataNode 的内部世界：LocalBlockStore 的目录布局与 BlockHeader 二进制格式、HeartbeatSender 的后台线程与命令分发、BlockReporter 的全量报告与增量追踪，以及 NameNode 侧 DataNodeManager 的状态机设计。"
date: 2026-05-24
categories: [存储与分布式]
tags: [distributed-system, hdfs, datanode, heartbeat, storage-engine, cpp]
authors: ["liubang"]
weight: 5
series: ["MiniDFS"]
series_weight: 5
lightgallery: true
---

前四篇从全局视角走完了 MiniDFS 的命名空间、写入 Pipeline 和元数据管理。从这一篇开始，我们把视角切换到单个 DataNode 内部——它如何管理本地磁盘上的 block 文件，如何通过心跳向 NameNode 证明自己还活着，以及如何通过块报告让 NameNode 了解它持有哪些副本。

![DataNode 内部架构](/images/minidfs/datanode-internals.svg "DataNode 进程内部组件：LocalBlockStore、HeartbeatSender、BlockReporter 与 NameNode 的交互")

## LocalBlockStore：本地存储引擎

### 目录布局

每个 DataNode 的数据根目录下有三个子目录，对应 block 文件的三个生命阶段：

```
<storage_root>/
  tmp/            — 正在通过 Pipeline 写入的 block
    blk_1001_42.blk
  current/        — 已 finalize 的 block，对外可读
    blk_1000_41.blk
  trash/          — 软删除的 block，等待异步清理
    blk_999_40.blk
```

文件命名格式为 `blk_<block_id>_<generation_stamp>.blk`，将 block_id 和 generation_stamp 编码在文件名中，使得文件系统层面即可唯一标识一个 block 的特定版本。

生命周期转换通过 `rename(2)` 实现原子性：`create_block` 在 `tmp/` 创建文件，Pipeline 写入完成后 `finalize_block` 将其 rename 到 `current/`，NameNode 要求删除时 `delete_block` 将其 rename 到 `trash/`，最后 `purge_trash` 执行物理删除。每一步都是原子的——不存在"半完成"的中间态。

```cpp
pl::Result<pl::Void> LocalBlockStore::finalize_block(uint64_t block_id,
                                                     uint64_t generation_stamp) {
    std::lock_guard lock(mu_);
    auto src = block_path("tmp", block_id, generation_stamp);
    auto dst = block_path("current", block_id, generation_stamp);

    std::error_code ec;
    std::filesystem::rename(src, dst, ec);
    if (ec) {
        return pl::makeError(ErrorCode::kIOError, ec.message());
    }
    return pl::Void{};
}
```

### BlockHeader 二进制格式

每个 block 文件的头部是一个固定大小的 `#pragma pack(push, 1)` 结构体。这种设计允许通过 `pread/pwrite` 直接对 header 进行原子读写，无需序列化/反序列化开销：

```cpp
#pragma pack(push, 1)
struct BlockHeader {
    uint32_t magic = kBlockMagic;           // 0x4D444653 ("MDFS")
    uint32_t version = kBlockFormatVersion; // 1
    uint64_t block_id = 0;
    uint64_t inode_id = 0;
    uint32_t block_index = 0;
    uint64_t generation_stamp = 0;
    uint64_t data_length = 0;
    uint32_t compression_type = 0;
    uint32_t chunk_size = kDefaultChunkSize; // 1MB
    uint32_t chunk_count = 0;
    uint32_t checksum_type = static_cast<uint32_t>(ChecksumType::kCRC32C);
    uint32_t block_checksum = 0;
    uint32_t chunk_offsets[kMaxChunkCount] = {};   // 256 slots
    uint32_t chunk_checksums[kMaxChunkCount] = {}; // 256 slots
    uint8_t reserved[32] = {};
};
#pragma pack(pop)

static_assert(std::is_trivially_copyable_v<BlockHeader>,
              "BlockHeader must be trivially copyable for direct I/O.");
```

关键设计决策：`chunk_offsets` 和 `chunk_checksums` 数组大小固定为 `kMaxChunkCount`（256），即使 block 只有几个 chunk 也占满空间。这是一个空间换简单性的取舍——固定 header 大小意味着 data region 的起始偏移量是编译期常量 `kBlockHeaderSize`，随机读取某个 chunk 时无需解析变长 header。以默认 128 MB block / 1 MB chunk 计算，最多 128 个 chunk 远在 256 的上限之内。

`magic` 字段（`0x4D444653`，即 ASCII "MDFS"）用于文件格式识别和防止误读损坏文件。`validate_block_header` 在每次读取前检查 magic 和 version，任何不匹配都意味着文件损坏。

### 容量保护

`LocalBlockStore` 初始化时配置 `reserved_bytes`（默认 1 GB）。`available_bytes()` 通过 `std::filesystem::space()` 获取磁盘可用空间并减去保留量，当可用空间不足时拒绝新的 `create_block` 请求。这是一个简单但有效的保护机制——防止磁盘写满导致操作系统或日志等关键功能不可用。

## HeartbeatSender：心跳机制

### 设计目标

心跳是 DataNode 向 NameNode 证明自己存活的唯一方式。MiniDFS 的 `HeartbeatSender` 是一个后台线程，每 `kDefaultHeartbeatIntervalMs`（3 秒）发送一次心跳 RPC，携带当前磁盘容量信息。NameNode 据此更新 DataNode 的状态和可用容量，并在响应中下发管理命令。

```cpp
pl::Result<std::vector<HeartbeatCommand>> HeartbeatSender::send_once() {
    // 从本地文件系统获取容量信息
    auto avail_result = store_->available_bytes();
    uint64_t free_bytes = avail_result.hasValue() ? avail_result.value() : 0;

    std::error_code ec;
    auto space = std::filesystem::space(store_->storage_root(), ec);
    uint64_t capacity_bytes = ec ? 0 : space.capacity;
    uint64_t used_bytes = ec ? 0 : (space.capacity - space.available);

    // 发送心跳 RPC
    auto result = heartbeat_func_(config_.datanode_id, capacity_bytes,
                                  used_bytes, free_bytes);
    if (result.hasError()) {
        XLOGF(WARN, "heartbeat failed for datanode {}: {}",
              config_.datanode_id, result.error().describe());
        return pl::makeError(std::move(result.error()));
    }

    // 分发 NameNode 下发的命令
    for (const auto& cmd : result.value()) {
        if (cmd.type != CommandType::kNone && command_handler_) {
            command_handler_(cmd);
        }
    }
    return std::move(result.value());
}
```

### 命令分发

NameNode 在心跳响应中可能附带管理命令，由 `CommandHandler` 回调分发给对应的 worker：

```cpp
enum class CommandType : uint8_t {
    kNone = 0,
    kReplicate = 1,  // 将某个 block 复制到指定 DN
    kDelete = 2,     // 删除本地某个 block 副本
    kInvalidate = 3, // 作废并重新上报
    kShutdown = 4,   // 优雅停机
};
```

`kReplicate` 是最常见的命令——当 NameNode 检测到某个 block 的副本数不足时，选择一个持有该 block 的 DataNode 下发 Replicate 命令，由 `ReplicationWorker` 将数据发送到目标节点。`kDelete` 则用于清理多余副本或已失效的 block。

### 优雅停机

后台线程通过 `std::atomic<bool> running_` 控制。`stop()` 只需要将 `running_` 设为 false，`run_loop` 中的 sleep 每 100ms 醒来检查一次标志位，保证最长 100ms 内响应停机请求：

```cpp
void HeartbeatSender::run_loop() {
    while (running_.load(std::memory_order_relaxed)) {
        send_once();
        // 每 100ms 醒来检查 running_ 标志，实现快速停机
        auto deadline = std::chrono::steady_clock::now() +
                        std::chrono::milliseconds(config_.interval_ms);
        while (running_.load(std::memory_order_relaxed) &&
               std::chrono::steady_clock::now() < deadline) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
    }
}
```

## BlockReporter：块报告

### 全量报告

BlockReporter 是另一个后台线程，每 `kDefaultBlockReportIntervalMs`（10 分钟）执行一次全量块报告——扫描 `current/` 目录下所有 block 文件，将 `{block_id, generation_stamp, length}` 列表发送给 NameNode。NameNode 据此与自己的元数据对账：如果 DataNode 持有 NameNode 不知道的 block，标记为待删除；如果 NameNode 记录的某个副本在 DataNode 上不存在，标记为丢失并触发 re-replication。

```cpp
pl::Result<BlockReportResponse> BlockReporter::send_full_report() {
    auto blocks_result = store_->report_blocks();
    if (blocks_result.hasError()) {
        return pl::makeError(std::move(blocks_result.error()));
    }

    auto response = report_func_(config_.datanode_id, blocks_result.value());
    if (response.hasError()) {
        return pl::makeError(std::move(response.error()));
    }

    // 处理 NameNode 返回的删除指令
    process_response(response.value());

    // 全量报告成功后清除增量跟踪数据
    {
        std::lock_guard lock(delta_mu_);
        added_blocks_.clear();
        removed_blocks_.clear();
    }
    return std::move(response.value());
}
```

### 增量追踪

在两次全量报告之间，BlockReporter 维护 `added_blocks_` 和 `removed_blocks_` 两个集合，通过 `notify_block_finalized` 和 `notify_block_deleted` 接口实时更新。当 `finalize_block` 完成后，Pipeline handler 调用 `notify_block_finalized` 将 block_id 加入增量集合；当 `delete_block` 执行后调用 `notify_block_deleted`。

增量数据目前尚未用于发送增量报告（MiniDFS 简化为每次都发全量），但这个追踪机制为未来优化预留了接口——HDFS 的增量块报告正是基于类似的 delta tracking 实现，将 10 分钟间隔的全量报告压力降低了数个数量级。

### 启动时的首次报告

BlockReporter 启动后立即发送一次全量报告（`run_loop` 的第一行就是 `send_full_report()`），确保 NameNode 在 DataNode 加入集群的第一时间就了解其存储的所有 block。这对于故障恢复至关重要——如果一个 DataNode 重启后不立即报告，NameNode 会认为其副本全部丢失并触发不必要的 re-replication。

## DataNodeManager：NameNode 侧的状态机

### 状态转换

NameNode 的 `DataNodeManager` 负责维护所有 DataNode 的状态。每个 DataNode 有三个主要状态：`Live`（正常）、`Stale`（可疑）、`Dead`（已死亡）。状态转换由 `check_stale_and_dead()` 定期扫描触发：

```cpp
pl::Result<uint32_t> DataNodeManager::check_stale_and_dead() {
    auto all_dns = store_->list_all_datanodes();
    if (all_dns.hasError()) {
        return folly::makeUnexpected(all_dns.error());
    }

    uint64_t ts = now_ms();
    uint32_t changed = 0;

    for (auto& dn : all_dns.value()) {
        if (dn.state == DataNodeState::kDecommissioning ||
            dn.state == DataNodeState::kDecommissioned) {
            continue;
        }

        uint64_t elapsed = ts - dn.last_heartbeat_ms;
        DataNodeState new_state = dn.state;

        if (elapsed >= kDefaultDeadTimeoutMs) {        // 600s
            new_state = DataNodeState::kDead;
        } else if (elapsed >= kDefaultStaleTimeoutMs) { // 30s
            new_state = DataNodeState::kStale;
        } else {
            new_state = DataNodeState::kLive;
        }

        if (new_state != dn.state) {
            dn.state = new_state;
            store_->upsert_datanode(dn);
            ++changed;
        }
    }
    return changed;
}
```

### 时间常量的设计考量

三个关键时间常量的选择并非随意：

`kDefaultHeartbeatIntervalMs = 3000`（3 秒）——心跳频率。足够频繁以快速检测故障，又不至于给 NameNode 造成过大 RPC 压力。在千级别 DataNode 集群中，每秒约 300 次心跳 RPC 是完全可承受的。

`kDefaultStaleTimeoutMs = 30000`（30 秒）——Stale 阈值。允许 10 次连续心跳失败才判定为 Stale。网络抖动、GC 暂停或瞬时高负载都可能导致个别心跳延迟，30 秒的宽容度避免了误判。Stale 状态的 DataNode 不参与新 block 的放置，但其上的已有副本仍然对读路径可用。

`kDefaultDeadTimeoutMs = 600000`（10 分钟）——Dead 阈值。一旦标记为 Dead，NameNode 将该节点上所有副本视为丢失，触发 re-replication。10 分钟给了运维足够的时间处理瞬时故障（如机器重启），避免短暂中断引发大规模数据复制风暴。

### 注册与重新注册

`register_datanode` 支持幂等的重新注册——如果 UUID 已存在，则更新该 DataNode 的信息并重置状态为 Live。这处理了 DataNode 重启后携带新的 RPC 端口重新加入集群的场景。首次注册时通过 `alloc_id("datanode")` 分配全局唯一的 datanode_id。

```cpp
pl::Result<uint64_t> DataNodeManager::register_datanode(
    std::string_view uuid, std::string_view hostname,
    std::string_view ip, uint32_t rpc_port, uint32_t data_port,
    std::string_view rack, uint64_t capacity_bytes) {
    auto existing = store_->get_datanode_by_uuid(uuid);
    uint64_t ts = now_ms();

    if (existing.value().has_value()) {
        // 重新注册：更新信息，重置为 Live
        auto& dn = existing.value().value();
        dn.hostname = std::string(hostname);
        dn.ip = std::string(ip);
        dn.rpc_port = rpc_port;
        dn.data_port = data_port;
        dn.rack = std::string(rack);
        dn.state = DataNodeState::kLive;
        dn.capacity_bytes = capacity_bytes;
        dn.last_heartbeat_ms = ts;
        store_->upsert_datanode(dn);
        return dn.datanode_id;
    }

    // 新注册：分配 ID
    auto id_result = store_->alloc_id("datanode");
    DataNodeInfo dn;
    dn.datanode_id = id_result.value();
    dn.uuid = std::string(uuid);
    // ... 填充其他字段 ...
    dn.state = DataNodeState::kLive;
    dn.last_heartbeat_ms = ts;
    store_->upsert_datanode(dn);
    return dn.datanode_id;
}
```

## 组件协作：一次完整的 DataNode 生命周期

将上述组件串联起来，一个 DataNode 从启动到稳态运行的过程如下：启动时 `LocalBlockStore::init()` 确保三个子目录存在；然后向 NameNode 发送 `register_datanode` 注册自身；注册成功后启动 `HeartbeatSender` 和 `BlockReporter` 两个后台线程。

BlockReporter 立即发送首次全量报告，让 NameNode 了解本节点持有的所有 block。此后 HeartbeatSender 每 3 秒发送心跳保持 Live 状态，BlockReporter 每 10 分钟发送一次全量报告用于对账。NameNode 通过心跳响应下发命令——Replicate 命令交给 ReplicationWorker 处理，Delete 命令直接调用 `LocalBlockStore::delete_block`。

当有写入请求到来时，`DataTransferService::WriteBlock` 通过 `LocalBlockStore` 在 `tmp/` 中写入数据，完成后 `finalize_block` 将文件原子 rename 到 `current/`，同时通知 BlockReporter 更新增量集合。整个流程中没有单点——HeartbeatSender 失败只是日志告警，BlockReporter 失败会在下一轮重试，`finalize_block` 的原子性保证不会出现半写入的 block 对外可见。

## 小结

DataNode 的内部设计体现了分布式存储系统的几个核心原则：本地存储通过目录分级和原子 rename 实现状态隔离与故障安全；心跳机制用最小的开销维持存活性检测，同时承载管理命令的下发通道；块报告让 NameNode 能够在无状态的情况下重建副本分布的全景视图；而状态机的三级超时设计（Live/Stale/Dead）平衡了故障检测速度和误判风险。

下一篇将讨论读取链路——Client 如何从多个副本中选择最优的读取目标，DataNode 如何通过 chunk 级 CRC 校验保证返回数据的完整性，以及读取失败时的 failover 机制。
