#ifndef STELLARSCOPE_NATIVE_H
#define STELLARSCOPE_NATIVE_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    char id[96];
    char title[96];
    char category[48];
    char unit[24];
    char source[64];
    char rawKey[96];
    char text[192];
    double value;
    int hasValue;
    int isExperimental;
} SSNativeMetric;

int StellarScopeCollectNativeAdvanced(SSNativeMetric *metrics, int capacity);
const char *StellarScopeNativeMetricID(const SSNativeMetric *metric);
const char *StellarScopeNativeMetricTitle(const SSNativeMetric *metric);
const char *StellarScopeNativeMetricCategory(const SSNativeMetric *metric);
const char *StellarScopeNativeMetricUnit(const SSNativeMetric *metric);
const char *StellarScopeNativeMetricSource(const SSNativeMetric *metric);
const char *StellarScopeNativeMetricRawKey(const SSNativeMetric *metric);
const char *StellarScopeNativeMetricText(const SSNativeMetric *metric);

#ifdef __cplusplus
}
#endif

#endif
