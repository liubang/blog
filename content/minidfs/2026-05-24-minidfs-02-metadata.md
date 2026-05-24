---
title: "元数据层 — 从 EditLog 到 MySQL"
description: "深入 MiniDFS 的元数据持久化设计：为什么用 MySQL 替代 HDFS 的 EditLog+FsImage 方案，连接池 RAII 封装，事务绑定机制，以及 ID 原子分配的 MySQL 技巧。"
date: 2026-05-24
categories: [存储与分布式]
tags: [distributed-system, mysql, connection-pool, cpp]
authors: ["liubang"]
weight: 2
series: ["MiniDFS"]
series_weight: 2
lightgallery: true
---

NameNode 的核心职责是管理元数据。HDFS 用 EditLog + FsImage 实现持久化——这套方案在生产中经受了海量验证，但它的复杂度（checkpoint 合并、HA 下的 JournalNode 同步、启动时重放 EditLog）对一个教学项目来说是过度的。MiniDFS 选择了一条不同的路：直接用 MySQL 做元数据后端。

这篇文章深入讲解这个设计选择的 tradeoff，以及在 MySQL 之上构建的三层关键机制：连接池 RAII 封装、事务绑定、ID 原子分配。

![MiniDFS 元数据层架构](/images/minidfs/metadata-layer.svg "元数据层整体架构：从 NameNode Manager 到 MySQL 的分层设计")

## HDFS 的 EditLog + FsImage：为什么复杂

HDFS 的元数据持久化遵循经典的 WAL（Write-Ahead Log）思路。每次元数据变更——创建文件、追加 block、修改权限——都以一条 EditLog record 追加写入磁盘。FsImage 则是某一时刻的全量 namespace 快照。NameNode 启动时加载最近的 FsImage，然后顺序重放此后的所有 EditLog 条目，恢复到最新状态。

这个方案的工程复杂度主要体现在三处。第一是 Checkpoint 过程：SecondaryNameNode（或 HA 架构下的 StandbyNameNode）需要定期将 EditLog 合并进 FsImage 以避免重放时间无限增长，大集群的 FsImage 动辄数十 GB，合并本身就是一个不可忽视的 I/O 密集操作。第二是 HA 方案引入的 JournalNode 集群：Active NameNode 将 EditLog 写入多数派 JournalNode，Standby 从 JournalNode 拉取并重放，保持 namespace 同步——这套机制引入了 Paxos 式的多数派确认、fencing、epoch 管理等分布式一致性的全套复杂度。第三是 EditLog 自身的格式管理：segment 滚动、序列化版本升级、损坏恢复工具。

对于一个旨在阐明分布式文件系统核心逻辑的教学项目，这些实现细节会淹没真正重要的东西——namespace 如何组织、block 如何映射、lease 如何协调。我们需要一个更简单的持久化方案。

## MiniDFS 的选择：MySQL 作为元数据后端

MiniDFS 将 namespace tree、block 元数据、replica 映射、DataNode 注册信息和 lease 全部存储在 MySQL 的关系表中。这个决策带来了三个直接收益。

首先是开发效率的数量级提升。用 SQL 的 INSERT/SELECT/UPDATE/DELETE 表达元数据操作，比自己实现 EditLog 的序列化格式、segment 管理、checkpoint 合并简单得多。其次是调试体验的质变——随时用 `mysql` 客户端连入数据库查看系统状态，比解析二进制 FsImage 友好得多。第三是事务语义的天然可用性：多表联动操作（例如创建文件时同时插入 inode + block + lease）在 InnoDB 事务下自然满足原子性，不需要自己实现 WAL 来保证 crash consistency。

代价同样清晰。性能上限低于 HDFS 的全内存方案——HDFS 的 namespace 完全驻留在 NameNode 堆内存中，路径解析是 O(depth) 的哈希表查找，而 MySQL 方案的每次元数据操作至少产生一次网络往返和磁盘 I/O。此外，MySQL 本身成为系统可用性的单点——虽然可以通过主从复制缓解，但这超出了教学项目的范围。

对于教学目的，这个 tradeoff 完全值得。核心的分布式文件系统逻辑更加清晰，性能瓶颈可以在后续通过缓存层（例如在 NameNode 内存中缓存热点 inode）来缓解。

## MetadataStore 接口抽象

代码的第一层设计是一个纯虚接口 `MetadataStore`，定义在 `metadata_store.h` 中。所有上层组件——NamespaceManager、BlockManager、LeaseManager、DataNodeManager、ReplicationManager——都只依赖这个接口，不直接感知底层是 MySQL 还是其他存储。

