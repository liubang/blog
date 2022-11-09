---
title: c++17:string_view
categories: [programming]
tags: [c++, c++17]
date: 2022-02-14
---

## string_view 简介

`std::string_view`是 c++17 中新增的一种类型。其核心理念是，能够让我们在传统的 C++03 风格的具体性和泛型编程之间找到一个很好的折衷点。
在 C++17 标准之前，我们通常只能在粗糙的不严谨的模板实现和相对严谨但是有着冗长约束的模板之间做出选择。举个简单的例子：

```cpp
// c++03 style
class Widget
{
    std::string name_;

public:
    void setName(const char* new_name);
    void setName(const std::string& new_name);
};

// 不正确的欠约束的模板
class Widget
{
    std::string name_;

public:
    template<class T> void setName(T&& new_name);
};

// 正确的但是约束但滑稽冗长的模板
class Widget
{
    std::string name_;

public:
    template<class T, class = decltype(std::declval<std::string&>() = std::declval<T&&>()) >>
                              void setName(T&& new_name);
};
```

而有了 `string_view` 之后，以上代码就可以简化成如下：

```cpp
class Widget
{
private:
    std::string name_;

public:
    void setName(std::string_view name) { name_ = name; }
};
```

`string_view` 在替代`const std::string&`参数上取得了巨大的成功，但是有人坚持尝试在任何地方
使用`std::string_view`来替代`const std::string&`，这是不对的，例如下面的例子：

```cpp
const std::string& s1 = "hello world";  // OK, lifetime-extended
const std::string& s2 = std::string("hello world");  // OK, lifetime-extended
std::string_view sv1 = "hello world";  // OK, points to static array
std::string_view sv2 = std::string("hello world");  // BUG! Dangling pointer!
```

为了更加清楚的说明问题，这里用一个完整的示例来演示：

```cpp
#include <iostream>
#include <string>
#include <string_view>

class Widget
{
private:
    std::string name_;

public:
    explicit Widget(std::string_view name)
        : name_(name)
    {}
    void             setName(std::string_view name) { name_ = name; }
    std::string_view getName() const { return name_; }
};


int main(int argc, char* argv[])
{
    Widget w("ok");
    auto   name = w.getName();
    w.setName("hello");
    std::cout << name << std::endl;   // BUG! heap use after free
    return 0;
}
```

当我们使用`AddressSanitizer`工具来编译运行的时候，会报出`heap-use-after-free`的错误。
这个例子中使用 `string_view` 作为返回类型，由于 `string_view` 只是创建了一个 string 的视图，它既不能对 string 进行修改，也没有明确的所有权。
当我们调用`w.getName()`，返回的只是 `w::name_` 的一个视图，当我们调用`w.setName("hello");`后， `w::name_`替换成一个新构造的 string 对象，
由于`name`只是`w::name_`原来 string 对象的一个视图，它并不能延长原 string 对象的生命周期，因此原来的 string 对象被释放。当我们再使用`name`
变量的时候，就会出现问题。

## 传值还是引用

先说结论：按值传递 `string_view` 是通用的方式。下面来具体分析原因。

在 C++ 中，所有的值默认都是通过值传递，当我们使用`Widget w`的时候，实际上我们得到的是一个全新的对象。
但是对于大内存的拷贝是很昂贵的操作，因此当我们传递一些像`std::string`这样的很大的对象的时候，需要使用引用传递的方式来对按值传递进行优化。
而对于像`int`, `char *`, `std::pair<int, int>`, `std::span<Widget>`这样的轻量对象，我们依然更加倾向于使用默认的按值传递的方式。

对于`string_view`而言，按值传递比按引用传递有三个方面的性能优势：

**1. 消除了被调用方的间接指针**

`pass-by-const-reference` 意味着传递的是对象的地址，而 `pass-by-value` 意味着传递的是对象本身。
对于 `int`, `span`, `string_view` 这样的 trivial types 来说，它们会直接保存在寄存器上。
我们可以通过一个例子来具具体说明一下区别：

```cpp
// test_string_view.cpp
#include <string_view>

int byvalue(std::string_view sv)
{
    return sv.size();
}

int byref(const std::string_view& sv)
{
    return sv.size();
}
```

将上面的代码编译成汇编代码：

```cpp
# gcc 11.2
# g++ -std=c++20 -O1 test_string_view.cpp -o test_string_view.s
byvalue(std::basic_string_view<char, std::char_traits<char> >):
  movl %edi, %eax
  ret

byref(std::basic_string_view<char, std::char_traits<char> > const&):
  movl (%rdi), %eax
  ret
```

