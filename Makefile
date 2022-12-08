#======================================================================
#
# Makefile -
#
# Created by liubang on 2022/12/09 00:28
# Last Modified: 2022/12/09 00:28
#
#======================================================================

run:
	hugo serve

update:
	hugo mod get -u ./...
	hugo mod tidy
	hugo mod npm pack
	npm install
