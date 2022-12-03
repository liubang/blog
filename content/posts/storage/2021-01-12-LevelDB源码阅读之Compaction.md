---
title: LevelDB 源码阅读之 Compaction
tags: [leveldb, storage]
categories: [programming]
date: 2021-01-12
authors: ['liubang']
---

## 1. 概览

要谈论 LevelDB 的 Compaction 就不得不从 LevelDB 的整个数据写入流程入手。LevelDB 的基本写入流程大致为：

1. 数据先写入到 WAL 日志中，做持久化
2. 然后数据同步到`mutable memtable`中
3. 当`mutable memtable`大小达到`Options.write_buffer_size`设置的大小时，就会变成`immutable memtable`，并且创建一个新的`mutable memtable`
4. 后台的 Compaction 线程会把`immutable memtable`dump 成 sstable 文件，并设置于 Level 0 层
5. 当 Level i 达到一定条件后，就会和 Level i + 1 层的 sstable 进行合并，从而触发 Compaction 过程，并在 Level
   n + 1 层生成一个新的 sstable 文件

## 2. Compaction 分类

在 LevelDB 中，Compaction 大体上可以分为两类，分别是：

- `immutable memtable compaction`，也叫做**minor compaction**，指的是将`immutable memtable`dump 到 sstable 文件的过程
- `sstable compaction`，也叫做**major compaction**，指的是 sstable 文件之间的合并过程

而对于`sstable compaction`又可以细分为三种：

- `manual compaction`，是指外部通过调用`DBImpl::CompactRange`接口触发的
- `size compaction`，是指程序根据每个 Level 的总文件大小通过一定规则自动触发的
- `seek compaction`，每个 sstable 文件内部维护了一个**seek miss**的 counter，当达到一定条件的时候，LevelDB 就认为这个文件需要 Compact

从`DBImpl::BackgroundCompaction`的代码逻辑中不难看出，这些 Compaction 策略的优先级为：

`immutable memtable compaction` > `manual compaction` > `size compaction` > `seek compaction`

```c++
// db_impl.cc
void DBImpl::BackgroundCompaction() {
  mutex_.AssertHeld();

  // 首先判断是否存在 immutable memtable，如果存在，则优先进行
  // immutable memtable compaction
  if (imm_ != nullptr) {
    CompactMemTable();
    return;
  }
  Compaction* c;
  // 其次判断是否存在 manual_compaction_，如果有，则进行manual compaction
  bool is_manual = (manual_compaction_ != nullptr);
  InternalKey manual_end;
  if (is_manual) {
    // ...
  } else {
    // 然后通过PickCompaction选择size compaction还是seek compaction
    c = versions_->PickCompaction();
  }
  //......
}

// version_set.cc
Compaction* VersionSet::PickCompaction() {
  Compaction* c;
  int level;
  // We prefer compactions triggered by too much data in a level over
  // the compactions triggered by seeks.
  const bool size_compaction = (current_->compaction_score_ >= 1);
  const bool seek_compaction = (current_->file_to_compact_ != nullptr);
  if (size_compaction) {
    // ...
  } else if (seek_compaction) {
    // ...
  } else {
    return nullptr;
  }
  // ...
}
```

## 3. Immutable memtable Compaction

### 3.1 触发条件

由于`immutable memtable compaction`是当存在**Immutable memtable**的时候才会触发，因此，`immutable memtable compaction`的触发于数据的写入有着密切的关联。追踪整个数据写入的逻辑，不难发现整个调用的链路为：`DBImpl::Put` -> `DB::Put` -> `DBImpl::Write` -> `DBImpl::MakeRoomForWrite`。

`DBImpl::MakeRoomForWrite`的逻辑也很清晰：

