---
title: Expression Templates
categories: ["c++"]
tags: [c++, template]
date: 2022-04-06
---

## 什么是 Expression Templates

Expression Templates 是一种 C++
模板元编程技术，它通过在编译时构建计算表达式，这些计算表达式只会在需要的时候才会真正执行，从而生成高效的代码。
简单来说，通过 Expression Templates，我们可以实现惰性求值和消除因为中间结果而创建的临时变量。

## 一个常规示例

我们构造了一个`MyVector`类，并且重载了`MyVector`的`+`和`*`操作符，实现两个`MyVector`中相同下标元素的`+`和`*`操作。
通常对于这样的需求我们很容易做出一个简单的实现：

```cpp
#include <cassert>
#include <iostream>
#include <vector>

template<typename T> class MyVector
{
public:
    MyVector(const std::size_t n)
        : vec_(n)
    {}
    MyVector(const std::size_t n, const T initvalues)
        : vec_(n, initvalues)
    {}

    std::size_t size() const { return vec_.size(); }

    T operator[](const std::size_t i) const
    {
        assert(i < size());
        return vec_[i];
    }

    T& operator[](const std::size_t i)
    {
        assert(i < size());
        return vec_[i];
    }

private:
    std::vector<T> vec_;
};

template<typename T> MyVector<T> operator+(const MyVector<T>& a, const MyVector<T>& b)
{
    assert(a.size() == b.size());
    MyVector<T> result(a.size());
    for (std::size_t i = 0; i < a.size(); ++i) {
        result[i] = a[i] + b[i];
    }
    return result;
}

template<typename T> MyVector<T> operator*(const MyVector<T>& a, const MyVector<T>& b)
{
    assert(a.size() == b.size());
    MyVector<T> result(a.size());
    for (std::size_t i = 0; i < a.size(); ++i) {
        result[i] = a[i] * b[i];
    }
    return result;
}

template<typename T> std::ostream& operator<<(std::ostream& os, const MyVector<T>& vec)
{
    std::cout << '\n';
    for (std::size_t i = 0; i < vec.size(); ++i) {
        os << vec[i] << ' ';
    }
    os << '\n';
    return os;
}

int main(int argc, char* argv[])
{
    MyVector<double> x(10, 5.4);
    MyVector<double> y(10, 10.3);
    auto             ret = x + x + y * y;
    std::cout << ret << std::endl;
    return 0;
}
```

上面的实现平淡无奇，相信每个人都能随手写出来。在[godbolt](https://godbolt.org/z/zTenMfe6G)上编译成汇编来分析：

![my_vector1](/images/2022-04-07/my_vector1.png#center)

我们能发现，对于`x + x + y * y`这行来说，执行的过程为:

![my_vector1.1](/images/2022-04-07/my_vector1.1.png#center)

1. `temp1 = x + x`
2. `temp2 = y * y`
3. `temp3 = temp1 + temp2`

## 优化后的版本

在上面的实现中，虽然实现起来很简单，但是会造成一些额外的临时变量。是的，这是我们不能容忍的。
于是我们需要探索出一个更好的实现，如下图所示：

![my_vector2.1](/images/2022-04-07/my_vector2.1.png#center)

这里不需要为表达式`result[i] = x[i] + x[i] + y[i] * y[i]`
创建临时变量，赋值操作会直接触发运算的执行。

```cpp
#include <cassert>
#include <iostream>
#include <vector>

template<typename T, typename Cont = std::vector<T>> class MyVector
{
public:
    MyVector(const std::size_t n)
        : vec_(n)
    {}
    MyVector(const std::size_t n, const T initvalues)
        : vec_(n, initvalues)
    {}

    MyVector(const Cont& other)
        : vec_(other)
    {}

    template<typename T2, typename R2> MyVector& operator=(const MyVector<T2, R2>& other)
    {
        assert(size() == other.size());
        for (std::size_t i = 0; i < size(); ++i) vec_[i] = other[i];
        return *this;
    }

    std::size_t size() const { return vec_.size(); }
    T           operator[](const std::size_t i) const { return vec_[i]; }
    T&          operator[](const std::size_t i) { return vec_[i]; }
    const Cont& data() const { return vec_; }
    Cont&       data() { return vec_; }

private:
    Cont vec_;
};

template<typename T, typename Op1, typename Op2> class MyVectorAdd
{
public:
    MyVectorAdd(const Op1& a, const Op2& b)
        : op1_(a)
        , op2_(b)
    {}

    T           operator[](const std::size_t i) const { return op1_[i] + op2_[i]; }
    std::size_t size() const { return op1_.size(); }

private:
    const Op1& op1_;
    const Op2& op2_;
};

template<typename T, typename Op1, typename Op2> class MyVectorMul
{
public:
    MyVectorMul(const Op1& a, const Op2& b)
        : op1_(a)
        , op2_(b)
    {}

    T           operator[](const std::size_t i) const { return op1_[i] * op2_[i]; }
    std::size_t size() const { return op1_.size(); }

private:
    const Op1& op1_;
    const Op2& op2_;
};

template<typename T, typename R1, typename R2>
MyVector<T, MyVectorAdd<T, R1, R2>> operator+(const MyVector<T, R1>& a, const MyVector<T, R2>& b)
{
    return MyVector<T, MyVectorAdd<T, R1, R2>>(MyVectorAdd<T, R1, R2>(a.data(), b.data()));
}

template<typename T, typename R1, typename R2>
MyVector<T, MyVectorMul<T, R1, R2>> operator*(const MyVector<T, R1>& a, const MyVector<T, R2>& b)
{
    return MyVector<T, MyVectorMul<T, R1, R2>>(MyVectorMul<T, R1, R2>(a.data(), b.data()));
}

template<typename T> std::ostream& operator<<(std::ostream& os, const MyVector<T>& vec)
{
    os << '\n';
    for (std::size_t i = 0; i < vec.size(); ++i) os << vec[i] << ' ';
    os << '\n';
    return os;
}

int main(int argc, char* argv[])
{
    MyVector<double> x(10, 5.4);
    MyVector<double> y(10, 10.3);
    MyVector<double> result(10);
    result = x + x + y * y;
    std::cout << result << std::endl;
    return 0;
}
```

对于这个实现，同样的使用[godbold](https://godbolt.org/z/qfc3rjxMb)来分析：

![my_vector2.2](/images/2022-04-07/my_vector2.2.png#center)

汇编代码片段中表达式虽然很长，但是仔细看还是能看清它的结构。下面是一个简化版的代码生成图，用来说明模板的生成过程：

![Exression](/images/2022-04-07/Exression.png#center)

## 参考文档

[https://www.modernescpp.com/index.php/avoiding-temporaries-with-expression-templates](https://www.modernescpp.com/index.php/avoiding-temporaries-with-expression-templates)
