+++
type = "docs"
title = "并查集"
navWeight = 50
+++

## 基本概念

并查集是一种数据结构，用来处理一些不相交集合的合并和查询问题。
并查集支持如下操作：

- 查询(Find)：查询某个元素属于哪个集合，通常返回集合内的一个“代表元素”，这个操作能判断两个元素是否属于同一个集合；
- 合并(Union)：将两个集合合并成一个


所以，并查集主要就是以下接口：

```cpp
class UnionFind {
public:
    // 将 p 和 q 连接
    void Union(int p, int q);

    // 判断 q 和 p 是否连通
    bool Connected(int p, int q);

    // 返回当前节点的根节点（也就是集合的“代表元素”）
    int Find(int p);
};
```

## 数据结构

我们可以用一个数组来记录每个元素的前驱元素，数组下标表示当前元素，数组值表示当前元素的前驱元素:

```cpp
class UnionFind {
public:
    UnionFind(int num) {
        for (int i = 0; i < num; ++i) {
            // 初始化的时候，每个元素都是独立的集合
            // 所以其parent都指向自身
            parent_.push_back(i);
        }
    }

private:
    std::vector<int> parent_;
};
```

## Union 方法

将两个元素所属的集合合并成一个，其实就是找到两个元素的根节点，然后将其中一个根节点的`parent`指向
另一个根节点即可：

```cpp
class UnionFind {
public:
    //...
    void Union(int p, int q) {
        int pRoot = Find(p);
        int qRoot = Find(q);
        // 如果两个元素已经属于同一个集合，直接返回
        if (pRoot == qRoot) {
            return;
        }
        // 将p节点所在的集合合并到q节点所在的集合
        parent_[pRoot] = qRoot;
    }
    //...
private:
    std::vector<int> parent_;
};
```

## Find 方法

根节点特点是其`parent`指向自身，所以我们可一很容易实现:

```cpp
class UnionFind {
public:
    //...
    int Find(int p) {
        while (p != parent_[p]) {
            p = parent_[p];
        }
        return p;
    }
    //...
private:
    std::vector<int> parent_;
};

```

## 平衡性优化

上面对`Union`的实现中，我们在将谁合并到谁上并没有做什么判断，在极端情况下，可能会导致集合退化成一个链表
这样对我们后续的`Find`操作，时间复杂度会很高，因此我们可以在合并的时候做一个判断，永远将元素少的集合合并到
元素多的集合中，这样能对整个集合的高度做一个平衡，因此我们需要一个成员来记录每个连通分量中元素的个数：

```cpp
class UnionFind {
public:
    UnionFind(int num) {
        for (int i = 0; i < num; ++i) {
            // 初始化的时候，每个元素都是独立的集合
            // 所以其parent都指向自身
            parent_.push_back(i);
            // 初始状态下，每个连通分量中的元素个数都是1
            size_.push_back(1);
        }
    }

    //...
    void Union(int p, int q) {
        int pRoot = Find(p);
        int qRoot = Find(q);
        // 如果两个元素已经属于同一个集合，直接返回
        if (pRoot == qRoot) {
            return;
        }

        if (size_[pRoot] > size_[qRoot]) {
            parent_[qRoot] = pRoot;
            size_[pRoot] += size_[qRoot];
        } else {
            parent_[pRoot] = qRoot;
            size_[qRoot] += size_[pRoot];
        }
    }
    //...
private:
    std::vector<int> parent_;
    std::vector<int> size_;
};

```

## 路径压缩

尽管上面用平衡性优化能够降低集合的高度，但是事实上，我们并不关心元素到根节点的路径，我们只关心元素属于哪个根节点，
因此我们可以将整个集合打平，集合中所有元素的`parent`都直接指向根节点，这样对于`Find`操作，时间复杂度就为`O(1)`了，这里可以直接用递归实现：

```cpp
class UnionFind {
public:
    //...
    int Find(int p) {
        if (p != parent_[p]) {
            parent_[p] = Find(parent_[p]);
        }
        return parent_[p];
    }
    //...
private:
    std::vector<int> parent_;
    std::vector<int> size_;
};

```

