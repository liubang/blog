---
title: BloomFilter中的数学推导
tags: [storage]
categories: [programming]
date: 2025-01-01
authors: ["liubang"]
---

## False Positive Rate

$m$: 表示BloomFilter bit array的长度;  
$k$: 表示hash函数个数;  
$n$: 表示插入元素的个数;

假设hash函数以等概率选择bit array的下标，那么经过$k$个hash函数之后，某个bit位未被设置为1的概率为:

$$
(1 - \frac{1}{m})^k
$$

在插入$n$个元素之后，某个bit位仍然没有被设置为1的概率为:

$$
(1 - \frac{1}{m})^{kn}
$$

因此在插入$n$个元素之后，某个bit位被设置为1的概率为:

$$
p = 1 - (1 - \frac{1}{m})^{kn}
$$

对于一个不存在于集合中的元素，如果要出现误判，那么意味着经过$k$个hash函数之后，生成的下标所在的bit位
都是1，其概率为:

$$
\epsilon = p^k = (1 - (1 - \frac{1}{m})^{kn})^k
$$

接着来用欧拉恒等式来对上面的式子进行简化，已知欧拉恒等式可表示为:

$$
\lim_{m \to \infty}(1 + \frac{z}{m})^m = e^z
$$

令$z = -1$

$$
\lim_{m \to \infty}(1 - \frac{1}{m})^m = e^{-1}
$$

当$m$足够大的时候，有

$$
(1 - \frac{1}{m})^{kn} = ((1 - \frac{1}{m})^m)^{\frac{kn}{m}} \approx e^{-\frac{kn}{m}}
$$

代入上面的$\epsilon$可得:

$$
\epsilon = (1 - (1 - \frac{1}{m})^{kn})^k \approx (1 - e^{-\frac{kn}{m}})^k
$$

## 计算最优$k$

当$\epsilon$最小的时候，$k$为最优，因此需要对$\epsilon$关于$k$求导，找到极小值。

## 计算最优$m$