这一层抽象的首要目的是 testability。生产代码使用 `MySQLMetadataStore`，单元测试则注入 `MockMetadataStore`，可以在没有 MySQL 实例的情况下验证所有 Manager 层的业务逻辑。如果未来有需要（例如为了性能引入内存缓存层），只需要实现一个新的 `MetadataStore` 子类，上层代码无需改动。

接口按职责分为七组：

```cpp
class MetadataStore {
public:
    // Transaction management
    virtual pl::Result<std::unique_ptr<Transaction>> begin_transaction() = 0;

    // Inode operations: get_inode, get_child, list_children,
    //                   create_inode, update_inode, delete_inode

    // Block operations: get_block, get_blocks_by_inode,
    //                   create_block, update_block, get_blocks_by_state

    // Block Replica operations: get_replicas, get_replicas_by_datanode,
    //                           upsert_replica, delete_replicas_by_block, update_replica_state

    // DataNode operations: get_datanode, get_datanode_by_uuid,
    //                      list_datanodes_by_state, list_all_datanodes, upsert_datanode

    // Lease operations: create_lease, get_active_lease,
    //                   renew_lease, close_lease, expire_leases

    // ID Allocation
    virtual pl::Result<uint64_t> alloc_id(std::string_view name, uint64_t count = 1) = 0;

    // Operation Log
    virtual pl::Result<pl::Void> write_oplog(...) = 0;
    virtual pl::Result<bool> check_request_id(std::string_view request_id) = 0;
};
```

所有方法统一返回 `pl::Result<T>`（基于 `folly::Expected`），错误通过 `pl::Status` 携带错误码和消息。这避免了异常在高并发 RPC 路径上的性能开销，同时保证了错误不会被意外忽略。

`begin_transaction()` 返回一个 `std::unique_ptr<Transaction>`，`Transaction` 本身也是一个纯虚类，提供 `commit()` 和 `rollback()` 方法，析构时如果未 commit 则自动 rollback——标准的 RAII 事务模式。

## 连接池设计：PooledConnection RAII

MySQL 连接是昂贵资源。每次建立连接需要 TCP 三次握手、TLS 协商（如果启用）、MySQL 认证协议交互，耗时通常在毫秒级。在高并发场景下为每个请求新建连接是不可接受的，必须使用连接池复用已建立的连接。

`MySQLConnectionPool` 在初始化时预先创建 `pool_size`（默认 16）个 `boost::mysql::any_connection`，放入一个线程安全的队列 `idle_` 中。调用方通过 `acquire()` 获取连接，用完后归还。但这个"归还"动作不是手动调用的——它通过 RAII wrapper `PooledConnection` 自动完成。

```cpp
class PooledConnection {
public:
    ~PooledConnection() {
        if (conn_ && pool_) {
            pool_->release(std::move(conn_), std::move(io_ctx_));
        }
    }

    PooledConnection(PooledConnection&& other) noexcept;  // move-only
    PooledConnection& operator=(PooledConnection&& other) noexcept;
    PooledConnection(const PooledConnection&) = delete;    // non-copyable

    pl::Result<boost::mysql::results> execute(std::string_view sql);
};
```

`PooledConnection` 是 move-only 的：不可拷贝，只能转移所有权。当它离开作用域（正常返回或异常退出），析构函数自动将底层的 `any_connection` 归还给 pool。这保证了即使在复杂的错误处理路径上也不会泄漏连接。

`execute()` 方法封装了 SQL 执行和异常捕获——`boost::mysql` 的 API 在出错时抛出 `error_with_diagnostics` 异常，`execute()` 将其转换为 `pl::Result` 返回，与项目的整体错误处理风格一致。

连接池的 `acquire()` 使用 `std::condition_variable` 实现阻塞等待：当所有连接都被占用时，调用线程会阻塞直到有连接归还。`release()` 在归还连接后调用 `cv_.notify_one()` 唤醒一个等待者。这是一个简单但有效的固定大小池策略。

```cpp
pl::Result<PooledConnection> MySQLConnectionPool::acquire() {
    std::unique_lock lock(mutex_);
    cv_.wait(lock, [this] { return !idle_.empty(); });
    auto entry = std::move(idle_.front());
    idle_.pop();
    return PooledConnection(std::move(entry.conn), std::move(entry.io_ctx), this);
}
```

## 事务绑定：thread_local + bind_connection

连接池解决了连接复用的问题，但引入了一个新的挑战：事务的连接亲和性。

