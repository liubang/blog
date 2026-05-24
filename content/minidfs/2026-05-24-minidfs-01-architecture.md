---
title: "整体架构与协议设计"
description: "介绍 MiniDFS 的项目定位、与 HDFS 的取舍、三大角色的职责边界、RPC 协议设计，以及一次写入请求的完整链路。"
date: 2026-05-24
categories: [存储与分布式]
tags: [distributed-system, hdfs, cpp, architecture]
authors: ["liubang"]
weight: 1
series: ["MiniDFS"]
series_weight: 1
lightgallery: true
---

MiniDFS 是一个用 C++20 从零实现的简化版分布式文件系统。它不追求功能完整覆盖，而是聚焦分布式文件系统最核心的几个问题——元数据管理、数据分块与 Pipeline 复制、副本放置与容错——给出一个可以实际运行的实现，并在过程中深入理解每个设计决策背后的 tradeoff。

这篇文章是系列的入口。我会先讲为什么要造这个项目、它和 HDFS 的关系，然后给出整体架构，最后完整走一遍"写入一个文件"的端到端链路，让读者对后续每篇文章的位置有一个全局认知。

## 为什么要自己实现一个分布式文件系统

学习分布式系统最有效的方式是亲手实现一遍。阅读论文能理解设计意图，但只有真正写出能跑的代码，才会遇到论文中一笔带过的工程问题——事务边界怎么划、并发控制在哪一层做、心跳超时设多长才合理。

HDFS 的源码是 Java 实现，经过十余年演进，代码量庞大（核心模块超过 30 万行），HA、Federation、Erasure Coding 等高级特性与核心逻辑交织在一起，阅读门槛极高。MiniDFS 的目标是一个**最小可运行闭环**：保留 HDFS 的核心架构决策，砍掉所有非本质复杂度，把精力集中在真正重要的设计问题上。

## MiniDFS vs HDFS：保留了什么，砍掉了什么

MiniDFS 的设计哲学是「保留骨架，简化实现」。下面从两个维度做对比。

**保留的核心设计：**

单 NameNode + 多 DataNode 的 Master/Worker 架构；Block 分块存储 + Pipeline 链式复制；Rack-aware 副本放置策略；Lease 机制实现写互斥；Heartbeat + BlockReport 的注册与上报机制；Block 与 Replica 的双层状态机管理（`kAllocating → kCommitted → kDeleted` 和 `kWriting → kFinalized → kCorrupt → kDeleted`）。

**砍掉的特性：**

HA（Secondary NameNode / JournalNode / ZKFC）、Federation（多 Namespace）、Snapshot / Quota / ACL、Append / Truncate、Erasure Coding、Short-circuit Local Read、HDFS Balancer / Mover。这些特性各自重要，但它们本质上是在核心架构之上的增量演进，不影响对基本原理的理解。

**关键设计变更：**

元数据持久化方面，HDFS 使用 EditLog + FsImage 的 WAL 方案，MiniDFS 改用 MySQL。这个选择牺牲了部分写入性能（每次元数据变更都是一次 MySQL 事务），但换来了实现简洁性——不需要自己维护日志回放、Checkpoint、和 Standby 同步机制。对于一个教学项目，这是合理的 tradeoff。RPC 框架方面，HDFS 使用自研的 Hadoop RPC，MiniDFS 选择 brpc + protobuf，获得更好的性能和更简洁的接口定义。

## 技术栈选择

MiniDFS 的技术选型遵循「工程效率优先」的原则：选择成熟的基础设施，将精力聚焦在分布式系统本身的设计问题上。

语言选择 C++20，使用 Coroutines、`std::format`、Concepts 等现代特性提升表达力。构建系统使用 Bazel，天然支持 protobuf 代码生成和跨平台编译。RPC 框架选择百度开源的 brpc，它在延迟和吞吐上表现优异，且与 protobuf Service 无缝集成。元数据后端选择 MySQL 8.0，通过连接池 + RAII 封装保证资源安全。校验算法选择 CRC32C（Castagnoli 多项式），在 x86 平台利用 Intel ISA-L 的 SIMD 加速实现，在 ARM 平台利用 Google crc32c 库的硬件 CRC 指令，编译期自动适配。

## 三大角色与职责边界

MiniDFS 包含三个角色：NameNode 负责元数据管理与全局协调，DataNode 负责数据存储与传输，Client 提供用户接口并协调读写流程。

![MiniDFS 整体架构](/images/minidfs/architecture-overview.svg "MiniDFS 整体架构：Client、NameNode、DataNode 三角色协作关系")

### NameNode

