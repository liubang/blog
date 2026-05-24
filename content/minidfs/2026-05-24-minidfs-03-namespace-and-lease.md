---
title: "MiniDFS 03: Namespace 与 Lease"
description: "MiniDFS 的 inode 树设计、路径解析实现、递归创建与删除，以及 Lease 写互斥机制的完整实现。"
date: 2026-05-24
categories: [存储与分布式]
tags: [distributed-system, namespace, lease, cpp]
authors: ["liubang"]
weight: 3
series: ["MiniDFS"]
series_weight: 3
lightgallery: true
---

分布式文件系统对用户呈现的是一棵目录树——`/data/logs/2024/app.log` 这样的路径看起来和本地文件系统没什么区别。但在底层，这棵树的每个节点（inode）是存储在 MySQL 中的一行记录，路径解析是逐级查询，文件创建需要加写锁（Lease）来防止并发冲突。

这篇文章深入 NamespaceManager 和 LeaseManager 的实现，重点讲路径解析的逐级查找、`mkdir -p` 的事务化实现、递归删除的级联问题，以及 Lease 从分配到过期的完整生命周期。

![Namespace 与 Lease 机制架构](/images/minidfs/namespace-lease.svg "Namespace 目录树结构与 Lease 状态机：从路径解析到写互斥的全景视图")

## Inode 数据模型

MiniDFS 的目录树由 inode 节点构成。每个 inode 代表一个文件或目录，定义在 `types.h` 中：

```cpp
enum class InodeType : uint8_t {
    kDirectory = 1,
    kFile = 2,
};

enum class FileState : uint8_t {
    kNormal = 0,
    kUnderConstruction = 1,
    kDeleted = 2,
};

struct Inode {
    uint64_t inode_id = 0;
    InodeType type = InodeType::kDirectory;
    uint64_t parent_id = 0;
    std::string name;

    std::string owner;
    std::string group;
    uint32_t permission = kDefaultPermission;

    uint64_t length = 0;
    uint32_t replication = kDefaultReplication;
    uint64_t block_size = kDefaultBlockSize;

    FileState state = FileState::kNormal;

    uint64_t ctime_ms = 0;
    uint64_t mtime_ms = 0;
    uint64_t version = 0;
};
```

几个关键设计决策值得展开。首先是 `parent_id + name` 的组合定位方式。每个 inode 不存储完整路径（如 `/data/logs/app.log`），而是只存储自己的 `name`（`app.log`）加上父目录的 `inode_id`。这个设计使得 rename 操作只需修改一行记录的 `parent_id` 和 `name` 字段，而存储完整路径的方案需要更新这个节点及其所有后代的路径——在深层目录树中这是 O(n) 的代价。子目录查询也很自然：`WHERE parent_id = ?` 即可列出某目录下的所有直接子节点。

代价在于路径解析。从 `/a/b/c` 定位到目标 inode 需要逐级查找——先找 root 下名为 `a` 的子节点，再找 `a` 下名为 `b` 的子节点，最后找 `b` 下名为 `c` 的子节点。这是 O(depth) 次 MySQL 查询。HDFS 的 NameNode 将整个 namespace 驻留内存，路径解析是 O(depth) 的哈希表查找，单次操作不涉及 I/O；MySQL 方案的每一级都是一次网络往返。这对教学项目可以接受，生产环境可以通过在 NameNode 内存中缓存热点 inode 来缓解。

`FileState` 用三态标识文件的生命周期：`kUnderConstruction` 表示文件正在被写入（需要持有 Lease），`kNormal` 表示写入完成可被读取，`kDeleted` 用于软删除标记。`version` 字段是乐观锁版本号，配合 `UPDATE ... WHERE version = ?` 实现并发安全的更新。

对应的 MySQL 表设计如下：

