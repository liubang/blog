+++
type = "docs"
title = "链表"
navWeight = 99
+++

## 基本概念

链表（Linked List）是一种常见的数据结构，用于存储一系列的节点（Node），每个节点包含数据和指向下一个节点的指针。链表中的节点按照其在链表中的位置逐个连接，形成链式结构。

链表中的节点通常包含两个部分：

1. 数据域（Data）：存储节点的数据。
2. 指针域（Pointer）：指向下一个节点的指针，也可以称为“后继指针”（Next Pointer）。

链表可以分为多种类型，包括单向链表、双向链表和循环链表等。其中：

- 单向链表（Singly Linked List）：每个节点只包含一个后继指针，指向下一个节点，形成一个单向的链式结构。
- 双向链表（Doubly Linked List）：每个节点包含一个前驱指针（Previous Pointer）和一个后继指针，可以同时向前和向后遍历。
- 循环链表（Circular Linked List）：链表中的最后一个节点的后继指针指向链表的头部，形成一个循环。

链表相比于数组有一些优点和缺点：

优点：

- 动态性：链表的长度可以动态地增加或减少，不需要预先定义大小。
- 灵活性：链表的节点可以在任意位置插入或删除，而数组需要进行元素的移动。
- 空间利用：链表可以节省内存空间，因为节点只需额外存储数据和指针，而数组需要预留一段连续的内存空间。

缺点：

- 随机访问性：链表的节点之间是通过指针连接的，因此不支持像数组那样的随机访问，需要从头节点开始顺序遍历。
- 存储空间：链表需要额外存储指针信息，占用相对较多的存储空间。
- 链表常常用于解决需要频繁的插入、删除操作，并且不需要随机访问的场景，如实现栈、队列、LRU 缓存等数据结构和算法问题。

## 经典题目

1. [反转链表（Reverse Linked List）](https://leetcode.com/problems/reverse-linked-list/)：反转一个单链表。
2. [合并两个有序链表（Merge Two Sorted Lists）](https://leetcode.com/problems/merge-two-sorted-lists/)：合并两个有序链表，返回一个新的有序链表。
3. [删除链表的倒数第 N 个节点（Remove Nth Node From End of List）](https://leetcode.com/problems/remove-nth-node-from-end-of-list/)：删除链表中倒数第 n 个节点。
4. [判断链表是否有环（Linked List Cycle）](https://leetcode.com/problems/linked-list-cycle/)：判断一个链表是否包含环。
5. [相交链表（Intersection of Two Linked Lists）](https://leetcode.com/problems/intersection-of-two-linked-lists/)：找到两个链表相交的节点。
6. [回文链表（Palindrome Linked List）](https://leetcode.com/problems/palindrome-linked-list/)：判断一个链表是否是回文链表。
7. [环形链表 II（Linked List Cycle II）](https://leetcode.com/problems/linked-list-cycle-ii/)：找到一个链表中环的入口节点。
8. [旋转链表（Rotate List）](https://leetcode.com/problems/rotate-list/)：将链表向右旋转 k 个位置。
9. [排序链表（Sort List）](https://leetcode.com/problems/sort-list/)：对链表进行排序。
10. [删除排序链表中的重复元素（Remove Duplicates from Sorted List）](https://leetcode.com/problems/remove-duplicates-from-sorted-list/)：删除排序链表中的重复元素。
