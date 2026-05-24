---
title: "写入 Pipeline — Block 分配、链式复制与校验"
description: "深入 MiniDFS 的写入链路：Block 分配与 Generation Stamp、PlacementManager 的容量感知 + 机架感知策略、Pipeline 链式复制的 pop-head 转发模型、CRC32C 两层校验体系，以及 chunk 写入幂等性设计。"
date: 2026-05-24
categories: [存储与分布式]
tags: [distributed-system, hdfs, pipeline, checksum, cpp]
authors: ["liubang"]
weight: 4
series: ["MiniDFS"]
series_weight: 4
lightgallery: true
---

分布式文件系统的写入远比单机复杂——数据要同时落到多个副本上，任何一个环节的失败都需要被检测和处理。HDFS 的经典方案是 Pipeline Replication：Client 只需要把数据发给第一个 DataNode，由 DataNode 链式转发给后续节点，形成一条写入流水线。

这篇文章从一次 `put()` 调用开始，逐步拆解 Block 分配、目标节点选择、Pipeline 建立与数据传输、两层 CRC32C 校验，以及 chunk 级别的幂等重试设计。

## 写入请求的完整链路

一次 `DfsClient::put(dfs_path, local_path)` 调用涵盖五个阶段。首先通过 `CreateFile` RPC 在 NameNode 创建 inode 并获取 lease（保证写互斥）；接着按 `kDefaultBlockSize`（128 MB）将本地文件切分成若干 block，对每个 block 执行 AllocateBlock / 多次 WriteBlock / CommitBlock 的循环；最后 `CompleteFile` 释放 lease，使文件对外可见。

```cpp
void DfsClient::put(const std::string& dfs_path,
                    const std::string& local_path) {
  auto resp = nn_stub_->CreateFile(dfs_path, block_size_, replication_);
  auto inode_id = resp.inode_id();

  std::ifstream ifs(local_path, std::ios::binary);
  std::vector<char> buf(block_size_);
  while (ifs.read(buf.data(), block_size_) || ifs.gcount() > 0) {
    uint64_t bytes_read = ifs.gcount();
    auto alloc = nn_stub_->AllocateBlock(inode_id);
    write_block(alloc, buf.data(), bytes_read);
    nn_stub_->CommitBlock(alloc.block_id(), bytes_read,
                          alloc.generation_stamp());
  }
  nn_stub_->CompleteFile(inode_id);
}
```

整个过程中 NameNode 只参与元数据协调——分配 block_id、记录副本位置、推进状态机——从不接触实际数据。Client 将数据通过 `DataTransferService::WriteBlock` 直接发送给 Pipeline 的头节点（DN1），由 DN1 链式转发给后续节点。应答沿反方向回溯：DN3 完成写入后向 DN2 应答，DN2 再向 DN1 应答，最终 DN1 向 Client 返回结果。这种设计使 Client 只需维护一条连接，复制带宽由各 DataNode 分摊。

![写入链路时序](/images/minidfs/write-pipeline.svg "Client 写入 Pipeline 时序：NameNode 协调元数据，数据通过 DN1→DN2→DN3 链式转发")

## Block 分配与 Generation Stamp

Client 每写一个新 block，先调用 `AllocateBlock` RPC。`BlockManager::allocate_block` 的实现串联了 ID 分配、版本号生成、元数据持久化和副本放置四个步骤：

```cpp
LocatedBlock BlockManager::allocate_block(uint64_t inode_id,
                                          uint32_t replication) {
  uint64_t block_id = alloc_id("block");
  uint64_t gs = next_generation_stamp();

  // 持久化 BlockMeta，状态设为 kAllocating
  db_->execute(
      "INSERT INTO block_meta (block_id, inode_id, generation_stamp, state) "
      "VALUES (?, ?, ?, ?)",
      block_id, inode_id, gs,
      static_cast<int>(BlockState::kAllocating));

  // 选择目标 DataNode
  auto targets = placement_mgr_->choose_targets(replication);

  // 为每个副本创建 BlockReplica 记录
  for (auto& dn : targets) {
    db_->execute(
        "INSERT INTO block_replica (block_id, datanode_id, state) "
        "VALUES (?, ?, ?)",
        block_id, dn.id(),
        static_cast<int>(ReplicaState::kWriting));
  }

  return make_located_block(block_id, gs, targets);
}
```

