//
//  WCAIObfuscate.h  —  字符串分片（防 strings/内存扫描直接命中产品名）
//  说明：相邻字面量 @"a" @"b" 会被编译器合并成单个常量，因此必须走运行时拼接。
//

#ifndef WCAI_OBFUSCATE_H
#define WCAI_OBFUSCATE_H

#import <Foundation/Foundation.h>

/// 分片拼接：编译产物里不出现完整字符串
#define WCAI_JOIN3(a,b,c) [NSString stringWithFormat:@"%@%@%@", a, b, c]
#define WCAI_JOIN2(a,b)   [NSString stringWithFormat:@"%@%@", a, b]

/// 自身 dylib 名（用于文件系统过滤）——切忌写成完整字面量
static inline NSString *WCAISelfDylibName(void) {
    return WCAI_JOIN3(@"libmars", @"bridge", @".dylib");
}

/// 自身 image 名后缀（用于 dyld 枚举过滤）
static inline NSString *WCAISelfImageHint(void) {
    return WCAI_JOIN2(@"mars", @"bridge");
}

#endif
