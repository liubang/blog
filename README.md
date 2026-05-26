## My Personal Blog

![Build Status](https://github.com/liubang/blog/actions/workflows/gh-pages.yml/badge.svg?branch=main)

This blog is built with Hugo and the DoIt theme.

### Local development

Requirements:

- Hugo extended
- Go 1.21+
- Node.js and npm

Common setup:

```bash
make init
make run
```

Production build:

```bash
make build
```

### Upgrade theme

```bash
make update
git add themes/DoIt
git commit -m 'Bump theme to [version]'
```