```sql
CREATE TABLE inodes (
    inode_id BIGINT UNSIGNED PRIMARY KEY,
    parent_id BIGINT UNSIGNED NOT NULL,
    name VARCHAR(255) NOT NULL,
    type TINYINT UNSIGNED NOT NULL,
    owner VARCHAR(64) NOT NULL,
    `group` VARCHAR(64) NOT NULL,
    permission INT UNSIGNED NOT NULL DEFAULT 493,
    length BIGINT UNSIGNED NOT NULL DEFAULT 0,
    replication INT UNSIGNED NOT NULL DEFAULT 3,
    block_size BIGINT UNSIGNED NOT NULL DEFAULT 134217728,
    state TINYINT UNSIGNED NOT NULL DEFAULT 0,
    ctime_ms BIGINT UNSIGNED NOT NULL,
    mtime_ms BIGINT UNSIGNED NOT NULL,
    version BIGINT UNSIGNED NOT NULL DEFAULT 1,
    UNIQUE KEY uk_parent_name (parent_id, name),
    KEY idx_parent_id (parent_id)
);
```

`(parent_id, name)` 的唯一索引保证了同级目录下不会出现重名节点，同时也是路径解析时 `get_child(parent_id, name)` 的高效查询路径。

## 路径解析：walk_path

路径解析是 NamespaceManager 所有操作的基础。无论是 `mkdir`、`create_file` 还是 `remove`，第一步都是把路径字符串转换成对应的 inode。这个过程分两步：先将路径拆分为组件，再逐级查找。

```cpp
std::vector<std::string_view> NamespaceManager::split_path(std::string_view path) {
    std::vector<std::string_view> components;
    size_t start = 1; // skip leading '/'
    while (start < path.size()) {
        auto end = path.find('/', start);
        if (end == std::string_view::npos) {
            end = path.size();
        }
        if (end > start) {
            components.push_back(path.substr(start, end - start));
        }
        start = end + 1;
    }
    return components;
}
```

`split_path` 将 `/data/logs/app.log` 拆成 `["data", "logs", "app.log"]`，跳过开头的 `/` 和连续的分隔符。返回的 `string_view` 指向原始路径字符串，不产生额外拷贝。

逐级查找的核心是 `walk_path`：

```cpp
pl::Result<Inode> NamespaceManager::walk_path(
    const std::vector<std::string_view>& components) {
    auto current = store_->get_inode(kRootInodeId);
    if (current.hasError()) {
        return current;
    }

    for (const auto& name : components) {
        if (current.value().type != InodeType::kDirectory) {
            return pl::makeError(
                static_cast<pl::status_code_t>(ErrorCode::kNotDirectory),
                fmt::format("'{}' is not a directory", current.value().name));
        }
        auto child = store_->get_child(current.value().inode_id, name);
        if (child.hasError()) {
            return folly::makeUnexpected(child.error());
        }
        if (!child.value().has_value()) {
            return pl::makeError(
                static_cast<pl::status_code_t>(ErrorCode::kNotFound),
                fmt::format("path component '{}' not found", name));
        }
        current = std::move(child.value().value());
    }
    return current;
}
```

从 root inode（`kRootInodeId = 1`）出发，每一步先检查当前节点是否为目录（中间路径上不允许出现文件），然后通过 `get_child(parent_id, name)` 查找下一级。如果任何一级不存在或类型不匹配，立即返回错误。对于根路径 `/`，`components` 为空，直接返回 root inode。

所有公开方法在调用 `walk_path` 之前都会先执行路径校验：

```cpp
namespace {
pl::Result<pl::Void> validate_path(std::string_view path) {
    if (path.empty() || path[0] != '/') {
        return pl::makeError(static_cast<pl::status_code_t>(ErrorCode::kInvalidPath),
                             "path must be absolute (start with '/')");
    }
    if (path.size() > kMaxPathLength) {
        return pl::makeError(
            static_cast<pl::status_code_t>(ErrorCode::kPathTooLong),
            fmt::format("path length {} exceeds max {}", path.size(), kMaxPathLength));
    }
    return pl::Void{};
}
} // namespace
```

路径必须是绝对路径且不超过 8192 字节（`kMaxPathLength`）。

## mkdir：单级与递归创建

`mkdir` 支持两种模式：单级创建（父目录必须存在）和递归创建（类似 `mkdir -p`，自动创建不存在的中间目录）。两种模式通过 `create_parent` 参数区分：

