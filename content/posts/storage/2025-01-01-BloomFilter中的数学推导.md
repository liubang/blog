---
title: BloomFilter中的数学推导
description: "推导 Bloom Filter 的误判率公式，并给出最优哈希函数个数与位数组长度的数学结论。"
tags: [storage]
categories: [存储与分布式]
date: 2025-01-01
authors: ["liubang"]
---

## False Positive Rate

$m$: 表示 Bloom Filter bit array 的长度;  
$k$: 表示 hash 函数个数;  
$n$: 表示插入元素的个数;

假设 hash 函数以等概率选择 bit array 的下标，那么某次 hash 后，某个特定 bit 位未被设置为 1 的概率为 $1 - \frac{1}{m}$。经过 $k$ 个 hash 函数之后，该 bit 位仍未被设置为 1 的概率为:

$$
\left(1 - \frac{1}{m}\right)^k
$$

在插入 $n$ 个元素之后，某个 bit 位仍然没有被设置为 1 的概率为:

$$
\left(1 - \frac{1}{m}\right)^{kn}
$$

因此在插入 $n$ 个元素之后，某个 bit 位被设置为 1 的概率为:

$$
p = 1 - \left(1 - \frac{1}{m}\right)^{kn}
$$

对于一个不存在于集合中的元素，如果要出现误判（false positive），意味着经过 $k$ 个 hash 函数之后，生成的 $k$ 个下标所对应的 bit 位全部为 1，其概率为:

$$
\varepsilon = p^k = \left(1 - \left(1 - \frac{1}{m}\right)^{kn}\right)^k
$$

接下来利用自然常数 $e$ 的极限定义对上式进行简化。已知:

$$
\lim_{m \to \infty}\left(1 + \frac{z}{m}\right)^m = e^z
$$

令 $z = -1$:

$$
\lim_{m \to \infty}\left(1 - \frac{1}{m}\right)^m = e^{-1}
$$

当 $m$ 足够大时，有:

$$
\left(1 - \frac{1}{m}\right)^{kn} = \left(\left(1 - \frac{1}{m}\right)^m\right)^{\frac{kn}{m}} \approx e^{-\frac{kn}{m}}
$$

代入 $\varepsilon$ 可得:

$$
\varepsilon \approx \left(1 - e^{-\frac{kn}{m}}\right)^k
$$

## 计算最优 $k$

当 $\varepsilon$ 最小时，$k$ 为最优。因此需要对 $\varepsilon$ 关于 $k$ 求导，找到极小值点。

令 $f = \left(1 - e^{-\frac{kn}{m}}\right)^k$，对等式两边取对数:

$$
g = \ln f = k \cdot \ln\left(1 - e^{-\frac{kn}{m}}\right)
$$

对 $g$ 关于 $k$ 求导（利用乘积法则）:

$$
\frac{dg}{dk} = \ln\left(1 - e^{-\frac{kn}{m}}\right) + k \cdot \frac{d}{dk}\ln\left(1 - e^{-\frac{kn}{m}}\right)
$$

对第二项应用链式法则:

$$
\frac{d}{dk}\ln\left(1 - e^{-\frac{kn}{m}}\right) = \frac{\frac{n}{m} \cdot e^{-\frac{kn}{m}}}{1 - e^{-\frac{kn}{m}}}
$$

因此:

$$
\frac{dg}{dk} = \ln\left(1 - e^{-\frac{kn}{m}}\right) + \frac{kn}{m} \cdot \frac{e^{-\frac{kn}{m}}}{1 - e^{-\frac{kn}{m}}}
$$

令 $\frac{dg}{dk} = 0$（在不考虑 $k$ 为整数的约束下寻找极值点）:

$$
\ln\left(1 - e^{-\frac{kn}{m}}\right) + \frac{kn}{m} \cdot \frac{e^{-\frac{kn}{m}}}{1 - e^{-\frac{kn}{m}}} = 0
$$

整理得:

$$
-\ln\left(1 - e^{-\frac{kn}{m}}\right) = \frac{kn}{m} \cdot \frac{e^{-\frac{kn}{m}}}{1 - e^{-\frac{kn}{m}}}
$$

对等式两边取指数:

$$
\frac{1}{1 - e^{-\frac{kn}{m}}} = e^{\frac{kn}{m} \cdot \frac{e^{-\frac{kn}{m}}}{1 - e^{-\frac{kn}{m}}}}
$$

为简化表达，令 $x = e^{-\frac{kn}{m}}$（其中 $0 < x < 1$），可得:

$$
\frac{1}{1 - x} = \left(\frac{1}{x}\right)^{\frac{x}{1 - x}}
$$

$$
\iff (1 - x)^{-1} = x^{-\frac{x}{1-x}} \iff (1 - x) = x^{\frac{x}{1 - x}}
$$

对等式两边取对数:

$$
\ln(1 - x) = \frac{x}{1 - x} \cdot \ln x
$$

$$
\iff (1 - x) \cdot \ln(1 - x) = x \cdot \ln x
$$

设 $h(t) = t \cdot \ln t$，上式即 $h(1 - x) = h(x)$。由于 $h(t)$ 在 $(0, 1)$ 上先递减后递增，且关于 $t = \frac{1}{2}$ 对称（即 $h(t) = h(1-t)$ 当且仅当 $t = \frac{1}{2}$），可得 $x = \frac{1}{2}$。

又因为 $x = e^{-\frac{kn}{m}}$，所以:

$$
e^{-\frac{kn}{m}} = \frac{1}{2} \iff -\frac{kn}{m} = \ln\frac{1}{2} = -\ln 2 \iff k = \frac{m}{n} \ln 2
$$

## 计算最优 $m$

已知 $\varepsilon \approx \left(1 - e^{-\frac{kn}{m}}\right)^k$，将 $k = \frac{m}{n}\ln 2$ 代入。

由前面的推导，当 $k$ 取最优值时 $e^{-\frac{kn}{m}} = \frac{1}{2}$，因此:

$$
\varepsilon \approx \left(1 - \frac{1}{2}\right)^{\frac{m}{n}\ln 2} = \left(\frac{1}{2}\right)^{\frac{m}{n}\ln 2}
$$

对两边取自然对数:

$$
\ln \varepsilon \approx \frac{m}{n} \ln 2 \cdot \ln\frac{1}{2} = -\frac{m}{n} (\ln 2)^2
$$

解出 $m$:

$$
m \approx -\frac{n \ln \varepsilon}{(\ln 2)^2} \approx -1.44 \, n \log_2 \varepsilon
$$

其中 $\frac{1}{(\ln 2)^2} \approx 2.08$，所以也可以写成 $m \approx -2.08 \, n \ln \varepsilon$。

## 总结

给定预期插入元素数 $n$ 和可接受的误判率 $\varepsilon$:

- 最优 bit array 长度: $m \approx -\frac{n \ln \varepsilon}{(\ln 2)^2}$
- 最优 hash 函数个数: $k = \frac{m}{n} \ln 2 \approx -\log_2 \varepsilon$

例如，若期望误判率为 1%（$\varepsilon = 0.01$），则每个元素约需 9.6 bits，最优 hash 函数个数约为 7。

## 参考文档

- [Bloom Filter - Wikipedia](https://en.wikipedia.org/wiki/Bloom_filter)
- [Characterizations of the exponential function](https://en.wikipedia.org/wiki/Characterizations_of_the_exponential_function)
