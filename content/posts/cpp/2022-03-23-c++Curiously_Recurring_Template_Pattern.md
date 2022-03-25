---
title: curiously recurring template pattern
categories: ["c++"]
tags: ["c++", "pattern"]
date: 2022-03-23
---

## 简介

Curiously recurring template pattern 简称 CRTP, 是 c++模板编程中的惯用模式，其主要特点是把派生类作为基类的模板参数。

CRTP 的一般写法为：

```cpp
template<class T>
class Base
{
    // methods within Base can use template to access members of Derived
};
class Derived : public Base<Derived>
{
    // ...
};
```

## CRTP 的优点

### 动态多态 (Dynamic Polymorphism)

在分析 CRTP 之前，我们先来聊聊动态多态。为了实现 c++的多态，c++使用了一种动态绑定的技术，这个技术的核心就是虚函数表(virtual table)。
在 c++中，每个包含虚函数的类都有一个虚表。我们来看下面这个类：

```cpp
// demo.cpp
class A
{
public:
    virtual void vfunc1();
    virtual void vfunc2();
    void         func1();
    void         func2();

private:
    int m_data1, m_data2;
};
```

我们可以借助编译器来查看上述类的对象布局：

```bash
# 使用llvm编译工具
clang -Xclang -fdump-record-layouts -stdlib=libc++ -c demo.cpp # 查看对象布局
clang -Xclang -fdump-vtable-layouts -stdlib=libc++ -c demo.cpp # 查看虚表布局

# 使用gcc编译工具
g++ -fdump-lang-class demo.cpp
```

这里为了便于分析，使用clang打印的结果来具体说明：

```cpp
// clang -Xclang -fdump-record-layouts -stdlib=libc++ -c demo.cpp
*** Dumping AST Record Layout
         0 | class A
         0 |   (A vtable pointer)
         8 |   int m_data1
        12 |   int m_data2
           | [sizeof=16, dsize=16, align=8,
           |  nvsize=16, nvalign=8]

// clang -Xclang -fdump-vtable-layouts -stdlib=libc++ -c demo.cpp
Original map
Vtable for 'A' (4 entries).
   0 | offset_to_top (0)
   1 | A RTTI
       -- (A, 0) vtable address --
   2 | void A::vfunc1()
   3 | void A::vfunc2()

VTable indices for 'A' (2 entries).
   0 | void A::vfunc1()
   1 | void A::vfunc2()
```

根据对象布局可以简单画出`class A`的对象布局图：

![virtual table](/images/2022-03-23/vtable1.png)

- offset_to_top(0)：表示这个虚表地址距离对象顶部地址的偏移量，这里是0，表示该虚表位于对象最顶端
- RTTI指针：Run-Time Type Identification，通过运行时类型信息程序能够使用基类的指针或引用来检查这些指针或引用所指的对象的实际派生类型
- RTTI下面就是虚函数表指针真正指向的地址，存储了类里面所有的虚函数

花了这么大力气，来讲解了类的对象布局和虚表，其实是为了给接下来类的继承和动态多态的实现做铺垫。我们在上面类的基础上，写实现一个派生类：

```cpp
class B : public A
{

};
```

然后再通过工具打印出类的对象布局：

```cpp
// clang -Xclang -fdump-record-layouts -stdlib=libc++ -c demo.cpp
*** Dumping AST Record Layout
         0 | class A
         0 |   (A vtable pointer)
         8 |   int m_data1
        12 |   int m_data2
           | [sizeof=16, dsize=16, align=8,
           |  nvsize=16, nvalign=8]

*** Dumping AST Record Layout
         0 | class B
         0 |   class A (primary base)
         0 |     (A vtable pointer)
         8 |     int m_data1
        12 |     int m_data2
           | [sizeof=16, dsize=16, align=8,
           |  nvsize=16, nvalign=8]

// clang -Xclang -fdump-vtable-layouts -stdlib=libc++ -c demo.cpp
Original map
Vtable for 'B' (4 entries).
   0 | offset_to_top (0)
   1 | B RTTI
       -- (A, 0) vtable address --
       -- (B, 0) vtable address --
   2 | void A::vfunc1()
   3 | void A::vfunc2()


Original map
Vtable for 'A' (4 entries).
   0 | offset_to_top (0)
   1 | A RTTI
       -- (A, 0) vtable address --
   2 | void A::vfunc1()
   3 | void A::vfunc2()

VTable indices for 'A' (2 entries).
   0 | void A::vfunc1()
   1 | void A::vfunc2()
```

### 静态多态 (Static Polymorphism)

## 示例分析


