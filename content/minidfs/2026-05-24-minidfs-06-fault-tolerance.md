---
title: "MiniDFS 06: 容错与自愈"
description: "MiniDFS 容错体系的完整闭环：Lease 写互斥防止并发冲突、ReplicationManager 扫描与修复欠副本、Heartbeat 通道下发命令、ReplicationWorker 执行数据拷贝，以及幂等性与事务原子性保障。"
date: 2026-05-24
categories: [存储与分布式]
tags: [distributed-system, hdfs, fault-tolerance, replication, cpp]
authors: ["liubang"]
weight: 6
series: ["MiniDFS"]
series_weight: 6
lightgallery: true
---

分布式存储系统的核心价值不在于"一切正常时能工作"，而在于"局部故障时仍然可靠"。前五篇我们搭建了 MiniDFS 的完整数据通路——从命名空间到元数据持久化，从读路径到写 Pipeline，再到 DataNode 内部机制。这一篇，我们把目光转向系统的免疫系统：Lease 管理如何防止写冲突，ReplicationManager 如何检测和修复副本缺失，以及整个容错闭环如何通过 Heartbeat 通道协调 NameNode 与 DataNode 完成自愈。

## Lease 管理：写互斥的语义保证

在分布式文件系统中，同一个文件不能被两个 Client 同时写入——否则数据会混乱不可恢复。MiniDFS 通过 Lease 机制实现写互斥：Client 在 CreateFile 时获取 Lease，持有期间独占写权限，CompleteFile 时释放。

LeaseManager 的接口设计非常精炼：

```cpp
class LeaseManager {
public:
    explicit LeaseManager(MetadataStore* store);

    Result<uint64_t> acquire_lease(uint64_t inode_id,
                                   const std::string& client_id);
    Result<Void> renew_lease(uint64_t lease_id,
                             const std::string& client_id);
    Result<Void> release_lease(uint64_t lease_id);
    Result<Void> expire_stale_leases();
    Result<bool> has_active_lease(uint64_t inode_id);

private:
    MetadataStore* store_;
};
```

几个关键设计决策值得展开讨论。

### 互斥语义

`acquire_lease` 在获取前先检查目标 inode 是否已有 active lease。如果有，直接返回 `kLeaseConflict` 错误码，不做排队或等待。这是有意为之——在文件系统语义中，写冲突是程序 bug 而非正常竞争，快速失败比排队等待更合理。

```cpp
Result<uint64_t> LeaseManager::acquire_lease(uint64_t inode_id,
                                             const std::string& client_id) {
    auto existing = store_->get_active_lease(inode_id);
    if (existing.ok() && existing.value().state == LeaseState::kActive) {
        return Error(ErrorCode::kLeaseConflict);
    }

    auto now = current_time_ms();
    Lease lease{
        .inode_id = inode_id,
        .client_id = client_id,
        .state = LeaseState::kActive,
        .acquire_time_ms = now,
        .expire_time_ms = now + kDefaultLeaseTimeoutMs,  // 60s
    };
    return store_->create_lease(lease);
}
```

### 续约与超时

Client 在写入过程中需要周期性续约（通过 `RenewLease` RPC），否则 Lease 会在 60 秒后过期。续约时会验证 client_id 一致性——只有 Lease 的持有者才能续约，防止其他 Client 劫持写会话。

```cpp
Result<Void> LeaseManager::renew_lease(uint64_t lease_id,
                                       const std::string& client_id) {
    auto lease = store_->get_active_lease_by_id(lease_id);
    if (!lease.ok()) return Error(ErrorCode::kLeaseNotFound);
    if (lease.value().client_id != client_id) {
        return Error(ErrorCode::kLeaseConflict);
    }

    auto new_expire = current_time_ms() + kDefaultLeaseTimeoutMs;
    return store_->renew_lease(lease_id, new_expire);
}
```

### 过期回收

NameNode 后台线程定期调用 `expire_stale_leases()` 批量关闭超时的 Lease。这处理的是 Client 崩溃的场景——Client 进程死掉后无法 release lease，系统需要自动回收以允许后续写入：

```cpp
Result<Void> LeaseManager::expire_stale_leases() {
    auto now = current_time_ms();
    return store_->expire_leases(now);  // UPDATE leases SET state='closed' WHERE expire_time_ms < now
}
```

### 与写路径的集成

Lease 的生命周期严格绑定在文件写入的完整流程中：

```
CreateFile  → inode(kUnderConstruction) + acquire_lease → 返回 lease_id
写入过程中  → 周期性 RenewLease
CompleteFile → release_lease + inode(kNormal) → 文件可读
```