`alloc_id("block")` 复用了第二篇介绍的 MySQL `LAST_INSERT_ID` 原子自增技巧，保证 block_id 全局唯一且无锁竞争。`next_generation_stamp()` 则是一个 `std::atomic<uint64_t>` 的 `fetch_add(1)`，保证严格单调递增——Generation Stamp 本质上是 block 的版本号。当 DataNode 向 NameNode 上报某个 block 的 generation_stamp 低于最新值时，NameNode 即可判定该副本为 stale，将其标记为待清理。

Block 的生命周期涉及两层状态机。NameNode 侧的 `BlockMeta` 状态为 `kAllocating -> kCommitted -> kDeleted`：分配后等待写入完成，Client 调用 CommitBlock 后推进到 kCommitted，后续删除文件时标记 kDeleted 供 GC 回收。DataNode 侧的 `BlockReplica` 状态为 `kWriting -> kFinalized -> kCorrupt | kStale | kDeleted`：写入中、已固化、或者因校验失败/版本过期而被标记为异常。双层状态机分离了"整体进度"和"单副本健康度"两个关注点，使得 NameNode 可以在部分副本异常时仍然维持 block 的有效性。

## PlacementManager：容量感知 + 机架感知

副本应该放在哪些 DataNode 上？纯随机选择忽略了磁盘容量差异，容易把写入打到小盘节点；纯容量排序又会使所有写入集中在最大盘节点形成热点。MiniDFS 的 `PlacementManager::choose_targets` 采用 **容量感知排序 + 有界随机打散 + 机架感知贪心** 的三步策略：

```cpp
std::vector<DataNodeInfo> PlacementManager::choose_targets(
    uint32_t num_replicas) {
  auto nodes = registry_->live_datanodes();
  if (nodes.size() < num_replicas) {
    throw NotEnoughReplicasException(nodes.size(), num_replicas);
  }

  // Step 1: 按剩余空间降序排序
  std::sort(nodes.begin(), nodes.end(), [](const auto& a, const auto& b) {
    return a.free_bytes() > b.free_bytes();
  });

  // Step 2: 在 top(2 * num_replicas) 范围内 shuffle
  auto bound = std::min(nodes.size(),
                        static_cast<size_t>(2 * num_replicas));
  std::shuffle(nodes.begin(), nodes.begin() + bound, rng_);

  // Step 3: 机架感知贪心选择
  std::vector<DataNodeInfo> chosen;
  std::unordered_set<std::string> used_racks;
  // 优先选不同 rack 的节点
  for (size_t i = 0; i < bound && chosen.size() < num_replicas; ++i) {
    if (used_racks.find(nodes[i].rack_id()) == used_racks.end()) {
      chosen.push_back(nodes[i]);
      used_racks.insert(nodes[i].rack_id());
    }
  }
  // 不足时回填
  for (size_t i = 0; i < bound && chosen.size() < num_replicas; ++i) {
    if (std::find(chosen.begin(), chosen.end(), nodes[i]) == chosen.end()) {
      chosen.push_back(nodes[i]);
    }
  }
  return chosen;
}
```

这个算法的核心洞察是：先按容量排序保证候选池中都是"有能力"承接写入的节点，再通过有界 shuffle 引入随机性避免热点——"有界"意味着只在 top-2N 范围内打散，不会把容量太小的节点提上来。第三步的机架感知是贪心的：尽可能让副本分布在不同 rack 上以容忍整机架故障，但不像 HDFS 那样强制要求第二副本必须在 remote rack。这是一个务实的简化——MiniDFS 作为教学系统不具备真实的拓扑发现能力，优先不同 rack 但允许降级到同 rack 节点。