```cpp
pl::Result<Inode> NamespaceManager::mkdir(std::string_view path,
                                          std::string_view owner,
                                          std::string_view group,
                                          uint32_t permission,
                                          bool create_parent) {
    auto valid = validate_path(path);
    if (valid.hasError()) {
        return folly::makeUnexpected(valid.error());
    }

    auto components = split_path(path);
    if (components.empty()) {
        return store_->get_inode(kRootInodeId);
    }

    Inode parent;
    if (create_parent) {
        auto parent_result = ensure_parent(components, owner, group, permission);
        if (parent_result.hasError()) {
            return parent_result;
        }
        parent = std::move(parent_result.value());
    } else {
        auto parent_components =
            std::vector<std::string_view>(components.begin(), components.end() - 1);
        auto parent_result = walk_path(parent_components);
        if (parent_result.hasError()) {
            return parent_result;
        }
        parent = std::move(parent_result.value());
    }

    auto& dir_name = components.back();
    auto existing = store_->get_child(parent.inode_id, dir_name);
    if (existing.hasError()) {
        return folly::makeUnexpected(existing.error());
    }
    if (existing.value().has_value()) {
        if (existing.value()->type == InodeType::kDirectory) {
            return existing.value().value();  // 幂等：已存在则直接返回
        }
        return pl::makeError(static_cast<pl::status_code_t>(ErrorCode::kAlreadyExists),
                             fmt::format("'{}' already exists as a file", dir_name));
    }

    auto id_result = store_->alloc_id("inode");
    if (id_result.hasError()) {
        return folly::makeUnexpected(id_result.error());
    }

    uint64_t ts = now_ms();
    Inode dir;
    dir.inode_id = id_result.value();
    dir.type = InodeType::kDirectory;
    dir.parent_id = parent.inode_id;
    dir.name = std::string(dir_name);
    dir.owner = std::string(owner);
    dir.group = std::string(group);
    dir.permission = permission;
    dir.ctime_ms = ts;
    dir.mtime_ms = ts;
    dir.version = 1;

    auto create_res = store_->create_inode(dir);
    if (create_res.hasError()) {
        return folly::makeUnexpected(create_res.error());
    }
    return dir;
}
```

逻辑分为三个阶段。第一阶段定位父目录：非递归模式直接 `walk_path` 到父路径，如果中间任何一级不存在就报错；递归模式则调用 `ensure_parent` 逐级"走或创建"。第二阶段检查目标是否已存在：如果已存在且是目录则幂等返回，如果已存在但是文件则报错。第三阶段创建新目录：通过 `alloc_id` 获取全局唯一 ID，组装 Inode 结构，调用 `create_inode` 写入 MySQL。

`ensure_parent` 是递归创建的核心：

```cpp
pl::Result<Inode> NamespaceManager::ensure_parent(
    const std::vector<std::string_view>& components,
    std::string_view owner,
    std::string_view group,
    uint32_t permission) {
    auto current = store_->get_inode(kRootInodeId);
    if (current.hasError()) {
        return current;
    }

    for (size_t i = 0; i + 1 < components.size(); ++i) {
        auto child = store_->get_child(current.value().inode_id, components[i]);
        if (child.hasError()) {
            return folly::makeUnexpected(child.error());
        }
        if (child.value().has_value()) {
            if (child.value()->type != InodeType::kDirectory) {
                return pl::makeError(
                    static_cast<pl::status_code_t>(ErrorCode::kNotDirectory),
                    fmt::format("'{}' exists but is not a directory", components[i]));
            }
            current = std::move(child.value().value());
        } else {
            auto id_result = store_->alloc_id("inode");
            if (id_result.hasError()) {
                return folly::makeUnexpected(id_result.error());
            }
            uint64_t ts = now_ms();
            Inode dir;
            dir.inode_id = id_result.value();
            dir.type = InodeType::kDirectory;
            dir.parent_id = current.value().inode_id;
            dir.name = std::string(components[i]);
            dir.owner = std::string(owner);
            dir.group = std::string(group);
            dir.permission = permission;
            dir.ctime_ms = ts;
            dir.mtime_ms = ts;
            dir.version = 1;

            auto create_res = store_->create_inode(dir);
            if (create_res.hasError()) {
                return folly::makeUnexpected(create_res.error());
            }
            current = dir;
        }
    }
    return current;
}
```

