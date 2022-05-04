---
title: 深入理解 enable_shared_from_this
categories: [programming]
tags: [c++]
date: 2022-05-03
---

## 关于 shared_ptr

`shared_ptr`是一种共享所有权的智能指针，允许我们安全地访问和管理对象的生命周期。`shared_ptr`的多个实例
通过共享控制块结构来控制对象的生命周期。控制块维护了引用计数(reference count)，弱引用计数(weak count)和其他
必要的信息，以管理对象在内存中的存在。

当使用原始指针构造或者初始化一个`shared_ptr`时，将会创建一个新的控制块。为了确保一个对象仅由一个共享控制块
管理，必须通过将已存在的`shared_ptr`复制到该对象来生成的任何其他`shared_ptr`实例，例如：

```cpp
void good()
{
  auto p{new int(10)}; // p is int*
  // create additional shared_ptr from an existing shared_ptr
  std::shared_ptr<int> sp1{p};
  // sp2 shares control block with sp1
  auto sp2{sp1};
}
```

而使用指向已由`shared_ptr`管理的对象的原始指针来初始化另一个`shared_ptr`会创建另一个控制块来管理该对象，
这会导致 undefined behavior，例如：

```cpp
void bad()
{
  auto p{new int(10);};
  std::shared_ptr<int> sp1{p};
  std::shared_ptr<int> sp2{p}; // Undefined behavior!
}
```

从一个原始指针实例化多个`shared_ptr`是一种编码疏忽，会造成严重后果。因此尽量使用`std::make_shared`或者
`std::allocate_shared`来降低出错的可能性。毕竟除非有人刻意为之，否则我们似乎很难遇到这样的代码：

```cpp
auto sp1 = std::make_shared<int>();
std::shared_ptr<int> sp2{sp1.get()};
```

但是在某些情况下，`shared_ptr`管理的对象需要为自己获取`shared_ptr`，我们会在后面的篇幅中重点讲解这种情况。
但是首先需要说明的是，类似于下面这样尝试从自身指针创建`shared_ptr`是行不通的：

```cpp
struct Egg
{
  std::shared_ptr<Egg> get_self_ptr()
  {
    return std::shared_ptr<Egg>(this);
  }
};

void spam()
{
  auto sp1 = std::make_shared<Egg>();
  auto sp2 = sp1->get_self_ptr(); // undefined behavior
  // sp1 and sp2 have two different control blocks managing same Egg
}
```

为了解决这个问题，我们就需要用到`std::enable_shared_from_this`。public 继承`std::enable_shared_from_this`
的类可以通过调用`shared_from_this()`方法来获取自身的`shared_ptr`，下面是一个例子：

```cpp
struct Thing;
void some_api(const std::shared_ptr<Thing>& tp);

struct Thing : public std::enable_shared_from_this<Thing>
{
  void method()
  {
    some_api(shared_from_this());
  }
};

void foo()
{
  auto sp = std::make_shared<Thing>();
  sp->method();
}
```

## 为什么要从 this 创建 shared_ptr

让我们来看一个更有说服力的例子，在这种情况下，`shared_ptr`管理的对象需要为自己获取一个`shared_ptr`。

一个`Processor`类异步处理数据并将其保存到数据库。在接收数据时，`Processor`通过自定义执行器来异步处理
数据：

```cpp
class Executor
{
public:
  void execute(const std::function<void(void)>& task);

private:
  // ...
};

class Processor
{
public:
  void process_data(const std::string& data);

private:
  void do_process_and_save(const std::string& data) {
    // process data
    // sava data to DB
  }

private:
  Executor* executor_;
};
```

下面，`Processor`类从一个`Client`类接收数据，这个`Client`持有该`Processor`的一个`shared_ptr`实例：

```cpp
class Client
{
public:
  void some_method()
  {
    processor_->process_data("xxxxxx");
  }

private:
  std::shared_ptr<Processor> processor_;
}
```

