#import <Foundation/Foundation.h>
#import <errno.h>
#import <stdint.h>
#import <stdio.h>
#import <string.h>
#import <sys/sysctl.h>
#import <unistd.h>

#ifndef MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT
#define MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT 6
#endif

extern int memorystatus_control(uint32_t command, int32_t pid, uint32_t flags, void *buffer, size_t buffersize);

#ifndef PROC_ALL_PIDS
#define PROC_ALL_PIDS 1
#endif

#ifndef PROC_PIDPATHINFO_MAXSIZE
#define PROC_PIDPATHINFO_MAXSIZE 4096
#endif

extern int proc_listpids(uint32_t type, uint32_t typeinfo, void *buffer, int buffersize);
extern int proc_name(int pid, void *buffer, uint32_t buffersize);

static void LALog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    FILE *file = fopen("/tmp/LiquidAss.log", "a");
    if (!file) return;
    fprintf(file, "[LiquidAss] %s\n", message.UTF8String ?: "");
    fclose(file);
}

static uint64_t LAPhysicalMemoryBytes(void) {
    uint64_t memsize = 0;
    size_t size = sizeof(memsize);
    if (sysctlbyname("hw.memsize", &memsize, &size, NULL, 0) == 0 && memsize > 0) {
        return memsize;
    }
    return (uint64_t)[NSProcessInfo processInfo].physicalMemory;
}

static pid_t LASpringBoardPID(void) {
    int bufferSize = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (bufferSize <= 0) return -1;

    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)bufferSize];
    int bytes = proc_listpids(PROC_ALL_PIDS, 0, data.mutableBytes, (int)data.length);
    if (bytes <= 0) return -1;

    int count = bytes / (int)sizeof(pid_t);
    pid_t *pids = (pid_t *)data.bytes;
    for (int i = 0; i < count; i++) {
        pid_t pid = pids[i];
        if (pid <= 0) continue;

        char name[PROC_PIDPATHINFO_MAXSIZE] = {0};
        if (proc_name(pid, name, sizeof(name)) <= 0) continue;
        if (strcmp(name, "SpringBoard") == 0) return pid;
    }
    return -1;
}

int main(int argc, char *argv[], char *envp[]) {
    @autoreleasepool {
        uint64_t physicalBytes = LAPhysicalMemoryBytes();
        if (physicalBytes == 0) {
            LALog(@"jetsam helper skipped: unable to read physical memory");
            return 1;
        }

        uint64_t limitMB64 = (physicalBytes + (1024ULL * 1024ULL - 1ULL)) / (1024ULL * 1024ULL);
        if (limitMB64 > (uint64_t)INT32_MAX) limitMB64 = (uint64_t)INT32_MAX;
        uint32_t limitMB = (uint32_t)limitMB64;

        pid_t pid = -1;
        for (int attempt = 0; attempt < 30; attempt++) {
            pid = LASpringBoardPID();
            if (pid > 0) break;
            usleep(1000000);
        }

        if (pid <= 0) {
            LALog(@"jetsam helper skipped: SpringBoard pid not found limit=%uMB", limitMB);
            return 2;
        }

        errno = 0;
        int result = memorystatus_control(MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT, pid, limitMB, NULL, 0);
        int savedErrno = errno;
        if (result != 0) {
            LALog(@"jetsam helper failed pid=%d physical=%lluMB limit=%uMB task=%d errno=%d",
                  pid,
                  physicalBytes / (1024ULL * 1024ULL),
                  limitMB,
                  result,
                  savedErrno);
        }

        return result == 0 ? 0 : savedErrno;
    }
}