如果 CreateFile 后 Client 崩溃，Lease 过期后 inode 仍处于 kUnderConstruction 状态。此时其他 Client 可以对该文件执行 recovery（实际场景中会涉及 pipeline recovery，MiniDFS 简化为超时后允许覆盖写）。

## ReplicationManager：副本状态扫描与修复

DataNode 会故障、磁盘会损坏、网络会中断。当副本数量低于期望值时，系统需要自动补充；当副本数量超过期望值时（比如 DataNode 重新上线后），系统需要清理多余副本。这就是 ReplicationManager 的职责。

```cpp
class ReplicationManager {
public:
    ReplicationManager(MetadataStore* store,
                       PlacementManager* placement,
                       uint32_t desired_replication);

    std::vector<ReplicationTask> scan();

private:
    MetadataStore* store_;
    PlacementManager* placement_;
    uint32_t desired_replication_;
};
```

### 扫描逻辑

`scan()` 方法是整个副本修复的核心。它的逻辑分三步：查询所有已提交的 block，统计每个 block 的健康副本数，然后决定补充或删除。

```cpp
std::vector<ReplicationTask> ReplicationManager::scan() {
    std::vector<ReplicationTask> tasks;

    auto blocks = store_->get_blocks_by_state(BlockState::kCommitted);
    if (!blocks.ok()) return tasks;

    for (const auto& block : blocks.value()) {
        auto replicas = store_->get_replicas(block.block_id);
        if (!replicas.ok()) continue;

        // 统计健康副本（仅 Finalized 状态）
        std::vector<uint64_t> healthy_dns;
        for (const auto& r : replicas.value()) {
            if (r.state == ReplicaState::kFinalized) {
                healthy_dns.push_back(r.datanode_id);
            }
        }

        uint32_t healthy = healthy_dns.size();

        if (healthy < desired_replication_ && healthy > 0) {
            // 欠副本：选择新目标，排除已有副本的 DN
            uint32_t deficit = desired_replication_ - healthy;
            auto targets = placement_->choose_targets(
                deficit, healthy_dns);  // exclude existing
            for (auto target : targets) {
                tasks.push_back(ReplicationTask{
                    .block_id = block.block_id,
                    .source_datanode = healthy_dns[0],
                    .target_datanode = target,
                    .is_deletion = false,
                });
            }
        } else if (healthy > desired_replication_) {
            // 超副本：从尾部选择多余的副本删除
            for (uint32_t i = desired_replication_; i < healthy; ++i) {
                tasks.push_back(ReplicationTask{
                    .block_id = block.block_id,
                    .source_datanode = 0,
                    .target_datanode = healthy_dns[i],
                    .is_deletion = true,
                });
            }
        }
        // healthy == 0：无源可拷贝，跳过（数据已丢失）

        if (tasks.size() >= kDefaultMaxReplicationTasksPerRound) break;
    }
    return tasks;
}
```

几个细节值得注意：只有 `ReplicaState::kFinalized` 的副本才算健康——正在写入的、损坏的都不计入；当健康副本数为零时不生成任务，因为没有源数据可拷贝（这块数据已经不可恢复）；每轮最多生成 100 个任务，避免单次扫描产生过多负载。

### 任务下发：搭 Heartbeat 的便车

ReplicationManager 生成的任务不是立即推送给 DataNode 的——MiniDFS 没有 NameNode 到 DataNode 的主动连接。任务通过 Heartbeat 响应下发，这是一个巧妙的设计复用：

```protobuf
message HeartbeatResponse {
    StatusProto status = 1;
    repeated DataNodeCommand commands = 2;
}

message DataNodeCommand {
    enum CommandType {
        NONE = 0;
        REPLICATE = 1;
        DELETE = 2;
        INVALIDATE = 3;
        SHUTDOWN = 4;
    }
    CommandType type = 1;
    uint64 block_id = 2;
    uint64 generation_stamp = 3;
    string target_host = 4;
    uint32 target_port = 5;
}
```

NameNode 在处理 Heartbeat 时，从待分发队列中取出属于该 DataNode 的任务，序列化为 `DataNodeCommand` 附在响应里返回。DataNode 心跳间隔 3 秒，所以任务下发的最大延迟也是 3 秒——对副本修复这种后台操作完全可以接受。

## DataNode 侧：ReplicationWorker

DataNode 收到命令后，由 ReplicationWorker 异步执行。它是一个固定大小的线程池，从任务队列中取出命令并执行：

