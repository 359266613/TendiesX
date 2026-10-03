//
//  TXPosterStoreProbe.h
//  一次性把系统 PosterBoard 海报存储的目录结构写进日志。
//
//  用途：ca 型 .tendies 里是 CoreAnimation(.ca/CAAML + JS) 包，自己渲染成本很高；
//  更稳的路子是像 Nugget 那样把 descriptors/<UUID> 安装进系统的海报存储，
//  由 SpringBoard 原生渲染。这个探测就是用来确定「到底该写到哪里」。
//
//  拿到目录结构后即可实现安装逻辑，之后本文件可删除。
//

#import <Foundation/Foundation.h>

FOUNDATION_EXPORT void TXProbePosterStore(void);