`Executor`是一个线程池，它封装了多个线程和一个任务队列，并从队列中执行不同的 task。

在`Processor::process_data`中，我们需要将执行过程包装成 task 传递给`Executor`。在 task 中调用私有方法
`do_process_and_save`，该方法在将数据保存到数据库之前对数据进行处理。因此，构造 task 的时候，需要捕获对
`Processor`对象本身的引用：

```cpp
void Processor::process_data(const std::string& data)
{
  executor_->execute([this, data]() {
    // ...
    do_process_and_save(data);
  });
}
```

但是，`Client`可以出于各种原因随时将`shared_ptr`丢弃或者重置为其他关联的`Processor`，这可能会破坏
`Processor`。因此在执行排队的 lambda 之前或期间，捕获的`this`指针可能会失效。

我们可以通过在 lambda 中捕获`this`对象的`shared_ptr`来避免上面的 undefined
behavior 的发生。只要排队的 lambda 持有一个`Processor`的`shared_ptr`，`Processor`就会保持正常的运行状态。
然而，我们知道，像这样创建一个`shared_ptr<Processor>(this)`是行不通的。

我们需要一种机制，让一个`shared_ptr`管理对象以某种方式控制它的控制块，从而获取另一个自身的`shared_ptr`对象。
使用`std::enable_shared_from_this`就是为了达到了这个目的：

```cpp
class Processor : public std::enable_shared_from_this
{
  // ...
};

void Processor::process_data(const std::string& data)
{
  executor_->execute([self = shared_from_this(), data]() {
    // ...
    self->do_process_and_save(data);
  });
}
```

## 为什么要使用 enable_shared_from_this

本质上，额外的`shared_ptr`实例只能通过从可以访问控制块的 handle 生成。该 handle 可以是一个`shared_ptr`，
也可以是一个`weak_ptr`。如果一个对象有这个 handle，那么它就可以为自己创建额外的`shared_ptr`。但是`shared_ptr`
是一个强引用，会影响受管理对象的生命周期。将`shared_ptr`保存到自身对象将会导致内存泄漏:

```cpp
struct Immortal
{
  std::shared_ptr<Immortal> self;
};
```

解决这个问题可以通过`weak_ptr`来实现。`weak_ptr`是一种弱引用，它不会影响受管理对象的生命周期，但是
在需要时可以用于获取强引用。如果一个对象持有自身的`weak_ptr`，那么在需要的时候，就可以获取自身的`shared_ptr`:

```cpp
class Naive
{
public:
  static std::shared_ptr<Naive> create()
  {
    auto sp = std::shared_ptr<Naive>(new Naive);
    sp->weak_self_ = sp;
    return sp;
  }

  auto async_method()
  {
    return std::async(std::launch::async, [self = weak_self_.lock()]() {
      self->do_something();
    });
  }

  void do_something()
  {
    std::this_thread::sleep_for(std::chrono::seconds(1));
  }

private:
  Naive() {}
  Naive(const Naive&) = delete;
  const Naive& operator=(const Naive&) = delete;
  std::weak_ptr<Naive> weak_self_;
};

void test()
{
  std::future<void> ft;
  {
    auto pn = Naive::create();
    ft = pn->async_method();
  }
  ft.get();
}
```

上面的实现不够完美，因为它有很多限制。我们需要确保在构造`Naive`类的时候初始化对自身的`weak_ptr`，因此
`Naive`的构造必须仅通过静态工厂方法来进行约束。

这种解决方案对合理需求的设计施加了太多的限制。然而这个实现却为标准解决方案`std::enable_shared_from_this`设置了一个概念框架。

## std::enable_shared_from_this 的内部实现

`std::enable_shared_from_this`的典型实现是一个只包含了`weak_ptr<T>`字段的类：