通过上面的汇编代码，可以很清晰的看到，按值传递的时候是将 `string_view` 直接在寄存器之间传递，
而按引用传递，则是需要先将 size 成员通过引用的地址和偏移 load 到内存中，然后再传递给寄存器。

**2. 在调用的时候，能消除一次栈帧溢出**

当我们通过引用传递的时候，调用者需要将对象的地址放入寄存器，所以对象一定要有地址。
即使调用者的其他所有对象都可以直接通过寄存器来保存，但是传递对象地址的行为也会迫使调用者将其溢出到堆栈中。
而按值传递消除了溢出参数的必要，在一些极端情况下意味着此次调用根本不需要调用程序中的栈帧。

下面同样通过一个例子来更加具体的说明：

```cpp
#include <string_view>

int byvalue(std::string_view sv)
{
    return sv.size();
}

int byref(const std::string_view& sv)
{
    return sv.size();
}


void callbyvalue(std::string_view sv)
{
    byvalue("hello");
}

void callbyref(std::string_view sv)
{
    byref("hello");
}
```

同样的编译成汇编代码：

```cpp
# gcc 11.2
.LC0:
  .string "hello"
callbyvalue(std::basic_string_view<char, std::char_traits<char> >):
  movl $5, %edi
  movl $.LC0, %esi
  jmp byvalue(std::basic_string_view<char, std::char_traits<char> >)
callbyref(std::basic_string_view<char, std::char_traits<char> >):
  subq $24, %rsp // 分配堆栈空间
  movq %rsp, %rdi
  movq $5, (%rsp)
  movq $.LC0, 8(%rsp)
  call byref(std::basic_string_view<char, std::char_traits<char> > const&)
  addq $24, %rsp // 清理堆栈空间
  ret
```

在 callbyvalue 中，只需要在寄存器中设置好 `string_view` 的数据指针和大小就直接调用 `byvalue` 了。而在
callbyref 中，需要使用 `string_view` 参数的地址，所以首先在堆栈上分配空间，当调用 byref 返回的时候，需要清理之前分配好的堆栈空间。

**3. 对编译器优化更加友好**

当我们传递引用的时候，我们给被调用的函数一个它们一无所知的对象引用，被调用方不知道还有谁持有这个对象的引用，
也不知道自己的指针是否指向该对象或该对象的一部分。因此编译器在做优化的时候必须非常保守。
而当我们按值传递的时候，我们给被调用函数一个全新的副本，一个绝对不会与程序中其他任何对象构成别名的副本，因此编译器可以尽可能做更多的优化。

例如下面的例子：

```cpp
#include <stddef.h>
#include <string_view>

void byvalue(std::string_view sv, size_t* p)
{
    *p = 0;
    for (size_t i = 0; i < sv.size(); ++i) *p += 1;
}

void byref(const std::string_view& sv, size_t* p)
{
    *p = 0;
    for (size_t i = 0; i < sv.size(); ++i) *p += 1;
}
```

编译成汇编代码：

```cpp
# gcc 11.2
byvalue(std::basic_string_view<char, std::char_traits<char> >, unsigned long*):
  movq %rdi, (%rdx)
  ret
byref(std::basic_string_view<char, std::char_traits<char> > const&, unsigned long*):
  movq $0, (%rsi)
  xorl %eax, %eax
  cmpq $0, (%rdi)
  je .L5
.L6:
  addq $1, %rax
  movq %rax, (%rsi)
  cmpq (%rdi), %rax
  jb .L6
.L5:
  ret
```

在 `byvalue` 中，编译器能够很聪明的知道循环是以 1 为步幅，累加 `sv.size()` 次，因此直接将程序优化为将 `*p` 赋值为 `sv.size()`。
而 `byref` 中，编译器老老实实生成循环的代码。

## 总结

`string_view`作为 c++17 引入的新类型，其功能还是非常强大的。但是在使用的时候也要对其特性足够的了解，切勿滥用，尤其不能笼统的使用 `std::string` 替代 `const std::string&`。
在通常情况下，函数的参数，或者循环控制变量是`string_view`两个最常用的使用场景。对于其他使用场景，大家一定要注意 `string_view` 不会延长原 `std::string` 的生命周期，因此在对象中保存
`string_view` 或者通过函数返回 `string_view` 的时候一定要非常小心。

另外，对于`string_view`这种简单的类型，更倾向于按值传递。