```c++
// db_impl.cc
Status DBImpl::MakeRoomForWrite(bool force) {
  mutex_.AssertHeld();
  assert(!writers_.empty());
  bool allow_delay = !force;
  Status s;
  while (true) {
    if (!bg_error_.ok()) {
      // Yield previous error
      s = bg_error_;
      break;
    } else if (allow_delay && versions_->NumLevelFiles(0) >=
                                  config::kL0_SlowdownWritesTrigger) {
      // ...
      mutex_.Unlock();
      env_->SleepForMicroseconds(1000);
      allow_delay = false;  // Do not delay a single write more than once
      mutex_.Lock();
    } else if (!force &&
               (mem_->ApproximateMemoryUsage() <= options_.write_buffer_size)) {
      // There is room in current memtable
      break;
    } else if (imm_ != nullptr) {
      // ...
      background_work_finished_signal_.Wait();
    } else if (versions_->NumLevelFiles(0) >= config::kL0_StopWritesTrigger) {
      // ...
      background_work_finished_signal_.Wait();
    } else {
      // ...
      imm_ = mem_;
      has_imm_.store(true, std::memory_order_release);
      mem_ = new MemTable(internal_comparator_);
      mem_->Ref();
      // ...
      MaybeScheduleCompaction();
    }
  }
  return s;
}
```

1. 先判断 Level 0 层的文件数是否达到了 `kL0_SlowdownWritesTrigger (default: 8)`中配置的值，如果达到的话，则 Sleep 1ms
2. 判断当前 memtable 占用的内存大小是否达到了 `Options.write_buffer_size` 的值，如果没有达到，则说明当前 memtable 符合写入条件
3. 如果当前 memtable 占用的内存大小达到了阈值，则检查是否有还未 compaction 的 immutable memtable，如果有，则等待直到上一个 immutable memtable compaction 执行完成
4. 如果不存在还未 compaction 的 immutable memtable，则判断当前 Level 0 层的的文件数是否达到了 `kL0_StopWritesTrigger (default: 12)`设置的数量，如果达到了则等待后台的 compaction 任务执行完成，并且直到满足条件
5. 如果当前 Level 0 层的文件数没有达到阈值，则将当前的 mutable memtable 设置成 immutable mentable，并创建一个新的 mutable memtable，然后触发 compaction

### 3.2 执行过程

Immutable memtable compaction 的执行过程逻辑在`DBImpl::CompactMemTable` -> `DBImpl::WriteLevel0Table`中，整个流程分为 3 个步骤：

```c++
// db_impl.cc
Status DBImpl::WriteLevel0Table(MemTable* mem, VersionEdit* edit,
                                Version* base) {
  // ...
  Status s;
  {
    mutex_Unlock();
    s = BuildTable(dbname_, env_, options_, table_cache_, iter, &meta);
    mutex_Lock();
  }
  // ...
  int level = 0;
  if (s.ok() && meta.file_size > 0) {
    const Slice min_user_key = meta.smallest.user_key();
    const Slice max_user_key = meta.largest.user_key();
    if (baze != nullptr) {
      level = baze->PickLevelForMemTableOutput(min_user_key, max_user_key);
    }
    edit->AddFile(level, meta.number, meta.file_size, meta.smallest,
                  meta.largest);
  }
  // ...
}
```

1. 调用`DBImpl::BuildTable`将 Immutable memtable 中的数据 dump 成 sstable 文件
2. 调用`VersionSet::PickLevelForMemTableOutput`为这个新生成的 sstable 文件选择一个新的 Level
3. 调用`VersionEdit::AddFile`将这个新的 sstable 文件放到选出来的 Level 中

下图是`VersionSet::PickLevelForMemTableOutput`的流程图