```cpp
class ReplicationWorker {
public:
    using CopyFunc = std::function<Result<Void>(
        uint64_t block_id, uint64_t gs,
        const std::string& data,
        const std::string& host, uint32_t port)>;

    ReplicationWorker(LocalBlockStore* store,
                      CopyFunc copy_func,
                      uint32_t max_concurrent_tasks);

    void enqueue(DataNodeTask task);
    void start();
    void stop();

private:
    void worker_loop();

    LocalBlockStore* store_;
    CopyFunc copy_func_;
    std::queue<DataNodeTask> queue_;
    std::vector<std::thread> workers_;
    std::mutex mu_;
    std::condition_variable cv_;
    bool running_ = false;
};
```

任务有两种：Copy 和 Delete。

Copy 流程是"读本地块 → 通过 TransferBlock RPC 发送到目标 DN"：

```cpp
void ReplicationWorker::worker_loop() {
    while (running_) {
        DataNodeTask task;
        {
            std::unique_lock lock(mu_);
            cv_.wait(lock, [&] { return !running_ || !queue_.empty(); });
            if (!running_ && queue_.empty()) return;
            task = std::move(queue_.front());
            queue_.pop();
        }

        if (task.kind == TaskKind::kCopy) {
            auto data = store_->read_block_data(task.block_id);
            if (data.ok()) {
                copy_func_(task.block_id, task.generation_stamp,
                           data.value(), task.target_host, task.target_port);
            }
        } else {  // TaskKind::kDelete
            store_->delete_block(task.block_id);
        }
    }
}
```

Delete 流程更简单——调用 LocalBlockStore 的 `delete_block()`，将块文件从 `current/` 移入 `trash/`（第五篇介绍过的生命周期管理），最终由后台 purge 线程异步清理。

## 容错闭环：从故障检测到自愈完成

把前面的组件串起来，我们可以画出一个完整的容错闭环。假设一个 DataNode 因磁盘故障下线：

![容错闭环：从 DataNode 下线到副本自动修复的完整流程](/images/minidfs/fault-tolerance.svg "MiniDFS 容错闭环")

整个流程的时间线如下：

**T+0s：DataNode-2 磁盘故障，停止发送 Heartbeat。** 此时 NameNode 的 DataNodeManager 尚未感知——上一次心跳可能刚刚到达。

**T+30s：DataNodeManager 将 DN-2 标记为 Stale。** 超过 `kStaleTimeoutMs=30000`没有收到心跳，DN-2 从 Live 转为 Stale。Stale 状态下 PlacementManager 不再选择该 DN 作为写入目标，但尚不触发副本修复。

**T+600s：DataNodeManager 将 DN-2 标记为 Dead。** 超过 `kDeadTimeoutMs=600000`，DN-2 进入 Dead 状态。此时该 DN 上所有 replica 的状态被标记为 Lost。

**T+600s~：ReplicationManager 扫描发现欠副本。** 下一轮 scan 发现 DN-2 上的 block 健康副本数不足。假设 block-7 原本有 3 副本分布在 DN-1、DN-2、DN-3，现在只有 DN-1 和 DN-3 的副本是健康的。deficit=1，调用 PlacementManager 选出 DN-4 作为目标。

**T+603s：命令通过 Heartbeat 下发到 DN-1。** ReplicationManager 生成的 `ReplicationTask{block_id=7, source=DN-1, target=DN-4}` 被转换为 DataNodeCommand，在 DN-1 的下一次 heartbeat 响应中下发。

**T+603s~：DN-1 的 ReplicationWorker 执行 Copy。** 读取本地 block-7 数据，通过 TransferBlock RPC 发送到 DN-4。DN-4 收到后创建块文件、写入数据、完成 finalize。

**T+606s~：DN-4 在下一次 BlockReport 或 CommitBlock 中上报新副本。** NameNode 更新元数据，block-7 恢复为 3 副本。自愈完成。

整个过程从故障发生到修复完成大约 10 分钟多一点，没有任何人工干预。这就是分布式系统"自愈"的含义。

## 幂等性保障：重复请求不会破坏一致性

在分布式环境中，网络超时后 Client 可能重试同一个请求。如果 NameNode 处理不当，重复的 CreateFile 或 AllocateBlock 可能导致元数据混乱。MiniDFS 通过 OpLog 实现请求级幂等：

