---
layout: article
title: 动态连接器技巧之使用LD_PRELOAD改变程序的行为
tags: [c, sp]
categories: ["sp"]
date: 2019-07-18
---

我们有这样一段简单的代码，用来输出 10 个[0, 100)的随机数：

```c
// random.c
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

int main() {
    srand(time(NULL));
    int i = 10;
    while (i--) printf("%d\n", rand() % 100);
    return 0;
}
```

编译运行：

```shell
liubang@venux-dev:~$ gcc random.c -o random
liubang@venux-dev:~$ ./random
44
46
97
51
62
76
92
76
38
10
```

这个程序每次运行的结果都是不一样的，现在我们希望我们能够在不修改源码的情况下，控制程序的输出结果，例如我希望这段程序运行的结果是
每次都能输出 10 个 10。由于不能修改源码，或者我们根本没有源码，面对这样一个编译后的可执行二进制文件，想要修改程序的运行结果，可能显
得有些困难。然而，如果能够善用动态连接器的话，这都不是问题。

下面我们来创建一段程序：

```c
// unrandom.c
int rand() {
    return 10;
}
```

然后将它编译成动态链接库：

```shell
liubang@venux-dev:~$ gcc -shared -fPIC unrandom.c -o libunrandom.so
```

这样我们就得到了一个名为`libunrandom.so`的动态链接库，然后执行：

```shell
liubang@venux-dev:~$ LD_PRELOAD=./libunrandom.so ./random
10
10
10
10
10
10
10
10
10
10
```

是不是发现原来程序的结果变成了 10 个 10，即使执行多次，结果都一样。为什么会这样呢？`LD_PRELOAD`到底做了什么事？
下面我们来进一步了解其中的原理。

我们使用 ldd 命令查看原始程序用到的链接库：

```shell
liubang@venux-dev:~$ ldd random
	linux-vdso.so.1 (0x00007ffebcba5000)
	libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f21ad8d7000)
	/lib64/ld-linux-x86-64.so.2 (0x00007f21adeca000)
```

这些链接库是在程序编译时期就确定的，而且被编译到最终的可执行文件中了。众所周知，`libc.so`提供了标准 c 函数库，所以所有的 c 程序都会使用到这个链接库。
我们可以使用下面的命令查看`libc.so`都提供了哪些标准函数：

```shell
liubang@venux-dev:~$ nm -D /lib/x86_64-linux-gnu/libc.so.6
...
...
00000000000443a0 T rand
...
```

在输出的结果中，我们确实能够看到`rand`这个标准函数。

下面我们再来看看，使用`LD_PRELOAD`后到底发生了什么。

```shell
liubang@venux-dev:~$ LD_PRELOAD=./libunrandom.so ldd ./random
	linux-vdso.so.1 (0x00007ffe48bed000)
	./libunrandom.so (0x00007f419497d000)
	libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f419458c000)
	/lib64/ld-linux-x86-64.so.2 (0x00007f4194d81000)
```

很显然，我们的程序“被强制”使用了`libunrandom.so`这个链接库。从而导致 random 程序在调用`rand()`函数的时候使用了我们自己实现的，而不是真正的`rand()`函数。

这个技巧仅仅使用来 hack 程序，修改程序的运行结果吗？其实不然，在实际的应用中，通常会使用这个技巧来做一些类似于 Java 中的'AOP'，对程序进行切面，并注入一些有用的代码，以实现一些功能。

下面我们来看另一个例子：我们想要知道某个二进制程序中每次调用 malloc 时的参数，并统计调用了多少次。注意这里仅仅是想要获取调用标准函数 malloc 的参数，而不会改变原始程序的行为。

```c
// malloc_trace.c
#include <dlfcn.h>
#include <unistd.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

static int c = 0;

void *malloc(size_t size) {
    char buf[128];
    static void *(*real_malloc)(size_t) = NULL;
    if (real_malloc == NULL) {
        real_malloc = dlsym(RTLD_NEXT, "malloc");
    }
    c++;
    sprintf(buf, "malloc called, size = %zu, count = %d\n", size, c);
    write(2, buf, strlen(buf));
    return real_malloc(size);
}
```

编译成动态链接库：

```shell
liubang@venux-dev:~$ gcc -D_GNU_SOURCE -shared -ldl -fPIC -o libmalloc_trace.so malloc_trace.c
```

然后我们来统计一下`ls`这个命令中 malloc 调用的参数和次数：

```shell
liubang@venux-dev:~$ LD_PRELOAD=./libmalloc_trace.so ls
malloc called, size = 552, count = 1
malloc called, size = 120, count = 2
malloc called, size = 1024, count = 3
malloc called, size = 5, count = 4
......
malloc called, size = 5928, count = 174
malloc called, size = 208, count = 175
malloc called, size = 208, count = 176
malloc called, size = 1024, count = 177
 bin   btree.c   Desktop   Documents   Downloads   go   libmalloc_trace.so   libunrandom.so   malloc_trace.c   merge_sort.c   Pictures   Public   random   random.c   rsync.sh   unrandom.c  'VirtualBox VMs'   workspace   模板
```

大功告成，是不是很简单。
