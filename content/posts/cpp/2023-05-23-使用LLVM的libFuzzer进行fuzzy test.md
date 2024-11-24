---
title: 使用LLVM的libFuzzer进行fuzzy test
categories: [programming]
tags: [c++]
date: 2023-05-23
authors: ["liubang"]
---

## libFuzzer 简介

LLVM libFuzzer 是 LLVM 生态系统中的一个fuzzy test工具，用于自动化地发现软件程序中的漏洞和错误。它通过生成大量的随机输入数据并观察程序的行为来进行fuzzy test。
libFuzzer 是一个基于内存的fuzzy test引擎，使用 LLVM 的插桩技术和代码优化功能来提高测试效率和覆盖率。

以下是 libFuzzer 的一些功能特点：

1. 自动化fuzzy test：libFuzzer 提供了一种自动化的fuzzy test方法，可以生成大量的随机输入数据，并在每个输入上运行目标函数进行测试。它通过观察程序的崩溃、断言失败、未定义行为等反馈来发现潜在的问题。
2. 内存安全性：libFuzzer 通过使用 AddressSanitizer (ASan) 和 UndefinedBehaviorSanitizer (UBSan) 等工具来确保fuzzy test过程中的内存安全性。这有助于检测和报告内存错误、缓冲区溢出、使用已释放内存等问题。
3. 代码覆盖率分析：libFuzzer 使用 LLVM 提供的代码覆盖率分析技术，帮助确定已经执行过的代码路径和未执行的代码区域。这有助于评估测试的质量和覆盖范围，并帮助发现潜在的漏洞。
4. 快速收敛：libFuzzer 使用一种称为 "回退"（Backoff）的策略，以更快地收敛到程序中的漏洞。它会根据测试结果调整输入数据的变异程度，使得能够更快地发现问题并生成更有潜力的测试用例。
5. 灵活性和可定制性：libFuzzer 提供了多种选项和配置参数，使用户能够根据自己的需求进行定制。例如，可以设置最大测试时间、内存消耗限制、覆盖率报告等。
6. 多线程支持：libFuzzer 支持多线程执行，可以利用多核处理器并行进行fuzzy test，加快测试速度。

## 示例

下面是一个使用 libFuzzer 的简单示例

首先我们有一个 test_fuzzy.cpp:

```cpp
#include <cstddef>
#include <cstdint>

void DoSomethingWithData(const uint8_t* data, std::size_t size) {
  int* p = nullptr;
  if (size < 10) return;
  if (data[0] == 'h' && data[1] == 'e' && data[2] == 'l' && data[3] == 'l' && data[4] == '0') {
    *p = 42;
  }
  return;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, std::size_t size) {
  DoSomethingWithData(data, size);
  return 0;
}
```

使用 clang++进行编译：

```bash
/opt/homebrew/Cellar/llvm/16.0.3/bin/clang++ -g -fsanitize=address,fuzzer test_fuzzy.cpp -o test_fuzzy
```

然后直接运行：

```bash
./test_fuzzy

```

程序崩溃，并输出：