## Pipeline 链式复制

分布式文件系统写入多副本有两种经典拓扑：星型（Client 并发写 N 份）和链式（Client 写一份，DataNode 逐级转发）。星型方案要求 Client 出口带宽为 N 倍数据量，在大文件场景下极不经济；链式方案下 Client 只承担单份带宽，复制开销由各 DataNode 内网分摊，代价是延迟变为 N 跳串行——但对吞吐优先的批量写入场景影响很小。MiniDFS 选择链式复制。

### Pop-Head 转发模型

链式复制的关键问题是：每个 DataNode 怎么知道自己该转发给谁？MiniDFS 采用"Pop-Head"模型——`WriteBlockRequest` 中携带一个 `pipeline` 列表，表示当前节点之后的所有下游。每个节点取出 `pipeline[0]` 作为转发目标，将 `pipeline[1:]` 传给下游：

```
Client -> DN1: pipeline=[DN2, DN3], data, chunk_index=0
DN1    -> DN2: pipeline=[DN3],      data, chunk_index=0
DN2    -> DN3: pipeline=[],         data, chunk_index=0
```

这种设计无需中心协调——每个 DataNode 只需要看自己收到的 pipeline 列表即可决定下一步行为。pipeline 为空意味着自己是链尾。

### WriteBlock 处理流程

`DataTransferServiceImpl::WriteBlock` 是 DataNode 侧的核心 RPC handler，处理逻辑如下：

```cpp
grpc::Status DataTransferServiceImpl::WriteBlock(
    grpc::ServerContext* context,
    const WriteBlockRequest* request,
    WriteBlockResponse* response) {
  auto block_id = request->block_id();
  auto chunk_index = request->chunk_index();

  // 第一个 chunk 到达时创建 block 文件
  if (chunk_index == 0) {
    store_->create_block(block_id, request->generation_stamp());
  }

  // CRC32C 校验
  auto data = request->data();
  auto expected_crc = request->checksum();
  if (!verify_crc32c(data.data(), data.size(), expected_crc)) {
    response->set_status(StatusCode::kChecksumError);
    return grpc::Status::OK;
  }

  // 写入本地磁盘
  store_->append_chunk(block_id, chunk_index,
                       data.data(), data.size(), expected_crc);

  // Pipeline 转发
  if (request->pipeline_size() > 0) {
    auto downstream = request->pipeline(0);
    WriteBlockRequest fwd_req;
    fwd_req.CopyFrom(*request);
    fwd_req.mutable_pipeline()->erase(
        fwd_req.mutable_pipeline()->begin());

    auto stub = get_or_create_stub(downstream);
    WriteBlockResponse fwd_resp;
    grpc::ClientContext ctx;
    auto st = stub->WriteBlock(&ctx, fwd_req, &fwd_resp);
    if (!st.ok() || fwd_resp.status() != StatusCode::kOk) {
      response->set_status(StatusCode::kDownstreamError);
      return grpc::Status::OK;
    }
  }

  // 最后一个 chunk：finalize
  if (request->is_last_chunk()) {
    store_->finalize_block(block_id);
    block_reporter_->report_received_block(block_id);
  }

  response->set_status(StatusCode::kOk);
  return grpc::Status::OK;
}
```

整个流程是同步的：本地写入成功后才转发给下游，下游成功后才向上游返回 OK。这意味着当 Client 收到 DN1 的成功应答时，整条 Pipeline 上所有节点都已完成写入。任何一环的失败会沿着反方向传播具体的错误码——`kChecksumError` 表示数据损坏，`kDownstreamError` 表示转发失败，Client 据此决定是否需要重新分配 block。

## CRC32C 两层校验体系

