// dsh_hello_service.cpp — zeroaosp M1 冒烟用最小 native 服务（占位名 dsh_hello_service）
//
// 同一份源码支撑四种构建形态，用于分步验证"自研服务能不能被编出来、能不能起来、能不能被观测到"：
//   1) host 自测        : g++ -DDSH_BUILD_HOST=1                       → 证明进程能起来（CI 的 x86_64 host 上直接跑）
//   2) NDK 纯目标       : clang++ (无 binder 宏)                        → 证明能编成 Android ELF
//   3) NDK + libbinder_ndk: clang++ -DDSH_WITH_BINDER_NDK=1 -lbinder_ndk → **真的向 servicemanager 注册服务**
//                          （NDK 自带 libbinder_ndk，不需要 AOSP 树；这样 service list 能列出我们）
//   4) Soong/AOSP       : Android.bp 里 -DDSH_WITH_BINDER=1            → 用 C++ 版 libbinder（需要完整树，磁盘不允许）
//
// 常驻语义：Android 构建（2/3/4）默认常驻（供 ps / service list / dumpsys 观测）；加 --selftest 则打印后退出。
#include <cstdio>
#include <cstring>
#include <ctime>
#include <unistd.h>

#if defined(DSH_WITH_BINDER_NDK)
#include <android/binder_ibinder.h>
#include <android/binder_manager.h>
#include <android/binder_status.h>
#elif defined(DSH_WITH_BINDER)
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
#elif defined(DSH_WITH_BINDER_NDK)
    "android-ndk-libbinder_ndk";
#elif defined(DSH_WITH_BINDER)
    "android-soong-binder";
#else
    "android-ndk-stub";
#endif

#if defined(DSH_WITH_BINDER_NDK)
static void* NdkOnCreate(void* /*args*/) { return nullptr; }
static void NdkOnDestroy(void* /*userData*/) {}
static bool NdkOnTransact(AIBinder* /*binder*/, transaction_code_t /*code*/, const AParcel* /*in*/, AParcel* /*out*/) {
    return false;  // 本冒烟版只验证"注册 + 存活"，业务 transaction 留待插件框架
}
#elif defined(DSH_WITH_BINDER)
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

#if defined(DSH_WITH_BINDER_NDK)
    AIBinder_Class* clazz = AIBinder_Class_define("zeroaosp.dsh.IHelloService", NdkOnCreate, NdkOnDestroy, NdkOnTransact);
    if (clazz == nullptr) {
        printf("[%s] AIBinder_Class_define FAILED\n", kServiceName);
        return 2;
    }
    AIBinder* binder = AIBinder_new(clazz, nullptr);
    binder_status_t st = AServiceManager_addService(binder, kServiceName);
    printf("[%s] AServiceManager_addService(%s) -> %d (0=OK)\n", kServiceName, kServiceName, (int)st);
    fflush(stdout);
    if (selftest) {
        printf("[%s] selftest done: addService_rc=%d\n", kServiceName, (int)st);
        return st == STATUS_OK ? 0 : 3;
    }
    for (;;) sleep(2);  // 常驻：供 ps -A / service list 观测
#elif defined(DSH_WITH_BINDER)
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
        printf("[%s] selftest OK: process starts, no-binder build (registration path is compiled in the binder variants)\n",
               kServiceName);
        return 0;
    }
#if defined(DSH_BUILD_HOST)
    for (int i = 0; i < 3; ++i) {
        printf("[%s] tick %d\n", kServiceName, i);
        fflush(stdout);
        sleep(1);
    }
    printf("[%s] exiting (host no-binder build)\n", kServiceName);
    return 0;
#else
    printf("[%s] serving (no-binder build) — staying alive for ps observation\n", kServiceName);
    fflush(stdout);
    for (;;) sleep(2);
#endif
#endif
}
