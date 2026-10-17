/*
 * rg_date_filter.h — 个人主页短片「发布时间」过滤内核
 *
 * 纯 C，无 Foundation 依赖，方便在 iOS 工程里直接调用，也方便在
 * 非苹果环境下跑单元测试（见 tests.c）。
 *
 * 规则：
 *   days > 0   只保留 最近 days 天内 发布的短片（age <= days）
 *   days < 0   只保留 早于 |days| 天 发布的短片（age > |days|）
 *   days == 0  关闭过滤
 *   小数点    支持（0.5 = 12 小时）
 */

#ifndef RG_DATE_FILTER_H
#define RG_DATE_FILTER_H

#include <stddef.h>

typedef enum {
    RGDateFilterOff = 0,
    RGDateFilterNewer,   /* 只看最近 N 天 */
    RGDateFilterOlder    /* 只看 N 天以前 */
} RGDateFilterMode;

typedef struct {
    RGDateFilterMode mode;
    double days;         /* 始终 >= 0 */
} RGDateFilter;

/* 解析结果 */
typedef enum {
    RGParseOK = 0,
    RGParseEmpty,        /* 空输入 → 关闭过滤 */
    RGParseInvalid,      /* 非法字符 / 多个小数点 / nan / inf */
    RGParseTooLarge,     /* 绝对值超过上限（365 天 = 1 年） */
    RGParseTooSmall,     /* 0 < 绝对值 < 1 分钟 */
    RGParseZero          /* 解析为 0 → 关闭过滤 */
} RGParseResult;

#define RG_FILTER_MAX_DAYS 365.0
#define RG_FILTER_MIN_DAYS (1.0 / 1440.0)
#define RG_SECONDS_PER_DAY 86400.0

/*
 * 解析用户输入的天数。
 * 允许：前后空格、+/- 号、一个 '.'、全角负号 '－'、全角句点 '．'。
 * 不接受：逗号小数（0,5）、多个小数点、科学计数法、任何尾部杂字符。
 * 成功时写入 *out（原值，可为负）与 *filter。
 */
RGParseResult rg_parse_days(const char *input, double *out, RGDateFilter *filter);

/* 由已解析的天数构造过滤器 */
RGDateFilter rg_filter_make(double days);

/* 给定作品年龄（秒，>= 0），判断是否应保留 */
int rg_filter_should_keep(RGDateFilter filter, double age_seconds);

/* 判断是否处于「空结果」状态，用于分页保护：
 * 当一页作品全部被过滤时，客户端应停止自动翻页，
 * 否则会无限请求下一页。返回 1 = 应停止自动翻页。 */
int rg_should_stop_pagination(RGDateFilter filter, size_t page_count, size_t kept_count);

#endif /* RG_DATE_FILTER_H */
