---
layout: article
title: c++17 新特性constexpr if
tags: [c++, c++17]
---

constexpr 是 c++11 引入的关键字，用于编译时常量和常量表达式。而 c++17 将这一特性做了增强，引入了 `constexpr if` ，
使得编译器在编译时(compile time)能够做分支判断，从而有条件的编译代码。

下面可以通过一个简单的例子来看看`constexpr if`的用法：

```cpp
#include <iostream>
#include <type_traits>

template<typename T> auto getValue(T t)
{
    if constexpr (std::is_pointer<T>::value) {
        return *t;
    } else {
        return t;
    }
}

int main(int argc, char* argv[])
{
    int  a = 10;
    int* b = &a;
    getValue(a);
    getValue(b);
    return 0;
}
```

其实和普通的条件判断区别不大，只不过`constexpr if`中的条件是常量表达式，可以在编译时确定条件表达式的结果，从而选择编译对应的分支代码。
我们可以将上述代码编译成汇编来进一步分析：

```cpp
auto getValue<int>(int):
        push    rbp
        mov     rbp, rsp
        mov     DWORD PTR [rbp-4], edi
        mov     eax, DWORD PTR [rbp-4]
        pop     rbp
        ret
auto getValue<int*>(int*):
        push    rbp
        mov     rbp, rsp
        mov     QWORD PTR [rbp-8], rdi
        mov     rax, QWORD PTR [rbp-8]
        mov     eax, DWORD PTR [rax]
        pop     rbp
        ret
......
```

这里可以看到，生成的`getValue<int>`和`getValue<int*>`两个版本的函数分别保留了对应类型的分支逻辑，而没有了条件判断。

至此我们对`constexpr if`的用法有了初步的认知，下面来通过元编程来加深对其的理解。

## constexpr if 在元编程中的应用

说到元编程，我们就从元编程的"hello world"程序——计算阶乘开始，我们先写出一个不使用`constexpr
if`的阶乘：

```cpp
#include <iostream>

template<int N> struct Factorial
{
    static constexpr int value = N * Factorial<N - 1>::value;
};

template<> struct Factorial<1>
{
    static constexpr int value = 1;
};

template<int N> inline constexpr int Factorial_v = Factorial<N>::value;

int main(int argc, char* argv[])
{
    std::cout << Factorial_v<1> << std::endl;
    std::cout << Factorial_v<2> << std::endl;
    std::cout << Factorial_v<3> << std::endl;
    std::cout << Factorial_v<4> << std::endl;
    return 0;
}
```

这段代码非常简单，没什么可解释的，这里之所以拿出来是为了将其使用`constexpr if`进行重写：

```cpp
#include <iostream>

template<int N> constexpr int factorial()
{
    if constexpr (N >= 2) {
        return N * factorial<N - 1>();
    } else {
        return N;
    }
}

int main(int argc, char* argv[])
{
    std::cout << factorial<1>() << std::endl;
    std::cout << factorial<2>() << std::endl;
    std::cout << factorial<3>() << std::endl;
    std::cout << factorial<4>() << std::endl;
    return 0;
}
```

通过上面的改写，可以很容易发现，在不使用`constexpr
if`的时候，我们需要额外的对`Factorial`模板类做特例化，来定义递归的结束位置。而有了`constexpr
if`我们可以像写正常的函数那样写出能具有常量特性的函数，在编译期计算阶乘。

同样地，我们也可以很容易将fibonacci函数改造成`constexpr if`版本，这里就不再赘述了。
