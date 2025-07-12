#!/bin/bash

convert -draw 'text 5,5 "@liubang.github.io/blog"' -fill 'rgba(221, 34, 17, 0.25)' -pointsize 18 -gravity southeast $1 $2
