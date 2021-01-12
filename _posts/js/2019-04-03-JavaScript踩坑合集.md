---
layout: article
title: JavaScript踩坑合集
category: JavaScript
tags: [JavaScript]
---

## Bitwise shift operators

**问题描述:** int32 的整数 a 左移了 32 位结果还是 a

**原因：**查询[文档](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Operators/Bitwise_Operators)可以找到原因：

> Shift operators convert their operands to 32-bit integers in big-endian order and return a result of the same type as the left operand. The right operand should be less than 32, but if not only the low five bits will be used.

也就是说，a << b 等价于 a << (b & 0x1f)
