---
layout: article
title: RocksDB源码学习之MemTable
published: false
tags: [c++, RocksDB]
category: c++
---

MemTable 是一种基于内存的数据结果，用来将数据暂存到内存当中。当 MemTable 设定的容量写满的时候，当前的 MemTable 就会变得不可写，然后创建一个新的 MemTable 来代替他。
同时会有一个线程将这个被写满了的 MemTable 中的数据写入到 sst 文件当中，并且销毁这个 MemTable。简而言之，MemTable 就像是内存中的一个缓冲区，对于用户而言，数据的写操作
总是针对 MemTable，而读操作总是先读 MemTable，如果读不到，再读 sst 文件。

## 关键配置项

** memtable_factory **

** write_buffer_size: ** 单个 memtable 的大小

** db_write_buffer_size: ** 跨列簇的 memtable 总大小

** write_buffer_manager: ** 除了通过参数指定之外，用户还可以自定义 write buffer manager 来控制所有 memtable 占用空间的总和

** max_write_buffer_number: ** 内存中能够同时存在的 memtable 的最大个数

** max_write_buffer_size_to_maintain: ** 保存在内存中的写历史大小，这些写历史操作包括当前 memtable 的大小，即将被 flush 到 sst 中的 memtable 的大小，以及最近已经被 flush 到 sst 中的 memtable 中的数据；
如果删除一个已经被 flush 到 sst 中的 memtable 后，历史数据占用内存小于这个阈值，那么这个 memtable 就不会被删除

## Flush 的触发条件

当满足以下条件的时候，会触发 MemTable 中的数据写入 sst 文件:

1. 单个 MemTable 在一次写操作后的占用内存超过`write_buffer_size`配置的大小时
2. 所有的 MemTable 占用的内存总量超过`db_write_buffer_size`配置的大小，或者`write_buffer_manager`发出 flush 的信号时，最大的 MemTable 会被写入 sst 文件
3. WAL 文件的大小超过`max_total_wal_size`配置的大小时，将具有最旧数据的 MemTable 写入到 sst 文件，以清除包含此 MemTable 中数据的 WAL 文件

## 并发写操作

可以通过`allow_concurrent_memtable_write`配置来开启和关闭并发写特性，需要特别注意的是，目前只有基于`skiplist`的 MemTable 支持这项特性。

## MemTable 内置的实现

RocksDB 为我们提供了几种 MemTable 的实现，源码位于`memtable`目录下。

### Skiplist MemTable

Skiplist 其实就是在普通单向链表的基础上增加一些索引，并且这些索引是分层的，这样能实现数据的快速查找。
在 rocksdb 中，skiplist 的实现位于`memtable/skiplist.h`中。

```c++
template<typename Key, class Comparator>
class SkipList {
  private:
    struct Node;
  private:
    const uint16_t kMaxHeight_;
    const uint16_t kBranching_;
    const uint32_t kScaledInverseBranching_;
    Comparator const compare_;
    Allocator* const allocator_;
    Node* const head_;
    std::atomic<int> max_height_;
    Node** prev_;
    int32_t prev_height_;
  public:
    class Iterator {
      //......
    };
  //......
};
```

从 SkipList 的结构定义来看，整体上还是中规中矩。`kMaxHeight_`是该 SkipList 中元素索引的最大层数，`compare_`是用来做元素比较的，
因为这里是模板类，元素类型不确定，所以需要用户在使用中显示指定元素比较的实现; `allocator_`是用来指定内存分配器的；`head_`很显然
是用来标记跳表的表头元素；`max_height_`是当前跳表中元素的索引的最大层数，这个数在 SkipList 创建初期是变化的，但是不会超过`kMaxHeight_`;
这里有两个比较特别的成员，`kBranching_`和`kScaledInverseBranching_`，其实如果不仔细阅读代码的话，很难理解这个成员的含义，实际上`kScaledInverseBranching_`
是一个随机数值域中前`kBranching_`分之一的数字，这样说可能比较绕口，通俗点来说，SkipList 虽然索引分层，但是每一个层级中元素的个数并不是随机的，而是满足一定的
概率，越底层的元素越多，越上层的元素越少，那么如何来恒定这样一种概率关系，rocksdb 的 SkipList 中就引入了这样两个成员，`kBranching_`可以理解为概率因子，
而`kScaledInverseBranching_`则是满足这个概率因子的一个界定。下面就来从插入新元素时确定元素所在层的逻辑来具体分析:

```c++
// 首先在构造函数中对kScaledInverseBranching_初始化
kScaledInverseBranching_ = (Random::kMaxNext + 1) / kBranching_);

// Insert的时候会调用RandomHeight
template<typename Key, class Comparator>
int SkipList<Key, Comparator>::RandomHeight() {
    auto rnd = Random::GetTLSInstance();
    int height = 1;
    while (height < kMaxHeight_ && rnd->Next() < kScaledInverseBranching_) {
        height++;
    }
    return height;
}
```

假设概率因子$kBranching = 4$，那么在随机数值域内，生成的随机数$x$，$p(x < kScaledInverseBranching) = 1 / 4$，也就是说相邻的两层，
元素落到上层是落到下层的$1/4$。这种设计很巧妙的对分布到各层的元素进行了概率上的限定。而且对于后续的`EstimateCount`操作提供了可能。

```c++
template<typename Key, class Comparator>
uint64_t SkipList<Key, Comparator>::EstimateCount(const Key& key) const {
    uint64_t count = 0;
    Node* x = head_;
    int level = GetMaxHeight() - 1;
    while (true) {
        Node* next = x->Next(level);
        if (next == nullptr || compare_(next->key, key) >= 0) {
            if (level == 0) {
                return count;
            } else {
                count *= kBranching_;
                level--;
            }
        } else {
            x = next;
            count++;
        }
    }
}
```

### HashSkiplist MemTable

### HashLinklist MemTable

### Vector MemTable
