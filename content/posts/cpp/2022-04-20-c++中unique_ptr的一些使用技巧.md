---
title: c++中unique_ptr的一些使用技巧
categories: [programming]
tags: [c++]
date: 2022-04-20
---

## 前言

c++11 对智能指针做了很大的优化，废弃了 c++98 中的`auto_ptr`，引入了三种新的智能指针：`unique_ptr`，`shared_ptr`，`weak_ptr`。
本文将针对`unique_ptr`的一些使用技巧做一些整理和归纳。在正式开始之前，我们首先来回顾一下`unique_ptr`的特点：一个`unique_ptr`对象内包含一个原始指针，该`unique_ptr`对象负责管理原始指针的生命周期。
一个`unique_ptr`对象始终是其关联的原始指针的唯一拥有者。

在了解了`unique_ptr`的特点之后，我们来具体看看日常开发中`unique_ptr`的一些使用场景和技巧。

## 一些场景

### 本地对象指针

在开发中，我们经常会遇到或者写出类似于下面这样的逻辑：

```cpp
void somefunc() {
    Object obj = new Object;
    // ...
    if (/* event 1 */) {
        delete obj;
        return;
    }

    if (/* event 2 */) {
        delete obj;
        return;
    }
    delete obj;
}
```

对于这样的代码，写起来很麻烦，看上去也及其丑陋。以前我们常用的一种优化手段就是使用`goto`，而在 c++11 之后，我们有了一种更加优雅简洁的方式，来对上面的代码进行优化，那就是使用`unique_ptr`:

```cpp
void somefunc() {
    std::unique_ptr<Object> obj = std::make_unique<Object>(); // need c++14
    // ...
    if (/* event 1 */) {
        return;
    }

    if (/* event 2 */) {
        return;
    }
}
```

只需要将本地指针对象用`unique_ptr`包装起来，后面无需关心指针释放的问题，整体逻辑看上去更加简洁。

### 数组

在 c++中，数组的创建和释放是一个很容易出错的地方，因为尽管数组的创建跟其他对象的创建一样使用`new`操作符，但是数组的释放却不同于普通对象指针的释放，而是使用的`delete[]`:

```cpp
int *a = new int[10];
// ...
delete[] a;
```

而有了`unique_ptr`之后，情况就会变得非常简单：

```cpp
auto a = std::make_unique<int[]>(10);
// ...
```

### 工厂函数

通常工厂函数会创建对象，然后对对象做一些初始化操作，最后将对象返回给调用者，下面是一个简单的工厂函数的实现:

```cpp
Object* factory() {
    Object* o = new Object;
    o->init();
    return o;
}
```

但是当调用者拿到返回的对象指针后尝尝会困惑自己是否拥有该对象的所有权，是否应该负责该对象的释放。

解决这个问题的一个比较好的办法是，将构造好的对象包装成`unique_ptr`返回给调用者，这样相当于明确告诉调用方，把该对象和对象的所有权一起返回：

```cpp
std::unique_ptr<Object> factory() {
    auto o = std::make_unique<Object>();
    o->init();
    return o;
}
```

### 类成员和函数参数

当我们将一个指针做为类成员，或者作为函数参数的时候，由于指针本身的传递没有携带所有权的信息，所以在指针传递的中间环节，我们不知道自己是否拥有该对象的所有权，为了明确这一点，也可以使用`unique_ptr`做一层包装，明确所有权和对象一起传递。

### 只使用指针

考虑下面这种 case，我们只想使用指针，而不需要其所有权，在这种情况下，c++核心指南建议直接传递`T*`。如果我们假设所有裸指针都是非所有传递的，那这样自然没什么问题。当然我们还有一种办法是通过传递`const std::unique_ptr<T>&`来实现。这种用法看起来很不可思议，然而在一些著名的开源项目中却真实的存在，例如：
[https://github.com/opencv/opencv/blob/68d15fc62edad980f1ffa15ee478438335f39cc3/modules/gapi/src/compiler/passes/transformations.cpp#L66](https://github.com/opencv/opencv/blob/68d15fc62edad980f1ffa15ee478438335f39cc3/modules/gapi/src/compiler/passes/transformations.cpp#L66)

```cpp
// Tries to substitute __single__ pattern with substitute in the given graph
bool tryToSubstitute(ade::Graph& main,
                     const std::unique_ptr<ade::Graph>& patternG,
                     const cv::GComputation& substitute)
{
    GModel::Graph gm(main);

    // 1. find a pattern in main graph
    auto match1 = findMatches(*patternG, gm);
    if (!match1.ok()) {
        return false;
    }

    // 2. build substitute graph inside the main graph
    cv::gimpl::GModelBuilder builder(main);
    auto expr = cv::util::get<cv::GComputation::Priv::Expr>(substitute.priv().m_shape);
    const auto& proto_slots = builder.put(expr.m_ins, expr.m_outs);
    Protocol substituteP;
    std::tie(substituteP.inputs, substituteP.outputs, substituteP.in_nhs, substituteP.out_nhs) =
        proto_slots;

    const Protocol& patternP = GModel::Graph(*patternG).metadata().get<Protocol>();

    // 3. check that pattern and substitute are compatible
    // FIXME: in theory, we should always have compatible pattern/substitute. if not, we're in
    //        half-completed state where some transformations are already applied - what can we do
    //        to handle the situation better?  -- use transactional API as in fuse_islands pass?
    checkCompatibility(*patternG, gm, patternP, substituteP);

    // 4. make substitution
    performSubstitution(gm, patternP, substituteP, match1);

    return true;
}
```

在上面的函数中我们可以看到通过 const reference 的方式传递`unique_ptr`，在函数内部可以像`T*`那样直接使用，但是不能对指针本身做任何修改。

### 更新指针

我们经常会对类似于下面的代码产生困惑：

```cpp
void reset(T** pp) {
    *pp = new T;
}

T* p = nullptr;
reset(&p);
```

假如`p`已经被初始化过了，那调用`reset(&p)`在新建一个新的对象之前，还需要对原来的对象进行释放。

如果我们将`reset`函数修改成下面这样：

```cpp
void reset(std::unique_ptr<T>& pp) {
    pp = std::make_unique<T>();
}
```

情况就变得非常容易了，我们通过传递 non-const reference 的`unique_ptr`来对指针进行修改，而且不必单独为非空指针做专门的释放操作。

## 总结

使用`unique_ptr`的好处总结起来就是，在传递原始指针的同时，也传递了原始指针的所有权。这样使用者在使用指针的时候，不用对指针的所有权感到困惑以至于不清楚在使用完之后是否需要释放指针对象。

## 参考文档

- [https://isocpp.github.io/CppCoreGuidelines/CppCoreGuidelines](https://isocpp.github.io/CppCoreGuidelines/CppCoreGuidelines)
