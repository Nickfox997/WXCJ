//
//  WCAIFishhook.h  —  精简 GOT 重绑定（仅 arm64，仅 __got / __la_symbol_ptr）
//  用途：把 _dyld_image_count / _dyld_get_image_name 换成过滤版
//  风险：改错段会直接崩微信 —— 因此默认关闭（WCAI_ENABLE_GOT_PATCH=0）
//

#ifndef WCAI_FISHHOOK_H
#define WCAI_FISHHOOK_H

#ifdef __cplusplus
extern "C" {
#endif

/// 把名为 name 的导入符号在指定 image 内全部替换为 replacement。
/// outOriginal 返回被替换掉的原函数指针（全部一致时）。
/// 返回成功替换的指针个数。
int wcai_rebind_symbol(const char *name, void *replacement, void **outOriginal);

#ifdef __cplusplus
}
#endif

#endif