它遍历除最后一个元素外的所有路径组件（最后一个是 `mkdir` 的目标本身），对每一级执行"存在则走过去，不存在则创建"。这段逻辑在事务保护下执行——如果中途失败，事务回滚会撤销已创建的中间目录，保证 namespace 的一致性。

并发创建同一路径时，`(parent_id, name)` 唯一索引扮演了最后一道防线：即使两个线程同时发现某个中间目录不存在并尝试创建，只有一个 INSERT 能成功，另一个会触发唯一约束冲突。

## create_file：文件创建

文件创建与 `mkdir` 结构相似，但有几个关键区别：不支持递归创建父目录（父目录必须已存在），新文件的初始状态为 `kUnderConstruction`，并且文件创建后需要立即获取 Lease 才能写入数据。

```cpp
pl::Result<Inode> NamespaceManager::create_file(std::string_view path,
                                                std::string_view owner,
                                                std::string_view group,
                                                uint32_t permission,
                                                uint32_t replication,
                                                uint64_t block_size) {
    auto valid = validate_path(path);
    if (valid.hasError()) {
        return folly::makeUnexpected(valid.error());
    }

    auto components = split_path(path);
    if (components.empty()) {
        return pl::makeError(static_cast<pl::status_code_t>(ErrorCode::kInvalidPath),
                             "cannot create file at root path");
    }

    auto parent_components =
        std::vector<std::string_view>(components.begin(), components.end() - 1);
    auto parent_result = walk_path(parent_components);
    if (parent_result.hasError()) {
        return parent_result;
    }
    auto& parent = parent_result.value();

    if (parent.type != InodeType::kDirectory) {
        return pl::makeError(static_cast<pl::status_code_t>(ErrorCode::kNotDirectory),
                             "parent is not a directory");
    }

    auto& file_name = components.back();
    auto existing = store_->get_child(parent.inode_id, file_name);
    if (existing.hasError()) {
        return folly::makeUnexpected(existing.error());
    }
    if (existing.value().has_value()) {
        return pl::makeError(static_cast<pl::status_code_t>(ErrorCode::kAlreadyExists),
                             fmt::format("'{}' already exists", file_name));
    }

    auto id_result = store_->alloc_id("inode");
    if (id_result.hasError()) {
        return folly::makeUnexpected(id_result.error());
    }

    uint64_t ts = now_ms();
    Inode file;
    file.inode_id = id_result.value();
    file.type = InodeType::kFile;
    file.parent_id = parent.inode_id;
    file.name = std::string(file_name);
    file.owner = std::string(owner);
    file.group = std::string(group);
    file.permission = permission;
    file.replication = replication;
    file.block_size = block_size;
    file.state = FileState::kUnderConstruction;
    file.ctime_ms = ts;
    file.mtime_ms = ts;
    file.version = 1;

    auto create_res = store_->create_inode(file);
    if (create_res.hasError()) {
        return folly::makeUnexpected(create_res.error());
    }
    return file;
}
```

注意 `file.state = FileState::kUnderConstruction`——新创建的文件不可被读取，直到 Client 完成写入后调用 `complete_file` 将状态转为 `kNormal`。这保证了读路径永远不会看到写了一半的文件。

在完整的 CreateFile RPC 流程中，NameNode 会在 `create_file` 成功后紧接着调用 `LeaseManager::acquire_lease`，两步在同一个事务中执行。如果 inode 创建成功但 Lease 获取失败（极端情况下可能发生），事务回滚会同时撤销 inode 创建。即使极端场景下出现了"有 inode 但无 Lease"的孤儿记录，后台 GC 可以通过扫描 `state = kUnderConstruction` 且无 active lease 的 inode 来清理它们。

## Lease 机制详解

分布式环境下，Client 在写入文件的过程中可能崩溃——网络断开、进程被 kill、机器故障。如果没有保护机制，一个崩溃的 Client 会永久"霸占"文件，其他 Client 无法继续写入。Lease 解决的就是这两个问题：写互斥（同一时间只有一个 Client 能写某个文件）和崩溃检测（通过超时机制发现不活跃的 Client）。

Lease 的数据模型：