```cpp
template<class T>
class enable_shared_from_this
{
  mutable weak_ptr<T> weak_this;

public:
  shared_ptr<T> shared_from_this()
  {
    return shared_ptr<T>(weak_this);
  }

  // const overload
  shared_ptr<const T> shared_from_this() const
  {
    return shared_ptr<const T>(weak_this);
  }

  // .. more methods and constructors..
  // there is weak_from_this() also since c++17

  template <class U> friend class shared_ptr;
};
```

剩下的魔法代码在`shared_ptr`的构造函数中。当`shared_ptr`用`T*`初始化的时候，如果`T`是从
`std::enable_shared_from_this<T>` 继承来的，则`shared_ptr`构造函数会初始化`weak_this`。只有当`T`从
`std::enable_shared_from_this`
公开继承的时候，才能在编译时使用 trait
类(`std::enable_if`和`std::is_convertible`)来启用`weak_this`的初始化代码。**因此，必须使用`public`继承
`std::enable_shared_from_this`类，因为`shared_ptr`构造函数需要通过`weak_this`来进行初始化，如果不 public 继承，则会在运行时抛出`bad_weak_ptr`异常。**

关于`std::enable_shared_from_this`的一些值得注意的细节：

1. `weak_ptr`被声明为 mutable，因此它也可以被修改为 const 对象
2. `shared_ptr`被声明为友元类型，这样它就可以访问私有字段`weak_this`

下面是另一个基本的例子，用来描述这一切是如何联系在一起的。我们将初始化`shared_ptr`的代码故意分为两个
步骤，以演示嵌入的`weak_ptr`的创建和初始化的两个阶段：

```cpp
struct Article : public std::enable_shared_from_this<Article>
{
};

void foo()
{
  // step 1
  // Enclosed 'weak_this' is not associated with any control block.
  auto pa = new Article;

  // step 2
  // Enclosed 'weak_this' gets initialized with a control block
  auto spa = std::shared_ptr<Article>(pa);
}
```

## 关于 std::bad_weak_ptr 异常

调用`shared_from_this`方法有一个限制，就是智能在`shared_ptr`管理的对象内部调用。从 c++17 开始，在不受
`shared_ptr`管理的对象内部调用`shared_from_this`会触发`std::bad_weak_ptr`异常，而在 c++17 之前，这种操
作是 undefined behavior。

```cpp
struct Article : public std::enable_shared_from_this<Article>
{
  void foo()
  {
    auto self = shared_from_this();
    // ...
  }
}

void test()
{
  auto pa = new Article;
  pa->foo(); // ! std::bad_weak_ptr
}
```

当`shared_from_this`调用的时候，如果`weak_ptr`未初始化或者已过期，那么`shared_ptr`的构造函数就会抛出
异常。

另一个触发抛出`std::bad_weak_ptr`的例子是，当在构造函数占用调用`shared_from_this`的时候，
因为嵌入的`weak_this`尚未初始化而导致抛出异常。

触发`std::bad_weak_ptr`的另一个非常微妙而且难以定位的情况是，一个类没有 public
继承`std::enable_shared_from_this`类并且调用了`shared_from_this`方法。private 和 protected 继承都会阻止
`weak_this`成员的初始化，这可能会在没有任何编译器警告的情况下被忽略。例如：

```cpp
class Overlooked : std::enable_shared_from_this<Overlooked>
{
public:
  void foo()
  {
    // std::bad_weak_ptr
    auto self = shared_from_this();
  }
}
```

有些情况下会禁用或者避免抛出异常，对于这种情况，从 c++17 开始，就有了一种替代`shared_from_this`的方法。
c++17 将`weak_from_this`方法添加到`std::enable_shared_from_this`中，后者返回嵌入的`weak_this`的副本。
`shared_ptr`可以安全地从该`weak_ptr`中获取，而不会导致任何`std::bad_weak_ptr`异常的发生：

```cpp
class Overlooked : std::enable_shared_from_this<Overlooked>
{
public:
  void foo()
  {
    if (auto self = weak_from_this().lock()) {
      // ok, use self
    } else {
      // ...
    }
  }
}
```
