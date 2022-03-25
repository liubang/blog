#!/bin/bash

convert -draw 'text 5,5 "@iliubang.cn"' -fill 'rgba(221, 34, 17, 0.25)' -pointsize 18 -gravity southeast $1 $2