```cpp
enum class LeaseState : uint8_t {
    kActive = 0,
    kClosed = 1,
};

struct Lease {
    uint64_t lease_id = 0;
    uint64_t inode_id = 0;
    std::string client_id;
    LeaseState state = LeaseState::kActive;
    uint64_t expire_time_ms = 0;
    uint64_t ctime_ms = 0;
    uint64_t mtime_ms = 0;
};
```

每个 Lease 绑定到一个 `inode_id`（正在被写入的文件）和一个 `client_id`（持有写权限的 Client）。`expire_time_ms` 是 Lease 的到期时间，默认为创建时间加 60 秒（`kDefaultLeaseTimeoutMs = 60000`）。Client 需要在 Lease 到期前周期性续约（通常每 30 秒一次），如果超时未续约，NameNode 有权回收 Lease。

LeaseManager 的接口非常精简：

```cpp
class LeaseManager {
public:
    explicit LeaseManager(MetadataStore* store);

    pl::Result<Lease> acquire_lease(uint64_t inode_id, std::string_view client_id);
    pl::Result<pl::Void> renew_lease(uint64_t inode_id, std::string_view client_id);
    pl::Result<pl::Void> release_lease(uint64_t inode_id, std::string_view client_id);
    pl::Result<uint64_t> expire_stale_leases();
    pl::Result<bool> has_active_lease(uint64_t inode_id);

private:
    MetadataStore* store_;
};
```

五个方法覆盖了 Lease 的完整生命周期。`acquire_lease` 在文件创建时调用，`renew_lease` 由 Client 周期性心跳触发，`release_lease` 在文件写入完成时调用，`expire_stale_leases` 由后台定时任务驱动清理过期 Lease。

### acquire_lease：获取写锁

```cpp
pl::Result<Lease> LeaseManager::acquire_lease(uint64_t inode_id,
                                              std::string_view client_id) {
    auto existing = store_->get_active_lease(inode_id);
    if (existing.hasError()) {
        return folly::makeUnexpected(existing.error());
    }
    if (existing.value().has_value()) {
        return pl::makeError(static_cast<pl::status_code_t>(ErrorCode::kLeaseConflict),
                             "file already has an active lease");
    }

    auto id_result = store_->alloc_id("lease");
    if (id_result.hasError()) {
        return folly::makeUnexpected(id_result.error());
    }

    uint64_t ts = now_ms();
    Lease lease;
    lease.lease_id = id_result.value();
    lease.inode_id = inode_id;
    lease.client_id = std::string(client_id);
    lease.state = LeaseState::kActive;
    lease.expire_time_ms = ts + kDefaultLeaseTimeoutMs;
    lease.ctime_ms = ts;
    lease.mtime_ms = ts;

    auto create_res = store_->create_lease(lease);
    if (create_res.hasError()) {
        return folly::makeUnexpected(create_res.error());
    }
    return lease;
}
```

逻辑直接明了：先查看该文件是否已有 active lease，有则拒绝（写互斥）；没有则分配 ID、设置 60 秒过期时间、写入数据库。整个操作在事务中执行，`get_active_lease` 可以配合行级锁（`SELECT ... FOR UPDATE`）来防止两个 Client 同时通过"无 active lease"的检查。

### renew_lease：续约

```cpp
pl::Result<pl::Void> LeaseManager::renew_lease(uint64_t inode_id,
                                               std::string_view client_id) {
    auto existing = store_->get_active_lease(inode_id);
    if (existing.hasError()) {
        return folly::makeUnexpected(existing.error());
    }
    if (!existing.value().has_value()) {
        return pl::makeError(static_cast<pl::status_code_t>(ErrorCode::kLeaseNotFound),
                             "no active lease for this file");
    }

    auto& lease = existing.value().value();
    if (lease.client_id != client_id) {
        return pl::makeError(static_cast<pl::status_code_t>(ErrorCode::kLeaseConflict),
                             "lease held by different client");
    }

    uint64_t new_expire = now_ms() + kDefaultLeaseTimeoutMs;
    return store_->renew_lease(inode_id, new_expire);
}
```

续约时校验两点：Lease 必须存在且状态为 active，且调用者必须是 Lease 的持有者。校验通过后将 `expire_time_ms` 更新为当前时间加 60 秒。Client 通常每 30 秒发送一次 RenewLease RPC，保持 Lease 始终有 30-60 秒的剩余有效期。

