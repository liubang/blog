## My Personal Blog

![Build Status](https://github.com/liubang/blog/actions/workflows/gh-pages.yml/badge.svg?branch=main)

This blog built on top of Hugo and the HBS theme.

### Upgrade theme

```bash
hugo mod get -u ./...
hugo mod tidy
hugo mod npm pack
npm install
git add go.mod go.sum package.hugo.json package.json package-lock.json
git commit -m 'Bump theme to [version]'
```
