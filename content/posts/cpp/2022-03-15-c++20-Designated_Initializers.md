---
title: c++20:Designated Initializers
categories: [programming]
tags: [c++, c++20]
date: 2022-03-15
authors: ['liubang']
---

对于熟悉 c99 的人来说，Designated Initializers 并不算是什么新鲜事物，然而 c++直到 c++20 才正式支持这一特性。
虽然在 c++20 之前，像 GCC 这样的编译器通过扩展的形式已经对该特性做了支持，但是随着 c++20 将其纳入新标准，这一特性将在所有编译器中得到支持。

## 基本用法

Designated Initialization 是聚合初始化(Aggregate Initialization)的一种形式。
在 c++20 中，聚合类型(Aggregate types)是指：

- 数组类型
- 具备如下特性的 class 类型：
- - has no private or protected direct non-static data members
- - has no user-declared or inherited constructors
- - has no virtual, private, or protected base classes
- - has no virtual member functions

c++20 中的 Designated Initializers 的用法跟 c99 非常相似：

```cpp
struct Points
{
    double x{0.0};
    double y{0.0};
};

const Points p{.x = 1.1, .y = 2.2};
const Points o{.x{1.1}, .y{2.2}};
const Points x{.x = 1.1, .y{2.2}};
```

## 优点

使用 Designated Initializers 最大的好处就是能够提升代码的可读性。

我们考拿下面的例子来说，首先声明一个`struct Date`，其中有三个`int`类型的成员变量，分别代表了年、月、日。

```cpp
struct Date
{
    int year;
    int mon;
    int day;
}
```

如果没有 Designated Initializers，我们对它进行初始化通常会这样做：

```cpp
Date someday {2022, 3, 15};
```

而使用 Designated Initializers：

```cpp
Date someday { .year = 2022, .mon = 3, .day = 15 };
```

很显然，使用 Designated Initializers 能让人一目了然，知道每个数字的含义，而不使用的话，必须要回过头去看`Date`结构的定义才能确定这几个数字代表啥意思。

## 使用规则

c++20 中的 Designated Initializers 遵循一下规则：

- 只能用于聚合类型初始化(aggregate initialization)
- Designators 只能是非静态类型的成员
- Designators 的顺序应该跟成员声明时的顺序保持一致
- 并不是所有成员都要指定，可以跳过一些成员
- 普通的初始化和 Designated Initializers 不能混用
- Designators 不支持嵌套，例如 `.x.y = 10` 是不允许的

下面是一些代码示例：

```cpp
#include <iostream>
#include <string>

struct Product
{
    std::string name_;
    bool        inStock_{false};
    double      price_ = 0.0;
};

void Print(const Product& p)
{
    std::cout << "name: " << p.name_ << ", in stock: " << std::boolalpha << p.inStock_
              << ", price: " << p.price_ << '\n';
}

struct Time
{
    int hour;
    int minute;
};
struct Date
{
    Time t;
    int  year;
    int  month;
    int  day;
};

int main()
{
    Product p{.name_ = "box", .inStock_{true}};
    Print(p);

    Date d{.t{.hour = 10, .minute = 35}, .year = 2050, .month = 5, .day = 10};

    // pass to a function:
    Print({.name_ = "tv", .inStock_{true}, .price_{100.0}});

    // not all members used:
    Print({.name_ = "car", .price_{2000.0}});
}
```