### release_lease：正常释放

```cpp
pl::Result<pl::Void> LeaseManager::release_lease(uint64_t inode_id,
                                                 std::string_view client_id) {
    auto existing = store_->get_active_lease(inode_id);
    if (existing.hasError()) {
        return folly::makeUnexpected(existing.error());
    }
    if (!existing.value().has_value()) {
        return pl::Void{};  // 无 active lease，幂等返回成功
    }

    auto& lease = existing.value().value();
    if (lease.client_id != client_id) {
        return pl::makeError(static_cast<pl::status_code_t>(ErrorCode::kLeaseConflict),
                             "lease held by different client");
    }

    return store_->close_lease(inode_id);
}
```

在 CompleteFile 流程中，Client 通知 NameNode 文件写入完成，此时先调用 `NamespaceManager::complete_file` 将文件状态从 `kUnderConstruction` 转为 `kNormal`，再调用 `release_lease` 关闭 Lease。注意当 Lease 不存在时直接返回成功——这是幂等设计，避免重复释放导致错误。

### expire_stale_leases：崩溃恢复

```cpp
pl::Result<uint64_t> LeaseManager::expire_stale_leases() {
    return store_->expire_leases(now_ms());
}
```

这是整个 Lease 机制中最关键的"安全网"。NameNode 后台定时任务（例如每 10 秒一次）调用此方法，扫描 `leases` 表中 `state = kActive AND expire_time_ms < now_ms()` 的记录，批量将其状态设为 `kClosed`。底层 SQL 大致为：

```sql
UPDATE leases SET state = 1
WHERE state = 0 AND expire_time_ms < ?;
```

Lease 过期后，文件仍处于 `kUnderConstruction` 状态——已写入的 block 处于 `kAllocating` 状态，不会出现在读路径中。后续有两种处理方式：新的 Client 可以获取 Lease 继续写入（append），或者后台 GC 可以清理这些半成品文件和关联的孤儿 block。

## 删除操作：单文件与递归目录

删除操作需要处理两种场景：删除单个文件或空目录，以及递归删除整棵子树。

```cpp
pl::Result<Inode> NamespaceManager::remove(std::string_view path, bool recursive) {
    auto valid = validate_path(path);
    if (valid.hasError()) {
        return folly::makeUnexpected(valid.error());
    }

    auto components = split_path(path);
    if (components.empty()) {
        return pl::makeError(static_cast<pl::status_code_t>(ErrorCode::kInvalidPath),
                             "cannot remove root directory");
    }

    auto inode_result = walk_path(components);
    if (inode_result.hasError()) {
        return inode_result;
    }
    auto& inode = inode_result.value();

    if (inode.type == InodeType::kDirectory) {
        auto children = store_->list_children(inode.inode_id);
        if (children.hasError()) {
            return folly::makeUnexpected(children.error());
        }
        if (!children.value().empty() && !recursive) {
            return pl::makeError(
                static_cast<pl::status_code_t>(ErrorCode::kDirectoryNotEmpty),
                fmt::format("directory '{}' is not empty", inode.name));
        }
        if (recursive) {
            std::vector<uint64_t> delete_stack;
            std::vector<uint64_t> to_delete;
            delete_stack.push_back(inode.inode_id);
            while (!delete_stack.empty()) {
                uint64_t cur = delete_stack.back();
                delete_stack.pop_back();
                auto cur_children = store_->list_children(cur);
                if (cur_children.hasError()) {
                    return folly::makeUnexpected(cur_children.error());
                }
                for (const auto& child : cur_children.value()) {
                    to_delete.push_back(child.inode_id);
                    if (child.type == InodeType::kDirectory) {
                        delete_stack.push_back(child.inode_id);
                    }
                }
            }
            for (auto it = to_delete.rbegin(); it != to_delete.rend(); ++it) {
                auto del = store_->delete_inode(*it);
                if (del.hasError()) {
                    return folly::makeUnexpected(del.error());
                }
            }
        }
    }

    auto del = store_->delete_inode(inode.inode_id);
    if (del.hasError()) {
        return folly::makeUnexpected(del.error());
    }
    return inode;
}
```

