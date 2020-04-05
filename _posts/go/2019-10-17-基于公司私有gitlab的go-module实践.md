---
layout: article
title: 基于公司私有gitlab的go module实践
tags: [go]
category: go
---

## 背景

我们 laser 存储为了更好的跟引擎对接，适应其他团队的技术生态，决定开发一套 golang 的公共库来给大家使用。于是我们在公司私有的 gitlab 上新建了一个项目:git.yourcomp.com/ad/ads_core/adgo，并且我们想使用单一的 codebase 来管理所有的公共 library.

而且，为了更好的管理模块，我们统一使用了 go mod。

按照平时我们在 github 上拉取 go library 的惯例，我本以为直接使用`go get git.yourcomp.com/ad/ads_core/adgo/xxx`就能直接拉取到相应的模块了，然而在开发完功能测试的时候却发现，事实并不是想象中那样。

## 遇到的问题和解决方案

### 1. 仓库问题

执行`go get`后，实际上会请求"https://git.yourcomp.com/ad/ads_core/adgo?go-get=1"这个地址，如果使用`-insecure`选项，则会请求"http://git.yourcomp.com/ad/ads_core/adgo?go-get=1"，正常情况下回返回meta tag：

```html
<html>
  <head>
    <meta
      name="go-import"
      content="git.yourcomp.com/ad/ads_core git http://git.yourcomp.com/ad/ads_core.git"
    />
  </head>
</html>
```

这是 go remote import 的协议，meta tag 的格式一般为

```html
<meta name="go-import" content="import-prefix vcs repo-root" />
```

由于 gitlab 的版本问题，如果使用了 subgroup，则不能正确返回 meta tag。也就是说，我们使用的 gitlab 版本只支持一层 namespace 下建的项目。而"ad/ads_core/adgo"就是两层 namespace，所以 meta tag 中返回的 repo 地址是"http://git.yourcomp.com/ad/ads_core.git"显然是错的。于是我们又对代码库进行了迁移。

### 2. 权限问题

获取正确的 meta tag 后，通过对应的版本控制工具下载 repo。所以我们这里最终会转换成使用`git clone ...`来获取代码。由于是私有的 git 仓库，所以会遇到 clone 时需要输入用户名和密码的情况。

其实这个问题，我们首先会想到的是，如何把通过 https 的方式获取代码变成通过 ssh 的方式，这样就可以配置公钥免密码拉取。其实这个实现起来并不难，只需要在`.gitconfig`中添加一行配置就可以：

```
[url "ssh://git@git.yourcomp.com:2222"]
    insteadOf = http://git.yourcomp.com
```

这个配置就是将 http 形式的的请求，转换成 ssh 的形式。

### 3. 版本号问题

由于我们使用的单一的 codebase，对代码仓库打 tag 不能用来标识内部单个 library 的版本，而且内部 library 之间还存在依赖关系，所以这里就需要 Pseudo-versions，具体格式如下：

```
vX.0.0-yyyymmddhhmmss-abcdefabcdef
```

其中"abcdefabcdef"是 commit hash，而"yyyymmddhhmmss"是该 commit 的 UTC 时间，特别注意是 UTC 时间，跟我们所在的东八区相差 8 个小时。

为了方便，一般我们查看某个 commit 和 UTC 时间的话，需要使用`TZ=UTC git log`，获取 12 位的 commit id 也可以使用如下命令：

```
TZ=UTC git log -n 20 --pretty="format:%C(auto)%h %ad %C(auto)%s%d  %Cblue(%an)" --decorate --abbrev=12 --abbrev-commit --date=local
```

## 参考文档

[Support for Go remote import](https://gitlab.com/gitlab-org/gitlab-foss/issues/1337)

[Pseudo_versions](https://golang.org/cmd/go/#hdr-Pseudo_versions)
