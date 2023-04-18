+++
type = "docs"
title = "二叉搜索树"
navWeight = 96
+++

## 基本概念

二叉搜索树（Binary Search Tree，简称 BST）是一种二叉树，其中每个节点都包含一个值，并且满足以下性质：

1. 左子树中的所有节点的值都小于该节点的值。
2. 右子树中的所有节点的值都大于该节点的值。
3. 左子树和右子树也分别是二叉搜索树（即具有相同的性质）。

二叉搜索树是一种常见的数据结构，用于实现动态集合（Dynamic Set）或者映射（Map）等抽象数据类型。由于其具有有序性质，可以在平均情况下实现高效的搜索、插入和删除操作，时间复杂度通常为 O(log n)，其中 n 是树中节点的数量。

二叉搜索树有多种不同的实现方式，包括普通的二叉搜索树、平衡二叉搜索树（如 AVL 树、红黑树等）以及 B 树和 B+树等。这些实现方式在不同场景下具有不同的性能和应用特点，可以根据具体需求选择合适的实现方式。

## 经典题目

以下是一些关于二叉搜索树的经典题目在 LeetCode 上的示例：

1. [二叉搜索树中的插入操作（Insert into a Binary Search Tree）](https://leetcode.com/problems/insert-into-a-binary-search-tree/)：向一个二叉搜索树中插入一个新节点，并保持其二叉搜索树的性质。
2. [二叉搜索树中的删除操作（Delete Node in a Binary Search Tree）](https://leetcode.com/problems/delete-node-in-a-bst/)：从一个二叉搜索树中删除指定的节点，并保持其二叉搜索树的性质。
3. [二叉搜索树中的搜索操作（Search in a Binary Search Tree）](https://leetcode.com/problems/search-in-a-binary-search-tree/)：在一个二叉搜索树中搜索指定的值。
4. [二叉搜索树的最小绝对差（Minimum Absolute Difference in BST）](https://leetcode.com/problems/minimum-absolute-difference-in-bst/)：计算一个二叉搜索树中任意两个节点值之间的最小绝对差。
5. [二叉搜索树中的迭代器（Binary Search Tree Iterator）](https://leetcode.com/problems/binary-search-tree-iterator/)：设计一个迭代器，可以按中序遍历顺序遍历二叉搜索树的节点。
6. [二叉搜索树的范围和（Range Sum of BST）](https://leetcode.com/problems/range-sum-of-bst/)：计算二叉搜索树中在指定范围内节点值的和。
7. [修剪二叉搜索树（Trim a Binary Search Tree）](https://leetcode.com/problems/trim-a-binary-search-tree/)：将一个二叉搜索树中的节点值限制在指定范围内。
8. [二叉搜索树中的众数（Find Mode in Binary Search Tree）](https://leetcode.com/problems/find-mode-in-binary-search-tree/)：在一个二叉搜索树中找出出现次数最多的节点值。
9. [二叉搜索树中的第 K 小元素（Kth Smallest Element in a BST）](https://leetcode.com/problems/kth-smallest-element-in-a-bst/)：在一个二叉搜索树中找出第 K 小的节点值。
10. [二叉搜索树中的节点间最小距离（Minimum Distance Between BST Nodes）](https://leetcode.com/problems/minimum-distance-between-bst-nodes/)：计算一个二叉搜索树中任意两个节点值之间的最小距离。
