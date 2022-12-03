---
title: 使用std::list的splice方法实现LRU Cache
categories: [programming]
tags: [c++, c++11]
date: 2022-05-15
authors: ['liubang']
---

## std::list splice 简介

`splice`函数通过重新排列链表指针，将一个`std::list`中的节点转移到另一个`std::list`中。在元素的转移过程中不会触发元素的拷贝或者移动。因此，调用`splice`函数之后，元素现有的引用和迭代器都不会失效。

下面是一个将`listA`中所有节点附加到`listB`的一个简单代码示例，转移的过程不会导致`listA`中元素的引用和迭代器失效:

```cpp
// Note: c++17 required below. (For CTAD(Class template argument deducation))
std::list listA{1, 2, 3};
std::list listB{4, 5, 6};

auto it = listA.begin();   // Iterator to 1

// Append listA to listB
listB.splice(listB.end(), listA);

// All listA elements transferred to listB
std::cout << listB.size() << " " << listA.size() << std::endl;   // 6 0

// Prints Below: 4 5 6 1 2 3
for (auto i : listB) {
    std::cout << i << " ";
}
std::cout << std::endl;

// Iterator still valid
std::cout << *it << std::endl;   // 1
```

当然，我们也可以在不使用`splice`的情况下将一个 list 中的元素转移到另一个 list 中，但是需要将原 list 中的元素删除，并在目标 list 中插入新的元素。删除和新增元素对于较小的对象（例如 int）是可以接受的，但是对于较大的对象来说，由于需要调用拷贝/移动构造和析构函数，所以成本会很高。

`splice`函数有一些重载，用于传输所有节点、或者特定节点或者一系列节点。这些函数可以将节点从一个列表转移到另一个列表，或者修改节点在列表中的位置。除了将一系列节点（并非所有）从一个列表转移到另一个列表这一种情况，其他所有情况下`splice`函数的时间复杂度均为常数 O(1)。

splice 的另一个值得注意的特性是，我们可以将一个节点从列表的一个位置转移到该列表的另一个位置。而后面我们实现 LRU
Cache 就是需要使用到这个特性。

```cpp
std::list<std::string> strList{"A", "B", "C"};
// Transfers "C" to the front (before "A")
strList.splice(strList.begin(), strList, --strList.end());
// Prints below: C A B
for (auto& str : strList) {
    std::cout << str << " ";
}
```

## LRU Cache

Least Recently Used (LRU)
Cache，最近最少使用缓存，是一种容量有限的缓存，它会丢弃最近最少使用的元素，以便在容量已满时为新的元素腾出空间。

接下来我们将要创建一个通用的 KV LRU
Cache，他可以添加 KV，也可以通过给定的 K 来检索，以及删除特定的元素。无论是添加元素，检索元素还是删除元素，这些操作的平均时间复杂度都应为常数 O(1)。

### 设计

我们通常将缓存等同于哈希表+淘汰策略。虽然看上去有点简单粗暴，但是也不无道理。缓存的实现需要有一个能够加快检索的索引结构，在这里我们可以使用 hashmap 来作为键值对的索引，用于提升检索的时间复杂度。然而 LRU Cache 还有一个隐含的淘汰策略，那就是顺序，根据最近的使用情况来排列元素项，并进行相应的淘汰。
因此，我们将在这里使用两种数据结构来实现：链表和 hashmap。

链表按照最近使用顺序存储键值对，hashmap 用来构建索引。

最近使用的元素项是链表的第一个节点，最近最少使用的元素项是链表的最后一个节点。我们在列表前面添加一个新的元素项，如果缓存已满，则删除链表最后一个元素（淘汰最近最少访问的元素）。当一个元素被访问时，他会被转移到链表的前面。

### 实现

我们分别使用`std::list`和`std::unordered_map`来作为链表和哈希表，实现 LRU Cache:

