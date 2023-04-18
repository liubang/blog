+++
type = "docs"
title = "动态规划"
navWeight = 70
+++

## 基本概念

动态规划（Dynamic Programming, DP）是一种优化问题求解的方法，通过将原问题分解为若干个重叠子问题，并使用记忆化技术（通常是使用表格或数组）来存储子问题的解，从而避免重复计算，提高算法的效率。
动态规划常常应用于需要在多个阶段或决策中作出选择的问题，其中每个决策可能会影响后续的决策和最终的结果。动态规划的核心思想是将问题划分为多个子问题，通过解决子问题来逐步求解原问题，从而避免对相同子问题的重复计算，减少了时间复杂度。

动态规划的一般步骤包括：

1. 定义状态：明确问题中需要求解的状态，并用变量或数组表示。
2. 设计状态转移方程：根据问题的性质和要求，确定不同状态之间的转移关系，即如何从一个状态转移到下一个状态。
3. 初始化：设置初始状态的值，通常是问题中最简单的情况。
4. 递推求解：按照状态转移方程，通过已知的子问题的解来求解更大规模的问题，直到得到最终的问题解。
5. 可选的步骤：根据需要，可能需要添加一些额外的步骤，如记忆化优化（将子问题的解存储起来，避免重复计算）和路径记录（记录路径信息，用于输出最优解）等。

动态规划算法通常具有较高的时间复杂度优势，尤其是在问题中存在重叠子问题时，因为它可以避免重复计算，从而大大减少计算量。动态规划广泛应用于众多领域，如算法设计、优化问题、图像处理、自然语言处理、经济学等。

## 经典题目

以下是一些经典的动态规划问题以及对应的 LeetCode 题号：

1. [爬楼梯（Climbing Stairs）](https://leetcode.com/problems/climbing-stairs/)：一共有 n 级楼梯，每次可以爬 1 级或 2 级，求爬到第 n 级楼梯的不同方法数。
2. [零钱兑换（Coin Change）](https://leetcode.com/problems/coin-change/)：给定不同面额的硬币 coins 和一个总金额 amount，计算组成总金额所需的最少硬币数量。
3. [乘积最大子数组（Maximum Product Subarray）](https://leetcode.com/problems/maximum-product-subarray/)：给定一个整数数组，找出连续子数组的最大乘积。
4. [不同路径（Unique Paths）](https://leetcode.com/problems/unique-paths/)：在一个 m×n 的网格中，从左上角走到右下角，每次只能向右或向下移动一步，求不同的路径数。
5. [打家劫舍（House Robber）](https://leetcode.com/problems/house-robber/)：一排房子中，每个房子内有一定数量的钱，相邻房屋之间有安全系统，不能同时抢两个相邻的房子，求能抢到的最大金额。
6. [最长上升子序列（Longest Increasing Subsequence）](https://leetcode.com/problems/longest-increasing-subsequence/)：给定一个无序的整数数组，找到其中最长的上升子序列的长度。
7. [最小路径和（Minimum Path Sum）](https://leetcode.com/problems/minimum-path-sum/)：在一个 m×n 的网格中，从左上角走到右下角，每次只能向右或向下移动一步，求路径上数字之和的最小值。
8. [最大子序和（Maximum Subarray）](https://leetcode.com/problems/maximum-subarray/)：给定一个整数数组，找到一个具有最大和的连续子数组，返回该最大和。
9. [最大正方形（Maximal Square）](https://leetcode.com/problems/maximal-square/)：在一个由 '0' 和 '1' 组成的矩阵中，找到只包含 '1' 的最大正方形，并返回其面积。
10. [编辑距离（Edit Distance）](https://leetcode.com/problems/edit-distance/)：给定两个单词 word1 和 word2，计算将 word1 转换为 word2 所需的最少操作数。

这些题目涵盖了动态规划问题的不同类型，包括线性动态规划、背包问题、路径计数等。它们都是经典的动态规划问题，在学习和掌握动态规划算法时非常有价值。

## 特别说明

以上内容大多数由 ChatGPT 生成。
