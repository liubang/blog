+++
type = "docs"
title = "队列"
navWeight = 98
+++

## 基本概念

队列（Queue）是一种常见的数据结构，用于存储元素，并按照一定的规则进行元素的插入和删除操作。队列采用先进先出（First-In, First-Out，简称 FIFO）的策略，即最先插入的元素最先被删除，而最后插入的元素最后被删除。

队列通常包含两个基本操作：

1. 入队（Enqueue）：将元素添加到队列的末尾。
2. 出队（Dequeue）：从队列的头部删除并返回队头的元素。

队列还可以包含其他常用操作，如：

- 判空（isEmpty）：判断队列是否为空。
- 获取队头元素（getFront）：返回队头的元素，但不删除。
- 获取队列长度（getSize）：返回队列中元素的个数。

队列可以分为多种类型，包括普通队列、优先队列和循环队列等。其中：

- 普通队列：元素按照插入的先后顺序排列，先插入的元素排在队列的头部，后插入的元素排在队列的尾部。
- 优先队列：元素插入队列时会根据优先级进行排序，出队时总是删除优先级最高的元素。可以用于实现一些需要按照优先级处理元素的场景。
- 循环队列：队列的头部和尾部连接成一个环形，当队尾指针指向队列的末尾时，下一个元素会被插入到队列的开头。可以有效解决普通队列在出队时需要元素移动的性能问题。

队列常常用于需要按照先后顺序处理元素的场景，如实现任务调度、消息处理、广度优先搜索（BFS）等算法问题。

## 经典题目

1. [二叉树的层序遍历](https://leetcode-cn.com/problems/binary-tree-level-order-traversal/)
2. [滑动窗口最大值](https://leetcode-cn.com/problems/sliding-window-maximum/)
3. [岛屿数量](https://leetcode-cn.com/problems/number-of-islands/)
4. [任务调度器](https://leetcode-cn.com/problems/task-scheduler/)
5. [实现栈使用队列](https://leetcode-cn.com/problems/implement-stack-using-queues/)
6. [实现队列使用栈](https://leetcode-cn.com/problems/implement-queue-using-stacks/)
7. [设计循环队列](https://leetcode-cn.com/problems/design-circular-queue/)
8. [字符串解码](https://leetcode-cn.com/problems/decode-string/)
9. [二进制矩阵中的最短路径](https://leetcode-cn.com/problems/shortest-path-in-binary-matrix/)
10. [开锁](https://leetcode-cn.com/problems/open-the-lock/)