```cpp
// 每个写请求携带唯一的 request_id
message RequestHeader {
    string request_id = 1;   // UUID
    string client_id = 2;
    string user = 3;
}

// NameNode 处理写请求的模板
Result<Response> NameNodeServiceImpl::handle_write_request(
    const RequestHeader& header, auto&& operation) {
    // 1. 检查是否是重复请求
    auto dup = store_->check_request_id(header.request_id());
    if (dup.ok()) {
        return dup.value();  // 返回之前的结果
    }

    // 2. 执行操作
    auto result = operation();
    if (!result.ok()) return result.error();

    // 3. 记录 oplog
    store_->write_oplog(header.request_id(), result.value());
    return result;
}
```

op_log 表以 request_id 为唯一键，记录每个写操作的结果。重复请求到达时直接返回历史结果，既不会重复执行，也能让 Client 拿到正确的响应。

## 事务与原子性：CreateFile 的边界情况

一个容易出 bug 的地方是 CreateFile 的原子性。这个操作涉及三步：创建 inode、获取 lease、记录 oplog。如果中间某步失败，需要保证不会留下"孤儿"数据。

MiniDFS 通过 MySQL 事务解决这个问题：

```cpp
Result<uint64_t> NameNodeServiceImpl::create_file(
    const std::string& path, const std::string& client_id,
    const RequestHeader& header) {
    auto txn = store_->begin_transaction();

    // 三步操作在同一事务中
    auto inode_id = store_->create_inode(parent_id, name,
                                         InodeType::kFile,
                                         InodeState::kUnderConstruction);
    if (!inode_id.ok()) { txn->rollback(); return inode_id.error(); }

    auto lease_id = store_->create_lease(inode_id.value(), client_id);
    if (!lease_id.ok()) { txn->rollback(); return lease_id.error(); }

    store_->write_oplog(header.request_id(), inode_id.value());

    auto commit_result = txn->commit();
    if (!commit_result.ok()) return commit_result.error();

    return inode_id.value();
}
```

事务的连接绑定也值得一提——`begin_transaction()` 从连接池获取一个连接并绑定到当前线程，后续所有 `store_->xxx()` 操作复用同一连接，直到 commit/rollback。这通过 `thread_local PooledConnection* bound_conn_` 实现，是回归测试中修复的一个 P0 bug（早期版本事务内操作可能跑在不同连接上，导致看不到未提交的数据）。

## 错误码设计：分段编号的工程哲学

MiniDFS 的错误码按模块分段设计，这是一个值得借鉴的工程实践：

```cpp
enum class ErrorCode : uint32_t {
    kOk = 0,

    // 1xxx: Namespace
    kInvalidArgument = 1001,
    kNotFound        = 1002,
    kAlreadyExists   = 1003,
    // ...

    // 2xxx: Lease
    kLeaseExpired          = 2001,
    kLeaseConflict         = 2002,
    kFileUnderConstruction = 2003,

    // 3xxx: Block & DataNode
    kNoAvailableDataNode   = 3001,
    kBlockNotFound         = 3002,
    kBlockCorrupt          = 3003,
    kInsufficientReplicas  = 3007,

    // 4xxx: MySQL
    kMySQLError     = 4001,
    kTxnFailed      = 4004,

    // 5xxx: RPC
    kRPCError       = 5001,
    kPipelineError  = 5005,

    // 6xxx: IO
    kIOError    = 6001,
    kDiskFull   = 6002,

    // 9xxx: Internal
    kInternalError     = 9001,
    kRequestDuplicated = 9002,
};
```

分段设计的好处是：看到错误码就知道问题出在哪个模块，日志排查时不需要翻代码查定义；新增错误码时不会和已有的冲突；跨团队协作时，各模块可以独立管理自己的错误码段。

## 小结

这篇文章串联了 MiniDFS 容错体系的三个层次：Lease 管理防止写冲突、ReplicationManager 检测和修复副本异常、ReplicationWorker 执行具体的数据拷贝和清理。配合前几篇介绍的 Heartbeat 通道和 DataNode 状态机，整个系统形成了一个完整的自愈闭环——从故障检测到任务生成到命令下发到执行完成，全自动、无人工干预。

回顾整个 MiniDFS 系列，六篇文章覆盖了一个分布式文件系统的核心骨架：命名空间管理、元数据持久化、数据读写通路、存储节点管理、容错与自愈。每个模块都追求"最小可工作实现"——用 C++20 的现代特性写出清晰简洁的代码，用 MySQL 替代复杂的自研存储引擎，用 brpc 省去 RPC 框架的轮子。这不是生产级系统，但它展示了分布式存储的核心设计思想，以及如何用最少的代码量把这些思想变成可运行的程序。
