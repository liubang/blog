---
layout: article
title: 安全的使用string_view
tags: [c++, c++17]
---

## string_view 简介

`std::string_view`是 c++17 中新增的一种类型。其基本思想是，它可以让你在 C++03 风格的具体性和泛型编程之间找到一个很好的折衷点。在 C++17 之前，我们只能在不正确的欠约束模板和正确的但约束滑稽冗长的模板之间进行选择:

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

而有了 string_view 之后，这一切就变得相当简单了：

```cpp
class Widget
{
private:
    std::string name_;

public:
    void setName(std::string_view name) { name_ = name; }
};
```

string_view 在替代`const std::string&`参数上取得了巨大的成功，但是有人坚持尝试在任何地方
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
这个例子中使用 string*view 作为返回类型，由于 string_view 只是创建了一个 string 的视图，它既不能对 string 进行修改，也没有明确的所有权。
当我们调用`w.getName()`，返回的只是`w::name*`的一个视图，当我们调用`w.setName("hello")`后，`w::name*`替换成一个新构造的string对象， 由于`name`只是`w::name*`原来string对象的一个视图，它并不能延长原string对象的生命周期，因此原来的string对象被释放。当我们再使用`name`
变量的时候，就会出现问题。

## 传值还是引用

## 总结