考虑这个场景：`NamespaceManager::create_file()` 需要在一个事务中执行三个操作——创建 inode、创建首个 block、创建 lease。它调用 `store->begin_transaction()` 获取事务句柄，然后分别调用 `store->create_inode()`、`store->create_block()`、`store->create_lease()`。问题在于：如果 `create_inode()` 的实现内部独立地从池中 acquire 一个连接来执行 SQL，这个连接很可能不是 `begin_transaction()` 中执行了 `BEGIN` 的那个连接——那么这次 INSERT 就不在事务中，事务绑定形同虚设。

MiniDFS 的解决方案是 `thread_local` 绑定：

```cpp
class MySQLMetadataStore final : public MetadataStore {
    static thread_local PooledConnection* bound_conn_;

    void bind_connection(PooledConnection* conn);
    void unbind_connection();

    PooledConnection* get_active_conn(PooledConnection& owned) {
        return bound_conn_ ? bound_conn_ : &owned;
    }
};
```

当 `begin_transaction()` 被调用时，它从池中 acquire 一个连接，执行 `BEGIN` SQL，然后将该连接指针绑定到当前线程的 `bound_conn_`。此后，同一线程上所有 store 方法在获取连接时，会先检查 `bound_conn_` 是否存在——如果存在就直接使用它（跳过 acquire），保证所有操作都在同一个 MySQL 连接的同一个事务中执行。

`MySQLTransaction` 是这个机制的 RAII 载体：

```cpp
class MySQLTransaction final : public Transaction {
public:
    MySQLTransaction(PooledConnection conn, MySQLMetadataStore* store)
        : conn_(std::move(conn)), store_(store) {
        store_->bind_connection(&conn_);  // 绑定到当前线程
    }

    ~MySQLTransaction() override {
        if (!committed_) {
            rollback();  // 析构时未 commit 则自动 rollback
        }
        store_->unbind_connection();  // 解除绑定
    }

    pl::Result<pl::Void> commit() override {
        auto res = conn_.execute("COMMIT");
        if (res.hasError()) return folly::makeUnexpected(res.error());
        committed_ = true;
        return pl::Void{};
    }
};
```

每个 store 方法的连接获取模式统一为：

```cpp
pl::Result<Inode> MySQLMetadataStore::get_inode(uint64_t inode_id) {
    PooledConnection owned;
    if (!bound_conn_) {
        auto conn_result = pool_->acquire();
        if (conn_result.hasError()) return folly::makeUnexpected(conn_result.error());
        owned = std::move(conn_result.value());
    }
    auto* conn = get_active_conn(owned);
    // ... 使用 conn 执行 SQL ...
}
```

如果当前线程处于事务中（`bound_conn_` 非空），则跳过 acquire，直接使用事务绑定的连接；否则自行 acquire 一个临时连接，该连接会在方法返回时被 `owned` 的析构函数自动归还。

这个设计的隐含约束是：事务的 begin/commit/rollback 以及事务内的所有操作必须在同一个线程上执行。这对 MiniDFS 来说是自然成立的——brpc 的请求处理线程模型保证了单个 RPC 的处理逻辑在一个线程上顺序执行。

## ID 原子分配：LAST_INSERT_ID 技巧

NameNode 需要为 inode、block、lease、DataNode 分配全局唯一的递增 ID。多线程并发分配时，朴素的 "SELECT next_id → UPDATE next_id + count" 两步操作存在 TOCTOU（Time-of-Check to Time-of-Use）竞争：两个线程可能读到相同的 next_id，导致 ID 冲突。

MiniDFS 使用了一个 MySQL 专有的技巧：`LAST_INSERT_ID(expr)` 函数。这个函数的特殊之处在于：当以表达式为参数调用时，它将该表达式的值设置为当前会话（session）的 `LAST_INSERT_ID` 返回值——这个值是 session-local 的，不受其他连接影响。

`id_allocators` 表结构极其简单：

```sql
CREATE TABLE id_allocators (
    name    VARCHAR(64) NOT NULL PRIMARY KEY,
    next_id BIGINT UNSIGNED NOT NULL DEFAULT 0
);
```

分配操作是一条原子 SQL：

```sql
INSERT INTO id_allocators (name, next_id) VALUES ('inode', LAST_INSERT_ID(0) + :count)
ON DUPLICATE KEY UPDATE next_id = LAST_INSERT_ID(next_id) + :count;
```

随后通过 `SELECT LAST_INSERT_ID()` 获取分配范围的起始值。