```cpp
// Note: c++17 required.

template<typename K, typename V, std::size_t Capacity> class LRUCache
{
public:
    // Assert that Max size is greater than 0
    static_assert(Capacity > 0);

    // Adds a <key, Val> item, Returns false if key already exists
    bool put(const K& k, const V& v);

    // Gets the value for a key.
    // Returns empty std::optional if not found.
    // The returned item becomes most-recently-used
    std::optional<V> get(const K& k);

    // Erases an item
    void erase(const K& k);

    // Utility function.
    // Calls callback for each {key, value}
    template<typename C> void forEach(const C& cb) const
    {
        for (auto& [k, v] : items) {
            cb(k, v);
        }
    }

private:
    // std::list stores items (pair<K, V>) in most-recently-used to least-recently-used order
    std::list<std::pair<K, V>> items;

    // unordered_map acts as an index to the items store above.
    std::unordered_map<K, typename std::list<std::pair<K, V>>::iterator> index;
};
```

`put`方法用于添加一个键值对。为了简单起见，如果 key 已经存在了，那么他什么都不做，并返回 false。如果缓存已经满了，那么会删除列表中最后一项(LRU)。最后新的键值对总是被添加到列表的最前面，同时索引会更新：

```cpp
template<typename K, typename V, std::size_t Capacity>
bool LRUCache<K, V, Capacity>::put(const K& k, const V& v)
{
    // Return false if the key already exists
    if (index.count(k)) {
        return false;
    }

    // Check if cache is full
    if (items.size() == Capacity) {
        // Delete the LRU item
        index.erase(items.back().first);   // Erase the last item key from the map
        items.pop_back();                  // Evict last item from the list
    }

    // Insert the new item at front of the list
    items.emplace_front(k, v);

    // Insert {Key->item_iterator} in the map
    index.emplace(k, items.begin());

    return true;
}
```

`get`方法返回给定键的值。这里使用了`std::optional`，他可以为一个值，也可以为空，这取决于是否找到该项。在返回找到的值之前，通过调用`splice`函数，将当前查询的项转移到列表的开始位置。这个`splice`操作具有恒定的时间复杂度，不设及到元素的拷贝或者移动：

```cpp
template<typename K, typename V, std::size_t Capacity>
std::optional<V> LRUCache<K, V, Capacity>::get(const K& k)
{
    auto itr = index.find(k);
    if (itr == index.end()) {
        // empty std::optional
        return {};
    }

    // Use list splice to transfer this item to the first position,
    // which makes the item most-recently-used. Iterators still stay valid
    items.splice(items.begin(), items, itr->second);

    // Return the value in a std::optional
    return itr->second->second;
}
```

`erase`方法是最简单的一个，只需要将找到的元素从链表和哈希表中删除即可：

```cpp
template<typename K, typename V, std::size_t Capacity>
void LRUCache<K, V, Capacity>::erase(const K& k)
{
    auto itr = index.find(k);
    if (itr == index.end()) {
        return;
    }

    // Erase from the list
    items.erase(itr->second);

    // Erase from the map
    index.erase(itr);
}
```

### 测试

我们使用下面的代码来对上面实现的`LRUCache`进行测试：

```cpp
// Prints all items of an LRUCache in a line
// Items are printed in MRU -> LRU order
template<typename C> void printlnCache(const C& cache)
{
    cache.forEach([](auto& k, auto& v) { std::cout << k << "=>" << v << " "; });
    std::cout << std::endl;
}

int main()
{
    // City -> Population in millions (Max size 3)
    LRUCache<std::string, double, 3> cache;

    // Add 3 entries
    cache.put("London", 8.4);
    cache.put("Toronto", 2.5);
    cache.put("Sydney", 5.2);

    // Sydney=>5.2 Toronto=>2.5 London=>8.4
    printlnCache(cache);

    // Make "London" the most recently accessed
    std::cout << "London =>" << cache.get("London").value_or(-1) << std::endl;

    // London=>8.4 Sydney=>5.2 Toronto=>2.5
    printlnCache(cache);

    // This would remove the LRU item (Toronto)
    cache.put("Tokyo", 9.4);

    // Tokyo=>9.4 London=>8.4 Sydney=>5.2
    printlnCache(cache);

    return 0;
}
```

完整的实现和测试代码可以在[godbolt](https://gcc.godbolt.org/z/qoEoroT6s)上查看。

## 总结

虽然列表的`splice`功能一直都存在，但是他在同一个列表中修改节点位置的特性通常会被大家所忽略。通过上述的 LRUCache 的实现，我们能够很好的加深对 list 的`splice`功能的理解和使用，在实际的开发中，灵活使用标准库中提供的方法，能够在简化我们代码的同时，提升程序的效率。要做到这一点就需要我们不断加深对标准库的学习和理解。