数据在网络传输和磁盘存储中都可能发生位翻转，校验是分布式存储系统的底线防护。MiniDFS 选择 CRC32C（Castagnoli 多项式）作为校验算法——相比 MD5/SHA 等加密哈希，CRC32C 的优势在于现代 CPU 有硬件指令直接加速（Intel SSE4.2 的 `crc32` 指令、ARM 的 PMULL 指令），吞吐可达数十 GB/s，适合对每一个 chunk 做实时校验而不成为瓶颈。

### 平台自适应实现

MiniDFS 在 `common/checksum.h` 中通过编译期 `#if` 选择底层实现，零运行时分支开销：

```cpp
#if defined(__linux__)
#include <isa-l.h>
inline uint32_t compute_crc32c(const void* data, size_t size) {
  return crc32_iscsi(reinterpret_cast<const uint8_t*>(data), size, 0);
}
inline uint32_t extend_crc32c(uint32_t crc, const void* data, size_t size) {
  return crc32_iscsi(reinterpret_cast<const uint8_t*>(data), size, crc);
}
#elif defined(__APPLE__)
#include <crc32c/crc32c.h>
inline uint32_t compute_crc32c(const void* data, size_t size) {
  return crc32c::Crc32c(reinterpret_cast<const char*>(data), size);
}
inline uint32_t extend_crc32c(uint32_t crc, const void* data, size_t size) {
  return crc32c::Extend(crc, reinterpret_cast<const uint8_t*>(data), size);
}
#endif

inline bool verify_crc32c(const void* data, size_t size, uint32_t expected) {
  return compute_crc32c(data, size) == expected;
}
```

Linux 下使用 Intel ISA-L 库的 `crc32_iscsi`（利用 x86 SIMD 加速），macOS 下使用 google/crc32c 库（自动利用 ARM64 硬件 CRC 指令）。上层代码只看到统一的 `compute_crc32c` / `extend_crc32c` / `verify_crc32c` 三个接口。

### 两层校验架构

MiniDFS 的校验分为 chunk 级和 block 级两层。每个 chunk（1 MB）被写入时计算独立的 CRC32C，存入 `BlockHeader` 的 `chunk_checksums[i]` 数组。Block 级 CRC 通过 `extend_crc32c` 增量拼接所有 chunk 的校验值——第一个 chunk 直接 `compute`，后续 chunk 在前一个 block_crc 基础上 `extend`，无需全量重算整个 block。

这种设计的优点是：chunk 级 CRC 可以精确定位损坏的 1 MB 区间，block 级 CRC 则提供一次性的整体完整性校验。读路径上如果某个 chunk 校验失败，Client 可以直接 failover 到另一个副本的对应 chunk，而不必重读整个 128 MB block。

校验贯穿整条数据链路：Client 发送 chunk 时计算 CRC 填入 `WriteBlockRequest.checksum`；DataNode 接收后重新计算对比，不匹配则立即拒绝并返回 `kChecksumError`；读路径上 DataNode 同样在响应中附带 CRC，Client 收到后再次验证。端到端双向校验保证数据从写入到读出的完整性。

## Chunk 写入的幂等性设计

网络超时是分布式系统的常态。当 Client 发送 `WriteBlock` 后未收到响应，它会重试——但此时 DataNode 可能已经成功写入了这个 chunk。如果不做特殊处理，同一份数据会被追加两次，导致 block 内容损坏。MiniDFS 在 `LocalBlockStore::append_chunk` 中实现了 chunk 级别的幂等检查：