原理分析：当 `name='inode'` 已存在时（绝大多数情况），执行的是 UPDATE 分支——`LAST_INSERT_ID(next_id)` 先捕获当前的 `next_id` 值（假设是 1000）作为本次会话的返回值，然后 `+ :count` 将 `next_id` 更新为 1000 + count。后续的 `SELECT LAST_INSERT_ID()` 返回 1000，即分配范围 `[1000, 1000+count)` 的起始。整个操作在 InnoDB 行锁保护下原子执行，不存在 TOCTOU 窗口。

INSERT 分支处理首次使用某个 allocator 的情况——`LAST_INSERT_ID(0)` 将 session 值设为 0，`next_id` 列写入 `0 + count`，后续 SELECT 返回 0，分配范围为 `[0, count)`。

这个方案的一个微妙之处值得强调：`INSERT ... ON DUPLICATE KEY UPDATE` 在 MySQL 中作为单条语句执行，持有行的排他锁直到语句完成。并发的多个连接在同一行上会串行化执行，但每个连接的 `LAST_INSERT_ID` 值互不干扰——这正是 session-local 变量的关键特性。

初始化时各 allocator 的 `next_id` 设为 1000（`INSERT IGNORE INTO id_allocators (name, next_id) VALUES ('inode', 1000)`），为系统保留 ID（例如根目录 inode_id = 1）预留了空间。

## Schema 设计要点

MiniDFS 的 MySQL schema 包含七张表，各自职责清晰。

`inodes` 表存储整个 namespace 树。每个 inode 有一个 `parent_id` 指向父目录，加上 `(parent_id, name)` 的唯一索引 `uk_parent_name`，构成了树形结构的邻接表表示。路径解析通过从根开始逐级查询 `get_child(parent_id, name)` 实现。`version` 字段用于乐观锁——`update_inode()` 的 WHERE 子句包含 `AND version=:version`，更新时自增 version，如果 `affected_rows() == 0` 则说明发生了并发冲突。

`blocks` 表存储 block 元数据，通过 `(inode_id, block_index)` 索引与文件关联。`state` 字段追踪 block 生命周期（allocating → committed → deleted），`desired_replica` 记录期望副本数供 ReplicationManager 使用。

`block_replicas` 表是 block 到 DataNode 的映射关系，主键是 `(block_id, datanode_id, storage_id)` 三元组。DataNode 通过 BlockReport 上报其持有的 block 列表时，NameNode 通过 `upsert_replica()` 更新此表。

`leases` 表记录文件写租约。`(inode_id, state)` 索引支持快速查询某个文件是否有活跃租约，`(state, expire_time_ms)` 索引支持 LeaseManager 的过期扫描。

`op_log` 表通过 `request_id` 唯一索引实现操作幂等——Client 重试相同请求时，`check_request_id()` 发现该 request_id 已存在，直接返回成功而非重复执行。

## 操作日志与幂等性

分布式系统中，网络超时是常态。Client 发出写请求后如果未收到响应（可能是请求丢失，也可能是响应丢失——操作实际已成功执行），会进行重试。如果不做去重处理，重试会导致操作被执行多次——例如同一个文件被创建两次，或同一条 lease 被记录两次。

`op_log` 表是 MiniDFS 实现 at-least-once 到 exactly-once 语义转换的关键。每次写操作携带 Client 生成的 `request_id`（UUID），NameNode 在执行操作前先调用 `check_request_id()` 检查该 ID 是否已存在于 `op_log` 中。如果存在，说明这是一次重试，直接返回之前的结果；如果不存在，执行操作并在同一事务中将 `request_id` 写入 `op_log`。由于 `request_id` 列有唯一索引，即使在并发场景下也不会出现重复记录。

## 小结

选择 MySQL 作为元数据后端是 MiniDFS 在实现复杂度与系统能力之间做出的有意识的 tradeoff。EditLog+FsImage 的方案性能更优、无外部依赖，但实现复杂度会严重分散对核心逻辑的注意力。MySQL 方案让我们用一层薄薄的 SQL 抽象获得了完整的 ACID 保证、现成的并发控制和极低的调试门槛。

在 MySQL 之上构建的三层机制——连接池 RAII 封装保证资源不泄漏、`thread_local` 事务绑定保证多操作的事务一致性、`LAST_INSERT_ID()` 技巧保证 ID 分配的原子性——共同构成了一套可靠的元数据基础设施。上层的 NamespaceManager、BlockManager 等组件可以安全地调用 `MetadataStore` 接口，不必关心连接管理和并发安全的细节。

下一篇文章将在这套基础设施之上，讲解 NamespaceManager 如何管理目录树和文件生命周期，以及 LeaseManager 如何协调并发写入。