递归删除的实现使用迭代式 DFS（而非递归调用，避免栈溢出风险）：先用栈遍历整棵子树收集所有后代 inode_id，然后按逆序删除（最深的节点先删）。逆序删除是为了满足外键约束——如果 `inodes` 表有 `parent_id` 的外键引用，先删父节点会导致约束违反。即使没有物理外键，先删子节点再删父节点也能保证中途失败时不会产生"有父无子"的不一致状态（孤儿节点比"有子无父"更容易被 GC 发现和清理）。

整个删除在事务中执行。对于包含数百万节点的深层目录树，事务可能会非常大——生产系统通常采用标记删除（将 root 标记为 deleted）加后台 GC 的两阶段方案来避免长事务。MiniDFS 作为教学项目采用了更直观的即时删除。

## rename 操作

rename 是所有 namespace 操作中实现最简洁的一个：

```cpp
pl::Result<pl::Void> NamespaceManager::rename(std::string_view src, std::string_view dst) {
    auto src_valid = validate_path(src);
    if (src_valid.hasError()) {
        return src_valid;
    }
    auto dst_valid = validate_path(dst);
    if (dst_valid.hasError()) {
        return dst_valid;
    }

    auto src_components = split_path(src);
    auto dst_components = split_path(dst);

    if (src_components.empty()) {
        return pl::makeError(static_cast<pl::status_code_t>(ErrorCode::kInvalidPath),
                             "cannot rename root");
    }
    if (dst_components.empty()) {
        return pl::makeError(static_cast<pl::status_code_t>(ErrorCode::kInvalidPath),
                             "cannot rename to root");
    }

    auto src_inode = walk_path(src_components);
    if (src_inode.hasError()) {
        return folly::makeUnexpected(src_inode.error());
    }

    auto dst_parent_components =
        std::vector<std::string_view>(dst_components.begin(), dst_components.end() - 1);
    auto dst_parent = walk_path(dst_parent_components);
    if (dst_parent.hasError()) {
        return folly::makeUnexpected(dst_parent.error());
    }

    auto& dst_name = dst_components.back();
    auto existing = store_->get_child(dst_parent.value().inode_id, dst_name);
    if (existing.hasError()) {
        return folly::makeUnexpected(existing.error());
    }
    if (existing.value().has_value()) {
        return pl::makeError(static_cast<pl::status_code_t>(ErrorCode::kAlreadyExists),
                             fmt::format("destination '{}' already exists", dst_name));
    }

    Inode updated = src_inode.value();
    updated.parent_id = dst_parent.value().inode_id;
    updated.name = std::string(dst_name);
    updated.mtime_ms = now_ms();

    return store_->update_inode(updated);
}
```

核心逻辑非常清晰：解析源路径得到 inode，解析目标路径的父目录，检查目标名称不存在，最后修改 inode 的 `parent_id` 和 `name` 字段。因为 inode 的 ID 不变，所有指向这个 inode 的 block 映射和子节点关系都自动"跟着走"——这正是 `parent_id + name` 方案相比存储完整路径的优势所在。

当前实现没有检查"不能把目录移到自己的子目录下"这一约束（例如 rename `/a` to `/a/b/c`），这在生产系统中需要额外处理，否则会形成环路。检测方法是从目标父目录向上遍历，确认不会遍历到源 inode 自身。

## 小结

Namespace 管理的核心难点在于三处：路径解析的逐级查找带来的性能开销、递归操作（mkdir -p、rm -r）的事务化保证、以及并发控制。MiniDFS 通过 `parent_id + name` 的 inode 模型，配合 MySQL 唯一索引和事务机制，用相对简洁的代码实现了完整的目录树语义。

Lease 机制则为文件写入提供了两层保障：写互斥确保不会有两个 Client 同时向一个文件追加数据导致交叉覆盖，超时过期则确保崩溃的 Client 不会永久锁住文件。acquire → renew → release 的正常流程加上 expire_stale_leases 的兜底清理，构成了一个既简单又健壮的分布式锁方案。

下一篇文章将在 Namespace 和 Lease 的基础之上，讲解完整的写入 Pipeline——从 Client 调用 CreateFile 开始，经历 Lease 获取、Block 分配、Pipeline 建立、数据传输、到最终 CompleteFile 的全流程。