```bash
test_fuzzy(7057,0x1fb911b40) malloc: nano zone abandoned due to inability to reserve vm space.
INFO: Running with entropic power schedule (0xFF, 100).
INFO: Seed: 3129959573
INFO: Loaded 1 modules   (9 inline 8-bit counters): 9 [0x104488000, 0x104488009),
INFO: Loaded 1 PC tables (9 PCs): 9 [0x104488010,0x1044880a0),
INFO: -max_len is not provided; libFuzzer will not generate inputs larger than 4096 bytes
INFO: A corpus is not provided, starting from an empty corpus
#2	INITED cov: 3 ft: 3 corp: 1/1b exec/s: 0 rss: 44Mb
#726	NEW    cov: 4 ft: 4 corp: 2/11b lim: 11 exec/s: 0 rss: 45Mb L: 10/10 MS: 4 ChangeBit-ShuffleBytes-InsertByte-InsertRepeatedBytes-
#11087	NEW    cov: 5 ft: 5 corp: 3/21b lim: 110 exec/s: 0 rss: 45Mb L: 10/10 MS: 1 ChangeByte-
#29565	NEW    cov: 6 ft: 6 corp: 4/31b lim: 293 exec/s: 0 rss: 47Mb L: 10/10 MS: 3 CMP-ChangeBinInt-ChangeBit- DE: "%\000\000\000"-
#63786	NEW    cov: 7 ft: 7 corp: 5/41b lim: 625 exec/s: 0 rss: 50Mb L: 10/10 MS: 1 CMP- DE: "l\000"-
#64830	NEW    cov: 8 ft: 8 corp: 6/64b lim: 634 exec/s: 0 rss: 50Mb L: 23/23 MS: 4 EraseBytes-CrossOver-CrossOver-PersAutoDict- DE: "l\000"-
#65066	REDUCE cov: 8 ft: 8 corp: 6/63b lim: 634 exec/s: 0 rss: 50Mb L: 22/22 MS: 1 EraseBytes-
#65069	REDUCE cov: 8 ft: 8 corp: 6/53b lim: 634 exec/s: 0 rss: 50Mb L: 12/12 MS: 3 ShuffleBytes-ChangeBinInt-EraseBytes-
#66665	REDUCE cov: 8 ft: 8 corp: 6/51b lim: 643 exec/s: 0 rss: 50Mb L: 10/10 MS: 1 EraseBytes-
AddressSanitizer:DEADLYSIGNAL
=================================================================
==7057==ERROR: AddressSanitizer: SEGV on unknown address 0x000000000000 (pc 0x000104447fa8 bp 0x00016b9ba330 sp 0x00016b9ba260 T0)
==7057==The signal is caused by a WRITE memory access.
==7057==Hint: address points to the zero page.
    #0 0x104447fa8 in DoSomethingWithData(unsigned char const*, unsigned long) test_fuzzy.cpp:8
    #1 0x104447ff4 in LLVMFuzzerTestOneInput test_fuzzy.cpp:14
    #2 0x10445fc94 in fuzzer::Fuzzer::ExecuteCallback(unsigned char const*, unsigned long) FuzzerLoop.cpp:617
    #3 0x10445f588 in fuzzer::Fuzzer::RunOne(unsigned char const*, unsigned long, bool, fuzzer::InputInfo*, bool, bool*) FuzzerLoop.cpp:519
    #4 0x104460c60 in fuzzer::Fuzzer::MutateAndTestOne() FuzzerLoop.cpp:763
    #5 0x104461aa4 in fuzzer::Fuzzer::Loop(std::__1::vector<fuzzer::SizedFile, std::__1::allocator<fuzzer::SizedFile>>&) FuzzerLoop.cpp:908
    #6 0x104450e4c in fuzzer::FuzzerDriver(int*, char***, int (*)(unsigned char const*, unsigned long)) FuzzerDriver.cpp:912
    #7 0x10447dc80 in main FuzzerMain.cpp:20
    #8 0x1a014bf24  (<unknown module>)
    #9 0xb0c7ffffffffffc  (<unknown module>)

==7057==Register values:
 x[0] = 0x000000000000006f   x[1] = 0x000000000000006f   x[2] = 0x0000000000000000   x[3] = 0x0000000104488009
 x[4] = 0x00000001044b9c80   x[5] = 0x0000000000000001   x[6] = 0x000000016b1c0000   x[7] = 0x0000000000000001
 x[8] = 0x000000000000002a   x[9] = 0x0000000000000000  x[10] = 0x0000000104488000  x[11] = 0x0000000000000000
x[12] = 0x00000000000010c0  x[13] = 0x0000000000000000  x[14] = 0x0000000000000001  x[15] = 0x0000000000000000
x[16] = 0x00000001a04d23d0  x[17] = 0x0000000200438e00  x[18] = 0x0000000000000000  x[19] = 0x0000618000000080
x[20] = 0x000060200025b5f0  x[21] = 0x000000000000000d  x[22] = 0x0000621000000100  x[23] = 0x0000000104488400
x[24] = 0x0000000104488200  x[25] = 0x00000001044bbff8  x[26] = 0x00000001044bc000  x[27] = 0x0000000104488000
x[28] = 0x0000000000000000     fp = 0x000000016b9ba330     lr = 0x0000000104447f0c     sp = 0x000000016b9ba260
AddressSanitizer can not provide additional info.
SUMMARY: AddressSanitizer: SEGV test_fuzzy.cpp:8 in DoSomethingWithData(unsigned char const*, unsigned long)
==7057==ABORTING
MS: 3 CMP-InsertByte-CMP- DE: "\012\000\000\000"-"o\000"-; base unit: 428b50c9cb33d129aaf98b190836a5052a1859a8
0x68,0x65,0x6c,0x6c,0x6f,0x0,0xa,0xff,0xa,0x0,0x0,0xa,0x0,
hello\000\012\377\012\000\000\012\000
artifact_prefix='./'; Test unit written to ./crash-a27ccd37d9bf8363d556137baf72042fd37165dc
Base64: aGVsbG8ACv8KAAAKAA==
zsh: abort      ./test_fuzzy
```

在输出的最后，我们可以看到 `artifact_prefix='./'; Test unit written to ./crash-a27ccd37d9bf8363d556137baf72042fd37165dc`，将造成崩溃的测试用例写入到文件 `./crash-a27ccd37d9bf8363d556137baf72042fd37165dc`中了。
我们可以直接查看这个用例的输入：

```bash
cat ./crash-a27ccd37d9bf8363d556137baf72042fd37165dc
hello
```

当然，输出的信息中，也指出了程序崩溃的原因和代码行数，结合错误的 case，我们很容易能够复现和修复问题。