```cpp
Status LocalBlockStore::append_chunk(uint64_t block_id,
                                     uint32_t chunk_index,
                                     const void* data, size_t size,
                                     uint32_t checksum) {
  auto& header = load_header(block_id);

  // 幂等检查：如果 chunk_index 等于当前最后一个已写入的 chunk
  // 且 CRC 匹配，说明这是一次重试，直接返回成功
  if (chunk_index == header.chunk_count - 1 &&
      checksum == header.chunk_checksums[chunk_index]) {
    return Status::OK();
  }

  // 正常追加
  if (chunk_index != header.chunk_count) {
    return Status::InvalidArgument("unexpected chunk_index");
  }

  auto path = tmp_path(block_id);
  int fd = ::open(path.c_str(), O_WRONLY | O_APPEND);
  ::write(fd, data, size);
  ::close(fd);

  header.chunk_checksums[header.chunk_count] = checksum;
  header.chunk_count++;
  header.block_checksum = (chunk_index == 0)
      ? compute_crc32c(data, size)
      : extend_crc32c(header.block_checksum, data, size);
  flush_header(block_id, header);

  return Status::OK();
}
```

幂等判定的逻辑非常简洁：Pipeline 是严格顺序写入的，重试只可能发生在"最近一次 chunk"上——如果 `chunk_index` 等于当前已写入的最后一个 chunk 的索引，且 CRC 匹配，说明数据已经落盘，直接返回成功即可。更早的 chunk 如果需要重试，意味着 block 状态已经不一致，这种情况下 Client 会重新分配整个 block，不会在旧 block 上继续追加。

这种设计给 Client 提供了 at-least-once 的重试语义：任何 `WriteBlock` 调用都可以安全重发，无需引入 exactly-once 所需的复杂序列号机制。简单、正确、足够。

## CommitBlock 与 CompleteFile

当一个 block 的所有 chunk 都成功写入 Pipeline 后，Client 调用 `CommitBlock(block_id, length, generation_stamp)` 通知 NameNode。`BlockManager::commit_block` 执行两个状态转换：将 `BlockMeta.state` 从 `kAllocating` 推进到 `kCommitted`，同时将该 block 所有 `BlockReplica.state` 从 `kWriting` 推进到 `kFinalized`。此后该 block 对读路径可见——Client 可以通过 `GetBlockLocations` 获取其位置并发起读取。

```cpp
void BlockManager::commit_block(uint64_t block_id, uint64_t length,
                                uint64_t generation_stamp) {
  db_->execute(
      "UPDATE block_meta SET state = ?, length = ? "
      "WHERE block_id = ? AND generation_stamp = ?",
      static_cast<int>(BlockState::kCommitted), length,
      block_id, generation_stamp);

  db_->execute(
      "UPDATE block_replica SET state = ? WHERE block_id = ?",
      static_cast<int>(ReplicaState::kFinalized), block_id);
}
```

所有 block 都 committed 之后，Client 调用 `CompleteFile(inode_id)`。NameNode 将 inode 状态从 `kUnderConstruction` 推进到 `kNormal` 并释放 lease——此刻文件正式对外可见可读。

异常场景下的行为同样清晰：如果 Client 在写入过程中崩溃，lease 会在超时后自动释放（参见第三篇的 lease 过期机制），inode 保留在 `kUnderConstruction` 状态。已经 committed 的 block 包含有效数据不会丢失；未 committed 的 block 停留在 `kAllocating` 状态，后台 GC 线程会定期扫描这些"孤儿 block"并回收其占用的 DataNode 磁盘空间。

## 小结

这篇文章从 `DfsClient::put()` 出发，完整走过了 MiniDFS 写入链路的每一个环节。回顾核心设计决策：Pop-Head 转发模型用最简洁的"弹出首元素"语义实现了无中心协调的链式复制；容量感知 + 有界随机 + 机架贪心的三步策略平衡了负载均衡和容错；CRC32C 两层校验通过平台自适应硬件加速实现了无感知的端到端数据完整性保护；chunk 级幂等通过 CRC 比对以极低成本提供了 at-least-once 安全重试；`tmp/` 到 `current/` 的原子 rename 保证了 block 的 all-or-nothing 语义。

下一篇将深入 DataNode 的内部世界——本地存储引擎的文件布局与 BlockHeader 格式、心跳机制、以及块报告如何驱动 NameNode 的副本状态机。
