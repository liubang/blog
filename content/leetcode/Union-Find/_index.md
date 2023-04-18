+++
type = "docs"
title = "并查集"
navWeight = 80
+++

## 基本概念

并查集（Disjoint Set），又称为不相交集合或并查集合并数据结构，是一种用来管理元素分组的数据结构。它支持以下两种主要操作：

1. 合并（Union）：将两个不相交的集合合并成一个集合，通常使用集合的根节点来表示集合。
2. 查找（Find）：查找元素所属的集合，通常返回集合的根节点。

并查集常用于解决一些元素分组和连通性问题，例如判断图中的连通分量、网络中的节点连接关系、社交网络中的朋友关系等。

并查集的基本实现方式通常采用树形结构，其中每个节点表示一个元素，并且每个节点都有一个指向其父节点的指针。在合并操作中，可以通过将两个集合的根节点连接起来，从而合并两个集合。在查找操作中，可以通过沿着父节点的指针一直向上查找，直到找到根节点，从而确定元素所属的集合。

并查集的常见优化包括路径压缩和按秩合并。路径压缩指在执行查找操作时，将节点直接连接到根节点，从而减小树的高度，提高后续查找的效率。按秩合并指在执行合并操作时，将较小的树连接到较大的树上，从而避免树的高度过大，保持树的平衡性。

并查集是一种简单且高效的数据结构，常常在算法和计算机程序设计中被广泛应用。

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

## 典型题目

LeetCode 上有许多典型的题目涉及到并查集这一数据结构，以下是一些常见的典型题目：

1. [岛屿数量（Number of Islands）](https://leetcode.com/problems/number-of-islands/)：给定一个由 '1'（陆地）和 '0'（水域）组成的二维网格，计算岛屿的数量。每个相邻的陆地单元格被认为是连接的，即水平或垂直相邻，不包括对角线。
2. [被围绕的区域（Surrounded Regions）](https://leetcode.com/problems/surrounded-regions/)：给定一个二维字符矩阵，将被 'X' 围绕的 'O' 修改为 'X'，而不修改被 'X' 包围的区域。
3. [冗余连接（Redundant Connection）](https://leetcode.com/problems/redundant-connection/)：给定一个无向图的边集合，找到一条边，使得删除该边后，图变成一个无环的连通图。如果有多个答案，返回最后出现的边。
4. [账户合并（Accounts Merge）](https://leetcode.com/problems/accounts-merge/)：给定一组账户和它们的关联关系，将具有相同邮箱的账户合并成一个账户，并返回合并后的账户列表。
5. [最小生成树（Minimum Spanning Tree）](https://leetcode.com/tag/minimum-spanning-tree/)：一类涉及到构建最小生成树的问题，如连接所有点的最小费用（Min Cost to Connect All Points）、修建树的最短时间（Build the Shortest Valid Path）等。