NameNode 是系统的元数据中心和协调者，它管理 Namespace（inode 树）、负责 Block 分配与状态管理、做出副本放置决策、管理 Lease 写互斥、以及维护 DataNode 的生命周期。NameNode **不参与数据传输**——Client 写入和读取数据时直接与 DataNode 通信，NameNode 只提供"数据在哪里"的信息。

内部由六个 Manager 组件构成：`NamespaceManager` 管理 inode 树和路径操作；`BlockManager` 负责 Block ID 分配、Generation Stamp 生成和 Block 状态流转；`LeaseManager` 实现文件级写互斥和超时回收；`DataNodeManager` 维护 DataNode 注册信息并通过心跳检测 Live/Stale/Dead 状态；`PlacementManager` 实现容量感知 + 机架感知的副本放置策略；`ReplicationManager` 周期性扫描检测欠复制和过量复制并生成修复任务。

### DataNode

DataNode 是数据的实际载体。它通过 `LocalBlockStore` 在本地磁盘上管理 Block 文件（三级目录：`tmp/` → `current/` → `trash/`），周期性向 NameNode 发送心跳上报容量信息，周期性进行 BlockReport 全量同步本地持有的 Block 列表，并在 Pipeline 写入中作为链式复制的中间节点接收、校验、转发数据。此外，DataNode 还通过后台 `ReplicationWorker` 线程池执行 NameNode 通过心跳下发的副本复制和删除命令。

### Client

Client 对用户提供类 POSIX 的文件系统接口：`mkdir`、`put`（上传文件）、`get`（下载文件）、`ls`、`stat`、`rm`。在写路径上，Client 负责将文件按 `block_size`（默认 128MB）切分为 Block，每个 Block 再按 `chunk_size`（默认 1MB）切分为 Chunk，逐 Chunk 通过 Pipeline 写入 DataNode。在读路径上，Client 从 NameNode 获取 Block 位置列表后，直连 DataNode 读取数据并校验 CRC32C。

## 协议设计：四个 protobuf Service

MiniDFS 的 RPC 层基于 brpc + protobuf，定义了四个独立的 Service，共计 28 个 RPC 接口。拆分为多个 Service 的考量是：不同调用者（Client / DataNode / 运维工具）的权限模型不同，拆分后可以独立做访问控制；同时代码组织更清晰，每个 Service 对应一个 `*_service_impl.cpp`。

**NameNodeService** 是 Client 面向 NameNode 的接口，包含 10 个 RPC：`Mkdir`、`CreateFile`、`CompleteFile`、`GetFileStatus`、`ListStatus`、`Delete`、`Rename` 用于 Namespace 操作；`AllocateBlock`、`GetLocatedBlocks` 用于 Block 管理；`RenewLease` 用于 Lease 续约。

**DataNodeProtocolService** 是 DataNode 面向 NameNode 的接口，包含 4 个 RPC：`RegisterDataNode` 用于启动时注册；`Heartbeat` 用于周期性状态上报并接收命令；`BlockReport` 用于全量 Block 汇报；`CommitBlock` 用于确认 Block 写入完成。

**AdminService** 是运维诊断接口，包含 6 个 RPC：`GetClusterInfo`、`ListDataNodes`、`GetDataNodeInfo` 用于集群状态查询；`GetInodeInfo`、`GetFileBlocks`、`GetBlockInfo` 用于元数据诊断。

**DataTransferService** 是数据平面接口（Client 或 DataNode 直连 DataNode），包含 3 个 RPC：`WriteBlock` 用于 Pipeline 写入（逐 Chunk 传输 + 链式转发）；`ReadBlock` 用于客户端读取；`TransferBlock` 用于后台副本复制（全量传输）。

## 端到端链路：写入一个文件

理解一个分布式文件系统最好的方式是跟踪一次完整的写入请求。以 `client put /local/data.bin /dfs/data.bin`（3 副本）为例，下图展示了从 Client 发起到文件可读的完整消息流：

![写入 Pipeline 时序图](/images/minidfs/write-pipeline.svg "一次文件写入的完整消息流：CreateFile → AllocateBlock → Pipeline Write → CommitBlock → CompleteFile")

整个流程分为五个阶段：

**阶段一：CreateFile。** Client 调用 `NameNodeService::CreateFile(path="/dfs/data.bin", replication=3)`。NameNode 在 Namespace 中创建 inode（类型 `kFile`，状态 `kUnderConstruction`），通过 `LeaseManager` 分配 Lease 保证写互斥，返回 `inode_id` 和 `lease_id`。此时文件对其他 Client 不可见。

