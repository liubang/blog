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

接着来用欧拉公式来对上面的式子进行简化，已知欧拉公式可表示为:

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

令$f = (1 - e^{\frac{-kn}{m}})^k$，等式两边取对数 $g = \ln{f} = k \cdot \ln{(1 - e^{\frac{-kn}{m}})}$，对$g$关于$k$求导:

$$
\frac{dg}{dk} = k^\prime\cdot\ln{(1 - e^{\frac{-kn}{m}})} + k \cdot\ln^\prime{(1 - e^{\frac{-kn}{m}})}
$$

$$
\iff \frac{dg}{dk} = \ln{(1 - e^{\frac{-kn}{m}})} + k\cdot\frac{(1 - e^{\frac{-kn}{m}})^\prime}{1 - e^{\frac{-kn}{m}}}
$$

$$
\iff \frac{dg}{dk} = \ln{(1 - e^{\frac{-kn}{m}})} + \frac{kn}{m}\cdot\frac{e^{\frac{-kn}{m}}}{1 - e^{\frac{-kn}{m}}}
$$

要找到最小的$\epsilon$，使得$k$的值为最优（在不考虑$k$为整数的情况下），则需要找到极值点，也就是令$\frac{dg}{dk} = 0$,得到

$$
\ln{(1 - e^{\frac{-kn}{m}})} + \frac{kn}{m}\cdot\frac{e^{\frac{-kn}{m}}}{1 - e^{\frac{-kn}{m}}} = 0
$$

$$
\iff - \ln{(1 - e^{\frac{-kn}{m}})}  = \frac{kn}{m}\cdot\frac{e^{\frac{-kn}{m}}}{1 - e^{\frac{-kn}{m}}}
$$

对等式两边做整理得

$$
e^{- \ln{(1 - e^{\frac{-kn}{m}})}} = e^{\frac{kn}{m}\cdot\frac{e^{\frac{-kn}{m}}}{1 - e^{\frac{-kn}{m}}}}
$$

$$
\iff \frac{1}{(1 - e^{\frac{-kn}{m}})} = e^{\frac{kn}{m}\cdot\frac{e^{\frac{-kn}{m}}}{1 - e^{\frac{-kn}{m}}}}
$$

进一步简化等式，令$x = e^{\frac{-kn}{m}}$可得

$$
\frac{1}{1 - x} = (\frac{1}{x})^{\frac{x}{1 - x}}
$$

$$
\iff (1 - x)^{-1} = x^{-\frac{x}{1-x}} \iff (1 - x) = x^{\frac{x}{1 - x}}
$$

对等式两边取对数

$$
\ln{(1 - x)} = \ln{x^{\frac{x}{1 - x}}} \iff \ln{(1 - x)} = \frac{x}{1 - x}\ln(x) \iff (1 - x) \cdot \ln(1 - x) = x \cdot \ln(x)
$$

显然可得$x = \frac{1}{2}$，又因为$x = e^{\frac{-kn}{m}}$，所以

$$
e^{\frac{-kn}{m}} = \frac{1}{2} \iff \ln{e^{\frac{-kn}{m}}} = \ln\frac{1}{2} \iff -\frac{kn}{m} = \ln(2^{-1}) \iff \frac{kn}{m} = \ln(2)
$$

最终可得$k = \frac{m}{n}\ln(2)$

## 计算最优$m$

已知$\epsilon \approx (1 - e^{\frac{-kn}{m}})^k$，将$k = \frac{m}{n}\ln(2)$代入可得

$$
\epsilon \approx (1 - e^{-\ln{(2)}})^{\frac{m}{n}\ln2} = (1 - \frac{1}{2})^{\frac{m}{n}\ln2}
$$

$$
\iff \ln{(\epsilon)} \approx \frac{m}{n}\ln2\cdot\ln{\frac{1}{2}} = -\frac{m}{n}\cdot\ln{(2)}^2
$$

最终可得

$$
m \approx = -\frac{n\ln{(\epsilon)}}{\ln{(2)}^2} \approx -2.08n\ln{(\epsilon)}
$$

## 参考文档

- [Bloom Filter](https://en.wikipedia.org/wiki/Bloom_filter)
- [Euler's formula](https://en.wikipedia.org/wiki/Euler%27s_formula#Limit_definition)
