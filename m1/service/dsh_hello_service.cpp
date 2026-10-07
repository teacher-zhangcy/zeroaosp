// dsh_hello_service.cpp — zeroaosp M1 冒烟用最小 native 服务（占位名 dsh_hello_service）
//
// 同一份源码支撑三种构建形态，用于分步验证"自研服务能不能被编出来、能不能起来"：
//   1) host 自测   : g++ -DDSH_BUILD_HOST=1 ...            → 证明进程能起来（在 CI 的 x86_64 host 上直接跑）
//   2) NDK 目标构建: clang++ --target=aarch64-linux-android26 → 证明能编成 Android ELF（可 adb push 的产物）
//   3) Soong/AOSP  : Android.bp 里开 -DDSH_WITH_BINDER=1    → 真正向 servicemanager 注册 Binder 服务
//                                                            （此形态需要完整 AOSP 树，磁盘不允许；本仓先给出 .bp 素材）
//
// 设计约束（对齐 AOSP 惯例）：服务名与二进制名一致；注册到 servicemanager；实现 dump() 以便 dumpsys 观测。
#include <cstdio>
#include <cstring>
#include <ctime>
#include <unistd.h>

#if defined(DSH_WITH_BINDER)
#include <binder/Binder.h>
#include <binder/IPCThreadState.h>
#include <binder/IServiceManager.h>
#include <binder/ProcessState.h>
#include <utils/String8.h>
#include <utils/String16.h>
#endif

static const char kServiceName[] = "dsh_hello_service";

static const char* kBuildKind =
#if defined(DSH_BUILD_HOST)
    "host-selftest";
#elif defined(DSH_WITH_BINDER)
    "android-soong-binder";
#else
    "android-ndk-stub";
#endif

#if defined(DSH_WITH_BINDER)
class HelloService : public android::BBinder {
public:
    const android::String16& getInterfaceDescriptor() const override {
        static const android::String16 desc(kServiceName);
        return desc;
    }
    android::status_t dump(int fd, const android::Vector<android::String16>& /*args*/) override {
        android::String8 out;
        out.appendFormat("zeroaosp %s (%s)\n", kServiceName, kBuildKind);
        out.appendFormat("pid=%d uid=%d\n", (int)getpid(), (int)getuid());
        return write(fd, out.string(), out.size()) < 0 ? android::UNKNOWN_ERROR : android::OK;
    }
};
#endif

int main(int argc, char** argv) {
    const bool selftest = (argc > 1 && strcmp(argv[1], "--selftest") == 0);
    printf("[%s] build=%s pid=%d uid=%d\n", kServiceName, kBuildKind, (int)getpid(), (int)getuid());
    fflush(stdout);

#if defined(DSH_WITH_BINDER)
    android::ProcessState::self()->setThreadPoolMaxThreadCount(0);
    android::sp<android::IServiceManager> sm = android::defaultServiceManager();
    const android::status_t st =
            sm->addService(android::String16(kServiceName), new HelloService(), false /*allowIsolated*/);
    printf("[%s] addService(%s) -> %d\n", kServiceName, kServiceName, (int)st);
    fflush(stdout);
    if (st != android::OK) return 3;
    if (selftest) {
        printf("[%s] selftest OK: registered with servicemanager\n", kServiceName);
        return 0;
    }
    android::ProcessState::self()->startThreadPool();
    android::IPCThreadState::self()->joinThreadPool();
    return 0;
#else
    if (selftest) {
        printf("[%s] selftest OK: process starts, no-binder build (registration path is compiled in the Soong variant)\n",
               kServiceName);
        return 0;
    }
    for (int i = 0; i < 3; ++i) {
        printf("[%s] tick %d\n", kServiceName, i);
        fflush(stdout);
        sleep(1);
    }
    printf("[%s] exiting: no-binder build (this variant is for toolchain/packaging validation)\n", kServiceName);
    return 0;
#endif
}