**阶段二：AllocateBlock。** Client 按 `block_size` 切分本地文件，为每个 Block 调用 `AllocateBlock(inode_id, block_index)`。NameNode 通过 `BlockManager` 完成以下操作：调用 MetadataStore 的 `alloc_id("block")` 原子分配全局唯一 `block_id`；通过 `atomic<uint64_t>::fetch_add(1)` 生成单调递增的 `generation_stamp`；调用 `PlacementManager::choose_targets(3)` 选择 3 个 DataNode——先按可用空间降序排序，在 top `2×replication` 范围内 shuffle 引入随机性避免热点，第二副本优先选择不同 rack；为每个目标 DN 创建 `BlockReplica` 记录（状态 `kWriting`）。最终返回 `LocatedBlock{block_id, generation_stamp, [DN1, DN2, DN3]}`。

**阶段三：Pipeline Write。** Client 将每个 Block 按 `chunk_size`（1MB）切分，逐 Chunk 通过 Pipeline 写入。Client 只与 Pipeline 头节点 DN-1 通信：发送 `WriteBlock(data, checksum, chunk_index, pipeline=[DN2, DN3])`。DN-1 收到后验证 CRC32C，写入本地 `tmp/` 目录，然后从 `pipeline` 列表弹出头部（DN-2）作为下游转发目标，将 `pipeline=[DN3]` 传递给 DN-2。DN-2 重复同样的操作转发给 DN-3。ACK 沿反方向回传：DN-3 → DN-2 → DN-1 → Client。当 `is_last_chunk=true` 时，每个 DN 执行 `finalize_block()`——通过 `rename(tmp/blk_*, current/blk_*)` 原子性地将 Block 从"正在写入"变为"可读"。

**阶段四：CommitBlock。** Client 收到最后一个 Chunk 的 ACK 后，调用 `CommitBlock(block_id, length, generation_stamp)`。NameNode 将 `BlockMeta.state` 从 `kAllocating` 改为 `kCommitted`，所有 `BlockReplica.state` 从 `kWriting` 改为 `kFinalized`。此后该 Block 对读路径可见。

**阶段五：CompleteFile。** 所有 Block 都 committed 后，Client 调用 `CompleteFile(inode_id)`。NameNode 将 `Inode.state` 从 `kUnderConstruction` 改为 `kNormal`，释放 Lease。文件对外完全可见可读。

这个流程中有几个值得注意的设计决策：NameNode 不参与数据传输，避免成为带宽瓶颈；Pipeline 模式下 Client 出口带宽只需 ×1（相比星型拓扑的 ×N）；每个 Chunk 都附带 CRC32C，任何一环的数据损坏都会在下一跳被检测到；Generation Stamp 的单调性保证了即使发生重试也能区分新旧数据。

## 项目结构与构建

MiniDFS 的源码组织遵循模块化原则，每个子目录对应一个独立关注点：

```
cpp/pl/minidfs/
├── common/        # 类型定义、常量、配置、校验、错误码
├── protocol/      # protobuf Service 和 Message 定义
├── metadata/      # MetadataStore 接口 + MySQL 实现 + 连接池
├── namenode/      # NameNode 各 Manager + Service 实现
├── datanode/      # DataNode 本地存储 + Pipeline + 后台任务
└── client/        # DFS Client + CLI 入口
```

构建与测试使用 Bazel：

```bash
# 编译全部
bazel build //cpp/pl/minidfs/...

# 运行全部测试
bazel test //cpp/pl/minidfs/...

# 启动 NameNode
bazel run //cpp/pl/minidfs/namenode:namenode_main -- --config=namenode.yaml

# 启动 DataNode
bazel run //cpp/pl/minidfs/datanode:datanode_main -- --config=datanode.yaml

# 客户端操作
bazel run //cpp/pl/minidfs/client:cli_main -- put /local/file /dfs/path
```

开发环境依赖 MySQL 8.0，可通过项目提供的 `docker-compose.yml` 一键启动。

## 系列导读

本系列共六篇文章，从整体到局部逐层展开 MiniDFS 的设计与实现：

第二篇《元数据层》深入 MetadataStore 的设计——为什么用 MySQL 替代 EditLog+FsImage、连接池的 RAII 封装与线程绑定事务机制、以及 `LAST_INSERT_ID()` 原子 ID 分配技巧。第三篇《Namespace 与 Lease》讲解 inode 树的逐级路径解析、递归创建与删除的事务化实现、以及 Lease 写互斥的完整生命周期。第四篇《写入 Pipeline》深入数据平面——Block 分配流程、PlacementManager 的选择策略、Pipeline 链式复制的 pop-head 转发模型、CRC32C 两层校验体系。第五篇《DataNode 存储引擎》进入 DataNode 内部——BlockHeader 二进制格式、三级目录生命周期、心跳与命令下发、全量 BlockReport。第六篇《副本管理与读取路径》从全局视角看系统的自愈能力——ReplicationManager 的周期扫描与任务生成、欠复制修复与过量删除、以及 Client 读取时的多副本 failover 与校验机制。