![](/images/2021-01-12/PickLevelForMemTableOutput.jpg#center)

## 4. Sstable Compaction

Sstable Compaction 就是将不同层级的 sst 文件进行合并的，主要是为了均衡各个 level 的数据，保证读性能，同时也会合并 delete 数据，释放磁盘空间。

### 4.1 Manual Compaction

Manual Compaction 的核心逻辑在 `VersionSet::CompactRange` 中，执行流程为：

1. 通过 `Version::GetOverlappingInputs` 获取指定的 Level 中 key-range 与[start, end]有交集的 sstable
2. 如果指定的 Level > 0 则对一次 compaction 的 sst 文件总大小做个限制，避免一次 compact 过多
3. 通过 `VersionSet::SetupOtherInputs` 获取其他需要 compatcion 的 sstable
   1. 通过调用`VersionSet::AddBoundaryInputs`将当前 Level 中符合边界条件的 sst 添加到要 compaction 的 sst 列表中
   2. 通过调用`VersionSet::GetRange`确定当前 Level 中要 compaction 的 sst 文件的 key range
   3. 通过调用`Version::GetOverlappingInputs`获取 Level + 1 层中与上一步获取的 key range 有交集的 sst 文件
   4. 通过调用`VersionSet::GetRange2`获取所有将要参与 compaction 的 sst 文件的 key range
   5. 在不改变 Level + 1 层 compaction 文件个数的情况下，尝试增加 Level 层 compaction 文件的数量
   6. 获取 Level + 2 层中与上述获取的最终 key range 有交集的 sst 文件

### 4.2 Size Compaction

Size Compaction 的执行条件是 LevelDB 会计算每个 Level 的总文件大小，从而计算出一个 score，最后根据 score，来选择一个合适的 level 来进行 compaction。
score 的计算逻辑主要在`VersionSet::Finalize`中：当$Level = 0$时，$score = files.size() / 4$，当 $Level > 0$时，$score
= levelbytes / (1048576.0 * 10^level)$。通过遍历每一层的所有 sstable 文件，根据对应的公式计算出来$score$，然后挑选出最大的$score$以及对应的 Level。

### 4.3 Seek Compaction

在`FileMetaData`中，有一个字段是`allowed_seeks`，是用来保存当前 sst 文件，允许容忍的 seek miss 最大值，每次调用 Get，并且触发 seek miss 的时候，就会对对应的 sst 文件的`allowed_seeks`执行减 1。`allowed_seeks`的初始值为：$sstsize / 16384$，且最小为 100。
如果某个 sst 文件的`allowed_seeks`减到 0 的时候，则会将该 sst 文件赋值给`Version::file_to_compact_`，同时将该 sst 的 level 赋值给`Version::file_to_compact_level_`。

### 4.4 Do Compaction Work

前面的逻辑属于 Compaction 策略，而这一步可以说是真正执行 Compaction 的过程了，核心逻辑都在`DBImpl::DoCompactionWork`中：

1. 调用`VersionSet::MakeInputIterator`构造迭代器：
   1. 对于 Level 0 层的文件，会为每一个 sst 文件创建一个 Iterator
   2. 对于非 Level 0 层的文件，会创建一个 concatenating iterator (TwoLevelIterator)
   3. 然后将通过上述两条规则创建好的 Iterator 构造成 `MergingIterator`
2. 对构造好的 Iterator 进行遍历
   1. `input->SeekToFirst()`
   2. 优先检查并合并存在的`Immutable Memtable`
   3. 如果当前 key 与 level + 2 层产生的重叠的 sst 文件的 size 超过阈值，则调用 `DBImpl::FinishCompactionOutputFile` 立即结束当前写入的 sstable 文件
   4. 解析当前的 key
   5. 判断当前 key 是否重复且不在快照范围内，或者当前 key 被标记为删除(`type == kTypeDeletion`)并且当前 key 不在快照范围内并且在 Level + 2 层以上的 Level 中不存在该 key(`Compaction::IsBaseLevelForKey`)，满足上述条件时，该 key 被丢弃
   6. 当该 key 不被丢弃时，将该 key 写入到 compat 的 sst 文件中
   7. 当当前写入的 sst 文件大小超过阈值的时候，会关闭该文件，在下一次写入 key 的时候创建一个新的 sst 文件
   8. 调用迭代器迁移`input->Next()`
3. 更新 compact 统计信息
4. 调用`DBImpl::InstallCompactionResults`生效 compact 后的状态
   1. 将 compat 中的 input sstable 设置为删除，生成的新的 sstable 文件添加到 Level + 1 层中
   2. 调用`VersionSet::LogAndApply`应用 VersionEdit
      1. 以当前 version 为基准，构造新的 Version
      2. 通过`VersionSet::Builder`将 VersionEdit 应用在新的 Version 上
      3. 重新计算每一个 sstable 的 score 值
      4. 写入 MANIFEST 文件
      5. 将`current_`设置为新的 version
