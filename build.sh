#!/bin/bash
# 记得在终端执行: chmod +x build.sh

echo ">>> 清理旧文件..."
make clean

#echo ">>> 正在编译 Rootful (有根) 版本..."
#make package

#echo ">>> 正在编译 Roothide (隐藏越狱) 版本..."
#make package THEOS_PACKAGE_SCHEME=roothide

echo ">>> 正在编译 Rootless (无根) 版本..."
make package THEOS_PACKAGE_SCHEME=rootless

echo ">>> 编译完成！所有版本已生成。"